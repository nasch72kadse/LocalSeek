#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# This explicit entry point also works while automatic uploads are disabled.
export LOCALSEEK_PUBLISH_RELEASE=1
source Scripts/local-build-config.sh
exec python3 Scripts/publish-release.py "$@"
