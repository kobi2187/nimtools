#!/bin/bash
# Build and run every test suite. Exits non-zero if any suite fails.
set -u
cd "$(dirname "$0")/.."
fail=0
for t in tests/test_*.nim; do
  if ! nim c --hints:off -r "$t" 2>&1 | grep -qE '\[FAILED\]|Error:'; then
    echo "PASS $(basename "$t")"
  else
    echo "FAIL $(basename "$t")"; fail=1
  fi
done
exit $fail
