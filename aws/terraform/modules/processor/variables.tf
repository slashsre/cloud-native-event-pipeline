variable "name_prefix" {
  description = "Prefix applied to the function, role and policy names."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Lambda function."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "Region, used to scope the CloudWatch Logs resource ARN."
  type        = string
}

variable "artifact_source_dir" {
  description = "Directory holding the built Lambda code + dependencies."
  type        = string
}

variable "artifact_zip_path" {
  description = "Path where the packaged deployment ZIP is written."
  type        = string
}

variable "lambda_endpoint" {
  description = "Endpoint the Lambda uses to reach Floci from inside its container."
  type        = string
}

variable "queue_arn" {
  description = "ARN of the SQS queue the Lambda consumes."
  type        = string
}

variable "table_name" {
  description = "DynamoDB table the Lambda writes structured events to."
  type        = string
}

variable "table_arn" {
  description = "ARN of the DynamoDB table (for the IAM policy)."
  type        = string
}

variable "bucket_name" {
  description = "S3 bucket the Lambda archives raw payloads to."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the S3 bucket (for the IAM policy)."
  type        = string
}
