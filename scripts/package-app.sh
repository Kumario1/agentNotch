#!/usr/bin/env bash
# Build a distributable agentNotch.app (unsigned).
# Usage: ./scripts/package-app.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-"$ROOT/dist"}"
APP="$OUT/agentNotch.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"

echo "==> Building release binaries"
swift build -c release --product agentNotch
swift build -c release --product agentnotch-hook

BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN/agentNotch" "$MACOS/agentNotch"
cp "$BIN/agentnotch-hook" "$MACOS/agentnotch-hook"
chmod +x "$MACOS/agentNotch" "$MACOS/agentnotch-hook"

# SPM resource bundle must sit next to the executable for Bundle.module.
# Add Info.plist so codesign accepts the nested .bundle.
if [[ -d "$BIN/agentNotch_agentNotch.bundle" ]]; then
  cp -R "$BIN/agentNotch_agentNotch.bundle" "$MACOS/agentNotch_agentNotch.bundle"
  cp "$ROOT/packaging/ResourceBundle-Info.plist" \
    "$MACOS/agentNotch_agentNotch.bundle/Info.plist"
fi

cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"

# Optional app icon if present.
if [[ -f "$ROOT/packaging/AppIcon.icns" ]]; then
  cp "$ROOT/packaging/AppIcon.icns" "$RESOURCES/AppIcon.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$CONTENTS/Info.plist"
fi

echo "==> Done: $APP"
echo "    Install:  cp -R \"$APP\" /Applications/"
echo "    Open:     open \"$APP\""
echo "    Sign next: ./scripts/sign-and-notarize.sh \"$APP\""
