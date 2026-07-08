#!/usr/bin/env bash
# Create a simple drag-to-Applications DMG from agentNotch.app.
# Usage: ./scripts/make-dmg.sh [path/to/agentNotch.app] [output.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-"$ROOT/dist/agentNotch.app"}"
DMG="${2:-"$ROOT/dist/agentNotch.dmg"}"

if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP (run ./scripts/package-app.sh first)" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/agentNotch.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "agentNotch" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "==> DMG ready: $DMG"
