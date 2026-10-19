#!/bin/bash
# Sourced after changing to the repository root. No local settings on CI runners.
if [[ "${GITHUB_ACTIONS:-}" != true && -f .env.local ]]; then
  set -a
  source .env.local
  set +a
fi
export LOCALSEEK_PUBLISH_RELEASE="${LOCALSEEK_PUBLISH_RELEASE:-0}"
[[ "$LOCALSEEK_PUBLISH_RELEASE" == 0 || "$LOCALSEEK_PUBLISH_RELEASE" == 1 ]] || {
  echo 'LOCALSEEK_PUBLISH_RELEASE muss 0 oder 1 sein.' >&2
  exit 1
}
