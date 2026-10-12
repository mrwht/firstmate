#!/usr/bin/env bash
# Tests for the primary->secondmate inherited local-material propagation:
# propagate_inheritable_config unit behavior and config push.
#   The primary pushes a declared, extensible set of LOCAL (gitignored) config
#   items - config/crew-dispatch.json, config/crew-harness,
#   config/backlog-backend, config/backend, config/herdr-presentation-spaces,
#   config/startup-memory-budget, and config/trace-context - down into each
#   secondmate home's config/. For config/herdr-presentation-spaces, an absent
#   primary file and an absent destination file both mean the same
#   unconfigured default, so the generic absence mirror converges that item
#   without deciding its release-dependent floor.
#   It is primary-authoritative (re-pushed on the bootstrap secondmate sweep and
#   by config push). After a successful push that changes allowlisted config
#   under an already-running home, a literal-content reread instruction is
#   written to the secondmate home and only its pointer is sent via the routed
#   secondmate path (exact destination bytes, no summaries); unchanged config
#   sends nothing unless a previous send failure is pending.
# Harness detection and crew resolution live in tests/fm-harness.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

# Drop ambient harness markers so what this suite asserts does not depend on
# which harness it was launched from.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-harness)
export FM_BACKEND=tmux

# ===========================================================================
# B) propagate_inheritable_config unit behavior
# ===========================================================================
test_propagate_lib() {
  local d src dest home m1 m2 outside stdout stderr guard_repo err_text
  d="$TMP_ROOT/prop-lib"
  src="$d/src"
  home="$d/home1"
  dest="$home/config"
  mkdir -p "$src" "$dest" "$home/state"

  # 1. present source is copied
  printf '{"default":{"harness":"codex"}}\n' > "$src/crew-dispatch.json"
  printf 'codex\n' > "$src/crew-harness"
  printf 'manual\n' > "$src/backlog-backend"
  printf 'tmux\n' > "$src/backend"
  : > "$src/herdr-presentation-spaces"
  : > "$src/trace-context"
  stdout="$d/clean-copy.out"
  stderr="$d/clean-copy.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr" || fail "propagate returned non-zero"
  [ ! -s "$stdout" ] || fail "clean copy wrote to stdout"
  [ ! -s "$stderr" ] || fail "clean copy wrote to stderr"
  [ "$(cat "$dest/crew-dispatch.json")" = '{"default":{"harness":"codex"}}' ] || fail "crew-dispatch.json not propagated"
  [ "$(cat "$dest/crew-harness")" = codex ] || fail "crew-harness not propagated"
  [ "$(cat "$dest/backlog-backend")" = manual ] || fail "backlog-backend not propagated"
  [ "$(cat "$dest/backend")" = tmux ] || fail "backend not propagated"
  [ -f "$dest/herdr-presentation-spaces" ] || fail "herdr-presentation-spaces not propagated"
  printf 'herdr\n' > "$dest/backend"
  propagate_inheritable_config "$src" "$dest"
  [ "$(cat "$dest/backend")" = tmux ] || fail "primary backend did not overwrite a divergent destination"
  [ -f "$dest/trace-context" ] || fail "trace-context not propagated by the default inheritable set"

  # 2. idempotent: an unchanged re-run does not churn the mtime
  m1=$(date -r "$dest/crew-harness" +%s 2>/dev/null || stat -c %Y "$dest/crew-harness")
  sleep 1
  stdout="$d/unchanged.out"
  stderr="$d/unchanged.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr"
  [ ! -s "$stdout" ] || fail "unchanged propagation wrote to stdout"
  [ ! -s "$stderr" ] || fail "unchanged propagation wrote to stderr"
  m2=$(date -r "$dest/crew-harness" +%s 2>/dev/null || stat -c %Y "$dest/crew-harness")
  [ "$m1" = "$m2" ] || fail "idempotent re-run churned mtime ($m1 -> $m2)"

  # 3. a changed source value converges downstream
  printf '{"default":{"harness":"claude"}}\n' > "$src/crew-dispatch.json"
  printf 'claude\n' > "$src/crew-harness"
  printf 'tasks-axi\n' > "$src/backlog-backend"
  printf 'zellij\n' > "$src/backend"
  propagate_inheritable_config "$src" "$dest"
  [ "$(cat "$dest/crew-dispatch.json")" = '{"default":{"harness":"claude"}}' ] || fail "changed dispatch profile did not converge"
  [ "$(cat "$dest/crew-harness")" = claude ] || fail "changed value did not converge"
  [ "$(cat "$dest/backlog-backend")" = tasks-axi ] || fail "changed backlog backend did not converge"
  [ "$(cat "$dest/backend")" = zellij ] || fail "changed backend did not converge"

  outside="$d/outside-target"
  rm -f "$dest/crew-harness" "$outside"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$dest/crew-harness"
  printf 'pi\n' > "$src/crew-harness"
  propagate_inheritable_config "$src" "$dest"
  [ ! -L "$dest/crew-harness" ] || fail "destination symlink was not replaced"
  [ "$(cat "$dest/crew-harness")" = pi ] || fail "destination symlink replacement has wrong content"
  [ "$(cat "$outside")" = outside ] || fail "destination symlink target was overwritten"

  # 4. removing the source mirrors absence downstream (primary-authoritative)
  printf 'herdr\n' > "$dest/backend"
  rm -f "$src/crew-dispatch.json" "$src/crew-harness" "$src/backlog-backend" \
    "$src/backend" "$src/herdr-presentation-spaces" "$src/trace-context"
  propagate_inheritable_config "$src" "$dest"
  [ -e "$dest/crew-dispatch.json" ] && fail "dispatch profile absence not mirrored downstream"
  [ -e "$dest/crew-harness" ] && fail "absence not mirrored downstream"
  [ -e "$dest/backlog-backend" ] && fail "backlog-backend absence not mirrored downstream"
  [ -e "$dest/backend" ] && fail "backend absence not mirrored downstream"
  [ -e "$dest/herdr-presentation-spaces" ] && fail "herdr-presentation-spaces absence not mirrored downstream"
  [ -e "$dest/trace-context" ] && fail "trace-context absence not mirrored downstream"

  rm -f "$dest/crew-harness"
  ln -s "$d/missing-target" "$dest/crew-harness"
  propagate_inheritable_config "$src" "$dest"
  [ -L "$dest/crew-harness" ] && fail "broken destination symlink not removed on absence mirror"

  mkdir -p "$dest/crew-harness"
  stderr="$d/remove-error.err"
  if propagate_inheritable_config "$src" "$dest" 2>"$stderr"; then
    fail "failed absence mirror returned success"
  fi
  assert_contains "$(cat "$stderr")" "fm-config-inherit: error: failed to remove crew-harness" \
    "remove error did not emit a stderr diagnostic"
  [ -d "$dest/crew-harness" ] || fail "failed absence mirror removed the wrong path"
  rm -rf "$dest/crew-harness"

  # 5. secondmate-harness is never inherited; backend still is
  printf 'grok\n' > "$src/secondmate-harness"
  printf '{"default":{"harness":"codex"}}\n' > "$src/crew-dispatch.json"
  printf 'codex\n' > "$src/crew-harness"
  printf 'manual\n' > "$src/backlog-backend"
  printf 'herdr\n' > "$src/backend"
  rm -rf "$d/home2"
  mkdir -p "$d/home2/config" "$d/home2/state"
  propagate_inheritable_config "$src" "$d/home2/config"
  [ -e "$d/home2/config/secondmate-harness" ] && fail "secondmate-harness was inherited (must not be)"
  [ "$(cat "$d/home2/config/crew-dispatch.json")" = '{"default":{"harness":"codex"}}' ] || fail "crew-dispatch.json not propagated alongside"
  [ "$(cat "$d/home2/config/crew-harness")" = codex ] || fail "crew-harness not propagated alongside"
  [ "$(cat "$d/home2/config/backlog-backend")" = manual ] || fail "backlog-backend not propagated alongside"
  [ "$(cat "$d/home2/config/backend")" = herdr ] || fail "backend not propagated alongside"

  # 6. nothing to propagate -> destination dir is never created (a true no-op)
  rm -rf "$d/src3" "$d/dest3"
  mkdir -p "$d/src3"
  # Keep backend out of the empty-source case by clearing it from src3 only.
  propagate_inheritable_config "$d/src3" "$d/dest3/config"
  [ -e "$d/dest3/config" ] && fail "empty-source propagation created a destination dir"

  # 7. a git worktree that does not ignore an inherited item gets a visible
  # stderr warning and a skip, not a silent miss.
  guard_repo="$d/guard-repo"
  git init -q -b main "$guard_repo"
  printf 'config/crew-harness\nconfig/backlog-backend\n' > "$guard_repo/.gitignore"
  printf 'guard\n' > "$guard_repo/README.md"
  git -C "$guard_repo" add -A
  git -C "$guard_repo" commit -qm guard
  printf '{"default":{"harness":"grok"}}\n' > "$src/crew-dispatch.json"
  stdout="$d/guard-skip.out"
  stderr="$d/guard-skip.err"
  FM_INHERITABLE_CONFIG=crew-dispatch.json propagate_inheritable_config "$src" "$guard_repo/config" >"$stdout" 2>"$stderr" \
    || fail "guard skip should not make propagation fail"
  [ ! -s "$stdout" ] || fail "guard skip wrote to stdout"
  err_text=$(cat "$stderr")
  assert_contains "$err_text" "fm-config-inherit: warning: skipped crew-dispatch.json" \
    "guard skip did not emit a stderr warning"
  [ ! -e "$guard_repo/config/crew-dispatch.json" ] || fail "guard skip still copied the unignored item"

  pass "B1 propagate_inheritable_config: copy, idempotence, convergence, absence-mirror, exclusion, no-op, skip diagnostics"
}

