#!/bin/bash
set -euo pipefail
set +x
if [[ -n "${LOCALSEEK_CI_SIGNING_DIR:-}" ]]; then
  [[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]]
  case "$LOCALSEEK_CI_SIGNING_DIR" in
    "$RUNNER_TEMP"/localseek-signing.*) ;;
    *) echo 'Unerwarteter Signierpfad; Bereinigung abgebrochen.' >&2; exit 1 ;;
  esac
  if [[ -f "${LOCALSEEK_CI_KEYCHAIN:-}" ]]; then
    security delete-keychain "$LOCALSEEK_CI_KEYCHAIN"
  fi
  rm -rf -- "$LOCALSEEK_CI_SIGNING_DIR"
fi
