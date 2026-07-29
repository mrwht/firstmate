#!/usr/bin/env bash
# Behavior tests for bin/fm-task-mode.sh: the per-task config/task-mode.<id>
# override resolver a caller (firstmate) runs ahead of bin/fm-project-mode.sh
# and before passing the result to fm-spawn.sh/fm-brief.sh's required
# --mode/--yolo flags, per docs/configuration.md "Delivery mode overrides".
# Neither fm-spawn.sh nor fm-brief.sh reads config/task-mode.<id> itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TASKMODE="$ROOT/bin/fm-task-mode.sh"
PROJECTMODE="$ROOT/bin/fm-project-mode.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-mode)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' '- app [direct-PR +yolo] - test app (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' "$home"
}

run_taskmode() {
  local home=$1 id=$2 proj=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$TASKMODE" "$id" "$proj" 2>&1
}

# fm-project-mode.sh itself must stay unchanged by this feature: it takes only
# a project name, never a task id.
test_fm_project_mode_unchanged_signature() {
  local home out
  home=$(make_home unchanged)
  out=$(FM_HOME="$home" "$PROJECTMODE" app)
  [ "$out" = "direct-PR on" ] || fail "fm-project-mode.sh output changed unexpectedly: $out"
  pass "fm-project-mode.sh remains project-name-only and unchanged"
}

# Table: override-present-with-distinct-mode -> used instead of project default.
test_override_present_used_instead_of_project_default() {
  local home out
  home=$(make_home override-present)
  printf '%s\n' 'local-only' > "$home/config/task-mode.task-a"
  out=$(run_taskmode "$home" task-a app)
  [ "$out" = "local-only off" ] || fail "override mode was not used: $out"
  pass "present override with a distinct mode is used instead of the project default"
}

test_override_present_with_yolo_flag() {
  local home out
  home=$(make_home override-yolo)
  printf '%s\n' 'no-mistakes +yolo' > "$home/config/task-mode.task-b"
  out=$(run_taskmode "$home" task-b app)
  [ "$out" = "no-mistakes on" ] || fail "override +yolo was not parsed: $out"
  pass "override file's +yolo token is honored"
}

# Table: override-absent -> falls through to fm-project-mode.sh unchanged (regression guard).
test_override_absent_falls_through() {
  local home out
  home=$(make_home override-absent)
  out=$(run_taskmode "$home" task-none app)
  [ "$out" = "direct-PR on" ] || fail "absent override did not fall through to project default: $out"
  pass "absent override falls through to fm-project-mode.sh unchanged"
}

# Table: override file with "default" mode token -> falls through.
test_override_default_token_falls_through() {
  local home out
  home=$(make_home override-default)
  printf '%s\n' 'default' > "$home/config/task-mode.task-c"
  out=$(run_taskmode "$home" task-c app)
  [ "$out" = "direct-PR on" ] || fail "default mode token did not fall through: $out"
  pass "override file with mode token 'default' falls through to the project default"
}

test_override_unknown_mode_falls_through_with_warning() {
  local home out
  home=$(make_home override-unknown)
  printf '%s\n' 'bogus-mode' > "$home/config/task-mode.task-d"
  out=$(run_taskmode "$home" task-d app)
  assert_contains "$out" "direct-PR on" "unknown mode did not fall through to project default"
  assert_contains "$out" "warn: unknown mode" "unknown mode did not warn"
  pass "override file with an unknown mode token warns and falls through"
}

# Id sanitization: a "/" or ".." id must not escape config/ or read/write an
# unintended path; it must fall through to the project default instead.
test_id_sanitization_rejects_path_traversal() {
  local home out secretdir
  home=$(make_home sanitize)
  secretdir="$TMP_ROOT/sanitize-outside"
  mkdir -p "$secretdir"
  printf '%s\n' 'local-only' > "$secretdir/task-mode.evil"

  out=$(run_taskmode "$home" "../sanitize-outside/task-mode.evil" app)
  [ "$out" = "direct-PR on" ] || fail "path-traversal id was not rejected: $out"

  out=$(run_taskmode "$home" "evil/../../sanitize-outside/task-mode.evil" app)
  [ "$out" = "direct-PR on" ] || fail "embedded-slash id was not rejected: $out"
  pass "an id containing / or .. is sanitized away and falls through to the project default"
}

