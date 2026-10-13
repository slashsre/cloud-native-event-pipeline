#!/usr/bin/env bash
# Generates the two Secrets the server needs to ship access events to the AWS
# ingestion pipeline , into this same directory:
#
#   ingestion-api-key.secret.yaml   API key, read at runtime from Secrets Manager
#                                    (gitignored: it carries the key value)
#   ingestion-ca.secret.yaml        CA cert of the ingestion endpoint, so the
#                                    server validates TLS (public -> committable)
#
# The API key lives in Floci's Secrets Manager (source of truth); this only
# materialises it into a k8s Secret. Nothing is hardcoded in the repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-event-pipeline}"
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
SECRET_ID="${SECRET_ID:-event-pipeline/ingestion-api-key}"
# CA of the ingestion nginx proxy
AWS_CA="${AWS_CA:-${HERE}/../../../../aws/certs/nginx/server.pem}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Reading API key from Secrets Manager ($SECRET_ID)..."
KEY=$(aws --endpoint-url="$FLOCI_ENDPOINT" secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" --query SecretString --output text)

kubectl create secret generic ingestion-api-key -n "$NS" \
  --from-literal=api-key="$KEY" \
  --dry-run=client -o yaml > "${HERE}/ingestion-api-key.secret.yaml"
echo "Wrote ingestion-api-key.secret.yaml (gitignored)"

kubectl create secret generic ingestion-ca -n "$NS" \
  --from-file=ca.pem="$AWS_CA" \
  --dry-run=client -o yaml > "${HERE}/ingestion-ca.secret.yaml"
echo "Wrote ingestion-ca.secret.yaml"

echo "Done. Apply with:"
echo "  kubectl apply -f ${HERE}/ingestion-ca.secret.yaml"
echo "  kubectl apply -f ${HERE}/ingestion-api-key.secret.yaml"
