import boto3
import os
from datetime import datetime, timedelta, timezone

S3_BUCKET_NAME = os.environ['S3_BUCKET_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
ALERT_DAYS_BEFORE_EXPIRATION = int(os.environ.get('ALERT_DAYS_BEFORE_EXPIRATION', 7))
LIFECYCLE_EXPIRATION_DAYS = int(os.environ.get('LIFECYCLE_EXPIRATION_DAYS', 365))

s3 = boto3.client('s3')
sns = boto3.client('sns')

def lambda_handler(event, context):
    today = datetime.now(timezone.utc)
    notifications = []
    print(f"Checking bucket '{S3_BUCKET_NAME}' for objects nearing {LIFECYCLE_EXPIRATION_DAYS}-day expiration, with a {ALERT_DAYS_BEFORE_EXPIRATION}-day alert window.")

    try:
        paginator = s3.get_paginator('list_objects_v2')
        for page in paginator.paginate(Bucket=S3_BUCKET_NAME):
            if 'Contents' not in page:
                continue
            for obj in page['Contents']:
                object_key = obj['Key']
                # LastModified is already timezone-aware (UTC)
                last_modified = obj['LastModified']

                # Calculate potential expiration date based on lifecycle rule
                potential_expiration_date = last_modified + timedelta(days=LIFECYCLE_EXPIRATION_DAYS)
                
                # Calculate when the alert period starts
                alert_start_date = potential_expiration_date - timedelta(days=ALERT_DAYS_BEFORE_EXPIRATION)

                if alert_start_date <= today < potential_expiration_date:
                    days_to_expire = (potential_expiration_date - today).days
                    message_body = (
                        f"S3 Object Alert:\n"
                        f"Bucket: {S3_BUCKET_NAME}\n"
                        f"Object Key: {object_key}\n"
                        f"Last Modified: {last_modified.strftime('%Y-%m-%d %H:%M:%S %Z')}\n"
                        f"Scheduled for deletion in approximately: {days_to_expire} day(s) (around {potential_expiration_date.strftime('%Y-%m-%d')})."
                    )
                    notifications.append({
                        "object_key": object_key,
                        "message": message_body,
                    })
                    print(f"Alert for object: {object_key}, expires around: {potential_expiration_date.strftime('%Y-%m-%d')}")

        if notifications:
            subject = f"[{len(notifications)}] S3 Object(s) Nearing Expiration in Bucket: {S3_BUCKET_NAME}"
            consolidated_message = f"The following S3 object(s) in bucket '{S3_BUCKET_NAME}' are nearing their {LIFECYCLE_EXPIRATION_DAYS}-day lifecycle expiration:\n\n"
            consolidated_message += "\n\n---\n\n".join([n['message'] for n in notifications])
            
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Message=consolidated_message,
                Subject=subject
            )
            print(f"Published {len(notifications)} alert(s) to SNS topic {SNS_TOPIC_ARN}")
        else:
            print("No objects found nearing expiration within the alert window.")

    except Exception as e:
        print(f"Error processing S3 expiration alerts: {e}")
        raise e

    return {
        'statusCode': 200,
        'body': f'Processed. Found {len(notifications)} object(s) nearing expiration.'
    }