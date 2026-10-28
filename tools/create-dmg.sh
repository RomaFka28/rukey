#!/usr/bin/env bash
#
# create-dmg.sh — create a drag-and-drop macOS installer for Rukey.app.
#
set -euo pipefail

APP_VERSION="${APP_VERSION:-1.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Rukey.app"
OUTPUT="$ROOT_DIR/dist/Rukey-${APP_VERSION}.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rukey-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [ ! -d "$APP_DIR" ]; then
  echo "error: $APP_DIR is missing; run tools/package-app.sh first." >&2
  exit 1
fi

mkdir -p "$STAGING_DIR/Rukey"
cp -R "$APP_DIR" "$STAGING_DIR/Rukey/"
ln -s /Applications "$STAGING_DIR/Rukey/Applications"
rm -f "$OUTPUT"

hdiutil create \
  -volname "Rukey ${APP_VERSION}" \
  -srcfolder "$STAGING_DIR/Rukey" \
  -ov \
  -format UDZO \
  "$OUTPUT" >/dev/null

printf '%s\n' "$OUTPUT"
