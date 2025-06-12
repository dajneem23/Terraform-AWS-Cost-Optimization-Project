import boto3
import os

# Define the tag key and value to identify instances to stop.
TAG_KEY = "Schedulable"
TAG_VALUE = "true"
REGION = os.environ['AWS_REGION']

ec2 = boto3.client('ec2', region_name=REGION)

def lambda_handler(event, context):
    """
    This function finds all EC2 instances with the tag 'Schedulable: true'.
    If more than one instance is running, it stops all but one to maintain
    a minimal presence.
    """
    # Find all running instances with the specified tag
    response = ec2.describe_instances(
        Filters=[
            {'Name': f'tag:{TAG_KEY}', 'Values': [TAG_VALUE]},
            {'Name': 'instance-state-name', 'Values': ['running']}
        ]
    )

    running_instance_ids = []
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            running_instance_ids.append(instance['InstanceId'])

    # If we have more than one instance, we will stop all except the first one in the list.
    # The Auto Scaling Group will handle maintaining the desired capacity later if needed.
    instances_to_stop = running_instance_ids[1:]
    
    print(f"Found {len(running_instance_ids)} running instances. Stopping {len(instances_to_stop)} to keep one active.")
    print(f"Instances to be stopped: {', '.join(instances_to_stop)}")

    # Stop the selected instances
    ec2.stop_instances(InstanceIds=instances_to_stop)

    success_message = f"Successfully sent stop command for instances: {', '.join(instances_to_stop)}"
    print(success_message)

    return {
        'statusCode': 200,
        'body': success_message
    }