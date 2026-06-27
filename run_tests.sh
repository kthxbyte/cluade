#!/bin/sh
# Run the cluade test suite. Tests resolve modules via cwd-relative paths, so
# they must run from the repo root -- this script cd's there first, so it works
# no matter where it is invoked from.
cd "$(dirname "$0")" || exit 1

fail=0
for t in tests/test_*.lua; do
  if lua5.1 "$t" >/dev/null 2>&1; then
    echo "PASS  $t"
  else
    echo "FAIL  $t"
    lua5.1 "$t" 2>&1 | sed 's/^/      /'
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "\nAll tests passed."
else
  echo "\nSome tests FAILED."
fi
exit $fail
