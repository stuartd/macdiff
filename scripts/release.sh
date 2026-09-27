#!/bin/bash
set -euo pipefail

if [[ $# != 0 ]]; then
    echo "Usage: SIGNING_IDENTITY='Developer ID Application: …' NOTARY_PROFILE='…' $0" >&2
    exit 2
fi

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name or SHA-1.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile.}"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Commit or stash changes before releasing; the About commit must identify the released source." >&2
    exit 1
fi
commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short HEAD)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 1
fi
release_dir="$project_root/dist/releases"
release_name="MacDiff-${version}-${short_commit}"
final_zip="$release_dir/$release_name.zip"
if [[ -e "$final_zip" ]]; then
    echo "Release already exists: $final_zip" >&2
    exit 1
fi

# Check Keychain access before spending time building. No credential values are printed.
identities="$(security find-identity -v -p codesigning)"
if ! printf '%s\n' "$identities" | grep -F 'Developer ID Application:' | grep -Fq -- "$SIGNING_IDENTITY"; then
    echo "Developer ID signing identity not found: $SIGNING_IDENTITY" >&2
    exit 1
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null

mkdir -p "$release_dir"
work_dir="$(mktemp -d "$project_root/dist/.release.XXXXXX")"
trap 'result=$?; if [[ $result == 0 ]]; then rm -rf "$work_dir"; else printf "Release stopped. Build and diagnostics retained at: %s\n" "$work_dir" >&2; fi' EXIT

# A fresh scratch directory also regenerates the embedded commit and build time.
swift test --scratch-path "$work_dir/tests" 2>&1 | tee "$work_dir/tests.log"
MACDIFF_UNIVERSAL=1 MACDIFF_SCRATCH_PATH="$work_dir/build" \
    MACDIFF_OUTPUT_DIR="$work_dir/app" ./scripts/build-app.sh release 2>&1 | tee "$work_dir/build.log"
app="$work_dir/app/MacDiff.app"
architectures=" $(/usr/bin/lipo -archs "$app/Contents/MacOS/MacDiff") "
if [[ "$architectures" != *" arm64 "* || "$architectures" != *" x86_64 "* ]]; then
    echo "Universal build is missing an architecture:$architectures" >&2
    exit 1
fi

# Fail if source changed while tests/builds ran.
if [[ "$(git rev-parse HEAD)" != "$commit" || -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Source changed during the release build; start again from committed source." >&2
    exit 1
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

upload_zip="$work_dir/notarization.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$upload_zip"
# Capture JSON even on failure so Apple's status and submission ID can be inspected.
if ! xcrun notarytool submit "$upload_zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json > "$work_dir/submission.json"; then
    cat "$work_dir/submission.json"
    echo "Notarization did not complete successfully. Inspect the retained submission result." >&2
    exit 1
fi
cat "$work_dir/submission.json"
status="$(/usr/bin/plutil -extract status raw -o - "$work_dir/submission.json")"
submission_id="$(/usr/bin/plutil -extract id raw -o - "$work_dir/submission.json")"
if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" \
        "$work_dir/notarization-log.json" || true
    echo "Apple returned $status; no release ZIP was produced." >&2
    exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"

# Stapling changes the app. Publish only a new archive made after that step.
verified_zip="$work_dir/$release_name.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$verified_zip"
/usr/bin/ditto -x -k "$verified_zip" "$work_dir/check"
checked_app="$work_dir/check/MacDiff.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$checked_app"
xcrun stapler validate "$checked_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$checked_app"

cp "$work_dir/submission.json" "$release_dir/$release_name-notarization.json"
mv "$verified_zip" "$final_zip"
(cd "$release_dir" && shasum -a 256 "$release_name.zip" > "$release_name.zip.sha256")
cat "$release_dir/$release_name.zip.sha256"
printf 'Verified release: %s\n' "$final_zip"
