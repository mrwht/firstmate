#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

prime_seen() { # <state> <status>
  local state=$1 status=$2 sig
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$status"); else sig=$(stat -c '%s:%Y' "$status"); fi
  printf '%s' "$sig" > "$state/.seen-$(basename "$status" | tr '.' '_')"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race
  write_child "$MATE" child 'failed: terminal' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MATE" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

# The actual watcher poll invokes the helper.
test_watcher_hook_surfaces_terminal_loss() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"
  pass "watcher hook wakes for terminal loss"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  [ "$elapsed" -le 3 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_main_direct_terminal_presentation_receipt
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_watcher_hook_surfaces_terminal_loss
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_reconciliation_never_calls_forge

echo "all inactive reconciliation tests passed"