# ===========================================================================
# B integration: bootstrap and config push propagate inherited local
# material and keep it converged on the primary (independent of tracked-file ff
# status).
# ===========================================================================

# A PRIMARY firstmate repo on main with one commit + a home dir, mirroring the
# real gitignore (config/crew-harness ignored, so a propagated value never dirties
# the secondmate worktree on a later sweep). Echoes the world dir.
new_world() {
  local name=$1 dispatch_ignore=${2:-yes} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  git init -q -b main "$w/main"
  {
    printf 'projects/\nstate/\ndata/\n.no-mistakes/\n'
    [ "$dispatch_ignore" = no ] || printf 'config/crew-dispatch.json\n'
    printf 'config/crew-harness\nconfig/secondmate-harness\nconfig/backlog-backend\n'
    printf 'config/backend\nconfig/herdr-presentation-spaces\nconfig/startup-memory-budget\n'
  } > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
  printf '%s\n' "$w"
}

record_live_watcher_fixture() {
  local home=$1 identity
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$$") || fail "could not identify the live watcher fixture"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

# A live secondmate home as a DETACHED worktree of the primary at <commit>, with
# its seed marker and a live kind=secondmate meta.
add_sm_worktree() {
  local w=$1 id=$2 commit=$3
  git -C "$w/main" worktree add -q --detach "$w/$id" "$commit"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  # tmux fake supports fm-send's composer-verified submit path and optional
  # FM_FAKE_TMUX_LOG / FM_FAKE_TMUX_FAIL_LITERAL for reread-nudge assertions.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
fi
case "$*" in
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex; exit 0 ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1'; exit 0 ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0; exit 0 ;;
  *capture-pane*) printf '❯\n'; exit 0 ;;
  *'send-keys'*' -l '*)
    [ "${FM_FAKE_TMUX_FAIL_LITERAL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *send-keys*)
    [ "${FM_FAKE_TMUX_FAIL_LITERAL:-0}" = 1 ] && exit 1
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.25'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

run_config_push() {
  local w=$1 fakebin log=${2:-}
  fakebin=$(make_fake_toolchain "$w")
  if [ -n "$log" ]; then
    PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
      FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" \
      "$ROOT/bin/fm-config-push.sh"
  else
    PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
      FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-config-push.sh"
  fi
}

reread_instruction_path() {
  local home=$1 state path latest=
  state="$(cd "$home/state" && pwd -P)"
  for path in "$state"/.fm-inherited-config-reread.*; do
    case "$path" in
      *.pending) continue ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest="$path"
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

reread_pending_path() {
  printf '%s.pending\n' "$(reread_instruction_path "$1")"
}

reread_retry_stage_path() {
  local home=$1 id=$2 retry_dir path latest=
  retry_dir="$home/state/.fm-inherited-config-reread-retry/$id"
  for path in "$retry_dir"/.fm-inherited-config-reread.*; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest="$path"
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

reread_retry_report_path() {
  local home=$1 id=$2 retry_dir path latest=
  retry_dir="$home/state/.fm-inherited-config-reread-retry/$id"
  for path in "$retry_dir"/.fm-inherited-config-reread.*.report; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest="$path"
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

reread_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

assert_no_reread_instructions() {
  local home=$1 state path
  state="$home/state"
  for path in "$state"/.fm-inherited-config-reread.*; do
    case "$path" in
      *.pending) continue ;;
    esac
    [ -f "$path" ] || [ -L "$path" ] || continue
    fail "unexpected config reread instruction: $path"
  done
}

assert_no_reread_pending() {
  local home=$1 state path
  state="$home/state"
  for path in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    fail "unexpected pending config reread marker: $path"
  done
}

assert_no_reread_retry_stages() {
  local home=$1 id=$2 retry_dir path
  retry_dir="$home/state/.fm-inherited-config-reread-retry/$id"
  for path in "$retry_dir"/.fm-inherited-config-reread.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    fail "unexpected staged config reread retry: $path"
  done
}

# config/backend: present and absent primary state converges exactly.
test_backend_inheritance_present_and_absent() {
  local w head out err status instruction
  w=$(new_world backend-inherit)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"

  printf 'tmux\n' > "$w/home/config/backend"
  err="$w/backend-inherit.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "backend present push should succeed"
  assert_contains "$out" "backend: pushed" "backend present value should report pushed"
  [ "$(cat "$w/sm/config/backend")" = tmux ] || fail "backend present value not pushed"
  instruction=$(reread_instruction_path "$w/sm") || fail "backend present reread instruction missing"
  assert_contains "$(cat "$instruction")" $'-----BEGIN config/backend-----\ntmux\n-----END config/backend-----' \
    "backend present reread must include exact bytes"

  printf 'herdr\n' > "$w/sm/config/backend"
  printf 'zellij\n' > "$w/home/config/backend"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "backend changed push should succeed"
  assert_contains "$out" "backend: pushed" "backend changed value should report pushed"
  [ "$(cat "$w/sm/config/backend")" = zellij ] \
    || fail "primary backend did not overwrite the divergent destination"

  rm -f "$w/home/config/backend"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "backend absence push should succeed"
  assert_contains "$out" "backend: pushed - mirrored primary absence" "backend should mirror primary absence"
  [ -e "$w/sm/config/backend" ] && fail "backend not removed on primary absence"
  instruction=$(reread_instruction_path "$w/sm") || fail "backend absence reread instruction missing"
  assert_contains "$(cat "$instruction")" $'-----BEGIN config/backend-----\nABSENT\n-----END config/backend-----' \
    "backend absence reread must use ABSENT token"
  pass "B12b backend inheritance: present values and primary absence converge exactly"
}

# config/herdr-presentation-spaces has an unconfigured default, so this item's
# convergence is asserted through the preference the spawn gate actually reads
# in the destination home, not through file presence alone: mirroring the primary's
# absence must converge a secondmate to the same unconfigured default rather
# than turning its projection off. The Herdr version floor that decides what
# that default resolves to is a property of the running release, not of
# inheritance, so it is pinned in tests/fm-backend-herdr.test.sh instead.
sm_presentation_verdict() {  # <config-dir> -> on|off
  bash -c '
    . "$0/bin/backends/herdr.sh"
    case "$(fm_backend_herdr_presentation_preference "$1")" in
      off) printf "off\n" ;;
      *) printf "on\n" ;;
    esac
  ' "$ROOT" "$1" 2>/dev/null
}

