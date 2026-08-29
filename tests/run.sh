#!/bin/bash
# Build and run every test suite. Exits non-zero if any suite fails.
set -u
cd "$(dirname "$0")/.."
fail=0
for t in tests/test_*.nim; do
  # The exit code is checked, not just the output: a suite that segfaults prints
  # no '[FAILED]' at all, so matching on text alone reported a crash as a PASS.
  # That is how a stack overflow in every scope-aware tool went unnoticed.
  out=$(nim c --hints:off -r "$t" 2>&1); rc=$?
  if [ $rc -eq 0 ] && ! grep -qE '\[FAILED\]|Error:' <<<"$out"; then
    echo "PASS $(basename "$t")"
  else
    echo "FAIL $(basename "$t") (exit $rc)"
    printf '%s\n' "$out" | tail -15
    fail=1
  fi
done
exit $fail
