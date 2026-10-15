#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock can run fm-session-start.sh first; session start reclaims the
# dead owner; at least two tokenless auto-arm and rewake cycles then complete
# with zero model-issued arm commands; and the cooperative guard consumes no
# forced continuation while the hook's launch is healthy. That print-mode run
# also keeps the SessionStart auto-arm inert, because Claude runs asyncRewake
# hooks synchronously there.
# A second phase opens an interactive Claude session in a dedicated tmux socket
# and never types a prompt: the tracked SessionStart registration must arm it
# after the digest completes, carry the hook-budget lease to the arm, and wake
# the untouched session through its exit-2 rewake.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

# The interactive phase needs one folder-trust acceptance; a stable lab path
# keeps that to a single Claude trust entry across runs.
OPEN_LAB="${TMPDIR:-/tmp}/fm-claude-sessionopen-live-e2e"
OPEN_PROJECT="$OPEN_LAB/project"
OPEN_HOME="$OPEN_LAB/fmhome"
OPEN_SOCKET="fm-sessionopen-live-$$"

cleanup() {
  tmux -L "$OPEN_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB" "$OPEN_PROJECT" "$OPEN_HOME"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart nudge,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: both the run-tier SessionStart hook's digest and the model's
# own session start drain once, then the model drains once per rewake. Keying
# on the arm count rather than the drain count keeps that startup variance out:
# the drain that handles the second cycle's rewake ends the in-flight need.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
echo "drain arm-count=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0)" >> "$FM_HOME/state/drain-ran"
if [ "$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0)" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its complete digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
MODEL_DRAINS=$(grep -c '^bin/fm-wake-drain.sh$' "$HOME_DIR/state/tool-calls.log" 2>/dev/null || true)
[ "$MODEL_DRAINS" = 2 ] || fail "expected exactly two model wake drains, got $MODEL_DRAINS: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ "$(sed -n '1p' "$HOME_DIR/state/tool-calls.log" 2>/dev/null)" = 'bin/fm-session-start.sh' ] \
  || fail "fresh Claude session did not run session start first: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control","hook_event_name":"Stop"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

# --- Phase 2: an untouched interactive session is armed at session open -------
command -v tmux >/dev/null 2>&1 || fail "tmux not found; the interactive session-open phase needs it"
rm -rf "$OPEN_PROJECT" "$OPEN_HOME"
mkdir -p "$OPEN_LAB"
git clone -q "$ROOT" "$OPEN_PROJECT"
cp -R "$ROOT/bin/." "$OPEN_PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$OPEN_PROJECT/.claude/settings.json"
mkdir -p "$OPEN_HOME/state" "$OPEN_HOME/config" "$OPEN_HOME/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$OPEN_HOME/state/task.meta"
# Run 1 closes actionable; later runs end the need so the session settles.
cat > "$OPEN_PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N at=$(date +%s) lease=${FM_WATCH_LEASE_DEADLINE:-unset} session=${CLAUDE_CODE_SESSION_ID:-unknown}" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-session-open\n'
exit 0
SH
cat > "$OPEN_PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
echo "drain at=$(date +%s)" >> "$FM_HOME/state/drain-ran"
printf 'stale: fixture-session-open drained\n'
SH
chmod +x "$OPEN_PROJECT/bin/fm-watch-arm.sh" "$OPEN_PROJECT/bin/fm-wake-drain.sh"

OPEN_STARTED=$(date +%s)
tmux -L "$OPEN_SOCKET" new-session -d -s open -x 200 -y 50 -c "$OPEN_PROJECT" \
  "env -i HOME=\"$HOME\" PATH=\"$PATH\" USER=\"${USER:-}\" TERM=xterm-256color FM_HOME=\"$OPEN_HOME\" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --effort low" \
  || fail "could not start the interactive Claude session"

# Accept the one-time folder-trust prompt; no prompt text is ever typed.
i=0
while [ "$i" -lt 60 ]; do
  PANE=$(tmux -L "$OPEN_SOCKET" capture-pane -p -t open 2>/dev/null || true)
  if printf '%s\n' "$PANE" | grep -q 'trust this folder'; then
    tmux -L "$OPEN_SOCKET" send-keys -t open Down
    sleep 0.5
    tmux -L "$OPEN_SOCKET" send-keys -t open Enter
    break
  fi
  [ -e "$OPEN_HOME/state/.session-start-complete" ] && break
  sleep 0.5
  i=$((i + 1))
done

# Wait for the session-open arm and for its rewake to reach the transcript.
OPEN_TRANSCRIPT=
i=0
while [ "$i" -lt 240 ]; do
  if [ -z "$OPEN_TRANSCRIPT" ] && [ -s "$OPEN_HOME/state/arm-ran" ]; then
    OPEN_SID=$(sed -n '1s/.* session=\([^ ]*\)$/\1/p' "$OPEN_HOME/state/arm-ran")
    OPEN_TRANSCRIPT=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "$OPEN_SID.jsonl" 2>/dev/null | head -1)
  fi
  if [ -n "$OPEN_TRANSCRIPT" ] && grep -q 'stale: fixture-session-open' "$OPEN_TRANSCRIPT" 2>/dev/null \
    && grep -q '"type":"assistant"' "$OPEN_TRANSCRIPT" 2>/dev/null; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

[ -s "$OPEN_HOME/state/arm-ran" ] \
  || fail "the untouched interactive session was never armed at session open: $(tmux -L "$OPEN_SOCKET" capture-pane -p -t open 2>/dev/null | tail -15)"
[ -n "$OPEN_TRANSCRIPT" ] || fail "could not locate the interactive session transcript from the arm record: $(cat "$OPEN_HOME/state/arm-ran")"
grep -q 'stale: fixture-session-open' "$OPEN_TRANSCRIPT" \
  || fail "the session-open rewake did not reach the untouched session: $OPEN_TRANSCRIPT"
grep -q '"type":"assistant"' "$OPEN_TRANSCRIPT" || fail "the session-open rewake did not start a model turn"
FIRST_ARM=$(sed -n '1p' "$OPEN_HOME/state/arm-ran")
FIRST_AT=$(printf '%s\n' "$FIRST_ARM" | sed -n 's/^arm-run=1 at=\([0-9]*\) .*/\1/p')
FIRST_LEASE=$(printf '%s\n' "$FIRST_ARM" | sed -n 's/.* lease=\([0-9]*\) .*/\1/p')
[ -n "$FIRST_AT" ] && [ -n "$FIRST_LEASE" ] || fail "the session-open arm carried no hook-budget lease: $FIRST_ARM"
[ "$FIRST_LEASE" -ge $((OPEN_STARTED + 518400)) ] && [ "$FIRST_LEASE" -le $((FIRST_AT + 518400)) ] \
  || fail "the session-open lease $FIRST_LEASE is not six days after the hook started ($OPEN_STARTED..$FIRST_AT)"
[ -e "$OPEN_HOME/state/.session-start-complete" ] \
  || fail "the session-open arm ran without a completed session start"
tmux -L "$OPEN_SOCKET" kill-server 2>/dev/null || true

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, kept the print-mode session-open arm inert, preserved the competing-live-owner boundary, and armed plus rewoke an untouched interactive session at session open with a six-day lease\n' "$CLAUDE_VERSION"