test_presentation_inheritance_default_on_and_opt_out() {
  local w head out err status verdict
  w=$(new_world presentation-inherit)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  err="$w/presentation-inherit.err"

  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "presentation default push should succeed"
  [ -e "$w/sm/config/herdr-presentation-spaces" ] \
    && fail "primary default must not write an opt-out downstream"
  verdict=$(sm_presentation_verdict "$w/sm/config")
  [ "$verdict" = on ] || fail "primary default left the secondmate projection $verdict"

  mkdir -p "$w/sm/config"
  printf 'off\n' > "$w/sm/config/herdr-presentation-spaces"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "presentation reconverge push should succeed"
  assert_contains "$out" "herdr-presentation-spaces: pushed - mirrored primary absence" \
    "a local secondmate opt-out should reconverge on the primary default"
  verdict=$(sm_presentation_verdict "$w/sm/config")
  [ "$verdict" = on ] || fail "primary default did not reconverge a locally opted-out secondmate ($verdict)"

  printf 'off\n' > "$w/home/config/herdr-presentation-spaces"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "presentation opt-out push should succeed"
  assert_contains "$out" "herdr-presentation-spaces: pushed" "explicit opt-out should report pushed"
  verdict=$(sm_presentation_verdict "$w/sm/config")
  [ "$verdict" = off ] || fail "explicit primary opt-out left the secondmate projection $verdict"

  : > "$w/home/config/herdr-presentation-spaces"
  out=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "presentation legacy opt-in push should succeed"
  verdict=$(sm_presentation_verdict "$w/sm/config")
  [ "$verdict" = on ] || fail "a legacy primary opt-in file left the secondmate projection $verdict"
  pass "B12c presentation inheritance: the primary default converges on, and only an explicit opt-out propagates off"
}

test_config_push_propagates_reports_without_ff_or_nudge() {
  local w c1 sm_real old_head out err status out2 tmp log instruction
  w=$(new_world config-push-basic)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf -- '- sm - config push target (home: %s; scope: config; projects: alpha; added 2026-06-30)\n' "$sm_real" > "$w/home/data/secondmates.md"
  tmp="$w/home/state/sm.meta.tmp"
  grep -v '^home=' "$w/home/state/sm.meta" > "$tmp"
  mv "$tmp" "$w/home/state/sm.meta"

  printf 'v2\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add AGENTS.md
  git -C "$w/main" commit -qm c2
  old_head=$(git -C "$w/sm" rev-parse HEAD)

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  printf 'tmux\n' > "$w/home/config/backend"
  record_live_watcher_fixture "$w/home"
  : > "$w/home/config/trace-context"
  err="$w/config-push-basic.err"
  log="$w/config-push-basic.tmux.log"
  out=$(run_config_push "$w" "$log" 2>"$err"); status=$?

  expect_code 0 "$status" "config push should succeed"
  assert_contains "$out" "config-push: $w/home -> live secondmate homes" \
    "config push lacked the header"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push did not discover the live secondmate through registry fallback"
  assert_contains "$out" "crew-dispatch.json: pushed" \
    "config push did not report crew-dispatch as pushed"
  assert_contains "$out" "crew-harness: pushed" \
    "config push did not report crew-harness as pushed"
  assert_contains "$out" "backlog-backend: pushed" \
    "config push did not report backlog-backend as pushed"
  assert_contains "$out" "backend: pushed" \
    "config push did not report backend as pushed"
  assert_contains "$out" "trace-context: unchanged" \
    "live config push must report trace-context as session-scoped and unchanged"
  [ ! -e "$w/sm/config/trace-context" ] \
    || fail "live config push retroactively enabled trace context in a legacy secondmate home"
  assert_contains "$out" "config-reread: sent" \
    "config push with changed config must send a literal reread instruction"
  assert_not_contains "$out" "NUDGE_SECONDMATES" \
    "config push must not use the AGENTS.md instruction-surface nudge channel"
  [ "$(git -C "$w/sm" rev-parse HEAD)" = "$old_head" ] \
    || fail "config push fast-forwarded tracked files"
  [ "$(cat "$w/sm/config/backend")" = tmux ] || fail "config push did not write backend"
  instruction=$(reread_instruction_path "$w/sm") || fail "config-push reread instruction missing"
  assert_contains "$(cat "$instruction")" $'-----BEGIN config/backend-----\ntmux\n-----END config/backend-----' \
    "config-push reread must include exact backend bytes"
  [ ! -s "$err" ] || fail "clean config push wrote unexpected stderr: $(cat "$err")"
  assert_contains "$(cat "$log")" "[fm-from-firstmate]" \
    "config reread must use the marked routed secondmate path"

  : > "$log"
  out2=$(run_config_push "$w" "$log" 2>"$err"); status=$?
  expect_code 0 "$status" "idempotent config push should succeed"
  assert_contains "$out2" "crew-dispatch.json: unchanged" \
    "idempotent config push did not report crew-dispatch as unchanged"
  assert_contains "$out2" "crew-harness: unchanged" \
    "idempotent config push did not report crew-harness as unchanged"
  assert_contains "$out2" "backlog-backend: unchanged" \
    "idempotent config push did not report backlog-backend as unchanged"
  assert_contains "$out2" "backend: unchanged" \
    "idempotent config push did not report backend as unchanged"
  assert_contains "$out2" "trace-context: unchanged" \
    "idempotent config push did not preserve session-scoped trace context"
  assert_not_contains "$out2" "config-reread: sent" \
    "unchanged config must not send a reread message"
  [ ! -s "$log" ] || fail "unchanged config push still invoked tmux send: $(cat "$log")"
  pass "B12 config-push propagates via shared live discovery, reports items, rereads on change only, and does not fast-forward"
}

