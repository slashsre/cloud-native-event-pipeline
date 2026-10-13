#!/usr/bin/env bash
# ==============================================================================
# Inspect Remote State & Locks in Floci
# ==============================================================================
set -euo pipefail

ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
STATE_BUCKET="${STATE_BUCKET:-event-pipeline-tfstate}"
LOCKS_TABLE="${LOCKS_TABLE:-event-pipeline-tflocks}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"

awsl() {
  command aws --endpoint-url="$ENDPOINT" "$@"
}

echo "=========================================================="
echo ">> Inspecting Terraform Remote State in Floci"
echo "=========================================================="

echo ""
echo "--- [1] Objects in S3 Bucket ($STATE_BUCKET) ---"
awsl s3 ls "s3://$STATE_BUCKET" --recursive || echo "Bucket not found or empty."

echo ""
echo "--- [2] State Versions in S3 Bucket ---"
awsl s3api list-object-versions --bucket "$STATE_BUCKET" \
  --query 'Versions[].{Key:Key, VersionId:VersionId, LastModified:LastModified, IsLatest:IsLatest}' \
  --output table 2>/dev/null || echo "No versions found."

echo ""
echo "--- [3] Active Locks in DynamoDB ($LOCKS_TABLE) ---"
awsl dynamodb scan --table-name "$LOCKS_TABLE" \
  --output json 2>/dev/null || echo "Lock table not found."

echo ""
echo "=========================================================="
