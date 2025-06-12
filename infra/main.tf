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
