# ==============================================================================
# Remote Backend Configuration using Floci (Local AWS Emulator)
# ==============================================================================
# Stores Terraform state remotely in S3 and implements distributed locking
# via DynamoDB, exactly as in production AWS architectures, running 100% locally.
#
# Prerequisite: run `make bootstrap-backend` (or `./scripts/bootstrap_backend.sh`)
# to initialize the S3 bucket and DynamoDB table in Floci before `terraform init`.
# ==============================================================================

terraform {
  backend "s3" {
    bucket                      = "event-pipeline-tfstate"
    key                         = "infra/terraform.tfstate"
    region                      = "us-east-1"
    endpoint                    = "http://localhost:4566"
    dynamodb_table              = "event-pipeline-tflocks"
    dynamodb_endpoint           = "http://localhost:4566"
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true
    encrypt                     = true
  }
}
