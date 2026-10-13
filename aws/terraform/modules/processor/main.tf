# --- Lambda execution role (consumes SQS, writes DynamoDB + S3) ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-ingest-processor-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Least-privilege: consume only this queue, put only to this table, archive only
# under raw/*, and write only its own log group.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid = "ConsumeIngestionQueueOnly"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "WriteStructuredEventOnly"
    actions   = ["dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  statement {
    sid       = "ArchiveRawPayloadOnly"
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/raw/*"]
  }

  statement {
    sid       = "WriteOwnLogsOnly"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.name_prefix}-*:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name_prefix}-ingest-processor-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

# The ZIP is built by 5.-scripts/build_lambda.sh (dependencies included, no Lambda
# Layers since Floci doesn't implement them). Terraform only packages the
# already-built artifact so `terraform apply` stays idempotent.
data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.artifact_source_dir
  output_path = var.artifact_zip_path
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name_prefix}-ingest-processor"
  role             = aws_iam_role.this.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      DYNAMODB_TABLE = var.table_name
      S3_BUCKET      = var.bucket_name
      # From INSIDE the Lambda container, "localhost" is the Lambda itself, not
      # Floci. Floci's internal DNS resolves this hostname to the Floci container,
      # so the function's boto3 calls reach DynamoDB/S3. (Using localhost:4566 here
      # makes the calls hang and the function times out.)
      AWS_ENDPOINT_URL = var.lambda_endpoint
    }
  }

  tags = var.tags
}

# Decouples ingestion from processing: the Lambda only runs when there are
# messages in the queue, and failed items (via ReportBatchItemFailures) are
# retried up to maxReceiveCount before landing in the DLQ.
resource "aws_lambda_event_source_mapping" "this" {
  event_source_arn        = var.queue_arn
  function_name           = aws_lambda_function.this.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}