test_config_push_reports_skips_dirty_and_invalid_home() {
  local w head out err status stale_real dirty_real bad_home err_text tmp
  w=$(new_world config-push-warnings)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" dirty "$head"
  add_sm_worktree "$w" stale "$head"
  dirty_real=$(cd "$w/dirty" && pwd -P)
  stale_real=$(cd "$w/stale" && pwd -P)

  printf 'local edit\n' >> "$w/dirty/README.md"
  tmp="$w/stale/.gitignore.tmp"
  grep -v '^config/crew-dispatch.json$' "$w/stale/.gitignore" > "$tmp"
  mv "$tmp" "$w/stale/.gitignore"

  bad_home="$w/not-secondmate"
  mkdir -p "$bad_home"
  {
    printf 'window=firstmate:fm-bad\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$bad_home"
  } > "$w/home/state/bad.meta"

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  err="$w/config-push-warnings.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 0 "$status" "warnings-only config push should exit zero"
  assert_contains "$out" "secondmate dirty ($dirty_real):" \
    "config push did not report dirty home"
  assert_contains "$out" "home: dirty working tree - local-material push continuing" \
    "config push did not surface dirty state"
  assert_contains "$out" "secondmate stale ($stale_real):" \
    "config push did not report stale home"
  assert_contains "$out" "crew-dispatch.json: skipped - destination does not allow inherited item" \
    "config push did not report non-allowing item skip"
  assert_contains "$out" "secondmate bad ($bad_home): skipped - unsafe home: not a seeded secondmate home" \
    "config push did not report invalid secondmate home"
  err_text=$(cat "$err")
  assert_contains "$err_text" "fm-config-inherit: warning: skipped crew-dispatch.json" \
    "config push did not inherit the lib's skip stderr warning"
  pass "B13 config-push reports dirty, non-allowing, and invalid homes without failing warnings-only runs"
}

test_config_push_exits_nonzero_on_copy_error() {
  local w head out err status sm_real err_text
  w=$(new_world config-push-error)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf 'codex\n' > "$w/home/config/crew-harness"
  mkdir -p "$w/sm/config/crew-harness"

  err="$w/config-push-error.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 1 "$status" "copy-error config push should exit non-zero"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push error output missed the home"
  assert_contains "$out" "crew-harness: error - failed to copy" \
    "config push did not report the per-item copy error"
  err_text=$(cat "$err")
  assert_contains "$err_text" "fm-config-inherit: error: failed to copy crew-harness" \
    "copy error did not emit a stderr diagnostic"
  pass "B14 config-push exits nonzero on real propagation errors"
}

test_config_push_rereads_after_partial_propagation() {
  local w head log out err status instruction pointer
  w=$(new_world config-push-partial)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'invalid shared header\n' > "$w/home/data/captain-shared.md"
  log="$w/config-push-partial.tmux.log"
  err="$w/config-push-partial.err"

  out=$(run_config_push "$w" "$log" 2>"$err"); status=$?
  expect_code 1 "$status" "partial propagation should remain non-zero"
  assert_contains "$out" "crew-dispatch.json: pushed" \
    "partial propagation did not report the completed config item"
  assert_contains "$out" "data/captain-shared.md: error" \
    "partial propagation did not report the failed shared item"
  assert_contains "$out" "config-reread: sent" \
    "partial propagation lost the completed config reread"
  [ "$(cat "$w/sm/config/crew-dispatch.json")" = '{"default":{"harness":"codex"}}' ] \
    || fail "partial propagation did not retain the completed config write"
  instruction=$(reread_instruction_path "$w/sm") || fail "partial propagation reread instruction missing"
  assert_present "$instruction" "partial propagation did not write a reread instruction"
  pointer="CONFIG_REREAD: $(reread_instruction_path "$w/sm")"
  assert_contains "$(cat "$log")" "$pointer" \
    "partial propagation did not route the instruction pointer"
  pass "B14 config-push rereads completed config writes after partial propagation"
}

# ---------------------------------------------------------------------------
# Literal-content config reread nudge (post-propagation live-agent wake)
# ---------------------------------------------------------------------------

shared_captain_header_for_tests() {
  cat <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF
}

# End-user-aligned reproduction of the pre-fix gap, then the fixed behavior:
# two live homes start with different stale config subsets; after push each is
# updated and each live agent receives only its own changed-content instruction.
test_config_reread_per_home_changed_sets_and_exact_bytes() {
  local w head log out err status instr_a instr_b multiline_json pointer
  w=$(new_world config-reread-per-home)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" alpha "$head"
  add_sm_worktree "$w" beta "$head"
  mkdir -p "$w/alpha/config" "$w/beta/config" "$w/alpha/state" "$w/beta/state"

  # alpha is stale on harness + backlog; beta is stale on multiline dispatch only.
  printf 'pi\n' > "$w/alpha/config/crew-harness"
  printf 'tasks-axi\n' > "$w/alpha/config/backlog-backend"
  printf '{"default":{"harness":"old"}}\n' > "$w/beta/config/crew-dispatch.json"

  multiline_json=$(printf '{\n  "default": {\n    "harness": "grok",\n    "model": "grok-4.5"\n  },\n  "rules": [\n    {"when": "news", "use": {"harness": "grok"}}\n  ]\n}\n')
  printf '%s' "$multiline_json" > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  printf 'tmux\n' > "$w/home/config/backend"
  {
    shared_captain_header_for_tests
    printf '%s\n' "shared secret preference body that must never appear in a config reread"
  } > "$w/home/data/captain-shared.md"

  record_live_watcher_fixture "$w/home"
  log="$w/config-reread-per-home.tmux.log"
  err="$w/config-reread-per-home.err"
  out=$(run_config_push "$w" "$log" 2>"$err"); status=$?
  expect_code 0 "$status" "per-home reread config push should succeed"
  [ ! -s "$err" ] || fail "unexpected stderr: $(cat "$err")"

  # Destination bytes converged per home.
  cmp -s "$w/home/config/crew-dispatch.json" "$w/alpha/config/crew-dispatch.json" \
    || fail "alpha did not receive multiline dispatch"
  cmp -s "$w/home/config/crew-dispatch.json" "$w/beta/config/crew-dispatch.json" \
    || fail "beta did not receive multiline dispatch"
  [ "$(cat "$w/alpha/config/crew-harness")" = codex ] || fail "alpha harness not updated"
  [ "$(cat "$w/alpha/config/backlog-backend")" = manual ] || fail "alpha backlog-backend not updated"
  [ "$(cat "$w/alpha/config/backend")" = tmux ] || fail "alpha backend not updated"

  instr_a=$(reread_instruction_path "$w/alpha") || fail "alpha instruction missing after config push"
  instr_b=$(reread_instruction_path "$w/beta") || fail "beta instruction missing after config push"
  assert_present "$instr_a" "alpha should receive a config-reread instruction file"
  assert_present "$instr_b" "beta should receive a config-reread instruction file"
  [ "$(reread_mode "$instr_a")" = 600 ] || fail "alpha instruction is not private"
  [ "$(reread_mode "$instr_b")" = 600 ] || fail "beta instruction is not private"

  # Deterministic allowlist path order and exact destination bytes for alpha
  # (allowlisted config items were missing/stale and therefore pushed).
  assert_grep "These inherited config files changed" "$instr_a" "alpha framing missing"
  assert_grep "defaults/rules" "$instr_a" "alpha must preserve agent judgment framing"
  assert_contains "$(cat "$instr_a")" "config/crew-dispatch.json" "alpha missing dispatch path"
  assert_contains "$(cat "$instr_a")" "config/crew-harness" "alpha missing harness path"
  assert_contains "$(cat "$instr_a")" "config/backlog-backend" "alpha missing backlog path"
  assert_contains "$(cat "$instr_a")" "config/backend" "alpha missing backend path"
  # Path order follows FM_INHERITABLE_CONFIG.
  awk '
    /config\/crew-dispatch\.json/ { d=NR }
    /config\/crew-harness/ { h=NR }
    /config\/backlog-backend/ { b=NR }
    /config\/backend/ && !/backlog-backend/ { k=NR }
    END {
      if (!(d && h && b && k && d < h && h < b && b < k)) exit 1
    }
  ' "$instr_a" || fail "alpha instruction path order is not deterministic allowlist order"

  # Exact multiline JSON appears byte-for-byte between delimiters.
  assert_contains "$(cat "$instr_a")" "$multiline_json" \
    "alpha instruction must include exact multiline dispatch bytes"
  assert_contains "$(cat "$instr_a")" $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "alpha instruction must include exact harness scalar bytes"
  assert_contains "$(cat "$instr_a")" $'-----BEGIN config/backlog-backend-----\nmanual\n-----END config/backlog-backend-----' \
    "alpha instruction must include exact backlog-backend scalar bytes"
  assert_contains "$(cat "$instr_a")" $'-----BEGIN config/backend-----\ntmux\n-----END config/backend-----' \
    "alpha instruction must include exact backend scalar bytes"

  # No parsed/effective summary, no SHA, no captain-shared dump.
  assert_not_contains "$(cat "$instr_a")" "Default worker" "must not emit parsed worker summary"
  assert_not_contains "$(cat "$instr_a")" "sha" "must not emit sha tokens"
  assert_not_contains "$(cat "$instr_a")" "SHA" "must not emit SHA tokens"
  assert_not_contains "$(cat "$instr_a")" "captain-shared" "captain-shared path must not appear"
  assert_not_contains "$(cat "$instr_a")" "shared secret preference body" \
    "captain-shared content must never be inlined"
  assert_not_contains "$(cat "$instr_b")" "shared secret preference body" \
    "beta must not inline captain-shared either"

  # Beta started with only dispatch stale; harness/backlog were absent on both
  # sides for beta... wait: primary has harness+backlog, beta lacked them, so
  # they are also pushed. Seed beta with matching harness/backlog so only
  # dispatch changes for beta - re-run a focused unit of the write helper below.
  # For this push, beta was missing harness and backlog too, so all three push.
  # Prove isolation by comparing that neither instruction references the other's
  # pre-push stale unique value.
  assert_not_contains "$(cat "$instr_a")" '"harness":"old"' \
    "alpha must not receive beta's pre-push stale dispatch"
  assert_not_contains "$(cat "$instr_b")" $'pi\n' \
    "beta instruction must not leak alpha-only stale harness bytes as a standalone scalar block incorrectly"

  # Routed send used the from-firstmate marker and carried only the pointer.
  pointer="CONFIG_REREAD: $(reread_instruction_path "$w/alpha")"
  assert_contains "$(cat "$log")" "[fm-from-firstmate]" "reread send must be marked"
  assert_contains "$(cat "$log")" "$pointer" "reread send must point to the durable instruction file"
  assert_not_contains "$(cat "$log")" '"harness": "grok"' "sent message must not inline multiline JSON"
  assert_not_contains "$(cat "$log")" $'\n  "default"' "sent message must not contain embedded newlines"
  assert_not_contains "$(cat "$log")" "Default worker" "sent message must not summarize"
  pass "B15 config reread is per-home, exact-byte, ordered, and pointer-only"
}

