import hmac
import json
import os
import re
import time

import boto3
from botocore.exceptions import ClientError

ec2 = boto3.client('ec2')
table = boto3.resource('dynamodb').Table(os.environ['LEASE_TABLE'])
INSTANCE_ID = os.environ['INSTANCE_ID']
TOKEN = os.environ['CONTROL_TOKEN']
LEASE_SECONDS = 180
CLIENT_ID_RE = re.compile(r'^[a-f0-9-]{36}$')


def response(status, body):
    return {'statusCode': status, 'headers': {'content-type': 'application/json', 'cache-control': 'no-store'},
            'body': json.dumps(body)}


def client_id(event, body):
    value = body.get('clientId') or (event.get('queryStringParameters') or {}).get('clientId')
    return value if isinstance(value, str) and CLIENT_ID_RE.fullmatch(value) else None


def renew_lease(value):
    table.put_item(Item={'clientId': value, 'expiresAt': int(time.time()) + LEASE_SECONDS})


def instance_state():
    result = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return result['Reservations'][0]['Instances'][0]['State']['Name']


def start_if_stopped():
    state = instance_state()
    if state == 'stopped':
        try:
            ec2.start_instances(InstanceIds=[INSTANCE_ID])
            state = 'pending'
        except ClientError as error:
            if error.response['Error']['Code'] not in ('IncorrectInstanceState', 'OperationNotPermitted'):
                raise
            state = instance_state()
    return state


def cleanup_expired_leases():
    now = int(time.time())
    active = table.scan(ProjectionExpression='clientId, expiresAt')['Items']
    if any(int(item['expiresAt']) > now for item in active):
        return {'activeLeases': sum(int(item['expiresAt']) > now for item in active), 'stopped': False}
    state = instance_state()
    if state == 'running':
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        return {'activeLeases': 0, 'stopped': True}
    return {'activeLeases': 0, 'stopped': False}


def handler(event, context):
    if event.get('source') == 'aws.events':
        return cleanup_expired_leases()

    headers = {str(key).lower(): value for key, value in (event.get('headers') or {}).items()}
    supplied = headers.get('authorization', '').removeprefix('Bearer ').strip()
    if not hmac.compare_digest(supplied, TOKEN):
        return response(401, {'error': 'unauthorized'})

    method = event.get('requestContext', {}).get('http', {}).get('method', '').upper()
    path = event.get('rawPath', '')
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, json.JSONDecodeError):
        return response(400, {'error': 'invalid JSON'})
    value = client_id(event, body)
    if path not in ('/health',) and not value:
        return response(400, {'error': 'clientId must be a UUID'})

    try:
        if path == '/health' and method == 'GET':
            return response(200, {'ok': True})
        if path == '/connect' and method == 'POST':
            renew_lease(value)
            state = start_if_stopped()
            return response(200, {'state': state})
        if path == '/status' and method == 'GET':
            renew_lease(value)
            state = start_if_stopped()
            return response(200, {'state': state})
        if path == '/heartbeat' and method == 'POST':
            renew_lease(value)
            return response(200, {'ok': True})
        if path == '/disconnect' and method == 'POST':
            table.delete_item(Key={'clientId': value})
            return response(200, {'ok': True})
        return response(404, {'error': 'not found'})
    except (ClientError, KeyError, IndexError) as error:
        print('Control request failed:', type(error).__name__)
        return response(503, {'error': 'service temporarily unavailable'})
