# Contributing

LocalSeek's project code does not currently have an open-source license. Review
[LICENSE](LICENSE) before reusing code or proposing contributions.

## Working on a change

Use `dev` as the base for development. Keep changes focused, explain the problem and
resulting behavior, and include the validation needed to assess them. `main` is reserved
for promoted versions. Use English for repository documentation, issues, and pull requests.

Follow [the build guide](docs/BUILDING.md) for dependencies and tests. Commit source,
tests, manifests, and `Package.resolved`; leave generated Xcode projects, model weights,
build outputs, credentials, indexes, logs, and local planning notes out of Git.

For behavior changes, reproduce the problem with a meaningful regression test.
Run the build-tool checks for script changes and the Swift release test gate for
indexing/search/OCR changes. Documentation-only changes need link and example checks,
not a new copy of every application test. Publishing always requires the release gates.

## Reporting a bug

Include the app version or source commit, macOS version, Apple Silicon model, steps
to reproduce, expected behavior, and actual behavior. A small synthetic fixture is
preferable to an original document. Redact names, paths, queries, and credentials
from screenshots or logs before attaching them.

Report security concerns through a private channel; see [SECURITY.md](SECURITY.md).