test_config_reread_isolation_and_absent_and_send_failure() {
  local w head log out out2 err status status2 instr_a instr_b report retry_log retry_out retry_status retry_pointer
  local first_instr first_copy second_instr second_pointer
  w=$(new_world config-reread-absent)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" alpha "$head"
  add_sm_worktree "$w" beta "$head"
  mkdir -p "$w/alpha/config" "$w/beta/config" "$w/alpha/state" "$w/beta/state"

  # alpha: only harness will change (dispatch+backlog already match primary absence).
  # beta: only dispatch will change.
  printf 'old-harness\n' > "$w/alpha/config/crew-harness"
  printf '{"stale":true}\n' > "$w/beta/config/crew-dispatch.json"
  # Primary has only crew-harness set; dispatch and backlog absent.
  printf 'codex\n' > "$w/home/config/crew-harness"
  rm -f "$w/home/config/crew-dispatch.json" "$w/home/config/backlog-backend"

  log="$w/config-reread-absent.tmux.log"
  err="$w/config-reread-absent.err"
  out=$(run_config_push "$w" "$log" 2>"$err"); status=$?
  expect_code 0 "$status" "absent-mirror reread push should succeed"

  instr_a=$(reread_instruction_path "$w/alpha") || fail "alpha instruction missing after config push"
  instr_b=$(reread_instruction_path "$w/beta") || fail "beta instruction missing after config push"
  assert_present "$instr_a" "alpha instruction missing after harness change"
  assert_present "$instr_b" "beta instruction missing after dispatch removal"

  # alpha changed harness only.
  assert_contains "$(cat "$instr_a")" "config/crew-harness" "alpha should mention harness"
  assert_contains "$(cat "$instr_a")" $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "alpha harness block exact"
  assert_not_contains "$(cat "$instr_a")" "config/crew-dispatch.json" \
    "alpha must not list unchanged/absent-both dispatch"
  assert_not_contains "$(cat "$instr_a")" "config/backlog-backend" \
    "alpha must not list unchanged/absent-both backlog"
  assert_not_contains "$(cat "$instr_a")" '{"stale":true}' \
    "alpha must not receive beta's changed dispatch content"

  # beta: dispatch mirrored to ABSENT (and harness is also newly pushed from primary).
  assert_contains "$(cat "$instr_b")" "config/crew-dispatch.json" "beta should mention dispatch"
  assert_contains "$(cat "$instr_b")" $'-----BEGIN config/crew-dispatch.json-----\nABSENT\n-----END config/crew-dispatch.json-----' \
    "beta must represent removal as ABSENT"
  assert_not_contains "$(cat "$instr_b")" "old-harness" \
    "beta must not receive alpha's pre-push stale harness content"
  # Pure ABSENT + unchanged isolation via the write helper (no second inheritance path).
  report="$w/absent-only.report"
  {
    printf '%s\n' $'crew-dispatch.json\tpushed\tmirrored primary absence'
    printf '%s\n' $'crew-harness\tunchanged\t'
    printf '%s\n' $'backlog-backend\tunchanged\t'
    printf '%s\n' $'backend\tunchanged\t'
    printf '%s\n' $'data/captain-shared.md\tpushed\t'
  } > "$report"
  rm -f "$w/beta/config/crew-dispatch.json"
  fm_config_write_reread_instruction "$w/beta" "$report" "$w/beta/state/.fm-inherited-config-reread-absent" \
    || fail "ABSENT instruction write failed"
  assert_contains "$(cat "$w/beta/state/.fm-inherited-config-reread-absent")" \
    $'-----BEGIN config/crew-dispatch.json-----\nABSENT\n-----END config/crew-dispatch.json-----' \
    "helper ABSENT representation"
  assert_not_contains "$(cat "$w/beta/state/.fm-inherited-config-reread-absent")" "captain-shared" \
    "helper must ignore captain-shared even when report says pushed"
  assert_not_contains "$(cat "$w/beta/state/.fm-inherited-config-reread-absent")" "config/crew-harness" \
    "helper must omit unchanged items"

  # Send failure becomes a retryable diagnostic and non-zero exit.
  printf 'claude\n' > "$w/home/config/crew-harness"
  err="$w/config-reread-send-fail.err"
  out=$(PATH="$(make_fake_toolchain "$w"):$BASE_PATH" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_FAIL_LITERAL=1 \
    "$ROOT/bin/fm-config-push.sh" 2>"$err"); status=$?
  expect_code 1 "$status" "send failure should make config-push exit non-zero"
  assert_contains "$out" "CONFIG_REREAD: secondmate" "send failure diagnostic missing"
  assert_contains "$out" "send failed" "send failure must say send failed"
  assert_not_contains "$out" "config-reread: sent" \
    "must not claim reread landed when send failed"
  first_instr=$(reread_instruction_path "$w/alpha") || fail "alpha failed-send instruction missing"
  first_copy="$w/alpha/first-reread-generation.copy"
  cp "$first_instr" "$first_copy"
  assert_present "$(reread_pending_path "$w/alpha")" \
    "alpha send failure did not record a retry marker"
  assert_present "$(reread_pending_path "$w/beta")" \
    "beta send failure did not record a retry marker"

  # A later changed push publishes a distinct generation without overwriting
  # the failed generation, then an unchanged push retries both pointers.
  printf 'pi\n' > "$w/home/config/crew-harness"
  err="$w/config-reread-send-fail-second.err"
  out2=$(PATH="$(make_fake_toolchain "$w"):$BASE_PATH" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_FAIL_LITERAL=1 \
    "$ROOT/bin/fm-config-push.sh" 2>"$err"); status2=$?
  expect_code 1 "$status2" "second send failure should make config-push exit non-zero"
  assert_not_contains "$out2" "config-reread: sent" \
    "second send failure must not claim reread delivery"
  second_instr=$(reread_instruction_path "$w/alpha") || fail "alpha second generation missing"
  [ "$first_instr" != "$second_instr" ] || fail "successive pushes reused the same generation path"
  cmp -s "$first_copy" "$first_instr" || fail "later push overwrote the earlier generation bytes"
  second_pointer="CONFIG_REREAD: $second_instr"
  assert_present "$(reread_pending_path "$w/alpha")" \
    "alpha second generation did not remain pending"

  # A normal later push retries the durable pointers even though propagation is
  # unchanged, then clears every marker after delivery succeeds.
  retry_log="$w/config-reread-send-retry.tmux.log"
  retry_out=$(run_config_push "$w" "$retry_log" 2>"$err"); retry_status=$?
  expect_code 0 "$retry_status" "send failure should be retryable"
  assert_contains "$retry_out" "config-reread: sent" \
    "retry should report the reread as sent"
  retry_pointer="CONFIG_REREAD: $(reread_instruction_path "$w/beta")"
  assert_contains "$(cat "$retry_log")" "$retry_pointer" \
    "retry did not resend the durable pointer"
  assert_contains "$(cat "$retry_log")" "CONFIG_REREAD: $first_instr" \
    "retry did not resend the first pending generation"
  assert_contains "$(cat "$retry_log")" "$second_pointer" \
    "retry did not resend the second pending generation"
  assert_no_reread_pending "$w/alpha"
  assert_no_reread_pending "$w/beta"
  pass "B16 config reread isolation, ABSENT, generation safety, send failure, and retry"
}

