#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
cd "$project_dir"

swift scripts/generate-app-icon.swift
iconutil -c icns work/AppIcon.iconset -o Resources/AppIcon.icns

if [[ "$configuration" == "release" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
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
