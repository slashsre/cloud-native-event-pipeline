variable "aws_region" {
  description = "Region used for every resource (Floci accepts any valid AWS region name)."
  type        = string
  default     = "us-east-1"
}

variable "floci_endpoint" {
  description = "Floci single endpoint exposing all AWS service APIs (used from the host)."
  type        = string
  default     = "http://localhost:4566"
}

variable "floci_lambda_endpoint" {
  description = <<-EOT
    Endpoint the Lambda uses to reach Floci from INSIDE its container. `localhost`
    there is the Lambda itself, so we use Floci's internal DNS name. Using
    localhost:4566 makes the function's boto3 calls hang until timeout.
  EOT
  type        = string
  default     = "http://localhost.localstack.cloud:4566"
}

variable "project" {
  description = "Prefix applied to every resource name/tag."
  type        = string
  default     = "event-pipeline"
}

variable "environment" {
  description = "Environment tag applied to every resource."
  type        = string
  default     = "local"
}