test_config_reread_publication_failure_retries_exact_generation() {
  local w head fakebin real_mv alpha_state out status stage log instr retry_out retry_status
  w=$(new_world config-reread-publication-retry)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" alpha "$head"
  mkdir -p "$w/alpha/config" "$w/alpha/state"
  printf 'old\n' > "$w/alpha/config/crew-harness"
  printf 'codex\n' > "$w/home/config/crew-harness"

  fakebin=$(make_fake_toolchain "$w")
  real_mv=$(command -v mv)
  alpha_state=$(cd "$w/alpha/state" && pwd -P)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"$alpha_state/.fm-inherited-config-reread."*) exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1); status=$?
  expect_code 1 "$status" "publication failure should remain diagnostic"
  assert_contains "$out" "CONFIG_REREAD: secondmate" "publication failure diagnostic missing"
  assert_not_contains "$out" "config-reread: sent" \
    "publication failure must not claim reread delivery"
  [ "$(cat "$w/alpha/config/crew-harness")" = codex ] \
    || fail "publication failure did not retain the completed config write"
  stage=$(reread_retry_stage_path "$w/home" alpha) \
    || fail "publication failure did not retain an exact retry generation"
  assert_contains "$(cat "$stage")" \
    $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "retry generation did not retain exact destination bytes"
  assert_no_reread_instructions "$w/alpha"

  rm -f "$fakebin/mv"
  log="$w/config-reread-publication-retry.tmux.log"
  retry_out=$(run_config_push "$w" "$log" 2>/dev/null); retry_status=$?
  expect_code 0 "$retry_status" "publication failure should retry on an unchanged push"
  assert_contains "$retry_out" "config-reread: sent" \
    "successful publication retry should report delivery"
  instr=$(reread_instruction_path "$w/alpha") \
    || fail "publication retry did not publish an instruction"
  assert_contains "$(cat "$log")" "CONFIG_REREAD: $instr" \
    "publication retry did not send the durable pointer"
  assert_no_reread_retry_stages "$w/home" alpha
  pass "B20 config reread publication failures retain exact generations for retry"
}

test_config_reread_write_failure_retains_exact_retry_generation() {
  local w head fakebin real_mv retry_dir out status stage_path log retry_out retry_status instr
  local old_instr new_instr
  w=$(new_world config-reread-write-retry)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/config" "$w/sm/state"
  printf 'old\n' > "$w/sm/config/crew-harness"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fakebin=$(make_fake_toolchain "$w")
  real_mv=$(command -v mv)
  mkdir -p "$w/home/state/.fm-inherited-config-reread-retry/sm"
  retry_dir=$(cd "$w/home/state/.fm-inherited-config-reread-retry/sm" && pwd -P)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
target=
for arg in "\$@"; do target="\$arg"; done
case "\$target" in
  *"$retry_dir"/.fm-inherited-config-reread.*)
    case "\$target" in
      *.exact) ;;
      *) exit 1 ;;
    esac
    ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1); status=$?
  expect_code 1 "$status" "instruction-write failure should remain diagnostic"
  assert_contains "$out" "retained exact retry generation" \
    "instruction-write failure did not retain exact retry bytes"
  stage_path=$(reread_retry_stage_path "$w/home" sm) \
    || fail "instruction-write failure did not leave a durable exact generation"
  assert_contains "$(cat "$stage_path")" \
    $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "instruction-write failure did not retain the original exact bytes"
  printf 'changed-before-retry\n' > "$w/home/config/crew-harness"
  rm -f "$fakebin/mv"
  log="$w/config-reread-write-retry.tmux.log"
  retry_out=$(run_config_push "$w" "$log" 2>/dev/null); retry_status=$?
  expect_code 0 "$retry_status" "a later changed push should retry an instruction-write failure"
  assert_contains "$retry_out" "config-reread: sent" \
    "later changed push did not deliver the retained exact generation"
  old_instr=$(grep 'CONFIG_REREAD:' "$log" | head -n 1 | sed 's/.*CONFIG_REREAD: //')
  new_instr=$(grep 'CONFIG_REREAD:' "$log" | tail -n 1 | sed 's/.*CONFIG_REREAD: //')
  [ -n "$old_instr" ] && [ -n "$new_instr" ] && [ "$old_instr" != "$new_instr" ] \
    || fail "later changed push did not deliver both generations"
  instr="$old_instr"
  assert_contains "$(cat "$instr")" \
    $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "exact retry delivery did not preserve the original destination bytes"
  assert_contains "$(cat "$new_instr")" "changed-before-retry" \
    "later changed push did not deliver its new destination bytes"
  assert_no_reread_retry_stages "$w/home" sm
  pass "B21 config reread instruction-write failures retain exact retry generations"
}

