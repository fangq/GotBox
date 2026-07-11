#!/bin/sh
# Robust test runner: compile each console test, run it under a hard timeout so
# a hang fails fast instead of blocking forever, and print a one-line summary
# per test. Exits non-zero if any test fails. Override TIMEOUT/FPC as needed.
#
#   tests/run.sh            # run all tests
#   TIMEOUT=60 tests/run.sh # longer per-test cap

cd "$(dirname "$0")" || exit 2

FPC="${FPC:-fpc}"
TIMEOUT="${TIMEOUT:-300}"   # headroom for the multi-machine / binary E2E tests
                            # (Windows CI spawns git ~10x slower than Linux)
OUT=lib
mkdir -p "$OUT"

# Run hermetically w.r.t. git config: point global/system config at an empty
# file so tests don't inherit (or depend on) the developer's git identity --
# this makes local runs match CI and catches "no committer identity" bugs.
: > "$OUT/empty.gitconfig"
export GIT_CONFIG_GLOBAL="$PWD/$OUT/empty.gitconfig"
export GIT_CONFIG_SYSTEM="$PWD/$OUT/empty.gitconfig"

# Build the headless daemon so the binary end-to-end test (teste2e) can launch
# it. It is LCL-free (pure src/core), so a plain FPC build suffices. If this
# fails, teste2e skips itself rather than failing the suite.
mkdir -p "$OUT/gotboxd"
if "$FPC" -O2 -Fu../src/core -FU"$OUT/gotboxd" -o../gotboxd ../gotboxd.lpr \
    >"$OUT/gotboxd.build.log" 2>&1; then
  export GOTBOXD="$(cd .. && pwd)/gotboxd"
  echo "built gotboxd for teste2e"
else
  echo "note: gotboxd build failed; teste2e will skip (see $OUT/gotboxd.build.log)"
fi

# pick a timeout wrapper if available (macOS ships none; coreutils brings gtimeout)
if command -v timeout >/dev/null 2>&1; then
  TO="timeout $TIMEOUT"
elif command -v gtimeout >/dev/null 2>&1; then
  TO="gtimeout $TIMEOUT"
else
  TO=""
  echo "note: no timeout/gtimeout found; running without a hard per-test cap"
fi

# fast, watcher-independent tests first; timed/integration tests last
TESTS="testgit testauth testlink testremote testsuper teststray testengine testworker testsync testmultisync testhistory teste2e"

fail=0
for t in $TESTS; do
  [ -f "$t.lpr" ] || continue
  if ! "$FPC" -Fu../src/core -FU"$OUT" -o"$t" "$t.lpr" >"$OUT/$t.build.log" 2>&1; then
    echo "BUILD-FAIL  $t"
    grep -iE "error|fatal" "$OUT/$t.build.log" | head -5
    fail=1
    continue
  fi
  bin="$t"
  [ -f "$t.exe" ] && bin="$t.exe"   # Windows
  start=$(date +%s)
  if $TO "./$bin" >"$OUT/$t.run.log" 2>&1; then
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
