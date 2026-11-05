#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# > 1 )) || [[ $# -eq 1 && "${1:-}" != "--universal" ]]; then
  print -u2 "Usage: zsh scripts/build.sh [--universal]"
  exit 64
fi
POOL_ARCH_FLAGS=()
POOL_DEFAULT_BUILD_ROOT=".build/package"
if [[ "${1:-}" == "--universal" ]]; then
  POOL_ARCH_FLAGS=(--arch arm64 --arch x86_64)
  POOL_DEFAULT_BUILD_ROOT=".build/package-universal"
fi
POOL_PACKAGE_BUILD_ROOT="${POOL_BUILD_ROOT:-$POOL_DEFAULT_BUILD_ROOT}"
swift build --scratch-path "$POOL_PACKAGE_BUILD_ROOT" "${POOL_ARCH_FLAGS[@]}" -c release -Xswiftc -DPOOL_PACKAGED_BUILD
BIN_DIR="$(swift build --scratch-path "$POOL_PACKAGE_BUILD_ROOT" "${POOL_ARCH_FLAGS[@]}" -c release -Xswiftc -DPOOL_PACKAGED_BUILD --show-bin-path)"
APP="dist/Claude Pool.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudePool" "$APP/Contents/MacOS/ClaudePool"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# cp -R merges into an existing bundle, so a copy left by an earlier build (with its own Contents/Resources
# and an older catalog, which Bundle reads first) would shadow the new strings. Replace it whole.
rm -rf "$APP/Contents/Resources/ClaudeDesktopPool_PoolCore.bundle"
cp -R "$BIN_DIR/ClaudeDesktopPool_PoolCore.bundle" "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
swiftc -parse-as-library -o .build/make-icon Sources/ClaudePool/PoolIconArt.swift scripts/make-icon.swift
.build/make-icon
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
strip -S -x "$APP/Contents/MacOS/ClaudePool"
codesign --force --sign "${POOL_SIGNING_IDENTITY:--}" --options runtime "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
