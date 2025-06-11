# iam.tf

# --- IAM Role for EC2 Instances ---
# This role allows the EC2 instances to be managed by AWS services and access S3.
resource "aws_iam_role" "ec2_instance_role" {
  name = "ec2-g4dn-instance-role"
  path = "/"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# --- S3 Access Policy ---
# This policy grants specific permissions for our S3 bucket.
# It follows the principle of least privilege.
resource "aws_iam_policy" "s3_access_policy" {
  name        = "ec2-s3-access-policy"
  description = "Allows EC2 instances to access the designated S3 bucket"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.main.arn}/*" # Access objects inside the bucket
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.main.arn # List the bucket contents
      }
    ]
  })
}

# Attach the S3 policy to the EC2 role.
resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

# Create an instance profile to attach the role to our EC2 launch template.
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-g4dn-instance-profile"
  role = aws_iam_role.ec2_instance_role.name
}


# --- IAM Role & Policy for Lambda Scheduler (Moved from main.tf) ---
resource "aws_iam_role" "lambda_scheduler_role" {
  name = "lambda_scheduler_role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "lambda_scheduler_policy" {
  name = "lambda_scheduler_policy"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Action = [
        "ec2:DescribeInstances",
        "ec2:StopInstances"
      ]
      Effect   = "Allow"
      Resource = "*"
      }, {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_scheduler_attach" {
  role       = aws_iam_role.lambda_scheduler_role.name
  policy_arn = aws_iam_policy.lambda_scheduler_policy.arn
}

# --- IAM Role & Policy for S3 Expiration Alerter Lambda ---
resource "aws_iam_role" "s3_expiration_alerter_lambda_role" {
  name = "s3-expiration-alerter-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "s3_expiration_alerter_lambda_policy" {
  name   = "s3-expiration-alerter-lambda-policy"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*" # Standard Lambda logging
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"] # To list objects and their LastModified dates
        Resource = aws_s3_bucket.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish" # To send notifications
        Resource = aws_sns_topic.s3_expiration_alerts.arn # Reference the SNS topic defined in main.tf
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_expiration_alerter_lambda_attach" {
  role       = aws_iam_role.s3_expiration_alerter_lambda_role.name
  policy_arn = aws_iam_policy.s3_expiration_alerter_lambda_policy.arn
}