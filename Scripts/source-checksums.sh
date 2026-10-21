#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Record compiled sources and the inputs embedded/used by the release packaging.
# The GGUF is verified separately by its pinned manifest digest.
git ls-files --cached --others --exclude-standard -- \
  Apps Shared LlamaBridge project.yml Package.resolved \
  Scripts/build-native.sh Scripts/build.sh Scripts/package.sh \
  Scripts/local-build-config.sh Scripts/publish-release.sh Scripts/publish-release.py \
  Scripts/update_feed.py Scripts/sparkle-tools.sh Scripts/verify-updater.py Scripts/test-build-tools.sh \
  Scripts/verify-offline.sh Scripts/offline.sb \
  Scripts/test.sh Scripts/test-release.sh Scripts/release-tests.py Scripts/check-migration-sql.py Tests \
  Scripts/source-checksums.sh Scripts/verify-bundle.sh Scripts/check-bundle-privacy.py Scripts/verify-artifact.sh Scripts/ci \
  .github/workflows/build.yml \
  Models/manifest.json Models/native-dependencies.json Licenses \
  README.md THIRD_PARTY_NOTICES.md docs/INSTALLATION.md docs/releases \
  | LC_ALL=C sort | while IFS= read -r source; do
    shasum -a 256 "$source"
done
