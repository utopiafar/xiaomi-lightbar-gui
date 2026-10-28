#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="${1:-$project_dir/build/artifacts}"
mkdir -p "$artifact_dir"
export MACOSX_DEPLOYMENT_TARGET=13.0

cargo test --locked --manifest-path "$project_dir/core/Cargo.toml"
cargo build --locked --release --manifest-path "$project_dir/core/Cargo.toml" --target aarch64-apple-darwin
cargo build --locked --release --manifest-path "$project_dir/core/Cargo.toml" --target x86_64-apple-darwin
universal_core="$project_dir/core/target/liblightbar_core_universal.dylib"
lipo -create \
  "$project_dir/core/target/aarch64-apple-darwin/release/liblightbar_core.dylib" \
  "$project_dir/core/target/x86_64-apple-darwin/release/liblightbar_core.dylib" \
  -output "$universal_core"

cd "$project_dir/desktop"
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --release --no-pub
app_dir="$project_dir/desktop/build/macos/Build/Products/Release/Xiaomi Lightbar.app"
test -d "$app_dir"
cp "$universal_core" "$app_dir/Contents/Frameworks/liblightbar_core.dylib"

# Create separate, self-contained packages and verify every bundled Mach-O has
# the requested architecture. Ad-hoc signing is for local testing only.
for arch in arm64 x86_64; do
  stage_dir="$project_dir/build/macos-$arch"
  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  ditto "$app_dir" "$stage_dir/Xiaomi Lightbar.app"
  while IFS= read -r -d '' binary; do
    if file -b "$binary" | grep -q 'Mach-O'; then
      lipo -verify_arch "$arch" "$binary"
      lipo "$binary" -thin "$arch" -output "$binary.thin"
      chmod --reference="$binary" "$binary.thin" 2>/dev/null || chmod +x "$binary.thin"
      mv "$binary.thin" "$binary"
    fi
  done < <(find "$stage_dir/Xiaomi Lightbar.app" -type f -print0)
  codesign --force --deep --sign - "$stage_dir/Xiaomi Lightbar.app"
  codesign --verify --deep --strict "$stage_dir/Xiaomi Lightbar.app"
  cp "$project_dir/LICENSE" "$stage_dir/LICENSE.txt"
  python3 "$project_dir/scripts/collect-notices.py" "$stage_dir/THIRD_PARTY_NOTICES.txt"
  cp "$project_dir/docs/INSTALL-MAC.txt" "$stage_dir/README.txt"
  ditto -c -k --sequesterRsrc "$stage_dir" "$artifact_dir/xiaomi-lightbar-macos-$arch.zip"
  printf 'Built: %s\n' "$artifact_dir/xiaomi-lightbar-macos-$arch.zip"
done
