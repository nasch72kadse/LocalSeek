# Security and sensitive reports

LocalSeek indexes local documents. Its SQLite index contains extracted text and
should be protected like the source documents. The app uses the selected folders,
a local model, and an isolated OCR helper; it does not need a cloud search API.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting option when available, or contact the
repository owner through an existing private channel. Do not publish an exploitable
issue together with sensitive documents, credentials, or personal file paths.

Provide the affected version/commit, platform, reproduction steps, impact, and a
minimal synthetic example where possible. Do not attach your real index database,
keychain exports, signing keys, Apple passwords, or GitHub tokens.

## Development and distribution

Keep credentials in the macOS keychain or GitHub Actions secrets. `.env.local` is an
ignored local shell configuration, not a place for password values. Build artifacts
and local diagnostic exports are excluded from the source tree.

The distribution checks validate signatures, notarization tickets, bundled model
checksums, source provenance, offline behavior, and accidental private bundle content.
These checks do not replace protecting the user account or reviewing files before sharing.
