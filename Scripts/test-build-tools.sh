#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The same entry point is used in fresh CI checkouts and the local release gate.
bash Scripts/sparkle-tools.sh
exec python3 -m unittest discover -s Tests/BuildTools -v
