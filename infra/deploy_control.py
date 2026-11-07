import io
import json
import secrets
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'out' / 'aws-sdk'))
import boto3
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
REGION = 'ap-east-1'
FUNCTION = 'dongvpn-hk-control'
ROLE = 'dongvpn-hk-control-role'
TABLE = 'dongvpn-hk-leases'
RULE = 'dongvpn-hk-stop-idle'
CONFIG_PATH = ROOT / 'out' / 'hk-control.json'
INSTANCE = json.loads((ROOT / 'out' / 'hong-kong.json').read_text(encoding='utf-8'))['instanceId']
lambda_client = boto3.client('lambda', region_name=REGION)
iam = boto3.client('iam')
dynamodb = boto3.client('dynamodb', region_name=REGION)
events = boto3.client('events', region_name=REGION)


def ignore_missing(error, code):
    return error.response.get('Error', {}).get('Code') == code


def ensure_table():
    try:
        dynamodb.describe_table(TableName=TABLE)
    except ClientError as error:
        if not ignore_missing(error, 'ResourceNotFoundException'):
            raise
        dynamodb.create_table(TableName=TABLE,
                              AttributeDefinitions=[{'AttributeName': 'clientId', 'AttributeType': 'S'}],
                              KeySchema=[{'AttributeName': 'clientId', 'KeyType': 'HASH'}],
                              BillingMode='PAY_PER_REQUEST',
                              Tags=[{'Key': 'Project', 'Value': 'DongVPN'}])
        dynamodb.get_waiter('table_exists').wait(TableName=TABLE)
    current = dynamodb.describe_time_to_live(TableName=TABLE)['TimeToLiveDescription']['TimeToLiveStatus']
    if current in ('DISABLED', 'ENABLED', 'ENABLING'):
        if current == 'DISABLED':
            dynamodb.update_time_to_live(TableName=TABLE,
                                         TimeToLiveSpecification={'Enabled': True, 'AttributeName': 'expiresAt'})


def ensure_role(instance_arn, table_arn):
    trust = {'Version': '2012-10-17', 'Statement': [{
        'Effect': 'Allow', 'Principal': {'Service': 'lambda.amazonaws.com'}, 'Action': 'sts:AssumeRole'}]}
    try:
        role = iam.get_role(RoleName=ROLE)['Role']
    except ClientError as error:
        if not ignore_missing(error, 'NoSuchEntity'):
            raise
        role = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(trust),
                               Tags=[{'Key': 'Project', 'Value': 'DongVPN'}])['Role']
    policy = {'Version': '2012-10-17', 'Statement': [
        {'Effect': 'Allow', 'Action': ['ec2:DescribeInstances'], 'Resource': '*'},
        {'Effect': 'Allow', 'Action': ['ec2:StartInstances', 'ec2:StopInstances'], 'Resource': instance_arn},
        {'Effect': 'Allow', 'Action': ['dynamodb:PutItem', 'dynamodb:DeleteItem', 'dynamodb:Scan'],
         'Resource': table_arn},
        {'Effect': 'Allow', 'Action': ['logs:CreateLogGroup', 'logs:CreateLogStream', 'logs:PutLogEvents'],
         'Resource': f'arn:aws:logs:{REGION}:*:log-group:/aws/lambda/{FUNCTION}:*'},
    ]}
    iam.put_role_policy(RoleName=ROLE, PolicyName='dongvpn-hk-control', PolicyDocument=json.dumps(policy))
    time.sleep(10)
    return role['Arn']


def package():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(ROOT / 'infra' / 'control' / 'lambda_function.py', 'lambda_function.py')
    return stream.getvalue()


def ensure_function(role_arn, token):
    environment = {'Variables': {'INSTANCE_ID': INSTANCE, 'LEASE_TABLE': TABLE, 'CONTROL_TOKEN': token}}
    code = package()
    try:
        function = lambda_client.get_function(FunctionName=FUNCTION)['Configuration']
        lambda_client.update_function_code(FunctionName=FUNCTION, ZipFile=code, Publish=True)
        lambda_client.get_waiter('function_updated').wait(FunctionName=FUNCTION)
        lambda_client.update_function_configuration(FunctionName=FUNCTION, Role=role_arn, Runtime='python3.12',
                                                    Handler='lambda_function.handler', Timeout=10, MemorySize=128,
                                                    Environment=environment)
        lambda_client.get_waiter('function_updated').wait(FunctionName=FUNCTION)
        return lambda_client.get_function(FunctionName=FUNCTION)['Configuration']['FunctionArn']
    except ClientError as error:
        if not ignore_missing(error, 'ResourceNotFoundException'):
            raise
        created = lambda_client.create_function(FunctionName=FUNCTION, Runtime='python3.12',
                                                Role=role_arn, Handler='lambda_function.handler',
                                                Code={'ZipFile': code}, Timeout=10, MemorySize=128,
                                                Environment=environment,
                                                Tags={'Project': 'DongVPN'})
        lambda_client.get_waiter('function_active').wait(FunctionName=FUNCTION)
        return created['FunctionArn']


