#!/bin/bash
# Build Prompt Replace.app. Usage: ./build.sh [--install]
#   --install  copy to ~/Applications and (re)launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Prompt Replace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PromptReplace "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# A stable signing identity keeps the Accessibility grant valid across rebuilds;
# ad-hoc signing ("-") works but macOS will ask for permission again after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PromptReplace || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Prompt Replace.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Prompt Replace.app"
  echo "Installed to ~/Applications/Prompt Replace.app"
fi
