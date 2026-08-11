#!/usr/bin/env bash
# Regression test for bin/fm-spawn.sh recording branch= in state/<id>.meta.
#
# fm-crew-state.sh's worktree/branch identity check (data/fm-crew-state-run-
# step-stale-terminal/report.md) depends on fm-spawn.sh recording the crew's
# own expected branch - the fixed fm/<id> convention every ship brief
# instructs the crew to create (bin/fm-brief.sh) - at spawn time, before the
# worktree itself has that branch checked out. These pin the write:
#   - a ship spawn records branch=fm/<id>
#   - a scout spawn records no branch= line at all (scouts never branch;
#     fm-crew-state.sh already skips the run lookup for kind=scout, so the
#     identity check has nothing to compare against)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-branch-identity)

# Fake tmux: answers the pane-path query so the spawn's settle loop resolves
# immediately to the real worktree; every other call is a no-op.
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
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> -> echoes home|proj|wt|fakebin|id
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$1
EOF
}

run_spawn() {  # <extra fm-spawn.sh args...>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$CASE_ID" "$PROJ_DIR" "$@" 2>&1
}

test_ship_spawn_records_branch() {
  local rec out status meta
  rec=$(make_spawn_case ship-branch)
  read_case_record "$rec"
  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "spawn did not report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_grep "branch=fm/$CASE_ID" "$meta" \
    "ship spawn must record branch=fm/<id>, the branch every ship brief instructs the crew to create"
  pass "a ship spawn records the crew's own expected branch at spawn time"
}

test_scout_spawn_records_no_branch() {
  local rec out status meta
  rec=$(make_spawn_case scout-branch)
  read_case_record "$rec"
  out=$(run_spawn --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "spawn did not report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_no_grep "branch=" "$meta" \
    "a scout never branches, so its meta must record no branch= line"
  pass "a scout spawn records no branch= line (scouts work in a scratch worktree, not a branch)"
}

test_ship_spawn_records_branch
test_scout_spawn_records_no_branch

echo "all fm-spawn-branch-identity tests passed"
