#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
zsh scripts/build.sh "$@"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"
if [[ "${1:-}" == "--universal" ]]; then ARCH="universal"; fi
OUT="dist/Claude-Pool-${VERSION}-${ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent 'dist/Claude Pool.app' "$OUT"
# The checksum names the bare file, so `shasum -c` works next to the download.
(cd dist && shasum -a 256 "${OUT:t}" > "${OUT:t}.sha256")
echo "Packaged $OUT (not notarized by this script)"
