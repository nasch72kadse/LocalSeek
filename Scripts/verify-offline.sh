#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$(cat build/latest-package.txt)}"
mkdir -p build/reports
# Deny networking only for this child process. Does not alter the Mac's network.
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$APP/Contents/MacOS/LocalSeek" --self-test --report "$PWD/build/reports/offline.json"
