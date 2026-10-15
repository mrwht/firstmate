#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md), including its
# SessionStart session-open mode and its hook-budget lease.
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","hook_event_name":"Stop","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    benign-live)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    hang)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- registration contract ----------------------------------------------------

# The hook learns its own budget only from --hook-timeout, so every tracked
# auto-arm registration must repeat its registered timeout exactly, stay an
# asyncRewake hook, and keep that budget below the ~24.8-day JS timer ceiling.
test_tracked_registrations_repeat_their_timeout() {
  local settings rows event cmd timeout async flag count=0 stop=0 sessionstart=0
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  settings="$ROOT/.claude/settings.json"
  rows=$(jq -r '.hooks | to_entries[] | .key as $event | .value[].hooks[]
    | select(.command | contains("bin/fm-claude-stop-autoarm.sh"))
    | [$event, .command, (.timeout // ""), (.asyncRewake // false)] | @tsv' "$settings")
  while IFS=$'\t' read -r event cmd timeout async; do
    [ -n "$event" ] || continue
    count=$((count + 1))
    case "$event" in
      Stop) stop=$((stop + 1)) ;;
      SessionStart) sessionstart=$((sessionstart + 1)) ;;
      *) fail "auto-arm registered on an unexpected event: $event" ;;
    esac
    [ "$async" = true ] || fail "$event auto-arm registration must be asyncRewake"
    flag=$(printf '%s\n' "$cmd" | sed -n 's/.*--hook-timeout[ =]\([0-9][0-9]*\).*/\1/p')
    [ -n "$flag" ] || fail "$event auto-arm registration does not pass --hook-timeout: $cmd"
    [ "$flag" = "$timeout" ] || fail "$event auto-arm --hook-timeout $flag differs from its registered timeout $timeout"
    [ "$timeout" -gt 28800 ] || fail "$event auto-arm timeout $timeout must exceed the old 8-hour budget"
    [ "$((timeout * 1000))" -lt 2147483647 ] || fail "$event auto-arm timeout $timeout overflows the JS timer ceiling"
  done <<< "$rows"
  [ "$stop" -eq 1 ] && [ "$sessionstart" -eq 1 ] \
    || fail "expected one Stop and one SessionStart auto-arm registration, saw stop=$stop sessionstart=$sessionstart ($count total)"
  pass "auto-arm: Stop and SessionStart registrations repeat their sub-ceiling timeout as --hook-timeout"
}

# --- session open --------------------------------------------------------------

# Run the hook as a SessionStart firing inside a fake harness that holds the
# lock. $1 = fixture dir, $2 = completion mode: completed (session start already
# completed for this harness), late (completes 2s after the hook starts), or
# none (never completes). Interactive-session evidence comes from the caller's
# environment: CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_SESSION_ATTENDED.
run_sessionstart_autoarm() {
  local dir=$1 completion=$2 rc=0
  printf '%s\n' '{"session_id":"sess-open","hook_event_name":"SessionStart","source":"startup"}' \
    | FM_HOME="$dir" COMPLETION="$completion" "$FAKE_CLAUDE" -c '
        case "$COMPLETION" in
          completed)
            printf "%s\n" "$$" > "$FM_HOME/state/.lock"
            printf "%s\n" "$$" > "$FM_HOME/state/.session-start-complete"
            ;;
          late)
            # The digest hook is still reclaiming a dead prior owner.
            printf "9999999\n" > "$FM_HOME/state/.lock"
            ( sleep 2
              printf "%s\n" "$$" > "$FM_HOME/state/.lock"
              printf "%s\n" "$$" > "$FM_HOME/state/.session-start-complete" ) &
            ;;
          *) printf "%s\n" "$$" > "$FM_HOME/state/.lock" ;;
        esac
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh" --hook-timeout 604800
        rc=$?
        wait
        exit "$rc"
      ' 2>&1 || rc=$?
  return "$rc"
}

test_sessionstart_arms_interactive_session_after_its_start() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/ss-arm")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 run_sessionstart_autoarm "$dir" completed); status=$?
  expect_code 2 "$status" "an untouched interactive session with in-flight work must be armed and rewoken from SessionStart"
  assert_contains "$out" "stale: fixture-win actionable" "session-open rewake must carry the arm's reason"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "session-open arm must record outcome=rewake"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "session-open arm left the owner lock behind"
  pass "auto-arm: SessionStart arms an untouched interactive session once its own session start completed"
}

