#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 2
fi

configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "MacDiff requires macOS 14 or later and a Swift 6 toolchain." >&2
    exit 1
fi

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_root/dist"
app_path="$output_dir/MacDiff.app"

swift build --package-path "$project_root" --configuration "$configuration" --product MacDiff
binary_dir="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"

mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.macdiff-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/MacDiff.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

cp "$binary_dir/MacDiff" "$staged_app/Contents/MacOS/MacDiff"
cp "$project_root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
chmod +x "$staged_app/Contents/MacOS/MacDiff"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"

# Generate standard and Retina icon sizes from the source artwork.
icon_source="$project_root/icon/icon.png"
iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$iconset" --output "$staged_app/Contents/Resources/AppIcon.icns"

# This development signature supports local use; it does not notarize the app.
/usr/bin/codesign --force --sign - --timestamp=none "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

# Replace an existing build only after the new bundle is complete and verified.
rm -rf "$app_path"
mv "$staged_app" "$app_path"
printf 'Built %s\n' "$app_path"
printf 'Launch with: open "%s"\n' "$app_path"
