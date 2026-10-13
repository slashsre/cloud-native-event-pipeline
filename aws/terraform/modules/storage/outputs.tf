output "table_name" {
  value = aws_dynamodb_table.access_events.name
}

output "table_arn" {
  value = aws_dynamodb_table.access_events.arn
}

output "bucket_name" {
  value = aws_s3_bucket.raw_events.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.raw_events.arn
}
