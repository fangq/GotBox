#!/bin/sh
# Robust test runner: compile each console test, run it under a hard timeout so
# a hang fails fast instead of blocking forever, and print a one-line summary
# per test. Exits non-zero if any test fails. Override TIMEOUT/FPC as needed.
#
#   tests/run.sh            # run all tests
#   TIMEOUT=60 tests/run.sh # longer per-test cap

cd "$(dirname "$0")" || exit 2

FPC="${FPC:-fpc}"
TIMEOUT="${TIMEOUT:-30}"
OUT=lib
mkdir -p "$OUT"

# fast, watcher-independent tests first; timed/integration tests last
TESTS="testgit testauth testlink testremote testworker testsync testhistory"

fail=0
for t in $TESTS; do
  [ -f "$t.lpr" ] || continue
  if ! "$FPC" -Fu../src/core -FU"$OUT" -o"$t" "$t.lpr" >"$OUT/$t.build.log" 2>&1; then
    echo "BUILD-FAIL  $t"
    grep -iE "error|fatal" "$OUT/$t.build.log" | head -5
    fail=1
    continue
  fi
  start=$(date +%s)
  if timeout "$TIMEOUT" "./$t" >"$OUT/$t.run.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  dur=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %-12s %2ds\n' "$t" "$dur"
  elif [ "$rc" -eq 124 ]; then
    printf 'TIMEOUT %-10s (>%ss)\n' "$t" "$TIMEOUT"
    tail -8 "$OUT/$t.run.log"
    fail=1
  else
    printf 'FAIL  %-12s (exit %d)\n' "$t" "$rc"
    tail -8 "$OUT/$t.run.log"
    fail=1
  fi
done

echo '----------------------------------------'
if [ "$fail" -eq 0 ]; then
  echo 'ALL SUITES PASSED'
else
  echo 'SOME SUITES FAILED'
fi
exit "$fail"
