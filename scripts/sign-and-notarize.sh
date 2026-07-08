#!/usr/bin/env bash
# Sign (and optionally notarize) an agentNotch.app built by package-app.sh.
#
# Required for local/dev signing:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#
# Required for notarization (distribution to other Macs):
#   APPLE_ID        Apple ID email
#   APPLE_TEAM_ID   10-char Team ID
#   APPLE_APP_PASSWORD  app-specific password (appleid.apple.com)
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/sign-and-notarize.sh dist/agentNotch.app
#   SIGN_IDENTITY="…" APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… ./scripts/sign-and-notarize.sh dist/agentNotch.app
set -euo pipefail

APP="${1:?Usage: $0 path/to/agentNotch.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "SIGN_IDENTITY is required (Developer ID Application: …)" >&2
  echo "For ad-hoc local-only: SIGN_IDENTITY='-' $0 $APP" >&2
  exit 1
fi

ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/packaging/agentNotch.entitlements"

echo "==> Codesigning $APP"

# Ad-hoc ('-') cannot use --timestamp / hardened runtime the same way as Developer ID.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp --entitlements "$ENTITLEMENTS")
fi

# Innermost first: resource bundle → hook → main binary → app.
if [[ -d "$APP/Contents/MacOS/agentNotch_agentNotch.bundle" ]]; then
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/agentNotch_agentNotch.bundle"
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/agentnotch-hook"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/agentNotch"
codesign "${SIGN_FLAGS[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Signature OK"

if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "==> Skipping notarization (set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD to enable)"
  exit 0
fi

ZIP="${APP%.app}-notarize.zip"
echo "==> Submitting for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl --assess --type execute --verbose "$APP" || true
echo "==> Notarized and stapled: $APP"
