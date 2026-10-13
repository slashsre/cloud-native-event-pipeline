variable "name_prefix" {
  description = "Prefix applied to API, role, usage plan and secret names."
  type        = string
}

variable "tags" {
  description = "Tags applied to taggable resources."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "Region, used to build the SQS integration URI."
  type        = string
}

variable "account_id" {
  description = "AWS account id, used to build the SQS integration URI."
  type        = string
}

variable "floci_endpoint" {
  description = "Floci endpoint, used to build the invoke URL and drive the API-key CLI calls."
  type        = string
}

variable "queue_name" {
  description = "Name of the SQS queue API Gateway sends messages to."
  type        = string
}

variable "queue_arn" {
  description = "ARN of the SQS queue (scopes the apigw send permission)."
  type        = string
}
