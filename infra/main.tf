# main.tf

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "G4DN-Optimization"
      ManagedBy   = "Terraform"
      Environment = "Development"
    }
  }
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# --- RESOURCE: SECURE S3 BUCKET ---
resource "aws_s3_bucket" "main" {
  # bucket_prefix is used to ensure a unique bucket name, as S3 names are global.
  bucket_prefix = "g4dn-scalable-data-"
  acl           = "private"

  # Enforce encryption at rest
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}
# This resource defines rules to automatically manage objects in the main bucket,
# saving costs by transitioning objects to cheaper storage and deleting old ones.
resource "aws_s3_bucket_lifecycle_configuration" "main_lifecycle" {
  # This depends_on is not strictly required as Terraform infers it from the
  # bucket attribute, but it makes the relationship explicit.
  depends_on = [aws_s3_bucket.main]

  bucket = aws_s3_bucket.main.id

  # RULE 1: Transition and Expire regular objects
  rule {
    id     = "TransitionAndExpire"
    status = "Enabled"

    # You could filter this rule to apply only to certain prefixes, e.g.,
    # filter { prefix = "logs/" }
    # Without a filter, it applies to all objects in the bucket.

    # After 30 days, move objects to Standard-Infrequent Access.
    # Good for data that is not accessed often but needs to be available quickly.
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # After 90 days, move objects to Glacier Instant Retrieval.
    # Good for long-term archiving where you still need millisecond access.
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    # After 365 days, permanently delete the objects.
    expiration {
      days = 365
    }
  }

  # RULE 2: Clean up incomplete multipart uploads
  # This is a critical cost-saving measure for buckets that receive large files.
  rule {
    id     = "AbortIncompleteUploads"
    status = "Enabled"

    # Abort and delete failed/incomplete multipart uploads after 7 days.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
# --- STRATEGY: SPOT INSTANCES & AUTO SCALING ---
resource "aws_launch_template" "g4dn_spot_template" {
  name_prefix   = "g4dn-spot-template-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type

  # Attach the IAM role to the instances
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  instance_market_options {
    market_type = "spot"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "g4dn-spot-instance"
      Schedulable = "true" # For our Lambda scheduler
    }
  }
}

resource "aws_autoscaling_group" "g4dn_asg" {
  name                = "g4dn-asg"
  min_size            = 1                     # Always have at least 1 instance.
  max_size            = var.max_num_instances # Allow scaling up to 5 instances.
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public.id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.g4dn_spot_template.id
    version = "$Latest"
  }
}

# --- STRATEGY: DYNAMIC SCALING ---
# Policy to add an instance
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "g4dn-scale-up-policy"
  autoscaling_group_name = aws_autoscaling_group.g4dn_asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300 # Wait 5 minutes before another scale-up event
}

# Policy to remove an instance
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "g4dn-scale-down-policy"
  autoscaling_group_name = aws_autoscaling_group.g4dn_asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300 # Wait 5 minutes before another scale-down event
}

# CloudWatch Alarm to trigger the scale-up policy
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "g4dn-high-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = var.scale_up_cpu_threshold

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.g4dn_asg.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_up.arn]
}

# CloudWatch Alarm to trigger the scale-down policy
resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "g4dn-low-cpu-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = var.scale_down_cpu_threshold

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.g4dn_asg.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_down.arn]
}


# --- STRATEGY: SCHEDULING (AUTOMATED SHUTDOWN) ---
# Resources for the scheduler Lambda (unchanged logic, just moved IAM)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/stop_instances.py"
  output_path = "${path.module}/lambda/stop_instances.zip"
}

resource "aws_lambda_function" "instance_scheduler" {
  function_name    = "EC2InstanceScheduler"
  handler          = "stop_instances.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_scheduler_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  architectures    = ["arm64"]
  environment {
    variables = {
      AWS_REGION = var.aws_region
    }
  }
}

resource "aws_cloudwatch_event_rule" "daily_stop" {
  name                = "daily-ec2-stop-rule"
  schedule_expression = "cron(0 18 ? * MON-FRI *)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_stop.name
  target_id = "StopEC2Instances"
  arn       = aws_lambda_function.instance_scheduler.arn
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.instance_scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_stop.arn
}


# --- STRATEGY: GOVERNANCE (BUDGETS) ---
resource "aws_budgets_budget" "monthly_total" {
  name         = "monthly-total-cost-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }
}

# --- STRATEGY: S3 OBJECT EXPIRATION ALERTS ---

# SNS Topic for S3 expiration alerts
resource "aws_sns_topic" "s3_expiration_alerts" {
  name = "s3-object-expiration-alerts-topic"
  tags = {
    Description = "SNS topic for alerts about S3 objects nearing lifecycle expiration"
  }
}

# Subscribe an email endpoint to the SNS topic
resource "aws_sns_topic_subscription" "s3_expiration_email_alert_subscription" {
  topic_arn = aws_sns_topic.s3_expiration_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email # Reusing the existing notification email variable
}

# Package the S3 expiration alerter Lambda function
data "archive_file" "s3_expiration_alerter_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/s3_expiration_alerter.py"
  output_path = "${path.module}/lambda/s3_expiration_alerter.zip" # Terraform will create this zip
}

# Lambda function to check for S3 objects nearing expiration
resource "aws_lambda_function" "s3_expiration_alerter" {
  function_name    = "S3ObjectExpirationAlerter"
  handler          = "s3_expiration_alerter.lambda_handler" # filename.handler_function
  runtime          = "python3.9"
  role             = aws_iam_role.s3_expiration_alerter_lambda_role.arn # Defined in iam.tf
  filename         = data.archive_file.s3_expiration_alerter_zip.output_path
  source_code_hash = data.archive_file.s3_expiration_alerter_zip.output_base64sha256
  timeout          = 300 # 5 minutes, adjust if your bucket has many objects
  memory_size      = 256 # Adjust as needed
  architectures    = ["arm64"] # Match existing Lambda architecture

  environment {
    variables = {
      S3_BUCKET_NAME                 = aws_s3_bucket.main.bucket
      SNS_TOPIC_ARN                  = aws_sns_topic.s3_expiration_alerts.arn
      ALERT_DAYS_BEFORE_EXPIRATION   = var.s3_alert_days_before_expiration
      LIFECYCLE_EXPIRATION_DAYS      =  var.s3_lifecycle_expiration_days
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.s3_expiration_alerter_lambda_attach,
    aws_sns_topic.s3_expiration_alerts
  ]
}

# EventBridge (CloudWatch Events) rule to trigger the Lambda daily
resource "aws_cloudwatch_event_rule" "daily_s3_expiration_check" {
  name                = "daily-s3-object-expiration-check-rule"
  description         = "Triggers Lambda daily to check for S3 objects nearing expiration"
  schedule_expression = "cron(0 2 * * ? *)" # Runs daily at 2:00 AM UTC
}

# Target for the EventBridge rule: the S3 alerter Lambda
resource "aws_cloudwatch_event_target" "s3_alerter_lambda_event_target" {
  rule      = aws_cloudwatch_event_rule.daily_s3_expiration_check.name
  target_id = "S3ExpirationAlerterLambdaTarget"
  arn       = aws_lambda_function.s3_expiration_alerter.arn
}

# Permission for EventBridge to invoke the Lambda function
resource "aws_lambda_permission" "allow_cloudwatch_to_s3_alerter_lambda" {
  statement_id  = "AllowExecutionFromCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_expiration_alerter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_s3_expiration_check.arn
}
