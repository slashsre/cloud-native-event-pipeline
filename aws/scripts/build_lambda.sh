#!/usr/bin/env bash
# Packages the ingest_processor Lambda as a ZIP with its dependencies
# included (Floci does not implement Lambda Layers).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/lambda/ingest_processor"
BUILD_DIR="${ROOT_DIR}/.build/ingest_processor"
ZIP_PATH="${ROOT_DIR}/.build/ingest_processor.zip"

rm -rf "${BUILD_DIR}" "${ZIP_PATH}"
mkdir -p "${BUILD_DIR}"

pip install --no-cache-dir -r "${SRC_DIR}/requirements.txt" -t "${BUILD_DIR}" >/dev/null
cp "${SRC_DIR}/handler.py" "${BUILD_DIR}/"

# Strip compiled bytecode so the ZIP (and its source_code_hash) is reproducible:
# .pyc files carry timestamps/paths that vary between builds and machines.
find "${BUILD_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "${BUILD_DIR}" -type f -name '*.pyc' -delete

(cd "${BUILD_DIR}" && zip -qr "${ZIP_PATH}" .)

echo "Built ${ZIP_PATH}"
