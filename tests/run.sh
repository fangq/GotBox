#!/bin/sh
# Robust test runner: compile each console test, run it under a hard timeout so
# a hang fails fast instead of blocking forever, and print a one-line summary
# per test. Exits non-zero if any test fails. Override TIMEOUT/FPC as needed.
#
#   tests/run.sh            # run all tests
#   TIMEOUT=60 tests/run.sh # longer per-test cap

cd "$(dirname "$0")" || exit 2

FPC="${FPC:-fpc}"
TIMEOUT="${TIMEOUT:-120}"   # per-test cap (see the multi-machine test note below)
                            # (Windows CI spawns git ~10x slower than Linux)
OUT=lib
mkdir -p "$OUT"

# Run hermetically w.r.t. git config: point global/system config at an empty
# file so tests don't inherit (or depend on) the developer's git identity --
# this makes local runs match CI and catches "no committer identity" bugs.
: > "$OUT/empty.gitconfig"
export GIT_CONFIG_GLOBAL="$PWD/$OUT/empty.gitconfig"
export GIT_CONFIG_SYSTEM="$PWD/$OUT/empty.gitconfig"

# Diagnostic: trace every git op (start/end, thread id, elapsed ms, TIMEOUT flag)
# to stderr so a hung op leaves a dangling "GIT>" line -- the failure tail then
# names the exact stalling command + repo. Cheap; unset GOTBOX_GIT_TRACE to mute.
export GOTBOX_GIT_TRACE="${GOTBOX_GIT_TRACE:-1}"

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

# Heavy integration tests get a longer cap: the multi-machine / e2e tests do a
# lot of real git work and, on the ~10x-slower Windows CI, legitimately run well
# past the fast-test cap even when healthy (hangs are already bounded by the git
# runner's own timeout). Override with SLOW_TIMEOUT=...
SLOW_TIMEOUT="${SLOW_TIMEOUT:-300}"
SLOW_TESTS="${SLOW_TESTS:-testmultisync teste2e}"

# pick a timeout wrapper if available (macOS ships none; coreutils brings gtimeout)
if command -v timeout >/dev/null 2>&1; then
  TOCMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TOCMD=gtimeout
else
  TOCMD=""
  echo "note: no timeout/gtimeout found; running without a hard per-test cap"
fi

# per-test cap: SLOW_TIMEOUT for the heavy tests, TIMEOUT for the rest
cap_for() {
  for s in $SLOW_TESTS; do
    [ "$1" = "$s" ] && { echo "$SLOW_TIMEOUT"; return; }
  done
  echo "$TIMEOUT"
}

# fast, watcher-independent tests first; timed/integration tests last
TESTS="testgit testauth testlink testremote testsuper teststray testengine testworker testsync testfilestatus testoverlayipc testrootlock testmultisync testhistory teste2e"

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
  cap=$(cap_for "$t")
  [ -n "$TOCMD" ] && TO="$TOCMD $cap" || TO=""
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
    printf 'TIMEOUT %-10s (>%ss)\n' "$t" "$cap"
    echo "  last STEP: $(grep -a '== STEP:' "$OUT/$t.run.log" | tail -1)"
    echo "  dangling GIT> (started, never finished): $(grep -a 'GIT> ' "$OUT/$t.run.log" | tail -1)"
    tail -25 "$OUT/$t.run.log"
    fail=1
  else
    printf 'FAIL  %-12s (exit %d)\n' "$t" "$rc"
    echo "  last STEP: $(grep -a '== STEP:' "$OUT/$t.run.log" | tail -1)"
    tail -25 "$OUT/$t.run.log"
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