def ensure_function_url():
    try:
        return lambda_client.get_function_url_config(FunctionName=FUNCTION)['FunctionUrl']
    except ClientError as error:
        if not ignore_missing(error, 'ResourceNotFoundException'):
            raise
        return lambda_client.create_function_url_config(FunctionName=FUNCTION, AuthType='NONE')['FunctionUrl']


def ensure_public_url_permission():
    try:
        lambda_client.add_permission(FunctionName=FUNCTION, StatementId='DongVPNFunctionURLPublic',
                                     Action='lambda:InvokeFunctionUrl', Principal='*',
                                     FunctionUrlAuthType='NONE')
    except ClientError as error:
        if not ignore_missing(error, 'ResourceConflictException'):
            raise
    try:
        lambda_client.add_permission(FunctionName=FUNCTION, StatementId='DongVPNFunctionURLInvoke',
                                     Action='lambda:InvokeFunction', Principal='*',
                                     InvokedViaFunctionUrl=True)
    except ClientError as error:
        if not ignore_missing(error, 'ResourceConflictException'):
            raise


def ensure_cleanup_schedule(function_arn):
    rule_arn = events.put_rule(Name=RULE, ScheduleExpression='rate(1 minute)', State='ENABLED',
                               Description='Stop the Hong Kong VPN after all client leases expire.',
                               Tags=[{'Key': 'Project', 'Value': 'DongVPN'}])['RuleArn']
    events.put_targets(Rule=RULE, Targets=[{'Id': 'dongvpn-hk-control', 'Arn': function_arn}])
    try:
        lambda_client.add_permission(FunctionName=FUNCTION, StatementId='DongVPNIdleSchedule',
                                     Action='lambda:InvokeFunction', Principal='events.amazonaws.com',
                                     SourceArn=rule_arn)
    except ClientError as error:
        if not ignore_missing(error, 'ResourceConflictException'):
            raise


def check_function_url(url, token):
    result = __import__('subprocess').run(
        ['curl.exe', '--fail', '--silent', '--show-error', '-H', f'Authorization: Bearer {token}', url + 'health'],
        capture_output=True, text=True, timeout=30)
    if result.returncode or json.loads(result.stdout).get('ok') is not True:
        raise RuntimeError('The control endpoint health check failed')


def main():
    CONFIG_PATH.parent.mkdir(exist_ok=True)
    if CONFIG_PATH.exists():
        previous = json.loads(CONFIG_PATH.read_text(encoding='utf-8'))
        token = previous['token']
    else:
        token = secrets.token_urlsafe(32)
    ensure_table()
    account = boto3.client('sts').get_caller_identity()['Account']
    instance_arn = f'arn:aws:ec2:{REGION}:{account}:instance/{INSTANCE}'
    table_arn = f'arn:aws:dynamodb:{REGION}:{account}:table/{TABLE}'
    role_arn = ensure_role(instance_arn, table_arn)
    function_arn = ensure_function(role_arn, token)
    url = ensure_function_url()
    ensure_public_url_permission()
    ensure_cleanup_schedule(function_arn)
    try:
        logs = boto3.client('logs', region_name=REGION)
        logs.put_retention_policy(logGroupName=f'/aws/lambda/{FUNCTION}', retentionInDays=7)
    except ClientError as error:
        if not ignore_missing(error, 'ResourceNotFoundException'):
            raise
    config = {'url': url, 'token': token, 'leaseSeconds': 180}
    CONFIG_PATH.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    check_function_url(url, token)
    print(f'Hong Kong connection control is ready: {url}')
    print('Private client settings are in out/hk-control.json; the token is not printed.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Control service deployment failed: {error}', file=sys.stderr)
        raise
