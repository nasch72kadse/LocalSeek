#!/bin/bash
set -euo pipefail
set +x
cd "$(dirname "$0")/../.."
required=(APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD)
present=0
for name in "${required[@]}"; do
  if [[ -n "${!name:-}" ]]; then present=$((present + 1)); fi
done
if [[ "$present" == 0 ]]; then
  echo 'Apple-Secrets noch nicht eingerichtet; dieser Build wird privat signiert.'
  exit 0
fi
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Apple-Secret fehlt: $name" >&2; exit 1; }
done
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]]
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]
umask 077
SIGNING_DIR="$(mktemp -d "$RUNNER_TEMP/localseek-signing.XXXXXX")"
KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
PASSWORD="$(openssl rand -hex 32)"
# Register cleanup paths before importing any secret, including on setup failures.
printf 'LOCALSEEK_CI_SIGNING_DIR=%s\nLOCALSEEK_CI_KEYCHAIN=%s\n' "$SIGNING_DIR" "$KEYCHAIN" >> "$GITHUB_ENV"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$SIGNING_DIR/certificate.p12"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$SIGNING_DIR/certificate.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN" > "$SIGNING_DIR/identities.txt"
IDENTITY="$(python3 - "$SIGNING_DIR/identities.txt" "$APPLE_TEAM_ID" <<'PY'
import pathlib,re,sys
pattern=r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"Developer ID Application: .+ \('+re.escape(sys.argv[2])+r'\)"'
matches=re.findall(pattern,pathlib.Path(sys.argv[1]).read_text(),re.M)
if len(matches)!=1:
    raise SystemExit('Genau ein gültiges Developer-ID-Application-Zertifikat für die Team-ID ist erforderlich.')
print(matches[0])
PY
)"
xcrun notarytool store-credentials LocalSeek-CI --keychain "$KEYCHAIN" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null
rm -f "$SIGNING_DIR/certificate.p12" "$SIGNING_DIR/identities.txt"
printf 'LOCALSEEK_SIGN_IDENTITY=%s\nLOCALSEEK_NOTARY_PROFILE=LocalSeek-CI\nLOCALSEEK_NOTARY_KEYCHAIN=%s\n' \
  "$IDENTITY" "$KEYCHAIN" >> "$GITHUB_ENV"
echo 'Developer-ID-Signierung und Notarisierungsprofil sind vorbereitet.'
