#!/usr/bin/env bash
#
# make-signing-cert.sh — create the stable self-signed code-signing identity
# "Rukey Local Signing" used by tools/package-app.sh.
#
# Idempotent: the identity is created once and is never deleted, recreated or
# overwritten. Re-running prints the same SHA-1 hash; if a previous run imported
# the identity but could not add the trust setting, re-running retries only the
# trust step. A byte-identical certificate across runs is what lets the macOS
# Accessibility (TCC) grant survive app rebuilds: TCC stores the leaf
# certificate hash in the app's code requirement.
#
# Deviations from docs/superpowers/plans/2026-10-14-rukey-gui-shell.md:
#
#   1. The plan's openssl command is extended with -addext extensions
#      (basicConstraints=critical,CA:FALSE, keyUsage=critical,digitalSignature,
#      extendedKeyUsage=critical,codeSigning). Measured on macOS: without the
#      codeSigning EKU the certificate never appears in
#      `security find-identity -p codesigning`, so the plan's own verification
#      step ("print the SHA-1 hash find-identity reports") could not pass.
#
#   2. Trust is added in the *user* domain
#      (`security add-trusted-cert -r trustRoot -k login.keychain-db`), not the
#      admin domain with `-d` as written in the plan. `-d` writes to the
#      system-wide admin trust store and needs administrator authorization;
#      the user-domain setting needs no admin rights and is sufficient for both
#      `codesign` and the plan's `security find-identity -v` check — the effect
#      for this workflow is identical. If macOS refuses the trust change from
#      a non-interactive session, run this script from a regular Terminal.app
#      window (where the authorization prompt can be approved); nothing is
#      recreated by re-running.
#
#   3. The unencrypted private key PEM in /tmp is deleted after the import; the
#      key lives in the login keychain (imported with a /usr/bin/codesign read
#      ACL, so codesign never prompts). The certificate PEM is kept only for
#      the trust step and is re-exported from the keychain when missing.
#
#   4. The plan says to import the certificate and key "into a temporary
#      keychain"; this script imports them into the login keychain instead,
#      where the identity has to live for its whole life: the Accessibility
#      grant keys off the leaf certificate hash, so the identity must survive
#      app rebuilds, and codesign finds it through the login keychain without
#      extra flags or a search-list entry that a temporary keychain would need.
#
set -euo pipefail

IDENTITY_NAME="Rukey Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEY_PEM="/tmp/rukey-key.pem"
CERT_PEM="/tmp/rukey-cert.pem"

# All identities matching the name, whether trusted or not.
identity_hash_any() {
  security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
}

# Identities that are both present and trusted ("valid" for code signing).
identity_hash_valid() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
}

valid_hash="$(identity_hash_valid)"
if [ -n "$valid_hash" ]; then
  # Identity exists and is trusted: never touch it again.
  printf '%s\n' "$valid_hash"
  exit 0
fi

if [ -z "$(identity_hash_any)" ]; then
  echo "Generating self-signed code-signing certificate '$IDENTITY_NAME'..." >&2
  umask 077
  rm -f "$KEY_PEM" "$CERT_PEM"
  if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -days 3650 \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  then
    echo "error: openssl failed to create the certificate." >&2
    exit 1
  fi

  echo "Importing certificate and key into the login keychain..." >&2
  security import "$CERT_PEM" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign 1>&2
  security import "$KEY_PEM" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign 1>&2
  # The key now lives in the keychain; do not keep a plaintext copy around.
  rm -f "$KEY_PEM"
else
  # A previous run imported the identity but trust is still missing.
  if [ ! -f "$CERT_PEM" ]; then
    security find-certificate -c "$IDENTITY_NAME" -p "$LOGIN_KEYCHAIN" > "$CERT_PEM"
  fi
fi

echo "Trusting the certificate for code signing (user domain)..." >&2
if ! trust_output="$(security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$CERT_PEM" 2>&1)"; then
  echo "" >&2
  if [ -z "$trust_output" ]; then
    echo "error: macOS refused to add the trust setting for the certificate (no output)." >&2
  else
    echo "error: macOS refused to add the trust setting for the certificate:" >&2
    printf '%s\n' "$trust_output" >&2
  fi
  cat >&2 <<'EOF'

The identity is kept in the login keychain and will not be recreated.
Run this script from a regular Terminal.app window — that session can show
the authorization prompt — and approve it. Re-running only retries this
trust step and then prints the identity's SHA-1 hash.

EOF
  exit 1
fi

valid_hash="$(identity_hash_valid)"
if [ -z "$valid_hash" ]; then
  echo "error: '$IDENTITY_NAME' is still not listed as valid by" >&2
  echo "       security find-identity -v -p codesigning" >&2
  exit 1
fi

printf '%s\n' "$valid_hash"
