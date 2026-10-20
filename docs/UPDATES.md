# In-app updates

LocalSeek 1.2.0 and later use [Sparkle 2](https://sparkle-project.org/documentation/).
Install an updater-enabled DMG once. Earlier versions cannot discover this feature
on their own.

## App behavior

- Automatic checks are enabled by default, approximately once every 24 hours while
  the app is running. Users can disable them in **Settings → Updates**.
- **Check for Updates** also works when automatic checks are disabled. Available
  updates are offered through Sparkle's download, installation, and relaunch UI.
  Installation requires confirmation by default; Sparkle also lets users opt into
  automatic downloads and installation.
- A menu bar update symbol and an **Show Update** action remain available while an
  update is being offered. The updater does not interrupt another app to take focus.
- Stable builds default to stable updates. Builds produced by `Scripts/build.sh`
  on `dev` also accept development previews. The user can change this preference.
  Disabling previews does not downgrade an already installed preview.
- Search and OCR require no internet connection. Update checks contact GitHub and
  its download infrastructure, which receive ordinary connection/request metadata
  such as IP address and app version. No document contents, indexed paths, or search
  queries are sent. Sparkle system profiling is disabled.
- Index data and settings remain outside the application bundle. An update replaces
  the app; the existing asynchronous shutdown closes the index before termination.

## Trust and hosting

The public HTTPS feed is
`https://raw.githubusercontent.com/nasch72kadse/LocalSeek/updates/appcast.xml`.
The separate `updates` branch contains only the signed feed. It is not a source or
build branch. Versioned DMGs remain immutable GitHub Release assets.

The app authenticates feeds and requires Ed25519 signatures on downloads before
extraction. Sparkle's default 20-day recovery window applies if feed authentication
continually fails; it then strips untrusted informational metadata and still
requires a valid update archive. Published apps and DMGs must additionally be Developer
ID signed, notarized, and stapled. Sparkle's nested helpers are signed inside-out.
Its framework and signing tools are pinned to 2.10.0; downloads have pinned hashes.

The private update key lives in the login Keychain under Sparkle's account
`com.localseek.updates`. Only its public key is committed. On the configured release
Mac no additional setup is needed. For a replacement release Mac, securely transfer
the existing key using Sparkle's `generate_keys -x` / `-f` options with this account.
Keep an encrypted backup outside the repository. Do not generate an unrelated key
and replace the public key in an established release; existing installations trust
the original key. See [Sparkle key rotation](https://sparkle-project.org/documentation/#rotating-signing-keys).

## Publication and recovery

The local publisher validates the signing key and authenticates the previous feed
before building. Increment **CURRENT_PROJECT_VERSION** in `project.yml` for **every**
published build, across both branches. It must exceed all existing feed build numbers;
changing a Git tag or only the marketing version is insufficient.

After tests, packaging, notarization, and the offline self-test, the publisher signs
the DMG and the next feed. It publishes the release, checks the uploaded asset's size
and GitHub SHA-256 digest, and only then advances the feed branch. A concurrent feed
publisher is rejected by a non-fast-forward check. Failures keep the previous feed.
Stable feed entries are preserved when publishing previews.

If a complete release was published but feed publication failed, retain the exact
clean source checkout and local package, correct the reported problem, then run:

```bash
bash Scripts/publish-release.sh --publish --resume
```

This verifies the existing tag points to the current commit, rechecks the actual
package and public assets, and retries only the feed publication. It cannot overwrite
a release or bypass tests. It still requires a build number newer than the feed.
Incomplete/draft releases require inspection; this command does not repair uploads.

GitHub Actions builds and tests packages but does not publish update feeds. The
production Sparkle private key is not required on the hosted runner. A future Actions
publisher would need secure signing-key provisioning as well as the Apple credentials.

## Verification

The release gate includes unit tests for updater startup, persisted preferences,
channel defaults, and manual checking, plus build-tool tests for feed retention,
monotonic build numbers, publication failures, and concurrent publishers. Integration
tests use an ephemeral key and the real Sparkle tools to reject modified archives and
feeds. Bundle checks inspect the actual Info.plist and every embedded Sparkle helper.
These code checks do not automate clicking the updater or replacing a running user
installation.
