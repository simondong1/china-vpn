import json
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'out' / 'aws-sdk'))
import boto3
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
REGION = 'ap-east-1'
AZ = 'ap-east-1b'
NAME = 'DongVPN-HongKong'
KEY_NAME = 'dongvpn-hk-key'
SECURITY_GROUP = 'dongvpn-hk'
INSTANCE_STATE = ROOT / 'out' / 'hong-kong.json'
PROFILE_PATH = ROOT / 'out' / 'vpn-hong-kong.vless'
USER_DATA = (ROOT / 'infra' / 'hong-kong-user-data.sh').read_text(encoding='utf-8')
ec2 = boto3.client('ec2', region_name=REGION)


def one_instance(instance_id):
    rows = ec2.describe_instances(InstanceIds=[instance_id])['Reservations']
    return rows[0]['Instances'][0] if rows else None


def ensure_key_pair():
    try:
        ec2.describe_key_pairs(KeyNames=[KEY_NAME])
    except ClientError as error:
        if error.response['Error']['Code'] != 'InvalidKeyPair.NotFound':
            raise
        public_key = (ROOT / 'keys' / 'vpn_key.pub').read_text(encoding='ascii').strip()
        ec2.import_key_pair(KeyName=KEY_NAME, PublicKeyMaterial=public_key.encode('ascii'))


def ensure_network():
    vpcs = ec2.describe_vpcs(Filters=[{'Name': 'isDefault', 'Values': ['true']}])['Vpcs']
    if not vpcs:
        ec2.create_default_vpc()
        vpcs = ec2.describe_vpcs(Filters=[{'Name': 'isDefault', 'Values': ['true']}])['Vpcs']
    vpc_id = vpcs[0]['VpcId']
    subnets = ec2.describe_subnets(Filters=[
        {'Name': 'vpc-id', 'Values': [vpc_id]},
        {'Name': 'availability-zone', 'Values': [AZ]},
        {'Name': 'default-for-az', 'Values': ['true']},
    ])['Subnets']
    if not subnets:
        ec2.create_default_subnet(AvailabilityZone=AZ)
        subnets = ec2.describe_subnets(Filters=[
            {'Name': 'vpc-id', 'Values': [vpc_id]},
            {'Name': 'availability-zone', 'Values': [AZ]},
        ])['Subnets']
    if not subnets:
        raise RuntimeError(f'No public subnet is available in {AZ}')
    return vpc_id, subnets[0]['SubnetId']


def current_public_ip():
    result = subprocess.run(['curl.exe', '--fail', '--silent', 'https://checkip.amazonaws.com'],
                            check=True, capture_output=True, text=True, timeout=20)
    ip = result.stdout.strip()
    if ip.count('.') != 3:
        raise RuntimeError('Could not determine this computer\'s public IPv4 address')
    return ip


def ensure_security_group(vpc_id):
    groups = ec2.describe_security_groups(Filters=[
        {'Name': 'group-name', 'Values': [SECURITY_GROUP]},
        {'Name': 'vpc-id', 'Values': [vpc_id]},
    ])['SecurityGroups']
    if groups:
        group_id = groups[0]['GroupId']
    else:
        group_id = ec2.create_security_group(GroupName=SECURITY_GROUP,
                                             Description='DongVPN Hong Kong endpoint',
                                             VpcId=vpc_id)['GroupId']
        ec2.create_tags(Resources=[group_id], Tags=[{'Key': 'Project', 'Value': 'DongVPN'}])
    for port, cidr in ((443, '0.0.0.0/0'), (22, current_public_ip() + '/32')):
        try:
            ec2.authorize_security_group_ingress(
                GroupId=group_id,
                IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': port, 'ToPort': port,
                                'IpRanges': [{'CidrIp': cidr}]}],
            )
        except ClientError as error:
            if error.response['Error']['Code'] != 'InvalidPermission.Duplicate':
                raise
    return group_id


def latest_ubuntu_ami():
    images = ec2.describe_images(Owners=['099720109477'], Filters=[
        {'Name': 'name', 'Values': ['ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*']},
        {'Name': 'state', 'Values': ['available']},
        {'Name': 'architecture', 'Values': ['x86_64']},
    ])['Images']
    if not images:
        raise RuntimeError('No Ubuntu 24.04 image is available in Hong Kong')
    return max(images, key=lambda item: item['CreationDate'])['ImageId']


