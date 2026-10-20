#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/local-build-config.sh
exec python3 Scripts/release-tests.py "$@"
