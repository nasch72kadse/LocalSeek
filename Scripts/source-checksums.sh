#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Record compiled sources and the inputs embedded/used by the release packaging.
# The GGUF is verified separately by its pinned manifest digest.
git ls-files --cached --others --exclude-standard -- \
  Apps Shared LlamaBridge project.yml Package.resolved \
  Scripts/build-native.sh Scripts/build.sh Scripts/package.sh \
  Scripts/source-checksums.sh Scripts/verify-bundle.sh Scripts/verify-artifact.sh Scripts/ci \
  .github/workflows/build.yml \
  Models/manifest.json Models/native-dependencies.json Licenses \
  README.md THIRD_PARTY_NOTICES.md HANDOFF/INSTALLATION.md \
  | LC_ALL=C sort | while IFS= read -r source; do
    shasum -a 256 "$source"
done
