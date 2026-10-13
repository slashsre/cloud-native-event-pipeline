# Floci exposes every AWS API on a single endpoint (http://localhost:4566).
# Credentials are dummy values: Floci does not validate them, it only needs
# something non-empty for the AWS SDK/provider to build requests.
provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway     = var.floci_endpoint
    sqs            = var.floci_endpoint
    lambda         = var.floci_endpoint
    dynamodb       = var.floci_endpoint
    s3             = var.floci_endpoint
    secretsmanager = var.floci_endpoint
    ssm            = var.floci_endpoint
    iam            = var.floci_endpoint
    sts            = var.floci_endpoint
    acm            = var.floci_endpoint
    cloudwatch     = var.floci_endpoint
    logs           = var.floci_endpoint
  }
}
