#!/usr/bin/env bash
#
# Build Osprey, run the tests, and check the public content.
#
# Usage:
#   ./scripts/verify.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Toolchain"
swift --version

echo
echo "==> Build"
swift build

echo
echo "==> Test"
./scripts/test.sh

echo
echo "==> Public content"
python3 scripts/public_content_guard.py

echo
echo "==> Done"
