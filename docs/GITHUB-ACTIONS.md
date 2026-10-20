# GitHub Actions builds

## Branches and downloads

The [build workflow](../.github/workflows/build.yml) runs on pushes to `main` and
`dev`, and can also be started manually from the Actions tab. A local commit without
a push does not start a hosted build. New pushes cancel older runs for the same branch.

A standard `macos-26` GitHub-hosted runner builds for Apple Silicon. It installs missing
build tools, verifies the pinned model checksum, restores downloaded dependencies,
runs tests, builds the complete DMG, verifies its contents, and runs the offline self-test.
The current `dev` workflow uses the shared release test gate.

Download the DMG and checksum under **Actions → Run → Artifacts**. The latest successful
DMG per branch is retained for up to three days. Failure diagnostics are kept for up
to one day, with a bounded number of diagnostic artifacts. Failed runs do not replace
the previous successful download. Machine-specific compiled caches are not shared.

This workflow does not publish GitHub Releases; [local publishing](LOCAL-RELEASE.md)
is a separate path.

## Runner costs

The workflow selects a standard hosted runner, not a larger runner. Included minutes,
storage, and billing depend on repository visibility and the owner's plan. Review
[GitHub's current Actions billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and configure account budgets if paid overages must be blocked. A workflow cannot
enforce the owner's account-wide billing budget.

## Apple signing and notarization

Only `main` reads Apple repository secrets. `dev` artifacts are ad-hoc signed. Without
any Apple secrets, `main` also creates an ad-hoc-signed development package. A partially
configured signing setup fails rather than silently falling back.

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12`, including its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Nonempty password protecting that `.p12` export |
| `APPLE_ID` | Apple Account used for the developer membership |
| `APPLE_TEAM_ID` | Ten-character developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific Apple password for `notarytool` |

A **Developer ID Application** identity with its private key is required. An Apple
Development identity or a certificate without its key cannot replace it. The current
DMG does not require a Developer ID Installer identity; the app does not use additional
Developer ID capabilities requiring a provisioning profile.

Copy a certificate export's Base64 representation without printing it:

```bash
base64 -i /path/to/Developer-ID.p12 | pbcopy
```

Keep secret values out of commits, issues, workflow files, and logs. The runner uses
a temporary keychain, checks certificate type and team, signs and notarizes the app
and DMG, validates stapled tickets, and removes temporary credentials afterward.
The signing result is reported in the workflow summary.

Local signing success does not establish that GitHub's secrets are configured.
Validate hosted signing with a successful `main` run after configuring them.

## References

- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Signing Xcode applications on runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
