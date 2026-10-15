#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh: own-harness detection from verified
# environment markers and process ancestry, crewmate harness resolution from
# config/crew-harness, and refusal of any other subcommand.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The detection cases below fake `ps` so process ancestry is fully controlled,
# but bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside one of those harnesses inherits its marker, and the
# highest-precedence one wins over everything these cases set up. Drop the
# ambient markers so what this suite asserts does not depend on which harness
# it was launched from; every case states the marker it means to test.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-harness)

# detect_own is pinned to claude via CLAUDECODE=1 so the "fall through to own"
# rows are reproducible. Each row writes config/crew-harness in a fresh config
# dir (a literal '-' leaves the file absent).
#   <label>^<crew-harness>^<expect-crew>
test_crew_resolution() {
  local label crew exp_crew cfg got n
  n=0
  while IFS='^' read -r label crew exp_crew; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    cfg="$TMP_ROOT/crew-$n/config"
    mkdir -p "$cfg"
    [ "$crew" = "-" ] || printf '%s\n' "$crew" > "$cfg/crew-harness"
    got=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" crew)
    [ "$got" = "$exp_crew" ] || fail "$label: crew resolved '$got', expected '$exp_crew'"
  done <<'ROWS'
absent -> own^-^claude
set -> that adapter^codex^codex
signed Pi wrapper stays distinct^pi-signed^pi-signed
default -> own^default^claude
ROWS
  pass "fm-harness.sh crew resolves config/crew-harness, falling back to own"
}

# Only the bare own-harness form and `crew` exist. Any other subcommand,
# including the retired persistent-home resolution modes, is refused with a
# usage error and prints no harness, rather than silently reporting own.
test_unknown_subcommands_are_refused() {
  local sub out err status
  err="$TMP_ROOT/unknown.err"
  for sub in secondmate secondmate-model secondmate-effort bogus; do
    out=$(CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" "$sub" 2>"$err")
    status=$?
    expect_code 2 "$status" "fm-harness.sh $sub should be refused"
    [ -z "$out" ] || fail "fm-harness.sh $sub printed '$out' instead of refusing"
    assert_grep "unknown subcommand: $sub" "$err" "fm-harness.sh $sub refusal did not name the subcommand"
  done
  pass "fm-harness.sh refuses unknown subcommands, including the retired ones"
}

test_cursor_marker_detection() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-marker"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" CURSOR_INVOKED_AS=cursor-agent "$ROOT/bin/fm-harness.sh")
  [ "$got" = cursor ] || fail "Cursor's exact launcher marker resolved '$got', expected cursor"
  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" CURSOR_INVOKED_AS=cursor "$ROOT/bin/fm-harness.sh")
  [ "$got" != cursor ] || fail "an inexact Cursor marker value was accepted as Cursor Agent CLI"
  pass "fm-harness detects only Cursor Agent CLI's exact invocation marker"
}

test_pi_signed_detection_and_session_lock_identity() {
  local dir fakebin got
  dir="$TMP_ROOT/pi-signed-identity"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_SIGNED_SHAPE:-exact}" in
  100:comm=:*) printf '%s\n' '/test/Pi.app/bin/pi' ;;
  100:args=:*) printf '%s\n' 'Pi' ;;
  100:ppid=:*) printf '%s\n' 200 ;;
  200:comm=:exact) printf '%s\n' '/opt/test/bin/pi-signed' ;;
  200:args=:exact) printf '%s\n' 'pi-signed --model test/model' ;;
  200:comm=:helper) printf '%s\n' '/opt/test/bin/pi-signed-helper' ;;
  200:args=:helper) printf '%s\n' 'pi-signed-helper' ;;
  200:comm=:plain) printf '%s\n' '/bin/zsh' ;;
  200:args=:plain) printf '%s\n' 'zsh' ;;
  200:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' bash ;;
  *:ppid=:*) printf '%s\n' 100 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "unmarked shared signed-wrapper ancestry resolved '$got', expected pi"
  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi-signed ] || fail "selected signed wrapper resolved '$got', expected pi-signed"
  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true FM_PI_HARNESS=pi "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "selected plain Pi resolved '$got', expected pi"
  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed-helper "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "inexact signed selection marker resolved '$got', expected pi"
  got=$(env -u CLAUDECODE -u GROK_AGENT -u PI_CODING_AGENT PATH="$fakebin:$BASE_PATH" FM_PI_HARNESS=pi-signed "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "signed selection marker without Pi's family marker resolved '$got', expected pi"
  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true FM_TEST_SIGNED_SHAPE=plain "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "plain Pi marker resolved '$got', expected pi"
  got=$(env -u CLAUDECODE -u GROK_AGENT PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true FM_TEST_SIGNED_SHAPE=helper "$ROOT/bin/fm-harness.sh")
  [ "$got" = pi ] || fail "unrelated pi-signed-helper ancestry resolved '$got', expected pi"

  got=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 100 ] || fail "session-lock ancestry selected '$got', expected the inner Pi engine pid 100"
  PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 200' "$ROOT" \
    || fail "session-lock liveness rejected exact pi-signed holder"
  if PATH="$fakebin:$BASE_PATH" FM_TEST_SIGNED_SHAPE=helper bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 200' "$ROOT"; then
    fail "session-lock liveness accepted unrelated pi-signed-helper"
  fi

  pass "pi-signed identity: authoritative launch selection distinguishes shared wrapper ancestry"
}

test_dash_leading_process_names_are_basename_operands() {
  local dir fakebin got err status
  dir="$TMP_ROOT/dash-leading-process-names"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  4242:comm=) printf '%s\n' '/opt/test/bin/codex' ;;
  4242:args=) printf '%s\n' 'codex' ;;
  4242:ppid=) printf '%s\n' 1 ;;
  5252:comm=) printf '%s\n' '-codex' ;;
  5252:args=) printf '%s\n' '-codex' ;;
  5252:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' '-zsh' ;;
  *:args=) printf '%s\n' '-zsh' ;;
  *:ppid=) printf '%s\n' 4242 ;;
esac
SH
  chmod +x "$fakebin/ps"

  err="$dir/fm-harness.err"
  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh" 2>"$err")
  [ "$got" = codex ] || fail "dash-leading shell ancestry resolved '$got', expected codex"
  [ ! -s "$err" ] || fail "fm-harness wrote basename option noise for literal -zsh: $(cat "$err")"

  err="$dir/fm-session-lock-ancestry.err"
  got=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT" 2>"$err")
  [ "$got" = 4242 ] || fail "session-lock dash-leading ancestry selected '$got', expected pid 4242"
  [ ! -s "$err" ] || fail "session-lock ancestry wrote basename option noise for literal -zsh: $(cat "$err")"

  err="$dir/fm-session-lock-alive.err"
  PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 5252' \
    "$ROOT" 2>"$err"; status=$?
  expect_code 0 "$status" "session-lock liveness should accept literal -codex as a harness process name"
  [ ! -s "$err" ] || fail "session-lock liveness wrote basename option noise for literal -codex: $(cat "$err")"

  pass "harness identity: dash-leading ps command names are basename operands, not options"
}

test_crew_resolution
test_unknown_subcommands_are_refused
test_cursor_marker_detection
test_pi_signed_detection_and_session_lock_identity
test_dash_leading_process_names_are_basename_operands