test_sessionstart_waits_for_concurrent_session_start() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/ss-late")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # Record what the arm saw, so arming before the digest finished is visible.
  {
    sed -n '1p' "$dir/bin/fm-watch-arm.sh"
    printf '%s\n' 'cat "$FM_HOME/state/.session-start-complete" > "$FM_HOME/state/arm-saw-completion" 2>/dev/null'
    sed '1d' "$dir/bin/fm-watch-arm.sh"
  } > "$dir/bin/fm-watch-arm.sh.new"
  mv "$dir/bin/fm-watch-arm.sh.new" "$dir/bin/fm-watch-arm.sh"
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 run_sessionstart_autoarm "$dir" late); status=$?
  expect_code 2 "$status" "the session-open arm must wait for the concurrent digest hook to complete"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 1 ] || fail "session-open arm must run exactly once after the digest completes"
  [ -s "$dir/state/arm-saw-completion" ] || fail "session-open arm ran before the concurrent session start completed"
  [ "$(cat "$dir/state/arm-saw-completion")" = "$(cat "$dir/state/.lock")" ] \
    || fail "session-open arm must follow the completion recorded for its own session lock"
  pass "auto-arm: SessionStart waits for the concurrently running session start before arming"
}

test_sessionstart_needs_interactive_evidence() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/ss-print")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0 run_sessionstart_autoarm "$dir" completed); status=$?
  expect_code 0 "$status" "a print-mode session runs hooks synchronously and must not arm at session open"
  [ -z "$out" ] || fail "print-mode session open produced output: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "print-mode session open armed a synchronous hook"
  out=$(unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED; run_sessionstart_autoarm "$dir" completed); status=$?
  expect_code 0 "$status" "a session with no interactive evidence at all must not arm at session open"
  [ ! -e "$dir/state/arm-ran" ] || fail "session open armed without any interactive evidence"
  pass "auto-arm: SessionStart stays inert without interactive-session evidence"
}

# Either vendor signal alone carries the positive verdict. Drive them apart and
# confirm each divergent pair really diverges, so neither case is vacuous.
test_sessionstart_either_interactive_signal_suffices() {
  local dir entry attended status
  for pair in cli:0 sdk-cli:1; do
    entry=${pair%%:*}
    attended=${pair#*:}
    { [ "$entry" = cli ] && [ "$attended" = 1 ]; } && fail "test pair $pair does not diverge"
    { [ "$entry" != cli ] && [ "$attended" != 1 ]; } && fail "test pair $pair carries no positive signal"
    dir=$(make_primary_dir "$TMP_ROOT/ss-signal-$entry")
    : > "$dir/state/task.meta"
    write_arm_fixture "$dir" actionable
    CLAUDE_CODE_ENTRYPOINT=$entry CLAUDE_CODE_SESSION_ATTENDED=$attended run_sessionstart_autoarm "$dir" completed >/dev/null; status=$?
    expect_code 2 "$status" "SessionStart with entrypoint=$entry attended=$attended must still arm"
  done
  pass "auto-arm: SessionStart arms when either interactive-session signal alone is present"
}

test_sessionstart_inert_in_read_only_session() {
  local dir other out status started elapsed
  dir=$(make_primary_dir "$TMP_ROOT/ss-readonly")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  printf '%s\n' "$other" > "$dir/state/.session-start-complete"
  started=$(date +%s)
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 FM_HOME="$dir" \
      "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh" --hook-timeout 604800' 2>&1); status=$?
  elapsed=$(( $(date +%s) - started ))
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "a lock-refused read-only session must not arm at session open"
  [ "$elapsed" -lt 10 ] || fail "a live competing owner must end the session-open wait at once, took ${elapsed}s"
  [ ! -e "$dir/state/arm-ran" ] || fail "read-only session open armed"
  [ "$(cat "$dir/state/.lock")" = "$other" ] || fail "read-only session open replaced the live owner"
  pass "auto-arm: SessionStart stays inert at once in a lock-refused read-only session"
}

test_sessionstart_bounded_wait_without_completion() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/ss-truncated")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(CLAUDE_CODE_ENTRYPOINT=cli FM_CLAUDE_AUTOARM_SESSIONSTART_WAIT=2 run_sessionstart_autoarm "$dir" none); status=$?
  expect_code 0 "$status" "a session start that never completes must leave arming to the first Stop"
  [ ! -e "$dir/state/arm-ran" ] || fail "session open armed without a completed session start"

  dir=$(make_primary_dir "$TMP_ROOT/ss-stale")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"resume"}' \
    | CLAUDE_CODE_ENTRYPOINT=cli FM_CLAUDE_AUTOARM_SESSIONSTART_WAIT=2 FM_HOME="$dir" \
      "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh" --hook-timeout 604800' 2>&1); status=$?
  expect_code 0 "$status" "session open must not reclaim a stale lock itself"
  [ "$(cat "$dir/state/.lock")" = 9999999 ] || fail "session open reclaimed a stale lock that session start owns"
  [ ! -e "$dir/state/arm-ran" ] || fail "session open armed over a stale lock"
  pass "auto-arm: SessionStart gives up after a bounded wait and never reclaims a stale lock"
}

