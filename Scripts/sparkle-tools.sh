#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Official distribution; pin tooling separately from SPM's pinned framework.
DEST=build/Dependencies/Sparkle
ARCHIVE="$DEST/Sparkle-2.10.0.tar.xz"
EXPECTED=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
mkdir -p "$DEST"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
    --output "$ARCHIVE.pending"
  mv "$ARCHIVE.pending" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$EXPECTED" ]] || {
  echo 'Sparkle tools checksum mismatch.' >&2; exit 1;
}
tar -xf "$ARCHIVE" -C "$DEST" ./bin ./LICENSE
