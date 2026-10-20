#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$(cat build/latest-package.txt)}"
mkdir -p build/reports
# Deny IPv4/IPv6 only for this process and its children. Preserve local Unix IPC
# required by Vision/Core ML; no changes to the Mac's network configuration.
/usr/bin/sandbox-exec -f "$PWD/Scripts/offline.sb" \
  "$APP/Contents/MacOS/LocalSeek" --self-test --report "$PWD/build/reports/offline.json"