test_sessionstart_respects_afk_and_single_flight() {
  local dir out status holder
  dir=$(make_primary_dir "$TMP_ROOT/ss-afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(CLAUDE_CODE_ENTRYPOINT=cli run_sessionstart_autoarm "$dir" completed); status=$?
  expect_code 0 "$status" "away mode owns supervision at session open"
  [ ! -e "$dir/state/arm-ran" ] || fail "session open armed while state/.afk existed"

  dir=$(make_primary_dir "$TMP_ROOT/ss-single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"
  out=$(CLAUDE_CODE_ENTRYPOINT=cli run_sessionstart_autoarm "$dir" completed); status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 0 "$status" "a live auto-arm owner must keep the session-open firing from starting a second cycle"
  [ ! -e "$dir/state/arm-ran" ] || fail "session open started a second cycle beside a live owner"
  pass "auto-arm: SessionStart honors away mode and the single-flight owner lock"
}

# --- lease renewal ---------------------------------------------------------------

write_lease_arm_fixture() {
  local dir=$1 reasons=$2
  cat > "$dir/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
echo "\$\$" >> "\$FM_HOME/state/arm-ran"
printf '%s\n' "\${FM_WATCH_LEASE_DEADLINE:-unset}" > "\$FM_HOME/state/lease-deadline"
printf 'watcher: started pid=%s (beacon fresh)\n' "\$\$"
printf '$reasons'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

test_lease_deadline_derives_from_hook_timeout() {
  local dir before after deadline status
  dir=$(make_primary_dir "$TMP_ROOT/lease-deadline")
  : > "$dir/state/task.meta"
  write_lease_arm_fixture "$dir" 'stale: fixture\n'
  before=$(date +%s)
  printf '%s\n' '{"hook_event_name":"Stop"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-stop-autoarm.sh" --hook-timeout 700' >/dev/null 2>&1; status=$?
  after=$(date +%s)
  expect_code 2 "$status" "the leased cycle must still translate its actionable close"
  deadline=$(cat "$dir/state/lease-deadline")
  [ "$deadline" -ge $((before + 600)) ] && [ "$deadline" -le $((after + 600)) ] \
    || fail "lease deadline $deadline must sit one seventh of a 700s budget early (start+600), window $before-$after"

  rm -f "$dir/state/lease-deadline"
  printf '%s\n' '{"hook_event_name":"Stop"}' | FM_WATCH_LEASE_DEADLINE=1 FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1
  [ "$(cat "$dir/state/lease-deadline")" = unset ] || fail "without --hook-timeout no lease (not even an inherited one) may reach the arm"
  pass "auto-arm: the lease deadline is one seventh of --hook-timeout before Claude's deadline, and absent without it"
}

test_lease_renewal_rewakes_with_silent_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/lease-banner")
  : > "$dir/state/task.meta"
  write_lease_arm_fixture "$dir" 'check: lease-renewal\n'
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a lease-renewal close must rewake so one turn re-arms with a fresh budget"
  assert_contains "$out" "supervision lease renewal - no fleet event" "lease rewake must say it carries no fleet event"
  assert_contains "$out" "check: lease-renewal" "lease rewake must carry its typed reason"
  assert_contains "$out" "Send no captain-facing message" "lease rewake must ask for a silent handling turn"
  assert_contains "$out" "WAKE_ACK_REQUIRED" "lease rewake must still retire the closed cycle's episode"
  assert_not_contains "$out" "firstmate watcher wake" "a lease-only close must not look like a fleet event"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "lease rewake must record outcome=rewake for the turn-end guard"

  dir=$(make_primary_dir "$TMP_ROOT/lease-mixed")
  : > "$dir/state/task.meta"
  write_lease_arm_fixture "$dir" 'signal: task.status done: fixture\ncheck: lease-renewal\n'
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a close with a real event must rewake"
  assert_contains "$out" "firstmate watcher wake" "a real event beside the lease must use the ordinary wake banner"
  assert_not_contains "$out" "lease renewal - no fleet event" "a real event must never be described as lease-only"
  pass "auto-arm: a lease-only close rewakes with the silent renewal banner, a real event keeps the ordinary banner"
}


# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s","hook_event_name":"Stop"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale","hook_event_name":"Stop"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s","hook_event_name":"Stop"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "AFK without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "AFK without positive recovery reset the attended alarm"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk","hook_event_name":"Stop"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle","hook_event_name":"Stop"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_resolves_outermost_claude_pid_in_nested_bgspare_chain() {
  local dir out status inner_pid lock_pid
  dir=$(make_primary_dir "$TMP_ROOT/nested-chain")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # A genuine multi-level contiguous claude-named ancestry: the hook fires
  # inside an inner fake-claude process (its recorded pid is distinct from its
  # own parent, a second, outer fake-claude process holding the session lock -
  # the bg-spare shape). Only the outer pid may own the lock; a
  # first-match-wins walk would resolve to the inner pid instead and leave the
  # hook inert. The inner process records its own pid before running the hook
  # so bash cannot tail-exec-collapse it into the outer pid, which would
  # collapse the two-hop chain this test depends on down to one hop.
  out=$(printf '%s\n' '{"session_id":"nested","hook_event_name":"Stop"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FAKE_CLAUDE" -c "
          printf \"%s\n\" \"\$\$\" > \"\$FM_HOME/state/inner-pid\"
          \"\$FM_HOME/bin/fm-claude-stop-autoarm.sh\"
        "
      ' 2>&1); status=$?
  inner_pid=$(cat "$dir/state/inner-pid" 2>/dev/null || true)
  lock_pid=$(cat "$dir/state/.lock" 2>/dev/null || true)
  [ -n "$inner_pid" ] && [ "$inner_pid" != "$lock_pid" ] \
    || fail "test setup did not produce a genuine two-hop claude chain: inner=$inner_pid lock=$lock_pid"
  expect_code 2 "$status" "a nested contiguous claude ancestry must resolve to the outer lock-owning pid and arm"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not resolve past the inner claude-named process to the outer lock owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "nested-chain arm must record outcome=rewake"
  pass "auto-arm: resolves the outermost pid of a nested contiguous claude ancestry (bg-spare chain)"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "idle state without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "idle state without positive recovery reset the attended alarm"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_actionable_close_with_live_successor_rewakes_once() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/actionable-live-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live successor for actionable close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  write_arm_fixture "$dir" benign-live
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?

  expect_code 2 "$status" "an actionable close must rewake when a live successor already exists"
  expect_code 0 "$status2" "a repeated non-actionable close with the live successor must stay quiet"
  [ "$(printf '%s\n' "$out" | grep -c '^firstmate watcher wake')" -eq 1 ] \
    || fail "actionable close with a live successor did not emit exactly one wake banner: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^stale: fixture-win actionable')" -eq 1 ] \
    || fail "actionable close with a live successor did not surface its reason exactly once: $out"
  [ -z "$out2" ] || fail "repeated hook duplicated the delivered actionable result: $out2"
  kill -0 "$pid" 2>/dev/null || fail "actionable delivery stopped or replaced the live successor"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "the later benign close must record outcome=clean"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: actionable close survives a healthy successor without duplicate delivery"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "automatic supervision mechanism is broken" "failure rewake must describe the automatic mechanism failure"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "failure rewake must not create a manual arm loop"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "failure must exhaust exactly two bounded arm attempts"
  pass "auto-arm: bounded failure verification emits one automatic-mechanism alarm"
}

test_failed_cycles_notify_once_and_keep_retrying() {
  local dir out1 out2 status1 status2
  dir=$(make_primary_dir "$TMP_ROOT/failed-dedup")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  expect_code 2 "$status1" "the first exhausted failure must notify"
  expect_code 2 "$status2" "a consecutive exhausted failure must force another Stop-owned retry"
  [ -n "$out1" ] || fail "the first exhausted failure did not notify"
  [ -z "$out2" ] || fail "consecutive exhausted failure repeated an operator notice: $out2"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 4 ] || fail "each cycle must retain bounded automatic retries"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "failure episode marker was not recorded"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "second failure must record failed-suppressed"
  pass "auto-arm: consecutive failures keep Stop-owned retry without repeating notice"
}

