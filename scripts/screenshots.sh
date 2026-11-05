#!/bin/zsh
# Capture only deterministic demo views in offscreen windows.
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/.build/screenshots"
mkdir -p "$output" "$PWD/docs/images"
build_flags=()
if [[ "${2:-}" == "--skip-build" ]]; then build_flags+=(--skip-build); fi
CLAUDE_POOL_SCREENSHOTS="$output" swift test --scratch-path "${CLAUDE_POOL_UI_SCRATCH:-.build/ui-check}" --filter "${1:-ScreenshotTests.testRender}" "${build_flags[@]}"
for language in en zh-Hans zh-Hant ja ko; do
  for theme in light dark; do
    for screen in pool accounts routing usage settings setup menu; do
      if [[ -f "$output/$screen-$language-$theme.png" ]]; then
        cp "$output/$screen-$language-$theme.png" "$PWD/docs/images/"
      fi
    done
  done
done
print "Demo screenshots: $output"