test_config_reread_exact_temp_survives_adoption_failure() {
  local w head fakebin real_mv real_cp retry_dir out status stage_path log retry_out retry_status
  local old_instr new_instr
  w=$(new_world config-reread-exact-temp-fallback)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/config" "$w/sm/state"
  printf 'old\n' > "$w/sm/config/crew-harness"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fakebin=$(make_fake_toolchain "$w")
  real_mv=$(command -v mv)
  real_cp=$(command -v cp)
  mkdir -p "$w/home/state/.fm-inherited-config-reread-retry/sm"
  retry_dir=$(cd "$w/home/state/.fm-inherited-config-reread-retry/sm" && pwd -P)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
target=
for arg in "\$@"; do target="\$arg"; done
case "\$target" in
  *"$retry_dir"/.fm-inherited-config-reread.*) exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  cat > "$fakebin/cp" <<SH
#!/usr/bin/env bash
target=
for arg in "\$@"; do target="\$arg"; done
case "\$target" in
  *"$retry_dir"/.fm-inherited-config-reread.*) exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
  chmod +x "$fakebin/cp"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1); status=$?
  expect_code 1 "$status" "exact temporary fallback failure should remain diagnostic"
  assert_contains "$out" "retained exact retry temporary" \
    "exact temporary fallback failure did not retain the immutable bytes"
  stage_path=$(reread_retry_stage_path "$w/home" sm) \
    || fail "exact temporary fallback failure lost its retry artifact"
  case "$stage_path" in
    *.tmp.*) : ;;
    *) fail "exact temporary fallback retained an unexpected artifact: $stage_path" ;;
  esac
  [ ! -e "$stage_path.report" ] \
    || fail "exact temporary fallback created a lossy retry report"
  assert_contains "$(cat "$stage_path")" \
    $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "exact temporary fallback did not preserve the original bytes"
  printf 'changed-before-retry\n' > "$w/home/config/crew-harness"
  rm -f "$fakebin/mv" "$fakebin/cp"
  log="$w/config-reread-exact-temp-fallback.tmux.log"
  retry_out=$(run_config_push "$w" "$log" 2>/dev/null); retry_status=$?
  expect_code 0 "$retry_status" "later push should deliver retained exact temporary bytes"
  old_instr=$(grep 'CONFIG_REREAD:' "$log" | head -n 1 | sed 's/.*CONFIG_REREAD: //')
  new_instr=$(grep 'CONFIG_REREAD:' "$log" | tail -n 1 | sed 's/.*CONFIG_REREAD: //')
  [ -n "$old_instr" ] && [ -n "$new_instr" ] && [ "$old_instr" != "$new_instr" ] \
    || fail "later push did not deliver both exact generations"
  assert_contains "$(cat "$old_instr")" \
    $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
    "later push rebuilt the retained temporary from newer bytes"
  assert_contains "$(cat "$new_instr")" "changed-before-retry" \
    "later push did not deliver the new destination bytes"
  assert_no_reread_retry_stages "$w/home" sm
  pass "B21 config reread preserves exact bytes when temporary adoption also fails"
}

test_config_reread_serializes_concurrent_pushes() {
  local w head fakebin marker entered log first_out second_out first_pid first_status second_status
  local first_instr second_instr first_line second_line
  w=$(new_world config-reread-serialized-pushes)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/config" "$w/sm/state"
  printf 'old\n' > "$w/sm/config/crew-harness"
  printf 'one\n' > "$w/home/config/crew-harness"

  fakebin=$(make_fake_toolchain "$w")
  mv "$fakebin/tmux" "$fakebin/tmux.real"
  marker="$w/first-send.marker"
  entered="$w/first-send.entered"
  log="$w/config-reread-serialized.tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *send-keys*)
    if (set -o noclobber; : > "$marker") 2>/dev/null; then
      : > "$entered"
      sleep 1
    fi
    ;;
esac
exec "$fakebin/tmux.real" "\$@"
SH
  chmod +x "$fakebin/tmux"

  first_out="$w/first-push.out"
  (
    PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
      FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" \
      "$ROOT/bin/fm-config-push.sh" > "$first_out" 2>&1
  ) &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$entered" ] && break
    sleep 0.02
  done
  [ -e "$entered" ] || fail "first config push did not reach pointer delivery"
  first_instr=$(reread_instruction_path "$w/sm") \
    || fail "first concurrent push did not publish its generation"
  printf 'two\n' > "$w/home/config/crew-harness"
  second_out="$w/second-push.out"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-config-push.sh" > "$second_out" 2>&1
  second_status=$?
  wait "$first_pid"; first_status=$?
  expect_code 0 "$first_status" "first serialized config push failed"
  expect_code 0 "$second_status" "second serialized config push failed"
  second_instr=$(reread_instruction_path "$w/sm") \
    || fail "second concurrent push did not publish its generation"
  [ "$first_instr" != "$second_instr" ] || fail "concurrent pushes reused a generation"
  [ "$(cat "$w/sm/config/crew-harness")" = two ] \
    || fail "concurrent pushes did not converge the latest config bytes"
  first_line=$(grep -n -F "CONFIG_REREAD: $first_instr" "$log" | head -n 1 | cut -d: -f1)
  second_line=$(grep -n -F "CONFIG_REREAD: $second_instr" "$log" | head -n 1 | cut -d: -f1)
  [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] \
    || fail "concurrent pushes delivered generations out of order"
  pass "B21 config reread serializes concurrent propagation and delivery"
}

test_config_reread_full_retry_queue_drains_before_new_push() {
  local w head retry_dir path n fakebin log out status pointer_count
  w=$(new_world config-reread-full-queue)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/config" "$w/sm/state"
  printf 'old\n' > "$w/sm/config/crew-harness"
  printf 'new\n' > "$w/home/config/crew-harness"
  retry_dir="$w/home/state/.fm-inherited-config-reread-retry/sm"
  mkdir -p "$retry_dir"
  for n in $(seq -w 1 16); do
    path="$retry_dir/.fm-inherited-config-reread.20260721T000000.$n"
    printf 'generation-%s\n' "$n" > "$path"
    chmod 0600 "$path"
  done
  fakebin=$(make_fake_toolchain "$w")
  log="$w/config-reread-full-queue.tmux.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-config-push.sh" 2>&1); status=$?
  expect_code 0 "$status" "a full retry queue should drain before a new push"
  assert_contains "$out" "config-reread: sent" \
    "a new config generation was not delivered after retry draining"
  [ "$(cat "$w/sm/config/crew-harness")" = new ] \
    || fail "the new config generation did not propagate after retry draining"
  assert_no_reread_retry_stages "$w/home" sm
  pointer_count=$(grep -c 'CONFIG_REREAD:' "$log" 2>/dev/null || true)
  [ "$pointer_count" -ge 17 ] \
    || fail "full retry queue did not deliver all pending generations before the new one"
  pass "B22 full config reread retry queues drain before new publication"
}

test_config_reread_cleanup_runs_after_mixed_delivery_failure() {
  local w head fakebin state_real fail_path path n report out status count
  w=$(new_world config-reread-mixed-delivery)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/state"
  state_real=$(cd "$w/sm/state" && pwd -P)
  fail_path="$state_real/.fm-inherited-config-reread.9999-fail"
  for n in $(seq -w 1 18); do
    path="$state_real/.fm-inherited-config-reread.00$n"
    printf 'generation-%s\n' "$n" > "$path"
    chmod 0600 "$path"
  done
  printf 'failed-generation\n' > "$fail_path"
  chmod 0600 "$fail_path"
  for path in "$state_real"/.fm-inherited-config-reread.*; do
    fm_config_reread_mark_pending "$path" "$path.pending" \
      || fail "could not mark mixed-delivery generation pending"
  done
  fakebin=$(make_fake_toolchain "$w")
  mv "$fakebin/tmux" "$fakebin/tmux.real"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
  case "\$*" in
  *send-keys*'.9999-fail'*) exit 1 ;;
