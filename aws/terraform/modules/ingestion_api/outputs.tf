output "invoke_url" {
  description = "Floci-local invoke URL for the ingestion endpoint."
  value       = "${var.floci_endpoint}/restapis/${aws_api_gateway_rest_api.this.id}/${aws_api_gateway_stage.local.stage_name}/_user_request_/events"
}

output "api_key_secret_name" {
  value = aws_secretsmanager_secret.api_key.name
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}