# The caller (firstmate) resolves mode through fm-task-mode.sh and passes it
# to fm-brief.sh's required --mode flag; fm-brief.sh itself never reads the
# override file. Verify the resolved mode is what the override file dictates
# and that fm-brief.sh's generated text reflects that explicit --mode.
test_brief_uses_task_mode_override() {
  local home mode yolo out brief status
  home=$(make_home brief-override)
  printf '%s\n' 'local-only' > "$home/config/task-mode.task-e"
  read -r mode yolo <<EOF
$(run_taskmode "$home" task-e app)
EOF
  [ "$mode" = "local-only" ] || fail "fm-task-mode.sh did not resolve the override: $mode $yolo"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$BRIEF" task-e app --mode "$mode" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "brief scaffold failed: $out"
  brief="$home/data/task-e/brief.md"
  [ -f "$brief" ] || fail "brief was not written"
  grep -F 'firstmate handles the merge into local' "$brief" >/dev/null \
    || fail "brief did not reflect the local-only override"$'\n'"$(cat "$brief")"
  pass "fm-brief.sh's generated text reflects the config/task-mode.<id> override resolved by the caller"
}

# End-to-end fm-spawn.sh: the caller resolves each task's mode through
# fm-task-mode.sh and passes it via the required --mode/--yolo flags. One task
# on a project gets the override, an unrelated task on the same project still
# gets the project default - no cross-contamination, mirroring the
# secondmate-harness isolation case.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_e2e_no_cross_contamination() {
  local case_dir home proj wt1 wt2 fakebin out status mode1 yolo1 mode2 yolo2
  case_dir="$TMP_ROOT/spawn-e2e"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt1="$case_dir/wt1"
  wt2="$case_dir/wt2"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '- app [no-mistakes] - test app (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' 'local-only +yolo' > "$home/config/task-mode.spawn-override-z1"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  touch "$home/state/.last-watcher-beat"

  fm_git_worktree "$proj" "$wt1" "wt-override"
  fm_git_worktree "$proj" "$wt2" "wt-plain" 2>/dev/null || true
  mkdir -p "$home/data/spawn-override-z1" "$home/data/spawn-plain-z2"
  printf 'brief\n' > "$home/data/spawn-override-z1/brief.md"
  printf 'brief\n' > "$home/data/spawn-plain-z2/brief.md"

  read -r mode1 yolo1 <<EOF
$(run_taskmode "$home" spawn-override-z1 app)
EOF
  [ "$mode1" = "local-only" ] && [ "$yolo1" = "on" ] \
    || fail "fm-task-mode.sh did not resolve the override for spawn-override-z1: $mode1 $yolo1"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt1" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" spawn-override-z1 "$proj" --mode "$mode1" --yolo "$yolo1" 2>&1)
  status=$?
  expect_code 0 "$status" "override spawn should succeed: $out"
  assert_grep "mode=local-only" "$home/state/spawn-override-z1.meta" "override task did not record local-only mode"
  assert_grep "yolo=on" "$home/state/spawn-override-z1.meta" "override task did not record yolo=on"

  read -r mode2 yolo2 <<EOF
$(run_taskmode "$home" spawn-plain-z2 app)
EOF
  [ "$mode2" = "no-mistakes" ] && [ "$yolo2" = "off" ] \
    || fail "fm-task-mode.sh did not fall through to the project default for spawn-plain-z2: $mode2 $yolo2"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt1" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" spawn-plain-z2 "$proj" --mode "$mode2" --yolo "$yolo2" 2>&1)
  status=$?
  expect_code 0 "$status" "unrelated spawn should succeed: $out"
  assert_grep "mode=no-mistakes" "$home/state/spawn-plain-z2.meta" "unrelated task should keep the project default mode"
  assert_grep "yolo=off" "$home/state/spawn-plain-z2.meta" "unrelated task should keep the project default yolo"

  pass "fm-spawn.sh applies a per-task override, resolved by the caller through fm-task-mode.sh, without contaminating an unrelated task on the same project"
}

test_fm_project_mode_unchanged_signature
test_override_present_used_instead_of_project_default
test_override_present_with_yolo_flag
test_override_absent_falls_through
test_override_default_token_falls_through
test_override_unknown_mode_falls_through_with_warning
test_id_sanitization_rejects_path_traversal
test_brief_uses_task_mode_override
test_spawn_e2e_no_cross_contamination

echo "# all fm-task-mode tests passed"