esac
exec "$fakebin/tmux.real" "\$@"
SH
  chmod +x "$fakebin/tmux"
  report="$w/empty-reread.report"
  : > "$report"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 fm_config_send_reread_nudge sm "$w/sm" "$report" 2>&1); status=$?
  expect_code 1 "$status" "mixed delivery failure should remain diagnostic"
  assert_contains "$out" "CONFIG_REREAD: secondmate sm: send failed" \
    "mixed delivery failure diagnostic missing"
  count=0
  for path in "$state_real"/.fm-inherited-config-reread.*; do
    case "$path" in
      *.pending) continue ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    [ ! -e "$path.pending" ] || continue
    count=$((count + 1))
  done
  [ "$count" = 16 ] || fail "mixed delivery failure skipped bounded sent-history cleanup (count=$count)"
  assert_present "$fail_path.pending" "failed generation lost its retry marker"
  pass "B23 mixed config reread delivery failures still bound sent history"
}

test_config_reread_stops_after_failed_generation() {
  local w fakebin state_real old new report log out status
  w=$(new_world config-reread-order)
  mkdir -p "$w/sm/state"
  state_real=$(cd "$w/sm/state" && pwd -P)
  old="$state_real/.fm-inherited-config-reread.0000-fail"
  new="$state_real/.fm-inherited-config-reread.0001-new"
  printf 'old-generation\n' > "$old"
  printf 'new-generation\n' > "$new"
  chmod 0600 "$old" "$new"
  fm_config_reread_mark_pending "$old" "$old.pending" \
    || fail "could not mark older generation pending"
  fm_config_reread_mark_pending "$new" "$new.pending" \
    || fail "could not mark newer generation pending"
  fakebin=$(make_fake_toolchain "$w")
  mv "$fakebin/tmux" "$fakebin/tmux.real"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *send-keys*'.0000-fail'*) exit 1 ;;
esac
exec "$fakebin/tmux.real" "\$@"
SH
  chmod +x "$fakebin/tmux"
  report="$w/empty-reread.report"
  : > "$report"
  log="$w/config-reread-order.tmux.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" \
    fm_config_send_reread_nudge sm "$w/sm" "$report" 2>&1); status=$?
  expect_code 1 "$status" "an older failed generation should remain diagnostic"
  assert_contains "$out" "CONFIG_REREAD: secondmate sm: send failed" \
    "older generation failure diagnostic missing"
  assert_not_contains "$(cat "$log" 2>/dev/null || true)" ".0001-new" \
    "newer generation was delivered after an older failure"
  assert_present "$old.pending" "older failed generation lost its retry marker"
  assert_present "$new.pending" "newer generation was sent after an older failure"
  pass "B26 config reread delivery stops after the oldest failed generation"
}

test_bootstrap_detect_only_does_not_create_state() {
  local w fakebin detect_state out status
  w=$(new_world bootstrap-detect-only)
  detect_state="$w/detect-state"
  fakebin=$(make_fake_toolchain "$w")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$detect_state" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1); status=$?
  expect_code 0 "$status" "detect-only bootstrap should succeed"
  [ ! -e "$detect_state" ] || fail "detect-only bootstrap created its state directory"
  pass "B24 bootstrap detect-only mode remains filesystem read-only"
}

test_config_reread_skips_when_unchanged_and_reads_after_push() {
  local w head log out err status report instr n path pending_instruction count
  w=$(new_world config-reread-after-push)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  mkdir -p "$w/sm/config" "$w/sm/state"

  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'codex\n' > "$w/sm/config/crew-harness"
  log="$w/config-reread-unchanged.tmux.log"
  out=$(run_config_push "$w" "$log" 2>/dev/null); status=$?
  expect_code 0 "$status" "unchanged push should succeed"
  assert_not_contains "$out" "config-reread: sent" "no reread when nothing changed"
  [ ! -s "$log" ] || fail "unchanged push still sent text: $(cat "$log")"
  assert_no_reread_instructions "$w/sm"

  # Prove instruction bytes are taken from destination after write: if we only
  # read the primary source, a post-copy destination mutation would not matter.
  # Here we call the write helper after planting distinct dest bytes and a
  # pushed report line.
  printf '%s' 'destination-post-write' > "$w/sm/config/crew-harness"
  printf 'primary-source-only\n' > "$w/home/config/crew-harness"
  report="$w/after-push.report"
  printf '%s\n' $'crew-harness\tpushed\t' > "$report"
  instr="$w/sm/state/.fm-inherited-config-reread-dest"
  fm_config_write_reread_instruction "$w/sm" "$report" "$instr" \
    || fail "destination-byte instruction write failed"
  assert_contains "$(cat "$instr")" "destination-post-write" \
    "instruction must use destination post-write bytes"
  assert_contains "$(cat "$instr")" $'destination-post-write-----END config/crew-harness-----' \
    "instruction must not append a byte to a non-newline-terminated destination"
  assert_not_contains "$(cat "$instr")" "primary-source-only" \
    "instruction must not fall back to primary source bytes"
  : > "$w/sm/config/crew-harness"
  fm_config_write_reread_instruction "$w/sm" "$report" "$instr" \
    || fail "empty destination instruction write failed"
  assert_contains "$(cat "$instr")" $'-----BEGIN config/crew-harness-----
-----END config/crew-harness-----' \
    "instruction must represent an empty destination without a synthetic byte"
  pending_instruction="$w/sm/state/.fm-inherited-config-reread.20260721T000000.01"
  printf '%s\n' generation > "$pending_instruction"
  fm_config_reread_mark_pending "$pending_instruction" "$pending_instruction.pending" \
    || fail "could not create bounded-lifecycle pending marker"
  for n in $(seq -w 2 18); do
    path="$w/sm/state/.fm-inherited-config-reread.20260721T000000.$n"
    printf '%s\n' generation > "$path"
    chmod 0600 "$path"
  done
  fm_config_reread_cleanup_sent "$w/sm"
  count=0
  for path in "$w/sm/state"/.fm-inherited-config-reread.*; do
    case "$path" in
      *.pending) continue ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    [ ! -e "$path.pending" ] || continue
    count=$((count + 1))
  done
  [ "$count" = 16 ] || fail "sent reread generations were not bounded"
  assert_present "$pending_instruction" "cleanup deleted a pending reread generation"
  assert_present "$pending_instruction.pending" "cleanup deleted a pending reread marker"
  pass "B17 config reread skips unchanged homes and reads destination post-write bytes"
}


test_propagate_lib
test_backend_inheritance_present_and_absent
test_presentation_inheritance_default_on_and_opt_out
test_config_push_propagates_reports_without_ff_or_nudge
test_config_push_reports_skips_dirty_and_invalid_home
test_config_push_exits_nonzero_on_copy_error
test_config_push_rereads_after_partial_propagation
test_config_reread_per_home_changed_sets_and_exact_bytes
test_config_reread_isolation_and_absent_and_send_failure
test_config_reread_publication_failure_retries_exact_generation
test_config_reread_write_failure_retains_exact_retry_generation
test_config_reread_exact_temp_survives_adoption_failure
test_config_reread_serializes_concurrent_pushes
test_config_reread_full_retry_queue_drains_before_new_push
test_config_reread_cleanup_runs_after_mixed_delivery_failure
test_config_reread_stops_after_failed_generation
test_config_reread_skips_when_unchanged_and_reads_after_push
test_bootstrap_detect_only_does_not_create_state

echo "# all fm-secondmate-harness tests passed"
