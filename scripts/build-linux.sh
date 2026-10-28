#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="${1:-$project_dir/build/artifacts}"
mkdir -p "$artifact_dir"

cargo build --locked --release --manifest-path "$project_dir/core/Cargo.toml"
cargo test --locked --manifest-path "$project_dir/core/Cargo.toml"
python3 "$project_dir/core/tests/serial_simulator.py" "$project_dir/core/target/release/liblightbar_core.so"

cd "$project_dir/desktop"
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build linux --release --no-pub

bundle_dir="$project_dir/desktop/build/linux/x64/release/bundle"
cp "$project_dir/core/target/release/liblightbar_core.so" "$bundle_dir/lib/"
cp "$project_dir/LICENSE" "$bundle_dir/LICENSE.txt"
python3 "$project_dir/scripts/collect-notices.py" "$bundle_dir/THIRD_PARTY_NOTICES.txt"
cp "$project_dir/docs/INSTALL-LINUX.txt" "$bundle_dir/README.txt"
tar -czf "$artifact_dir/xiaomi-lightbar-linux-x86_64.tar.gz" -C "$bundle_dir" .
printf 'Built: %s\n' "$artifact_dir/xiaomi-lightbar-linux-x86_64.tar.gz"
