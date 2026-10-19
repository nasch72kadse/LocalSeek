#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$(cat build/latest-package.txt)}"
mkdir -p build/reports
/usr/bin/time -l /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$APP/Contents/MacOS/LocalSeek" --benchmark --report "$PWD/build/reports/benchmark-offline.json"
