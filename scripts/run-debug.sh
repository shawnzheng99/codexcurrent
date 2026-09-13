#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/Build/Debug/Codex Current.app"
cd "$project_root"
swift build -c debug
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$project_root/.build/debug/CodexCurrent" "$app_path/Contents/MacOS/CodexCurrent"
cp "$project_root/Packaging/Info.plist" "$app_path/Contents/Info.plist"
rm -rf "$app_path/Contents/Resources/CodexCurrent_CodexCurrent.bundle"
cp -R "$project_root/.build/debug/CodexCurrent_CodexCurrent.bundle" "$app_path/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.shawnzheng99.codexcurrent.debug' "$app_path/Contents/Info.plist"
if [[ -f "$project_root/Build/Codex Current.app/Contents/Resources/AppIcon.icns" ]]; then
    cp "$project_root/Build/Codex Current.app/Contents/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
fi
# No Developer ID signing, notarization, or release build in this local workflow.
open "$app_path" --args --expanded
