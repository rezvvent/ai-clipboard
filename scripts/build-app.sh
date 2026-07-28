#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
cd "$project_dir"

if [[ "$configuration" == "release" ]]; then
    api_url="$(/usr/libexec/PlistBuddy -c 'Print :AIClipboardAPIBaseURL' Resources/Info.plist 2>/dev/null || true)"
    if [[ -z "$api_url" || "$api_url" == *"REPLACE"* || "$api_url" != https://* ]]; then
        echo "Release blocked: Resources/Info.plist must contain the deployed HTTPS backend URL in AIClipboardAPIBaseURL." >&2
        echo "Deploy server/render.yaml first, set the resulting https://... address, then rebuild." >&2
        exit 2
    fi
fi

swift scripts/generate-app-icon.swift
iconutil -c icns work/AppIcon.iconset -o Resources/AppIcon.icns

if [[ "$configuration" == "release" ]]; then
    if [[ -d "/Applications/Xcode.app" ]]; then
        swift build -c release --arch arm64 --arch x86_64
        binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
    else
        echo "Full Xcode is unavailable; building a native release for $(uname -m)."
        swift build -c release
        binary_dir="$(swift build -c release --show-bin-path)"
    fi
else
    swift build -c "$configuration"
    binary_dir="$(swift build -c "$configuration" --show-bin-path)"
fi
app_dir="$project_dir/.build/AI Clipboard.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/AIClipboard" "$app_dir/Contents/MacOS/AIClipboard"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp -R "$project_dir/Resources/en.lproj" "$app_dir/Contents/Resources/"
cp -R "$project_dir/Resources/ru.lproj" "$app_dir/Contents/Resources/"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
