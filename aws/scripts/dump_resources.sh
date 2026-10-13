#!/usr/bin/env bash
# Dumps every resource this project creates in Floci, so you can verify they
# exist and inspect their data. Read-only: it never mutates anything.
#
# Usage:
#   ./5.-scripts/dump_resources.sh            # human-readable dump to stdout
#   FLOCI_ENDPOINT=http://localhost:4566 ./5.-scripts/dump_resources.sh
#
# Env overrides (all optional): FLOCI_ENDPOINT, PROJECT, AWS_DEFAULT_REGION.
set -uo pipefail

ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
PROJECT="${PROJECT:-event-pipeline}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Wrapper so every call targets Floci. `command aws` bypasses this function.
awsl() { command aws --endpoint-url="$ENDPOINT" "$@"; }
hdr()  { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }

QUEUE="$PROJECT-access-events"
DLQ="$PROJECT-access-events-dlq"
TABLE="$PROJECT-access-events"
BUCKET="$PROJECT-raw-events"
FUNCTION="$PROJECT-ingest-processor"
SECRET="$PROJECT/ingestion-api-key"

hdr "FLOCI HEALTH"
curl -sf "$ENDPOINT/_localstack/health" | python3 -m json.tool 2>/dev/null || echo "Floci not reachable at $ENDPOINT"

hdr "SQS — main queue ($QUEUE)"
QURL=$(awsl sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null)
echo "url: $QURL"
awsl sqs get-queue-attributes --queue-url "$QURL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible VisibilityTimeout RedrivePolicy \
  --query Attributes --output json 2>/dev/null

hdr "SQS — dead-letter queue ($DLQ)"
DURL=$(awsl sqs get-queue-url --queue-name "$DLQ" --query QueueUrl --output text 2>/dev/null)
echo "url: $DURL"
awsl sqs get-queue-attributes --queue-url "$DURL" \
  --attribute-names ApproximateNumberOfMessages --query Attributes --output json 2>/dev/null

hdr "DYNAMODB — table ($TABLE)"
awsl dynamodb describe-table --table-name "$TABLE" \
  --query "Table.{Name:TableName,Status:TableStatus,Keys:KeySchema,Billing:BillingModeSummary.BillingMode,Items:ItemCount}" \
  --output json 2>/dev/null
echo "-- items (scan) --"
awsl dynamodb scan --table-name "$TABLE" --output json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('count:',d.get('Count'));[print(json.dumps(i)) for i in d.get('Items',[])]" 2>/dev/null

hdr "S3 — bucket ($BUCKET)"
awsl s3api head-bucket --bucket "$BUCKET" 2>/dev/null && echo "bucket exists"
echo "-- versioning --"
awsl s3api get-bucket-versioning --bucket "$BUCKET" --output json 2>/dev/null
echo "-- objects --"
awsl s3api list-objects-v2 --bucket "$BUCKET" --query "Contents[].{Key:Key,Size:Size}" --output json 2>/dev/null

hdr "LAMBDA — function ($FUNCTION)"
awsl lambda get-function-configuration --function-name "$FUNCTION" \
  --query "{Name:FunctionName,Runtime:Runtime,Handler:Handler,Timeout:Timeout,State:State,Env:Environment.Variables}" \
  --output json 2>/dev/null
echo "-- event source mappings --"
awsl lambda list-event-source-mappings --function-name "$FUNCTION" \
  --query "EventSourceMappings[].{UUID:UUID,Source:EventSourceArn,State:State,BatchSize:BatchSize}" --output json 2>/dev/null

hdr "API GATEWAY — REST API ($PROJECT-ingestion-api)"
API_ID=$(awsl apigateway get-rest-apis --query "items[?name=='$PROJECT-ingestion-api'].id | [0]" --output text 2>/dev/null)
echo "rest-api-id: $API_ID"
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  echo "-- resources --"
  awsl apigateway get-resources --rest-api-id "$API_ID" --query "items[].{id:id,path:path}" --output json 2>/dev/null
  RES_ID=$(awsl apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/events'].id | [0]" --output text 2>/dev/null)
  echo "-- integration on POST /events --"
  awsl apigateway get-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST \
    --query "{type:type,uri:uri,httpMethod:httpMethod,templates:requestTemplates}" --output json 2>/dev/null \
    || echo "(GetIntegration NotFound — known Floci read quirk; the deployed stage can still work)"
  echo "-- stages --"
  awsl apigateway get-stages --rest-api-id "$API_ID" --query "item[].{stage:stageName,deploymentId:deploymentId}" --output json 2>/dev/null
  echo "-- invoke URL --"
  echo "$ENDPOINT/restapis/$API_ID/local/_user_request_/events"
fi
echo "-- api keys --"
awsl apigateway get-api-keys --query "items[].{id:id,name:name,enabled:enabled}" --output json 2>/dev/null
echo "-- usage plans --"
awsl apigateway get-usage-plans --query "items[].{id:id,name:name}" --output json 2>/dev/null

hdr "SECRETS MANAGER — secret ($SECRET)"
awsl secretsmanager describe-secret --secret-id "$SECRET" \
  --query "{Name:Name,ARN:ARN}" --output json 2>/dev/null
echo "-- value length (not printing the secret) --"
VAL=$(awsl secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text 2>/dev/null)
echo "length: ${#VAL}"

hdr "IAM — roles"
for ROLE in "$PROJECT-apigw-sqs-role" "$PROJECT-ingest-processor-role"; do
  echo "-- $ROLE --"
  awsl iam get-role --role-name "$ROLE" --query "Role.{Name:RoleName,Arn:Arn}" --output json 2>/dev/null
  awsl iam list-role-policies --role-name "$ROLE" --query "PolicyNames" --output json 2>/dev/null
done

hdr "CLOUDWATCH LOGS — lambda log group"
awsl logs describe-log-groups --log-group-name-prefix "/aws/lambda/$FUNCTION" \
  --query "logGroups[].logGroupName" --output json 2>/dev/null
echo "(note: Floci's Logs API often returns empty events; use 'make logs' / 'docker compose logs floci' for real Lambda output)"

hdr "DONE"
