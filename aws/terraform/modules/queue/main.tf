# Dead-letter queue: messages that fail processing max_receive_count times end
# up here instead of being retried forever or silently dropped.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-access-events-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = var.tags
}

# Main ingestion queue. API Gateway writes directly here (decoupled from
# processing); the Lambda consumes it via an event source mapping.
resource "aws_sqs_queue" "main" {
  name                       = "${var.name_prefix}-access-events"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}
