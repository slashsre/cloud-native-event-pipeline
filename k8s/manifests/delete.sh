#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup client microservice
kubectl delete -f "${HERE}/client-app-1.0.0/client-secret.yaml" --ignore-not-found
kubectl delete -f "${HERE}/client-app-1.0.0/deployment.yaml" --ignore-not-found
kubectl delete -f "${HERE}/client-app-1.0.0/service.yaml" --ignore-not-found

# Cleanup server microservice
kubectl delete -f "${HERE}/server-app-1.0.0/ingress.yaml" --ignore-not-found
kubectl delete -f "${HERE}/server-app-1.0.0/deployment.yaml" --ignore-not-found
kubectl delete -f "${HERE}/server-app-1.0.0/service.yaml" --ignore-not-found
kubectl delete -f "${HERE}/server-app-1.0.0/secret-tls.yaml" --ignore-not-found
kubectl delete -f "${HERE}/server-app-1.0.0/server-backend-ca.yaml" --ignore-not-found

# Cleanup namespace
kubectl delete -f "${HERE}/namespace.yaml" --ignore-not-found