test_unverified_clean_close_exhausts_retries() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a non-actionable close without a healthy watcher must fail closed"
  assert_contains "$out" "automatic supervision mechanism is broken" "unverified close must report automatic failure"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "unverified close must exhaust exactly two bounded attempts"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  pass "auto-arm: unverified clean close exhausts retries and fails closed"
}

test_post_alarm_actionable_close_is_suppressed() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/post-alarm-actionable")
  : > "$dir/state/task.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable result after attended fail-open must not continue"
  [ -z "$out" ] || fail "post-alarm actionable result produced continuation output: $out"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "post-alarm actionable result cleared the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "post-alarm actionable result cleared the attended alarm"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "post-alarm actionable result must record failed-suppressed"
  pass "auto-arm: post-alarm actionable outcomes cannot continue or reset failure state"
}

test_benign_cycle_end_with_live_watcher_is_silent() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/benign-live")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for benign close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a failed-looking cycle with a live fresh watcher must be benign"
  expect_code 0 "$status2" "the next Stop-owned cycle must remain benign with the live watcher"
  [ -z "$out" ] || fail "benign live cycle produced an operator notice: $out"
  [ -z "$out2" ] || fail "next benign live cycle produced an operator notice: $out2"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "benign live cycle must record outcome=clean, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "the next Stop-owned cycle must run its own bounded arm"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "benign live cycle must clear the prior block budget"
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] || fail "benign live cycle must not leave a failure-notice marker"
  [ ! -e "$dir/state/.claude-autoarm-failure-alarmed" ] || fail "benign live cycle must not leave an attended-alarm marker"
  pass "auto-arm: benign cycle end with a live watcher and fresh beacon stays silent across the next cycle"
}

