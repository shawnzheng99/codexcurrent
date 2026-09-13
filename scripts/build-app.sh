#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/Build/Codex Current.app"
binary_path="$project_root/.build/release/CodexCurrent"
icon_source="$project_root/app_icon.png"
sign_identity="${CODE_SIGN_IDENTITY:--}"

cd "$project_root"
swift build -c release

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/CodexCurrent"
cp "$project_root/Packaging/Info.plist" "$app_path/Contents/Info.plist"
zsh "$project_root/scripts/make-icon.sh" "$icon_source" "$app_path/Contents/Resources/AppIcon.icns"

if [[ "$sign_identity" == "-" ]]; then
    codesign --force --sign - "$app_path"
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$sign_identity" \
        "$app_path"
fi

echo "$app_path"
