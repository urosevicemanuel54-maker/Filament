#!/bin/sh
# Build filament-core for iOS and package it as FilamentCore.xcframework.
#
# Needs a Mac, Rust (rustup) and the three iOS targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Then add the produced FilamentCore.xcframework to the Filament target
# (Frameworks, Libraries, and Embedded Content: "Do Not Embed"). Once it is
# there, `canImport(FilamentCore)` is true and the app decodes through Rust.

set -eu

cd "$(dirname "$0")"

PROFILE="${PROFILE:-release}"
OUT="../../FilamentCore.xcframework"

cargo build --profile "$PROFILE" --target aarch64-apple-ios
cargo build --profile "$PROFILE" --target aarch64-apple-ios-sim
cargo build --profile "$PROFILE" --target x86_64-apple-ios

DEVICE_DIR="target/aarch64-apple-ios/$PROFILE"
SIM_DIR="target/aarch64-apple-ios-sim/$PROFILE"
X86_DIR="target/x86_64-apple-ios/$PROFILE"

mkdir -p target/sim-universal
lipo -create "$SIM_DIR/libfilament_core.a" "$X86_DIR/libfilament_core.a" \
    -output target/sim-universal/libfilament_core.a

rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/libfilament_core.a" -headers include \
    -library target/sim-universal/libfilament_core.a -headers include \
    -output "$OUT"

echo "Built $OUT"
