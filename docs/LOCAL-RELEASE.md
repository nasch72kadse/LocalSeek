# Publish a signed release from your Mac

This guide describes the current **`dev`** release tooling. It builds, signs, notarizes,
and uploads a DMG from your Mac without a GitHub runner. Actions remains independent:
its existing branch-push triggers still run on source pushes. Creating a release tag
does not trigger that branch-only workflow.

## One-time setup

1. Import a **Developer ID Application** certificate and private key into the login
   keychain. Run `security find-identity -v -p codesigning` to list available identities.
   An Apple Development identity cannot replace it for distribution.
2. Install and authenticate GitHub CLI with access to releases and tags:

   ```bash
   brew install gh
   gh auth login --hostname github.com --git-protocol https --web
   ```

3. Create an app-specific password in your Apple Account. Store the notarization
   credentials interactively in the keychain:

   ```bash
   xcrun notarytool store-credentials LocalSeek
   ```

   Supply your Apple Account, developer team ID, and app-specific password. Choose
   the Apple Account route rather than an App Store Connect API key. Do not store
   the password in repository files.
4. Copy `.env.local.example` to `.env.local` and set the signing identity, preferably
   its full SHA-1 identifier. This shell configuration is ignored by Git and never
   loaded on Actions. `LOCALSEEK_TEST_SIGN_IDENTITY` can optionally identify an Apple
   Development certificate for local XCTest bundles; macOS tool permissions still apply.

## Build and publish

Start from a clean, committed `dev` checkout whose commit is already on GitHub:

```bash
LOCALSEEK_PUBLISH_RELEASE=1 Scripts/build.sh
```

Set the default publication flag in `.env.local` to `1` to publish after each local
release build; override it with `0` to disable uploading for one invocation. The
example activates signing when publication is enabled. Signing without publication
requires setting the signing and notarization variables independently. Debug builds
never publish.

Check credentials without building or uploading:

```bash
LOCALSEEK_PUBLISH_RELEASE=1 bash Scripts/publish-release.sh --check
```

The publisher does not push source commits or change branches. Missing signing,
notarization, or GitHub access stops publication, without ad-hoc fallback.

## Required checks

Before Apple uploads, release builds require complete unit/integration tests, real
OCR with blocked IP traffic, model inference, OCR timeouts/cancellation, queue
continuation, migrations, and build/network checks. Failed, missing, or skipped tests
stop the release. Processes and individual tests have bounded runtimes.

The receipt in `build/reports/release-tests.json` expires after 24 hours and is bound
to the commit, source/test hashes, macOS, and Xcode. Fresh runs revoke the previous
receipt first. Direct packaging and publishing commands require it too.

Before publishing, checks cover source provenance, version, Developer ID team,
timestamps, Hardened Runtime, signatures, stapled tickets, Gatekeeper, DMG contents,
and private paths/credential/index files. The actual packaged app must pass its
offline self-test. Only then is its exact source commit tagged and the assets uploaded.

The offline test denies IPv4/IPv6, including loopback, TCP/UDP, and IP binding. Unix
sockets remain available for Apple Vision/Core ML's local initialization. This local
IPC does not require an internet connection.

## Versions and retries

- `dev` publishes prereleases such as `v1.1.1-dev.0123456789ab` without replacing the
  latest stable release.
- `main` publishes regular tags such as `v1.1.1` after the intended version and release
  tooling have been promoted to that branch.
- Existing releases/tags are never overwritten. Increment `MARKETING_VERSION` and,
  for every published build, `CURRENT_PROJECT_VERSION` in `project.yml` for a new regular release.
  A development release requires a new committed source state. Build numbers must
  exceed all published stable and preview builds.
- `LOCALSEEK_RELEASE_TAG` may specify a custom tag starting with `v` and a digit,
  followed by letters, digits, dots, underscores, or hyphens.
- A network failure after tag creation can leave a tag or draft. Inspect GitHub before
  retrying; the publisher does not automatically delete or reuse them.

Downloads inherit the repository's visibility. Signing and notarization do not make
a private repository public.

References: [GitHub CLI](https://cli.github.com/manual/gh_release_create),
[Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## In-app update publication

The same local command signs and publishes the Sparkle feed after verifying the
GitHub Release assets. See [update keys, channels, and recovery](UPDATES.md).
The configured release Mac already holds its update key in the login Keychain.
