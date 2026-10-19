#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
NAME="$(plutil -extract name raw Models/manifest.json)"
EXPECTED="$(plutil -extract sha256 raw Models/manifest.json)"
URL="$(plutil -extract download raw Models/manifest.json)"
[[ "$NAME" != */* && "$NAME" == *.gguf && "$EXPECTED" =~ ^[0-9a-f]{64}$ && "$URL" == https://* ]]
mkdir -p build/ci-model
MODEL="$PWD/build/ci-model/$NAME"
if [[ ! -f "$MODEL" || "$(shasum -a 256 "$MODEL" | awk '{print $1}')" != "$EXPECTED" ]]; then
  PENDING="$(mktemp "$PWD/build/ci-model/download.XXXXXX")"
  trap 'rm -f "$PENDING"' EXIT
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --connect-timeout 20 --max-time 480 \
    --output "$PENDING" "$URL"
  [[ "$(shasum -a 256 "$PENDING" | awk '{print $1}')" == "$EXPECTED" ]] || {
    echo 'Modell-Prüfsumme stimmt nicht; Build abgebrochen.' >&2; exit 1;
  }
  mv -f "$PENDING" "$MODEL"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'LOCALSEEK_MODEL=%s\nLOCALSEEK_TEST_MODEL=%s\n' "$MODEL" "$MODEL" >> "$GITHUB_ENV"
fi
printf 'Gebündeltes Modell verifiziert: %s\n' "$NAME"
