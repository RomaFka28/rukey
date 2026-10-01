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

# Runs `swift test`, retrying ONLY when the macro plugin failed to resolve.
#
# Why: on this machine (Command Line Tools, no full Xcode) `swift test` intermittently
# fails with "plugin for module 'TestingMacros' not found". It is NOT deterministic: it
# fails on some consecutive runs and succeeds on the next, and a clean `rm -rf .build`
# does not prevent it. Measured on an unchanged tree: macro_errors 0, 0, 60, 0 across four
# consecutive runs. So the only reliable strategy is to retry until the log contains a real
# summary line. This is a SwiftPM/CLT plugin-resolution bug, not a problem with the code
# under test.
#
# The retry is keyed on "did the suite actually run", never on pass/fail. A genuine test
# failure produces a summary line and is reported immediately.
run_tests() {
    swift build >/dev/null 2>&1
    attempt=0
    while [ "$attempt" -lt 6 ]; do
        attempt=$((attempt + 1))
        swift test >"$LOG" 2>&1
        test_ran_at_all && return 0
        if ! grep -q "TestingMacros" "$LOG"; then
            # A real build error, not the flaky plugin. Report it, do not spin.
            return 1
        fi
        echo "  (macro plugin flake on attempt $attempt, retrying)" >&2
    done
    return 1
}

# True when the suite produced a summary line, which means the tests actually executed.
test_ran_at_all() {
    grep -q "Test run with" "$LOG"
}

summary_is() {
    grep -qE "Test run with .* $1" "$LOG"
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