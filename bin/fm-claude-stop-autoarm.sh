#!/usr/bin/env bash
# Claude hook-owned watcher auto-arm (asyncRewake hook).
#
# Usage: fm-claude-stop-autoarm.sh [--hook-timeout <seconds>]
#   The hook payload arrives on stdin. --hook-timeout repeats the registered
#   hook's own "timeout" so this process knows when Claude will end it.
#
# Registered in tracked .claude/settings.json twice, each with "asyncRewake":
# true and the same explicit multi-day timeout: as a Stop command hook, which
# Claude Code fires in the background on EVERY Stop of a Claude primary session
# with no deduplication across firings, and as a SessionStart command hook, so a
# freshly opened session that never ends a turn is still supervised. The
# payload's hook_event_name selects the mode. Together they own routine
# tokenless watcher continuity for the Claude primary:
#
#   - Session open: a SessionStart firing arms only for source startup or
#     clear (compact and resume leave arming to the first Stop) and only in an
#     interactive session,
#     the only kind in which Claude backgrounds an asyncRewake hook
#     (CLAUDE_CODE_ENTRYPOINT=cli or CLAUDE_CODE_SESSION_ATTENDED=1); a print-mode
#     session runs hooks synchronously and must never block on a watcher cycle.
#     It runs beside the session-start digest hook, so it first waits a
#     bounded time (FM_CLAUDE_AUTOARM_SESSIONSTART_WAIT, default 240s) for
#     state/.session-start-complete to name the session lock
#     this session's own harness ancestry holds. A lock another live session
#     holds (a read-only session), a truncated startup, or a session that only
#     received the nudge exits 0 without arming; the first Stop arms instead.
#     This mode never reclaims a stale session lock: session start owns that.
#   - Lease renewal: Claude ends the hook's process group when its timeout
#     expires, and nothing re-arms until the next turn ends. With --hook-timeout
#     the owner exports FM_WATCH_LEASE_DEADLINE, one seventh of the budget before
#     Claude's deadline, and the arm layer closes the cycle there with the typed
#     wake "check: lease-renewal". This hook translates it into its own exit-2
#     banner so one silent handling turn re-arms with a fresh budget.
#
#   - Payload: only a Claude hook payload on stdin whose hook_event_name is an
#     event this hook serves (Stop or SessionStart). A hand-run, --help, any
#     argument other than --hook-timeout, or any other input prints usage and
#     exits 0 without arming; extend the event case below to serve another
#     hook event.
#   - Scope: only a genuine primary checkout (plain checkout) with AGENTS.md,
#     bin/, and the effective state dir - the exact fm-turnend-guard.sh scope.
#     Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  cat <<'USAGE'
Usage: fm-claude-stop-autoarm.sh [--hook-timeout <seconds>] < <Claude hook JSON payload>

Claude Code runs this as the primary session's Stop and SessionStart
asyncRewake hook (.claude/settings.json); it is not a manual command. It arms
the watcher only when stdin carries a Claude hook payload for an event it
serves (hook_event_name "Stop" or "SessionStart"). --hook-timeout repeats the
registered hook's own timeout so the arm can renew its lease before Claude
ends it; a non-numeric value means no lease. Run by hand, with --help, or with
any other argument or input, it prints this usage and exits without arming.
USAGE
}

HOOK_TIMEOUT=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --hook-timeout)
      HOOK_TIMEOUT=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --hook-timeout=*) HOOK_TIMEOUT=${1#--hook-timeout=}; shift ;;
    *) usage >&2; exit 0 ;;
  esac
done
case "$HOOK_TIMEOUT" in
  ''|*[!0-9]*) HOOK_TIMEOUT= ;;
esac
HOOK_STARTED_AT=$(date +%s)

# Refuse anything but a real Claude hook payload for an event this hook serves,
# so a hand-run or stray invocation never arms (or later rewakes) a session.
# Read the payload once and in full, so a slow writer can never wedge on a full
# pipe. An interactive stdin is a hand-run, never a hook, so do not block on it.
# jq parses the payload strictly; a home without jq falls back to reading the
# top-level key directly rather than losing hook-owned continuity.
if [ -t 0 ]; then
  usage >&2
  exit 0
