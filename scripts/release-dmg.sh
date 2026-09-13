#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/Build/Codex Current.app"
dist_dir="$project_root/Dist"
notary_profile="${NOTARY_PROFILE:-}"
sign_identity="${CODE_SIGN_IDENTITY:-}"

if [[ -z "$sign_identity" ]]; then
    sign_identity="$(
        security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
        head -n 1
    )"
fi

if [[ -z "$sign_identity" ]]; then
    echo "No Developer ID Application identity found in the keychain." >&2
    echo "Install the certificate, or set CODE_SIGN_IDENTITY explicitly." >&2
    exit 78
fi

if [[ -z "$notary_profile" ]]; then
    echo "NOTARY_PROFILE is required." >&2
    echo "Create one with: xcrun notarytool store-credentials PROFILE_NAME" >&2
    exit 78
fi

CODE_SIGN_IDENTITY="$sign_identity" zsh "$project_root/scripts/build-app.sh"

version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
dmg_path="$dist_dir/Codex-Current-$version.dmg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-current-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

mkdir -p "$dist_dir"
rm -f "$dmg_path"
ditto "$app_path" "$staging_dir/Codex Current.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -volname "Codex Current" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov \
    "$dmg_path"

codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
shasum -a 256 "$dmg_path"

echo "$dmg_path"
