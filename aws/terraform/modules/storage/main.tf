# Structured, idempotent record of every access event received through the
# ingestion pipeline. event_id is a deterministic hash of the raw payload so
# a redelivered SQS message never produces a duplicate item (conditional put
# with attribute_not_exists(event_id) in the Lambda).
resource "aws_dynamodb_table" "access_events" {
  name         = "${var.name_prefix}-access-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = var.tags
}

# Raw payload archive. Objects are written under a date-based prefix
# (raw/yyyy/mm/dd/<event_id>.json) so the bucket stays browsable/queryable
# by ingestion day.
resource "aws_s3_bucket" "raw_events" {
  bucket = "${var.name_prefix}-raw-events"

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "raw_events" {
  bucket                  = aws_s3_bucket.raw_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