fi
PAYLOAD=$(cat 2>/dev/null || true)
payload_field() {  # <top-level key>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" \
      | jq -r --arg k "$1" 'if type == "object" then (.[$k] // "") else "" end' 2>/dev/null || true
  else
    printf '%s' "$PAYLOAD" | tr -d '\n' \
      | sed -n 's/^[[:space:]]*{.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*}[[:space:]]*$/\1/p'
  fi
}
HOOK_EVENT=$(payload_field hook_event_name)
case "$HOOK_EVENT" in
  Stop|SessionStart) ;;
  *) usage >&2; exit 0 ;;
esac

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- session open: wait for this session's own completed session start -------
# SessionStart hooks run concurrently, so the digest hook may still be acquiring
# the lock and presenting the wake queue. Arm only after the completion record
# proves this session took the helm; a live competing owner is a read-only
# session and ends the wait at once.
if [ "$HOOK_EVENT" = SessionStart ]; then
  # Only a fresh or cleared session opens without a watcher cycle. Compaction
  # fires mid-turn after a prior cycle may have released the owner lock, and a
  # resume only receives the nudge, so both leave arming to the first Stop.
  case "$(payload_field source)" in
    startup|clear) ;;
    *) exit 0 ;;
  esac
  # Claude backgrounds an asyncRewake hook only for an interactive session (or
  # streaming SDK input); otherwise it runs the hook synchronously, where an
  # armed cycle would hold session initialization open until the next wake.
  # Arm only on positive evidence of an interactive session; either vendor
  # signal suffices so neither string alone is load-bearing, and missing
  # evidence leaves the first Stop to arm exactly as before.
  [ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
  SESSIONSTART_WAIT=${FM_CLAUDE_AUTOARM_SESSIONSTART_WAIT:-240}
  case "$SESSIONSTART_WAIT" in ''|*[!0-9]*) SESSIONSTART_WAIT=240 ;; esac
  wait_deadline=$((HOOK_STARTED_AT + SESSIONSTART_WAIT))
  until fm_session_start_completed_by_self "$STATE"; do
    if ! fm_session_lock_owned_by_self "$STATE"; then
      LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
      # The digest hook may claim the lock for this session between the two
      # reads, so a live owner refuses only while it is still not this session.
      case "$LOCK_PID" in
        ''|*[!0-9]*) ;;
        *)
          if fm_harness_pid_alive "$LOCK_PID" && ! fm_session_lock_owned_by_self "$STATE"; then
            exit 0
          fi
          ;;
      esac
    fi
    [ "$(date +%s)" -lt "$wait_deadline" ] || exit 0
    sleep 1
  done
fi

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
# The EXIT trap also runs when Claude's group TERM ends this hook mid-arm, so it
# owns removing the in-flight arm output; explicit exit paths remove it earlier.
OUT=
trap '[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null; fm_lock_release "$OWNER_LOCK"' EXIT

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

write_epoch arming

# Lease: close the cycle with a typed renewal wake one seventh of the hook
# budget before Claude's own timeout would end this process group without a
# rewake. The margin also absorbs Claude's sleep-inclusive timer firing late on
# wake from a long system sleep. Without a known budget no lease is set.
if [ -n "$HOOK_TIMEOUT" ] && [ "$HOOK_TIMEOUT" -ge 7 ]; then
  FM_WATCH_LEASE_DEADLINE=$((HOOK_STARTED_AT + HOOK_TIMEOUT - HOOK_TIMEOUT / 7))
  export FM_WATCH_LEASE_DEADLINE
else
  unset FM_WATCH_LEASE_DEADLINE
fi

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  if fm_failure_episode_reset "$STATE"; then
    write_epoch clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  [ -e "$FAILURE_ALARM" ] && exit 0
  exit 2
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  write_epoch rewake
  # A cycle whose only reason is the lease carries no fleet event: say so, so
  # the handling turn stays silent and cheap instead of looking for work.
  if ! grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | grep -qv '^check: lease-renewal$'; then
    {
      printf 'firstmate supervision lease renewal - no fleet event; the hook budget is nearly spent.\n'
      printf 'check: lease-renewal\n'
      printf 'Run bin/fm-wake-drain.sh, handle anything it presents, then run its exact WAKE_ACK_REQUIRED --ack-through command. Send no captain-facing message for the renewal itself: end the turn and the Stop hook re-arms with a fresh budget - do NOT run bin/fm-watch-arm.sh.\n'
    } >&2
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop.
if [ ! -e "$FAILURE_NOTICE" ]; then
  write_epoch failed
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  : > "$FAILURE_NOTICE" 2>/dev/null || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
write_epoch failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
