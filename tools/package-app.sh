#!/usr/bin/env bash
#
# package-app.sh — build, assemble and sign dist/Rukey.app.
#
# Packaging steps:
#   1. swift build -c release
#   2. assemble dist/Rukey.app/Contents/{MacOS,Resources}
#   3. embed the dictionaries so Bundle.module resolves inside the .app
#   4. sign with the "Rukey Local Signing" identity (hardened runtime)
#   5. print the resulting bundle path
#
# PRODUCT_NAME selects the executable product that becomes the app's main
# binary. The console `rukey` product stays CLI-only and is never packaged.
#
# Resource bundle: Package.swift declares `.process("Resources")` for the
# RukeyCore target. SwiftPM turns that into the compiled bundle
# `Rukey_RukeyCore.bundle` (package name + target name) containing the
# processed resource files. The script copies that bundle wholesale into
# Contents/Resources instead of assuming individual file names — that copy
# list is exactly what the `.process("Resources")` declaration produces, and
# Bundle.module looks for `Rukey_RukeyCore.bundle` next to the executable's
# main-resource directory (Contents/Resources for a .app).
#
# Signing: the identity must be listed by `security find-identity -v -p
# codesigning`, i.e. trusted; create it once with tools/make-signing-cert.sh.
# Hardened runtime (`--options runtime`) is kept — it signs fine with the
# self-signed identity. Re-running the script rebuilds and re-signs the bundle
# with the same certificate; the identity and bundle identifier never change.
#
set -euo pipefail

PRODUCT_NAME="RukeyGUI"
APP_NAME="Rukey"
RESOURCE_BUNDLE_NAME="Rukey_RukeyCore.bundle"
IDENTITY_NAME="${SIGNING_IDENTITY:-Rukey Local Signing}"
APP_VERSION="${APP_VERSION:-1.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$ROOT_DIR/Sources/RukeyGUI/Resources/Info.plist"
ICON_FILE="$ROOT_DIR/Sources/RukeyGUI/Resources/Rukey.icns"

cd "$ROOT_DIR"

echo "Building $PRODUCT_NAME (release)..." >&2
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# Preconditions checked before dist/ is touched: the resource bundle, the
# executable product and a trusted signing identity must all exist. A failure
# in a later step (install, cp, codesign) can still leave a partial
# dist/Rukey.app behind; the next run replaces it (see `rm -rf` below).
if [ ! -d "$BIN_DIR/$RESOURCE_BUNDLE_NAME" ]; then
  echo "error: $BIN_DIR/$RESOURCE_BUNDLE_NAME was not produced." >&2
  echo "       Check the .process(\"Resources\") declaration for the RukeyCore" >&2
  echo "       target in Package.swift; SwiftPM names the bundle" >&2
  echo "       <Package>_<Target>.bundle." >&2
  exit 1
fi

if [ ! -f "$BIN_DIR/$PRODUCT_NAME" ]; then
  echo "error: $BIN_DIR/$PRODUCT_NAME was not produced." >&2
  echo "       Check PRODUCT_NAME at the top of this script against the" >&2
  echo "       executable products declared in Package.swift." >&2
  exit 1
fi

if [ ! -f "$ICON_FILE" ]; then
  echo "error: application icon is missing: $ICON_FILE" >&2
  exit 1
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"
if [ -z "$IDENTITY" ]; then
  echo "error: no valid code-signing identity named '$IDENTITY_NAME'." >&2
  echo "       Create it first with tools/make-signing-cert.sh." >&2
  untrusted="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"
  if [ -n "$untrusted" ]; then
    echo "       (An identity with that name exists as $untrusted" >&2
    echo "        but is not trusted; re-run tools/make-signing-cert.sh from" >&2
    echo "        an interactive Terminal to add the trust setting. Refusing" >&2
    echo "        to sign with an untrusted identity.)" >&2
  fi
  exit 1
fi

echo "Assembling $APP_DIR..." >&2
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

install -m 755 "$BIN_DIR/$PRODUCT_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/"
cp -R "$BIN_DIR/$RESOURCE_BUNDLE_NAME" "$APP_DIR/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
  "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" \
  "$APP_DIR/Contents/Info.plist"

echo "Signing with '$IDENTITY_NAME' ($IDENTITY)..." >&2
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP_DIR"

printf '%s\n' "$APP_DIR"
