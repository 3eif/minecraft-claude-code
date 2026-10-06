#!/bin/sh
# Builds the helper for both Mac architectures and signs it ad hoc.
set -e
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/mcoverlay-build"
mkdir -p "$out"
swiftc -O -target arm64-apple-macos12 main.swift screens.swift player.swift server.swift pet.swift -o "$out/arm64"
swiftc -O -target x86_64-apple-macos12 main.swift screens.swift player.swift server.swift pet.swift -o "$out/x86_64"
lipo -create "$out/arm64" "$out/x86_64" -output MCOverlay
codesign --force --sign - MCOverlay
rm -rf "$out"
