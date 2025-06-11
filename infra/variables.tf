# variables.tf

variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type to use. Right-size this for your workload!"
  type        = string
  default     = "g4dn.xlarge"
}

variable "notification_email" {
  description = "Email address to send budget alerts to."
  type        = string
}

variable "monthly_budget_usd" {
  description = "The monthly budget amount in USD."
  type        = number
  default     = 2000
}

# --- NEW: Scaling Variables ---
variable "max_num_instances" {
  description = "The maximum number of instances the Auto Scaling Group can scale out to."
  type        = number
  default     = 5
}

variable "scale_up_cpu_threshold" {
  description = "The average CPU utilization percentage to trigger a scale-up event."
  type        = number
  default     = 75
}

variable "scale_down_cpu_threshold" {
  description = "The average CPU utilization percentage to trigger a scale-down event."
  type        = number
  default     = 25
}