def ensure_instance(subnet_id, group_id):
    if INSTANCE_STATE.exists():
        saved = json.loads(INSTANCE_STATE.read_text(encoding='utf-8'))
        try:
            instance = one_instance(saved['instanceId'])
            if instance and instance['State']['Name'] not in ('terminated', 'shutting-down'):
                return instance['InstanceId']
        except ClientError:
            pass
    existing = ec2.describe_instances(Filters=[
        {'Name': 'tag:Name', 'Values': [NAME]},
        {'Name': 'instance-state-name', 'Values': ['pending', 'running', 'stopping', 'stopped']},
    ])['Reservations']
    if existing:
        return existing[0]['Instances'][0]['InstanceId']
    response = ec2.run_instances(
        ImageId=latest_ubuntu_ami(),
        InstanceType='t3.micro',
        MinCount=1,
        MaxCount=1,
        KeyName=KEY_NAME,
        NetworkInterfaces=[{'DeviceIndex': 0, 'SubnetId': subnet_id,
                            'Groups': [group_id], 'AssociatePublicIpAddress': True}],
        BlockDeviceMappings=[{'DeviceName': '/dev/sda1', 'Ebs': {
            'VolumeSize': 8, 'VolumeType': 'gp3', 'Encrypted': True, 'DeleteOnTermination': True,
        }}],
        MetadataOptions={'HttpTokens': 'required', 'HttpEndpoint': 'enabled'},
        TagSpecifications=[{'ResourceType': 'instance', 'Tags': [
            {'Key': 'Name', 'Value': NAME}, {'Key': 'Project', 'Value': 'DongVPN'}]}],
        UserData=USER_DATA,
    )
    return response['Instances'][0]['InstanceId']


def ensure_elastic_ip(instance_id):
    addresses = ec2.describe_addresses(Filters=[{'Name': 'tag:Project', 'Values': ['DongVPN']}])['Addresses']
    if addresses:
        address = addresses[0]
    else:
        address = ec2.allocate_address(Domain='vpc', TagSpecifications=[{
            'ResourceType': 'elastic-ip', 'Tags': [
                {'Key': 'Name', 'Value': NAME}, {'Key': 'Project', 'Value': 'DongVPN'}]}])
    if address.get('InstanceId') != instance_id:
        ec2.associate_address(AllocationId=address['AllocationId'], InstanceId=instance_id,
                              AllowReassociation=True)
    return address['PublicIp']


def ssh_base(ip):
    return ['ssh.exe', '-i', str(ROOT / 'keys' / 'vpn_key'), '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=accept-new', '-o',
            f'UserKnownHostsFile={ROOT / "keys" / "known_hosts-hk"}', '-o', 'ConnectTimeout=5',
            f'ubuntu@{ip}']


def remote_state(ip):
    deadline = time.time() + 300
    while time.time() < deadline:
        result = subprocess.run(ssh_base(ip) + ['sudo', 'cat', '/root/dongvpn-state.env'],
                                capture_output=True, text=True, timeout=12)
        if result.returncode == 0 and 'UUID=' in result.stdout:
            return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        time.sleep(5)
    raise RuntimeError('The Hong Kong host did not finish setup or accept SSH within 5 minutes')


def configure_server(ip):
    subprocess.run(ssh_base(ip) + ['sudo', 'cloud-init', 'status', '--wait'],
                   capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=600)
    result = subprocess.run(ssh_base(ip) + ['sudo', 'bash', '-s'],
                            input=USER_DATA.replace('\r\n', '\n').encode('utf-8'),
                            capture_output=True, timeout=600)
    if result.returncode:
        details = (result.stderr or result.stdout or b'').decode('utf-8', 'replace').strip()[-800:]
        raise RuntimeError('The Hong Kong server setup failed: ' + details)
    deadline = time.time() + 60
    while time.time() < deadline:
        check = subprocess.run(ssh_base(ip) + ['sudo', 'systemctl', 'is-active', 'xray'],
                               capture_output=True, text=True, timeout=12)
        if check.returncode == 0 and check.stdout.strip() == 'active':
            return
        time.sleep(3)
    raise RuntimeError('The Hong Kong Xray service did not become active after setup')


def main():
    (ROOT / 'out').mkdir(exist_ok=True)
    (ROOT / 'keys').mkdir(exist_ok=True)
    ensure_key_pair()
    vpc_id, subnet_id = ensure_network()
    group_id = ensure_security_group(vpc_id)
    instance_id = ensure_instance(subnet_id, group_id)
    instance = one_instance(instance_id)
    if instance['State']['Name'] == 'stopped':
        ec2.start_instances(InstanceIds=[instance_id])
    ec2.get_waiter('instance_running').wait(InstanceIds=[instance_id], WaiterConfig={'Delay': 5, 'MaxAttempts': 60})
    ip = ensure_elastic_ip(instance_id)
    state = remote_state(ip)
    configure_server(ip)
    query = urlencode({'encryption': 'none', 'flow': 'xtls-rprx-vision', 'security': 'reality',
                       'sni': state['SNI'], 'fp': 'chrome', 'pbk': state['PUB'], 'sid': state['SID'], 'type': 'tcp'})
    link = f"vless://{state['UUID']}@{ip}:443?{query}#Hong-Kong"
    PROFILE_PATH.write_text(link + '\n', encoding='utf-8')
    INSTANCE_STATE.write_text(json.dumps({'instanceId': instance_id, 'securityGroupId': group_id,
                                          'elasticIp': ip, 'region': REGION}, indent=2) + '\n', encoding='utf-8')
    print(f'Hong Kong instance ready: {instance_id} at {ip}:443')
    print(f'Profile saved privately to {PROFILE_PATH.relative_to(ROOT)}')
    print('Compute is $0.0146/hour while running; 8 GiB storage and the reserved IPv4 continue billing while stopped.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Hong Kong deployment failed: {error}', file=sys.stderr)
        raise
