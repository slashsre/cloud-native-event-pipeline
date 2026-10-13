# --- API Gateway -> SQS (direct integration, no ingestion Lambda in the path) ---
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_sqs" {
  name               = "${var.name_prefix}-apigw-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

data "aws_iam_policy_document" "apigw_sqs_send" {
  statement {
    sid       = "AllowSendMessageToIngestionQueueOnly"
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]
  }
}

resource "aws_iam_role_policy" "apigw_sqs_send" {
  name   = "${var.name_prefix}-apigw-sqs-send"
  role   = aws_iam_role.apigw_sqs.id
  policy = data.aws_iam_policy_document.apigw_sqs_send.json
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.name_prefix}-ingestion-api"
  description = "Receives access events and pushes them straight to SQS (decoupled from processing)."

  tags = var.tags
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_method" "post_events" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.events.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

# Direct AWS service integration: API Gateway calls SQS SendMessage itself.
resource "aws_api_gateway_integration" "sqs" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = aws_iam_role.apigw_sqs.arn
  uri                     = "arn:aws:apigateway:${var.aws_region}:sqs:path/${var.account_id}/${var.queue_name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

resource "aws_api_gateway_method_response" "post_events_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "post_events_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = aws_api_gateway_method_response.post_events_200.status_code

  response_templates = {
    "application/json" = "{\"status\": \"accepted\"}"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # NOTE (Floci): Floci's GetIntegration returns NotFound on refresh, so Terraform
  # re-creates aws_api_gateway_integration.sqs on every apply. Re-creating the
  # integration invalidates the live stage snapshot, so we must re-deploy on every
  # apply to publish a fresh snapshot that includes it (otherwise the endpoint
  # returns 500 "No integration configured" until the next deploy). `timestamp()`
  # forces that redeploy; depends_on guarantees the integration exists first.
  triggers = {
    redeployment = timestamp()
  }

  depends_on = [
    aws_api_gateway_integration.sqs,
    aws_api_gateway_integration_response.post_events_200,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "local" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "local"
}

# --- API key, backed by the value stored in Secrets Manager ---
#
# The API key value is generated once and stored in Secrets Manager; nothing
# sensitive is hardcoded. It's what a real client would fetch at runtime via
# `aws secretsmanager get-secret-value` before calling the endpoint.
resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "api_key" {
  name        = "${var.name_prefix}/ingestion-api-key"
  description = "API key required by clients to POST access events to the ingestion endpoint."

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = random_password.api_key.result
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "${var.name_prefix}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.local.stage_name
  }
}

# The `aws_api_gateway_api_key` resource cannot be used against Floci: Floci's
# CreateApiKey/GetApiKey responses omit `createdDate`/`lastUpdatedDate`, and
# terraform-provider-aws does an unguarded `apiKey.CreatedDate.Format(...)` in its
# post-create read-back, which panics on the nil pointer and crashes the whole
# provider process (see TROUBLESHOOTING.md). Workaround: create the key and attach
# it to the usage plan out-of-band via the AWS CLI. The CLI never touches
# `createdDate`, so there is no crash, and the provider never reads the key back.
resource "null_resource" "client_api_key" {
  triggers = {
    key_name      = "${var.name_prefix}-client-key"
    key_value     = random_password.api_key.result
    usage_plan_id = aws_api_gateway_usage_plan.this.id
    endpoint      = var.floci_endpoint
    region        = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    # Secrets are passed as env vars (not on the command line) so they don't
    # leak into process listings. Terraform also redacts sensitive values.
    environment = {
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_DEFAULT_REGION    = self.triggers.region
      ENDPOINT              = self.triggers.endpoint
      KEY_NAME              = self.triggers.key_name
      KEY_VALUE             = self.triggers.key_value
      USAGE_PLAN_ID         = self.triggers.usage_plan_id
    }

    command = <<-EOT
      set -euo pipefail

      # Idempotent: reuse the key if one with this name already exists (client-side
      # JMESPath filter, so it works regardless of server-side name-query support).
      KEY_ID=$(aws --endpoint-url="$ENDPOINT" apigateway get-api-keys \
        --query "items[?name=='$KEY_NAME'].id | [0]" --output text 2>/dev/null || echo "None")

      if [ -z "$KEY_ID" ] || [ "$KEY_ID" = "None" ]; then
        KEY_ID=$(aws --endpoint-url="$ENDPOINT" apigateway create-api-key \
          --name "$KEY_NAME" --value "$KEY_VALUE" --enabled \
          --query 'id' --output text)
        echo "Created API key $KEY_ID"
      else
        echo "Reusing existing API key $KEY_ID"
      fi

      # Attach to the usage plan (ignore if it is already attached).
      aws --endpoint-url="$ENDPOINT" apigateway create-usage-plan-key \
        --usage-plan-id "$USAGE_PLAN_ID" \
        --key-id "$KEY_ID" --key-type API_KEY >/dev/null 2>&1 || true

      echo "API key $KEY_ID attached to usage plan $USAGE_PLAN_ID"
    EOT
  }

  # Best-effort cleanup on destroy so re-applies against a persistent Floci stay clean.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_DEFAULT_REGION    = self.triggers.region
      ENDPOINT              = self.triggers.endpoint
      KEY_NAME              = self.triggers.key_name
    }
    command = <<-EOT
      set -euo pipefail
      KEY_ID=$(aws --endpoint-url="$ENDPOINT" apigateway get-api-keys \
        --query "items[?name=='$KEY_NAME'].id | [0]" --output text 2>/dev/null || echo "None")
      if [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ]; then
        aws --endpoint-url="$ENDPOINT" apigateway delete-api-key --api-key "$KEY_ID" >/dev/null 2>&1 || true
        echo "Deleted API key $KEY_ID"
      fi
    EOT
  }

  depends_on = [aws_api_gateway_stage.local]
}
