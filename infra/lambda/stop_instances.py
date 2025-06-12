import boto3
import os
import logging

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get('AWS_REGION')
ASG_NAME = os.environ.get('ASG_NAME')

if not REGION:
    logger.error("AWS_REGION environment variable not set.")
    raise ValueError("AWS_REGION environment variable not set.")
if not ASG_NAME:
    logger.error("ASG_NAME environment variable not set.")
    raise ValueError("ASG_NAME environment variable not set.")

autoscaling_client = boto3.client('autoscaling', region_name=REGION)

def lambda_handler(event, context):
    """
    This function sets the MinSize and DesiredCapacity of the specified
    Auto Scaling Group (ASG) to 0. This effectively scales down the ASG
    and terminates its instances for the scheduled "off" period.
    """
    logger.info(f"Attempting to scale down Auto Scaling Group: {ASG_NAME}")

    try:
        autoscaling_client.update_auto_scaling_group(
            AutoScalingGroupName=ASG_NAME,
            MinSize=0,
            DesiredCapacity=0
        )
        success_message = f"Successfully set MinSize and DesiredCapacity to 0 for ASG: {ASG_NAME}"
        logger.info(success_message)
    except Exception as e:
        error_message = f"Error updating ASG '{ASG_NAME}': {str(e)}"
        logger.error(error_message)
        raise e # Re-raise the exception to indicate failure to Lambda

    return {
        'statusCode': 200,
        'body': success_message
    }