test_positive_recovery_budget_contention_preserves_episode() {
  local dir out status pid identity holder
  dir=$(make_primary_dir "$TMP_ROOT/recovery-budget-contention")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for recovery contention"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a healthy auto-arm must continue when the episode reset lock is busy"
  [ -z "$out" ] || fail "recovery contention produced an operator notice: $out"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "recovery contention must not record ordinary clean recovery"
  assert_present "$dir/state/.turnend-claude-blocks" "recovery contention partially cleared the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "recovery contention partially cleared the failure notice"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a later healthy auto-arm must complete the episode reset"
  assert_absent "$dir/state/.turnend-claude-blocks" "successful retry left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "successful retry left the failure notice"
  pass "auto-arm: budget contention preserves the episode and forces a reset retry"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_refuses_to_arm_without_a_stop_payload() {
  # Only a real Claude Stop payload may arm. A hand-run (the 2026-09-22
  # `--help` incident), an empty or malformed stdin, or another hook event must
  # print usage and exit 0 without arming, rewaking, or writing an epoch.
  local row dir out status payload
  for row in help empty malformed no-event subagent-stop; do
    dir=$(make_primary_dir "$TMP_ROOT/refuse-$row")
    : > "$dir/state/task.meta"
    write_arm_fixture "$dir" actionable
    case "$row" in
      help) payload= ;;
      empty) payload= ;;
      malformed) payload='{"hook_event_name":"Stop"' ;;
      no-event) payload='{"session_id":"sess-autoarm","stop_hook_active":false}' ;;
      subagent-stop) payload='{"session_id":"sess-autoarm","hook_event_name":"SubagentStop"}' ;;
    esac
    if [ "$row" = help ]; then
      out=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          "$FM_HOME/bin/fm-claude-stop-autoarm.sh" --help </dev/null
        ' 2>&1); status=$?
    else
      out=$(printf '%s' "$payload" | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
        ' 2>&1); status=$?
    fi
    expect_code 0 "$status" "a $row invocation must exit 0 without rewaking"
    assert_contains "$out" "Usage: fm-claude-stop-autoarm.sh" "a $row invocation must print usage"
    [ ! -e "$dir/state/arm-ran" ] || fail "a $row invocation armed the watcher"
    [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "a $row invocation wrote an auto-arm epoch"
  done
  pass "auto-arm: refuses to arm without a Claude Stop payload and prints usage"
}

test_payload_gate_without_jq() {
  # A home without jq must keep Stop-owned continuity, and still refuse input
  # that is not a Stop payload.
  local nojq bindir tool row dir out status payload
  nojq="$TMP_ROOT/nojq-bin"
  mkdir -p "$nojq"
  for bindir in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$bindir" ] || continue
    for tool in "$bindir"/*; do
      [ -x "$tool" ] || continue
      [ "$(basename "$tool")" = jq ] && continue
      [ -e "$nojq/$(basename "$tool")" ] || ln -s "$tool" "$nojq/$(basename "$tool")"
    done
  done
  ln -sf "$FAKE_CLAUDE" "$nojq/claude"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && fail "fixture PATH still exposes jq"
  for row in stop subagent-stop no-event; do
    dir=$(make_primary_dir "$TMP_ROOT/nojq-$row")
    : > "$dir/state/task.meta"
    write_arm_fixture "$dir" actionable
    case "$row" in
      stop) payload='{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}' ;;
      subagent-stop) payload='{"session_id":"s","hook_event_name":"SubagentStop"}' ;;
      no-event) payload='{"session_id":"s"}' ;;
    esac
    out=$(printf '%s\n' "$payload" | PATH="$nojq" FM_HOME="$dir" "$nojq/claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
    if [ "$row" = stop ]; then
      expect_code 2 "$status" "a Stop payload without jq must still arm and rewake"
      [ -e "$dir/state/arm-ran" ] || fail "a Stop payload without jq did not arm"
    else
      expect_code 0 "$status" "a $row payload without jq must exit 0"
      [ ! -e "$dir/state/arm-ran" ] || fail "a $row payload without jq armed the watcher"
      assert_contains "$out" "Usage: fm-claude-stop-autoarm.sh" "a $row payload without jq must print usage"
    fi
  done
  pass "auto-arm: payload gate works without jq"
}

test_term_mid_arm_leaves_no_output_file() {
  # Claude ends a hook's process group with one TERM on hook timeout or session
  # end. The hook's in-flight arm output must not leak into state/.
  local dir i gpid
  dir=$(make_primary_dir "$TMP_ROOT/term-mid-arm")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" hang
  printf '%s\n' '{"session_id":"sess-autoarm","hook_event_name":"Stop","stop_hook_active":false}' \
    | FM_HOME="$dir" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' >/dev/null 2>&1 &
  gpid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/state/arm-ran" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/arm-ran" ] || fail "hook never reached the foreground arm"
  ls "$dir/state"/.claude-autoarm-output.* >/dev/null 2>&1 || fail "hook did not create its arm output before the TERM"
  kill -TERM -- "-$gpid" 2>/dev/null || fail "could not TERM the hook process group"
  wait "$gpid" 2>/dev/null || true
  # The group TERM reaches the fake harness and the hook together, so the
  # hook's EXIT cleanup can still be running after the harness is reaped.
  i=0
  while [ "$i" -lt 60 ] && { ls "$dir/state"/.claude-autoarm-output.* >/dev/null 2>&1 \
    || [ -e "$dir/state/.claude-autoarm.lock" ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  ! ls "$dir/state"/.claude-autoarm-output.* >/dev/null 2>&1 \
    || fail "a group TERM leaked the hook's arm output: $(ls "$dir/state"/.claude-autoarm-output.*)"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "a group TERM left the auto-arm owner lock behind"
  pass "auto-arm: a group TERM mid-arm removes the arm output and owner lock"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_tracked_registrations_repeat_their_timeout
test_sessionstart_arms_interactive_session_after_its_start
test_sessionstart_waits_for_concurrent_session_start
test_sessionstart_needs_interactive_evidence
test_sessionstart_either_interactive_signal_suffices
test_sessionstart_inert_in_read_only_session
test_sessionstart_bounded_wait_without_completion
test_sessionstart_respects_afk_and_single_flight
test_lease_deadline_derives_from_hook_timeout
test_lease_renewal_rewakes_with_silent_banner
test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_resolves_outermost_claude_pid_in_nested_bgspare_chain
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_actionable_close_with_live_successor_rewakes_once
test_failed_close_rewakes_with_failure_banner
test_failed_cycles_notify_once_and_keep_retrying
test_unverified_clean_close_exhausts_retries
test_post_alarm_actionable_close_is_suppressed
test_benign_cycle_end_with_live_watcher_is_silent
test_positive_recovery_budget_contention_preserves_episode
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_refuses_to_arm_without_a_stop_payload
test_payload_gate_without_jq
test_term_mid_arm_leaves_no_output_file
test_fm_lock_status_still_works_with_shared_lib
