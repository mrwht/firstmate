#!/usr/bin/env bash
# Behavior tests for tests/fm-cpu-stress.sh, the bounded self-expiring CPU load
# helper, and for the FM_TEST_HINT line bin/fm-test-run.sh prints on failure.
#
# Workers are identified by the helper's own pid as their recorded parent plus
# the exact worker command line, never by process name alone, so a concurrent
# run or an unrelated perl process can never be matched or signalled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRESS="$ROOT/tests/fm-cpu-stress.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-cpu-stress)
WORKER_PIDS=()

# Never leave load behind if an assertion fails mid-test: the workers expire on
# their own, but a failing test should not even wait for that.
cleanup() {
  if [ "${#WORKER_PIDS[@]}" -gt 0 ]; then
    kill "${WORKER_PIDS[@]}" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

worker_pattern() {
  printf 'alarm shift; 1 while 1 %s' "$1"
}

worker_alive() {
  local pid=$1 seconds=$2 args
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in
    *"$(worker_pattern "$seconds")"*) return 0 ;;
  esac
  return 1
}

test_workers_outlive_killed_helper_then_expire() {
  local seconds=2 workers=2 helper pid ppid alive
  "$STRESS" --workers "$workers" --seconds "$seconds" 2>"$TMP_ROOT/stress.err" &
  helper=$!

  # Wait for exactly this helper's workers, matched by parent and command line.
  WORKER_PIDS=()
  for _ in $(seq 1 50); do
    WORKER_PIDS=()
    while IFS= read -r pid; do
      [ -n "$pid" ] && WORKER_PIDS+=("$pid")
    done < <(pgrep -P "$helper" -f "$(worker_pattern "$seconds")" || true)
    [ "${#WORKER_PIDS[@]}" -ge "$workers" ] && break
    sleep 0.1
  done
  [ "${#WORKER_PIDS[@]}" -eq "$workers" ] \
    || fail "expected $workers workers under helper $helper, found ${#WORKER_PIDS[@]}"

  # SIGKILL skips the helper's trap, the same as an agent tool timeout.
  kill -9 "$helper"
  wait "$helper" 2>/dev/null || true

  for pid in "${WORKER_PIDS[@]}"; do
    worker_alive "$pid" "$seconds" || fail "worker $pid died with its helper instead of at its deadline"
    ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
    [ "$ppid" != "$helper" ] || fail "worker $pid still reports killed helper $helper as parent"
  done
  pass "workers survive a SIGKILLed helper, reparented away from it"

  sleep 4
  alive=0
  for pid in "${WORKER_PIDS[@]}"; do
    worker_alive "$pid" "$seconds" && alive=$((alive + 1))
  done
  [ "$alive" -eq 0 ] || fail "$alive orphaned workers outlived their ${seconds}s deadline"
  WORKER_PIDS=()
  pass "orphaned workers expire at their own deadline"
}

test_bad_arguments_exit_2() {
  local args rc too_many
  too_many=$(( $( (sysctl -n hw.ncpu 2>/dev/null || nproc) | tr -d ' ') * 2 + 1 ))
  for args in "--workers 0" "--workers abc" "--workers $too_many" "--workers -1" \
    "--seconds 0" "--seconds 901" "--seconds 1.5" "--seconds" "--bogus"; do
    rc=0
    # shellcheck disable=SC2086
    "$STRESS" $args >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "args '$args' should exit 2, got $rc"
    grep -q 'Usage:' "$TMP_ROOT/bad.err" || fail "args '$args' should print usage on stderr"
  done
  pass "bad arguments exit 2 with usage on stderr"
}

test_runner_hint_only_on_failure() {
  local dir=$TMP_ROOT/runner
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho "not ok - fixture"\nexit 1\n' >"$dir/fail.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - fixture"\n' >"$dir/pass.test.sh"
  chmod +x "$dir/fail.test.sh" "$dir/pass.test.sh"

  "$RUNNER" "$dir/fail.test.sh" >"$dir/fail.out" 2>&1 \
    && fail "runner should fail on a failing fixture"
  [ "$(grep -c '^FM_TEST_HINT ' "$dir/fail.out")" -eq 1 ] \
    || fail "failing run should print exactly one FM_TEST_HINT line"
  grep -q '^FM_TEST_HINT .*tests/fm-cpu-stress.sh --workers N --seconds S (self-expiring)' "$dir/fail.out" \
    || fail "FM_TEST_HINT should name the self-expiring helper"

  "$RUNNER" "$dir/pass.test.sh" >"$dir/pass.out" 2>&1 \
    || fail "runner should pass on a passing fixture"
  ! grep -q 'FM_TEST_HINT' "$dir/pass.out" || fail "passing run must not print FM_TEST_HINT"
  pass "runner prints FM_TEST_HINT only when a script fails"
}

test_bad_arguments_exit_2
test_runner_hint_only_on_failure
test_workers_outlive_killed_helper_then_expire
