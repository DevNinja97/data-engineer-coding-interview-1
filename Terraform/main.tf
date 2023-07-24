# Configure the AWS provider
provider "aws" {
  region = var.region
}


# Create an Amazon SNS topic for notifications
resource "aws_sns_topic" "job_failure_notification" {
  name = "JobFailureNotificationTopic"
}

# Subscribe the support email to the SNS topic
resource "aws_sns_topic_subscription" "job_failure_notification_subscription" {
  topic_arn = aws_sns_topic.job_failure_notification.arn
  protocol  = "email"
  endpoint  = "data-support@mybigbank.co.za"
}

# Create an IAM role for the Step Functions state machine
resource "aws_iam_role" "step_functions_role" {
  name        = "step_functions_role"
  description = "Role for Step Functions state machine"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "states.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  })
}

# Attach the required policies to the Step Functions role
resource "aws_iam_role_policy_attachment" "step_functions_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSStepFunctionsFullAccess"
  role       = aws_iam_role.step_functions_role.name
}

# Create an IAM policy for publishing SNS messages for the Step Functions role
resource "aws_iam_policy" "sns_publish_policy" {
  name        = "StepFunctionsSNSPublishPolicy"
  description = "IAM policy to allow publishing SNS messages for Step Functions"
  policy      = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "sns:Publish",
        "Resource": aws_sns_topic.job_failure_notification.arn
      }
    ]
  })
}

# Attach the SNS publish policy to the Step Functions role
resource "aws_iam_role_policy_attachment" "sns_publish_policy_attachment" {
  policy_arn = aws_iam_policy.sns_publish_policy.arn
  role       = aws_iam_role.step_functions_role.name
}

# Create the Step Functions state machine definition
data "aws_s3_bucket_object" "state_machine_definition" {
  bucket = aws_s3_bucket.glue_scripts_bucket.bucket
  key    = "state_machine_definition.json" # Replace with the path to your state machine definition JSON file
}

# Create the Step Functions state machine
resource "aws_sfn_state_machine" "glue_job_scheduler" {
  name     = "GlueJobScheduler"
  role_arn = aws_iam_role.step_functions_role.arn
  definition = data.aws_s3_bucket_object.state_machine_definition.body # Replace with the state machine definition JSON content
}

# Create a CloudWatch Events rule to schedule the Step Functions state machine
resource "aws_cloudwatch_event_rule" "glue_job_schedule" {
  name        = "GlueJobSchedule"
  description = "Schedule for Glue Job State Machine"

  schedule_expression = "rate(1 day)" # Change this expression to your desired schedule
}

# Add the Step Functions state machine as a target for the CloudWatch Events rule
resource "aws_cloudwatch_event_target" "glue_job_schedule_target" {
  rule      = aws_cloudwatch_event_rule.glue_job_schedule.name
  target_id = "GlueJobScheduleTarget"
  arn       = aws_sfn_state_machine.glue_job_scheduler.arn
}

# Trigger the Glue job from the Step Functions state machine
resource "aws_sfn_activity" "trigger_glue_job_activity" {
  name = "TriggerGlueJobActivity"
}

# Define the state machine definition JSON content (replace with your actual Glue job ARN)
locals {
  glue_job_arn = aws_glue_job.monthly_etl_job.arn
}

data "aws_sfn_state_machine" "state_machine" {
  name = aws_sfn_state_machine.glue_job_scheduler.name
}

resource "aws_sfn_state_machine" "state_machine_definition" {
  name     = aws_sfn_state_machine.glue_job_scheduler.name
  role_arn = aws_iam_role.step_functions_role.arn
  definition = jsonencode({
    Comment = "Glue Job Scheduler",
    StartAt = "ScheduleGlueJob",
    States = {
      ScheduleGlueJob = {
        Type     = "Task",
        Resource = aws_sfn_activity.trigger_glue_job_activity.arn,
        TimeoutSeconds = 60,
        End = true
      },
      JobFailedNotification = {
        Type = "Fail",
        Error = "JobFailed",
        Cause = "The Glue job has failed. Please check the AWS Glue console for more details.",
        End = true
      }
    }
  })
}

