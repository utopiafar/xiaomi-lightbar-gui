#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/build}"
app_dir="$output_dir/小米挂灯控制.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/mac/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

architecture="$(uname -m)"
xcrun --sdk macosx swiftc -target "$architecture-apple-macosx13.0" \
    -swift-version 5 -parse-as-library \
    "$project_dir/mac/LampApp.swift" "$project_dir/mac/SerialBridge.swift" \
    -framework SwiftUI -framework AppKit \
    -o "$app_dir/Contents/MacOS/launcher"

codesign --force --sign - "$app_dir"
codesign --verify "$app_dir"
printf 'Built: %s\n' "$app_dir"
