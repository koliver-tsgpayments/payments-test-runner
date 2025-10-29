#!/usr/bin/env bash
set -euo pipefail
TAG="${1:-dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pushd "$ROOT/functions" >/dev/null
pip install -r requirements.txt -t ./vendor
zip -r ../dist/tsg-${TAG}.zip . -x '__pycache__/*' -x 'vendor/__pycache__/*'
zip -r ../dist/worldpay-${TAG}.zip . -x '__pycache__/*' -x 'vendor/__pycache__/*'
popd >/dev/null

echo "Artifacts at $ROOT/dist/tsg-${TAG}.zip and worldpay-${TAG}.zip"
