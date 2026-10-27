#!/bin/sh
# Builds the helper for both Mac architectures and signs it ad hoc. The Ogg
# Vorbis decoder (vorbis/stb_vorbis.c, public domain) is compiled in as C.
set -e
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/mcoverlay-build"
mkdir -p "$out"
for arch in arm64 x86_64; do
  clang -O2 -w -target "$arch-apple-macos12" -c vorbis/stb_vorbis.c -o "$out/vorbis-$arch.o"
  swiftc -O -target "$arch-apple-macos12" -import-objc-header vorbis/bridge.h \
    main.swift screens.swift player.swift server.swift host.swift pet.swift music.swift "$out/vorbis-$arch.o" -o "$out/$arch"
done
lipo -create "$out/arm64" "$out/x86_64" -output MCOverlay
codesign --force --sign - MCOverlay
rm -rf "$out"
