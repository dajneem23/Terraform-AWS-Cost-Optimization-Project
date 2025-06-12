# Terraform AWS Cost Optimization Project

This project deploys a highly cost-optimized and scalable EC2 environment on AWS using Terraform.

## Strategies Implemented

1. **Spot Instances**: The Auto Scaling Group is configured to use Spot pricing, saving up to 90% compared to On-Demand.
2. **Dynamic Auto Scaling**: The number of instances automatically scales between 1 and 5 based on CPU utilization, ensuring you only pay for the capacity you need.
    * **Scale-Up**: Triggers when average CPU is >= 75%.
    * **Scale-Down**: Triggers when average CPU is <= 25%.
3. **Instance Scheduling**: A Lambda function stops all tagged instances every weekday at 6 PM UTC to save costs during off-hours.
4. **S3 for Data**: A private, encrypted S3 bucket is created, and the EC2 instances are given secure, role-based access to it.
5. **Governance**:
    * **Tagging**: Default tags are applied to all resources for better cost allocation.
    * **Budgets**: An AWS Budget alerts you via email if costs exceed a defined threshold.
6. **Right-Sizing & OS Choice**: The instance type is a configurable variable (`g4dn.xlarge` by default), and the AMI is set to Amazon Linux 2 to avoid Windows licensing fees.

## How to Use

1. **Prerequisites**:
    * Install [Terraform](https://www.terraform.io/downloads.html).
    * Configure your [AWS credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html).

2. **Initialize the project**:

    ```sh
    terraform init
    ```

3. **Plan the deployment**:
    Review the plan. You must provide your email address for budget alerts.

    ```sh
    terraform plan -var="notification_email=your_email@example.com"
    ```

4. **Apply the changes**:

    ```sh
    terraform apply -var="notification_email=your_email@example.com"
    ```

    Enter `yes` when prompted.

5. **Customize (Optional)**:
    You can override default variables like instance type or scaling thresholds during apply. This example changes the max instances to 10.

    ```sh
    terraform apply \
      -var="notification_email=your_email@example.com" \
      -var="instance_type=g4dn.2xlarge" \
      -var="max_num_instances=10" \
      -var="scale_up_cpu_threshold=80"
    ```

6. **Clean up**:
    When you are finished, destroy all created resources to avoid incurring costs.

    ```sh
    terraform destroy -var="notification_email=your_email@example.com"
    ```

# Disclaimer

This project is for showcasing cost optimization strategies and may not be suitable for production use without further customization and testing. Always review and test configurations in a safe environment before deploying to production.
This code can be used in other projects.
Feel free to modify and adapt them to your needs.
