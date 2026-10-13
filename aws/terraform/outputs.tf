output "invoke_url" {
  description = "Floci-local invoke URL for the ingestion endpoint."
  value       = module.ingestion_api.invoke_url
}

output "api_key_secret_name" {
  description = "Secrets Manager secret holding the API key clients must send in x-api-key."
  value       = module.ingestion_api.api_key_secret_name
}

output "rest_api_id" {
  description = "API Gateway REST API id, injected into the nginx TLS proxy config."
  value       = module.ingestion_api.rest_api_id
}

output "sqs_queue_url" {
  value = module.queue.queue_url
}

output "sqs_dlq_url" {
  value = module.queue.dlq_url
}

output "dynamodb_table_name" {
  value = module.storage.table_name
}

output "s3_bucket_name" {
  value = module.storage.bucket_name
}

output "lambda_function_name" {
  value = module.processor.function_name
}
