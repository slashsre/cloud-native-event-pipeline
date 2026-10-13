# Root module: composes the ingestion pipeline from focused child modules.
#
#   POST /events -> API Gateway -> SQS -> Lambda -> DynamoDB + S3
#
#   modules/queue         SQS main queue + dead-letter queue
#   modules/storage       DynamoDB table + S3 raw-payload bucket
#   modules/processor     Lambda consumer + event source mapping + its IAM role
#   modules/ingestion_api API Gateway (direct SQS integration) + API key + secret

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

module "queue" {
  source      = "./modules/queue"
  name_prefix = var.project
  tags        = local.tags
}

module "storage" {
  source      = "./modules/storage"
  name_prefix = var.project
  tags        = local.tags
}

module "processor" {
  source      = "./modules/processor"
  name_prefix = var.project
  tags        = local.tags
  aws_region  = var.aws_region

  # The ZIP is built by scripts/build_lambda.sh; Terraform only packages the
  # already-built artifact (paths are relative to the root module dir).
  artifact_source_dir = "${path.root}/../.build/ingest_processor"
  artifact_zip_path    = "${path.root}/../.build/ingest_processor.zip"
  lambda_endpoint      = var.floci_lambda_endpoint

  queue_arn   = module.queue.queue_arn
  table_name  = module.storage.table_name
  table_arn   = module.storage.table_arn
  bucket_name = module.storage.bucket_name
  bucket_arn  = module.storage.bucket_arn
}

module "ingestion_api" {
  source         = "./modules/ingestion_api"
  name_prefix    = var.project
  tags           = local.tags
  aws_region     = var.aws_region
  account_id     = data.aws_caller_identity.current.account_id
  floci_endpoint = var.floci_endpoint

  queue_name = module.queue.queue_name
  queue_arn  = module.queue.queue_arn
}