resource "aws_sfn_activity" "trigger_glue_job_activity" {
  name = "TriggerGlueJobActivity"
}

# Associate the Lambda function as a target with the CloudWatch Event rule
resource "aws_cloudwatch_event_target" "rotation_trigger" {
  rule      = aws_cloudwatch_event_rule.monthly_rotation_schedule.name
  target_id = "rotation_trigger"
  arn       = aws_lambda_function.secrets_rotation_lambda.arn
}

# Create a Glue job
resource "aws_glue_job" "monthly_etl_job" {
  name         = "monthly_etl_job"
  description  = "Monthly data extraction job"
  role_arn     = aws_iam_role.glue_job_role.arn
  command {
    script_location = "s3://${aws_s3_bucket.glue_scripts_bucket.id}/etl.py"
    python_version  = "3"
  }

  timeout     = 60
  max_retries = 2
}

# Configure the AWS provider
provider "aws" {
  region = var.region
}

# Create an S3 bucket for Glue scripts
resource "aws_s3_bucket" "glue_scripts_bucket" {
  bucket = "glue-scripts-bucket" # Change this to a unique bucket name
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}



# Create an S3 bucket for files
resource "aws_s3_bucket" "files_bucket" {
  bucket = "banking_data" # Change this to a unique bucket name
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

# Create a Glue catalog database
resource "aws_glue_catalog_database" "my_database" {
  name     = "my_database"
  location = "s3://${aws_s3_bucket.glue_scripts_bucket.id}"
  start_date = var.start_date
  end_date   = var.end_date
}



# Create an AWS Secrets Manager secret for Glue job credentials
resource "aws_secretsmanager_secret" "glue_job_credentials" {
  name        = "glue_job_credentials"
  description = "Credentials for Glue job"
}

# Create a new version of the secret with the necessary credentials
resource "aws_secretsmanager_secret_version" "glue_job_credentials_version" {
  secret_id     = aws_secretsmanager_secret.glue_job_credentials.id
  secret_string = jsonencode({
    aws_access_key_id     = var.aws_access_key_id,
    aws_secret_access_key = var.aws_secret_access_key,
    aurora_username       = var.aurora_username,
    aurora_password       = var.aurora_password
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Create an AWS Lambda function for secrets rotation
resource "aws_lambda_function" "secrets_rotation_lambda" {
  filename      = "secrets_rotation_lambda.zip"
  function_name = "secrets_rotation_lambda"
  role          = aws_iam_role.secrets_rotation_lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.8"
  timeout       = 300

  environment {
    variables = {
      secret_id = aws_secretsmanager_secret.glue_job_credentials.id
    }
  }
}

# Create an IAM role for the Lambda function
resource "aws_iam_role" "secrets_rotation_lambda_role" {
  name        = "secrets_rotation_lambda_role"
  description = "Role for Secrets Rotation Lambda"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "lambda.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  })
}

# Attach the AWSLambdaBasicExecutionRole policy to the Lambda function role
resource "aws_iam_role_policy_attachment" "secrets_rotation_lambda_policy_attachment" {
  role       = aws_iam_role.secrets_rotation_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Create a CloudWatch Event rule for monthly rotation schedule
resource "aws_cloudwatch_event_rule" "monthly_rotation_schedule" {
  name        = "monthly_rotation_schedule"
  description = "Monthly rotation schedule"

  schedule_expression = "rate(1 month)"
}

# Associate the Lambda function as a target with the CloudWatch Event rule
resource "aws_cloudwatch_event_target" "rotation_trigger" {
  rule      = aws_cloudwatch_event_rule.monthly_rotation_schedule.name
  target_id = "rotation_trigger"
  arn       = aws_lambda_function.secrets_rotation_lambda.arn
}



# Create an IAM role for the Glue job
resource "aws_iam_role" "glue_job_role" {
  name        = "glue_job_role"
  description = "Role for Glue job"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "glue.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  })
}

# Attach the AWSGlueServiceRole policy to the Glue job role
resource "aws_iam_role_policy_attachment" "glue_job_policy_attachment" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}



