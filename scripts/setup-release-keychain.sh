#!/bin/bash
set -euo pipefail

# Called only by the tagged-release workflow. Values come from Actions secrets.
for variable in BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
    if [[ -z "${!variable:-}" ]]; then
        echo "::error::Missing Actions secret: $variable. See README.md for release setup." >&2
        exit 1
    fi
done
: "${RUNNER_TEMP:?This script requires the GitHub Actions temporary directory.}"
: "${GITHUB_ENV:?This script requires the GitHub Actions environment file.}"

umask 077
certificate_path="$RUNNER_TEMP/macdiff-signing.p12"
keychain_path="$RUNNER_TEMP/macdiff-signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
trap 'rm -f "$certificate_path"' EXIT
printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$certificate_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 7200 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" -P "$P12_PASSWORD" -k "$keychain_path" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path"
rm -f "$certificate_path"

identity_hashes="$(security find-identity -v -p codesigning "$keychain_path" \
    | awk '/"Developer ID Application:/ { print $2 }')"
if [[ -z "$identity_hashes" || "$identity_hashes" == *$'\n'* ]]; then
    echo "::error::The .p12 must contain exactly one valid Developer ID Application identity, including its private key." >&2
    exit 1
fi

# notarytool validates these credentials before tests and builds consume time.
xcrun notarytool store-credentials MacDiff-Notary \
    --keychain "$keychain_path" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
{
    echo "SIGNING_IDENTITY=$identity_hashes"
    echo "SIGNING_KEYCHAIN=$keychain_path"
    echo "NOTARY_PROFILE=MacDiff-Notary"
} >> "$GITHUB_ENV"
