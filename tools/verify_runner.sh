#!/bin/sh
# Verify the test runner can actually fail.
#
# A green run proves nothing until you have seen it go red. This injects a bug into the
# single-alphabet guarantee, confirms the suite fails with a non-zero exit code, then
# restores the file and confirms it is green again.
#
# Usage: tools/verify_runner.sh
#
# No `set -e` on purpose: this script's whole job is to observe failures, and `set -e`
# kills the script at the first non-zero status, including the ones we are looking for.
# Every step checks its own status explicitly.
cd "$(dirname "$0")/.."

TARGET="Sources/RukeyCore/Intent.swift"
BACKUP=$(mktemp /tmp/rukey-intent.XXXXXX.swift)
LOG=$(mktemp /tmp/rukey-testlog.XXXXXX)
cp "$TARGET" "$BACKUP"

# Restore on any exit path, including a signal. The restore below also happens inline,
# because the final check must observe the restored file, not wait for the trap.
cleanup() { cp "$BACKUP" "$TARGET"; rm -f "$BACKUP" "$LOG"; }
trap cleanup EXIT HUP INT TERM

# Runs `swift test` and prints the summary line.
#
# Why the retry: on this machine (Command Line Tools only, no full Xcode) the FIRST
# `swift test` after any Swift source edit fails with "plugin for module 'TestingMacros'
# not found". The second invocation succeeds. This is a SwiftPM/CLT plugin-resolution
# bug, not a problem with the code under test. Verified: same file, same tree, run 1 has
# 56 macro errors, run 2 reports real results.
run_tests() {
    # A prior `swift build` is required: restoring a file to content the build system
    # already has cached does not reliably invalidate the object file, and the next run
    # reports stale results. Touch alone is not enough.
    swift build >/dev/null 2>&1
    swift test >"$LOG" 2>&1
    # The TestingMacros retry. The macro plugin lives in
    # CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib, and the
    # first `swift test` after a source edit sometimes fails to resolve it. The retry only
    # fires on that specific failure, so a genuine test failure is never masked. Two
    # attempts, because it sometimes takes more than one.
    attempt=0
    while grep -q "TestingMacros" "$LOG" && [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        swift test >"$LOG" 2>&1
    done
}

# True when the run failed for a test reason rather than a build/macro reason. Without
# this distinction a broken build is misreported as "the suite stayed green".
summary_is() {
    grep -qE "Test run with .* $1" "$LOG"
}

test_ran_at_all() {
    grep -q "Test run with" "$LOG"
}

echo "== baseline =="
run_tests
grep -E "Test run with" "$LOG" || { echo "FAIL: no test summary at all" >&2; exit 1; }

echo "== injecting: reencode() returns a mixed-alphabet string =="
python3 - "$TARGET" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
needle = "            out.append(produced)"
assert needle in src, "anchor line not found; the file changed shape"
src = src.replace(needle, needle + "\n            if out.count == 1 { out.append(ch) }", 1)
open(path, 'w', encoding='utf-8').write(src)
PY

run_tests
if ! test_ran_at_all; then
    echo "FAIL: the suite never ran; the build is broken" >&2
    grep -E "error" "$LOG" | head -3 >&2
    exit 1
fi

if summary_is failed; then
    echo "OK: the suite went red"
else
    echo "FAIL: the suite stayed green with a bug in the core guarantee" >&2
    grep -E "Test run with" "$LOG" | head -3 >&2
    exit 1
fi

if swift test >/dev/null 2>&1; then
    echo "FAIL: a failing run still exited 0" >&2
    exit 1
else
    echo "OK: a failing run exits non-zero"
fi

echo "== restoring =="
cp "$BACKUP" "$TARGET"
run_tests
if ! test_ran_at_all; then
    echo "FAIL: the suite never ran after restore" >&2
    grep -E "error" "$LOG" | head -3 >&2
    exit 1
fi
if summary_is passed; then
    echo "OK: green again after restore"
else
    echo "FAIL: still red after restore" >&2
    grep -E "Test run with" "$LOG" | head -3 >&2
    exit 1
fi

echo "runner verified: fails when it should, passes when it should"