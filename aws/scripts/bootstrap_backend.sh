#!/usr/bin/env bash
# ==============================================================================
# Bootstrap Remote State Backend in Floci (S3 + DynamoDB State Locking)
# ==============================================================================
# This script idempotently initializes the S3 bucket and DynamoDB table
# required by Terraform's remote S3 backend before running `terraform init`.
#
# Prerequisite: Floci must be running on $FLOCI_ENDPOINT (default: http://localhost:4566)
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
echo ">> Initializing Terraform Remote Backend in Floci"
echo "   Endpoint: $ENDPOINT"
echo "   S3 Bucket: $STATE_BUCKET"
echo "   DynamoDB Table: $LOCKS_TABLE"
echo "=========================================================="

# 1. Check Floci health
if ! curl -sf "$ENDPOINT/_localstack/health" >/dev/null; then
  echo "[-] ERROR: Floci is not reachable at $ENDPOINT."
  echo "    Please start Floci first using: make -C aws up (or docker compose up -d floci)"
  exit 1
fi
echo "[+] Floci is healthy."

# 2. Idempotently create S3 bucket for tfstate
if awsl s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "[+] S3 bucket '$STATE_BUCKET' already exists."
else
  echo "[*] Creating S3 bucket '$STATE_BUCKET'..."
  if [ "$REGION" = "us-east-1" ]; then
    awsl s3api create-bucket --bucket "$STATE_BUCKET" >/dev/null
  else
    awsl s3api create-bucket --bucket "$STATE_BUCKET" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  echo "[+] S3 bucket '$STATE_BUCKET' created."
fi

# 3. Enable bucket versioning (essential for Terraform state recovery)
echo "[*] Enabling versioning on S3 bucket '$STATE_BUCKET'..."
awsl s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
echo "[+] Bucket versioning enabled."

# 4. Idempotently create DynamoDB table for state locking
if awsl dynamodb describe-table --table-name "$LOCKS_TABLE" >/dev/null 2>&1; then
  echo "[+] DynamoDB table '$LOCKS_TABLE' already exists."
else
  echo "[*] Creating DynamoDB table '$LOCKS_TABLE' for state locking..."
  awsl dynamodb create-table \
    --table-name "$LOCKS_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  echo "[+] DynamoDB table '$LOCKS_TABLE' created."
fi

echo "=========================================================="
echo "[✓] Terraform remote backend infrastructure is ready!"
echo "=========================================================="
