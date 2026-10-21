# Building and testing

These instructions describe the current **`dev` branch**. `main` is reserved for
promoted versions and may not yet include all development release tooling.

## Build requirements

- Apple Silicon Mac and full Xcode with Swift 6 support and the macOS SDK.
- Xcode's license and first-launch setup completed; developer tools allowed by macOS.
- Git, CMake, XcodeGen, and Python 3 for build-time helpers and tests.
- Internet for the initial dependency and model downloads.

The current development environment uses Xcode 27.1 and macOS 27.0.1. The app's
deployment target is macOS 14. Building the macOS app on Linux is not supported:
it depends on Apple's SwiftUI, Vision, AppKit, and Metal frameworks.

With Homebrew available, install the command-line build tools:

```bash
brew install cmake xcodegen
```

Python is a build-time requirement, not a runtime dependency of the finished app.
The build compiles pinned llama.cpp sources; a Homebrew llama.cpp installation is not needed.

## Get the source and model

```bash
git clone https://github.com/nasch72kadse/LocalSeek.git
cd LocalSeek
git switch dev
bash Scripts/ci/prepare-model.sh
export LOCALSEEK_MODEL="$PWD/build/ci-model/multilingual-e5-small-q8_0.gguf"
export LOCALSEEK_TEST_MODEL="$LOCALSEEK_MODEL"
```

The helper downloads and verifies the model declared in [the model manifest](../Models/manifest.json).
It keeps weights under the ignored `build/` directory. To use an existing verified
copy instead, point both environment variables at that file. The default model path
is `~/Library/Application Support/LocalSeek/models/multilingual-e5-small-q8_0.gguf`.

## Build a transferable app

```bash
Scripts/build.sh
```

Every successful release build ends with **`build/LocalSeek.dmg`** and its checksum.
The DMG includes the model and runtime components. The two newest completed packages
are retained under `build/packages/`; `build/latest-artifact.txt` identifies the latest one.

The build generates `LocalSeek.xcodeproj` from `project.yml`, resolves the versions
in `Package.resolved`, and compiles static native libraries for arm64/macOS 14.
Do not commit the generated project, downloaded model, or compiled dependencies.

Without signing configuration the package is ad-hoc signed for development.
For distribution, see [local signing and notarization](LOCAL-RELEASE.md).
Local settings belong in `.env.local`, copied from [the example](../.env.local.example);
GitHub Actions never loads that file.

## Automatic local cleanup

Builds, packaging, publication, and release tests apply bounded local retention:

- Keep the two newest completed packages, including their apps and DMGs.
- Remove staging copies and notarization ZIPs after the workflow succeeds. When
  publication is enabled, wait until both the GitHub Release and update feed succeed.
- Keep the three newest release-test result bundles, including failed runs.
- Preserve live builds/tests, packages referenced by the latest-package pointers,
  and the result bundle referenced by the current release-test receipt.
- Remove abandoned incomplete package directories after 24 hours.

Current pointers and active jobs can temporarily retain additional packages or
results. Compiler caches, dependency downloads, the model, small diagnostic reports,
and backup/investigation folders are preserved. GitHub Releases are unaffected.

Preview or apply the same policy manually:

```bash
python3 Scripts/build_retention.py
python3 Scripts/build_retention.py --apply
```

Cleanup failures produce a warning rather than invalidate a successful publication.

## Run checks

```bash
# Fast build-tool checks
python3 -m unittest discover -s Tests/BuildTools -v

# Build debug prerequisites, then run the complete release test gate
CONFIGURATION=Debug Scripts/build.sh
bash Scripts/test-release.sh

# Check an already built package without IP connectivity
Scripts/verify-offline.sh
```

The release gate runs Swift unit/integration tests, build-tool tests, and migration
checks. Real OCR and embedding tests use the bundled helper and the pinned model.
Failures, skipped tests, and missing results prevent packaging or publishing.
On the development branch the test receipt is bound to the commit, source hashes,
macOS, and Xcode, and expires after 24 hours.

macOS may require developer-tool permission for XCTest. Resolve that permission on
the build Mac; a successful compile does not prove tests have executed. You can set
`LOCALSEEK_TEST_SIGN_IDENTITY` to an available Apple Development identity for local test bundles.

Additional component checks and synthetic benchmarks:

```bash
python3 Scripts/check-migration-sql.py
bash Scripts/test-native-ann.sh 100000
bash Scripts/test-native-embeddings.sh
Scripts/benchmark.sh
```

The benchmark uses temporary synthetic data rather than your configured source folders.
Its timings depend on hardware and workload and are not a general performance guarantee.

## Packaging checks

`Scripts/package.sh` runs the build and packaging flow. Use
`Scripts/package.sh --skip-build` only when the compiled source inputs are unchanged.

Before distribution, the scripts check source provenance, signatures, architecture,
runtime dependencies, the model checksum, the DMG contents, and the Applications link.
Compiler paths are mapped to `/LocalSeek`; debug file references are stripped before
final signing. The bundle privacy check rejects absolute user/build paths, private
keys, credential files, and search index files.

The offline self-test denies IPv4/IPv6 traffic to the app and its child processes.
Local Unix sockets remain available for Apple framework communication; they do not
require an internet connection.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Apps/LocalSeek/` | Menu bar app, UI, and app-level indexing coordination |
| `Apps/LocalSeekOCR/` | Isolated Apple Vision OCR process |
| `Shared/` | Extraction, indexing, search, models, and SQLite persistence |
| `LlamaBridge/` | C/C++ embedding and vector-search bridge |
| `Models/` | Pinned model and native dependency manifests |
| `Scripts/` | Build, test, packaging, and release tools |
| `Tests/` | Swift, Python, and native component tests |
| `Licenses/` | Unmodified third-party license notices |
| `docs/` | Maintained project documentation |

Local handover reports, planning notes, logs, model weights, credentials, and build
outputs are ignored. `Package.resolved`, manifests, source files, tests, and license
notices remain version-controlled.
