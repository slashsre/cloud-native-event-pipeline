#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_ROOT="${HERE}/.."

# Deploy namespace
kubectl apply -f "${HERE}/namespace.yaml"

# Deploy client microservice
kubectl apply -f "${HERE}/client-app-1.0.0/client-secret.yaml"
kubectl apply -f "${HERE}/client-app-1.0.0/deployment.yaml"
kubectl apply -f "${HERE}/client-app-1.0.0/service.yaml"

# Deploy server microservice
# Create TLS secret dynamically from certs/ if not present (keeps private keys out of Git)
if [ -f "${K8S_ROOT}/certs/server.crt" ] && [ -f "${K8S_ROOT}/certs/server.key" ]; then
  kubectl create secret tls server-tls-secret -n event-pipeline \
    --cert="${K8S_ROOT}/certs/server.crt" \
    --key="${K8S_ROOT}/certs/server.key" \
    --dry-run=client -o yaml | kubectl apply -f -
elif [ -f "${HERE}/server-app-1.0.0/secret-tls.yaml" ]; then
  kubectl apply -f "${HERE}/server-app-1.0.0/secret-tls.yaml"
fi

kubectl apply -f "${HERE}/server-app-1.0.0/server-backend-ca.yaml"
kubectl apply -f "${HERE}/server-app-1.0.0/service.yaml"
kubectl apply -f "${HERE}/server-app-1.0.0/deployment.yaml"
kubectl apply -f "${HERE}/server-app-1.0.0/ingress.yaml"