#!/usr/bin/env bash
# tests/fm-secondmate-safety.test.sh - secondmate home safety invariants that
# remain reachable: seed registry/charter/lease validation refusals, per-home
# FM_HOME and lock scoping, bare-window send refusal, idle-pane staleness, and
# backlog-handoff safety. Spawning, briefing, and tearing down a secondmate home
# no longer exist, so their invariants were removed with them.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-safety)
export FM_BACKEND=tmux

test_fm_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app --mode no-mistakes >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  printf 'project=x\n' > "$home_one/state/task-a.meta"
  FM_HOME="$home_one" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "fm-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "fm-lock status is scoped per home"
}

test_home_seed_validate_rejects_unparseable_registry_entry() {
  local home err
  home="$TMP_ROOT/unparseable-registry-home"
  err="$TMP_ROOT/unparseable-registry.err"
  mkdir -p "$home/data"
  printf '%s\n' '- broken - prose (home: /tmp/child; scope: missing projects and date)' > "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "home-seed validation accepted an operationally unparseable registry record"
  fi
  grep -F 'malformed secondmate registry entry' "$err" >/dev/null \
    || fail "home-seed validation did not explain the malformed registry record"
  pass "home-seed validation rejects registry records no operational parser can consume"
}

test_home_seed_refuses_broken_registry_symlink() {
  local home sub err target
  home="$TMP_ROOT/broken-registry-symlink-home"
  sub="$TMP_ROOT/broken-registry-symlink-subhome"
  err="$TMP_ROOT/broken-registry-symlink.err"
  target="$home/data/missing-secondmates.md"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  ln -s "$target" "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "home-seed validation accepted a broken registry symlink"
  fi
  grep -F 'secondmate registry is unavailable or unsafe' "$err" >/dev/null \
    || fail "home-seed validation did not explain the broken registry symlink"
  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$sub" alpha >/dev/null 2>"$err"; then
    fail "home seeding accepted a broken registry symlink"
  fi
  [ -L "$home/data/secondmates.md" ] || fail "home seeding replaced the broken registry symlink"
  [ ! -e "$target" ] || fail "home seeding wrote through the broken registry symlink"
  [ ! -e "$sub" ] || fail "home seeding provisioned a home before broken registry refusal"
  [ ! -e "$home/data/design" ] || fail "home seeding created a brief before broken registry refusal"
  pass "home seeding refuses broken registry symlinks before provisioning"
}

test_home_seed_refuses_unreadable_registry() {
  local home sub err registry
  home="$TMP_ROOT/unreadable-registry-home"
  sub="$TMP_ROOT/unreadable-registry-subhome"
  err="$TMP_ROOT/unreadable-registry.err"
  registry="$home/data/secondmates.md"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  printf '%s\n' '- design - design domain (home: /tmp/design; scope: design; projects: alpha; added 2026-07-30)' > "$registry"
  chmod 000 "$registry"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    chmod 600 "$registry"
    fail "home-seed validation accepted an unreadable registry"
  fi
  grep -F 'secondmate registry is unavailable or unsafe' "$err" >/dev/null || {
    chmod 600 "$registry"
    fail "home-seed validation did not explain the unreadable registry"
  }
  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$sub" alpha >/dev/null 2>"$err"; then
    chmod 600 "$registry"
    fail "home seeding accepted an unreadable registry"
  fi
  chmod 600 "$registry"
  [ ! -e "$sub" ] || fail "home seeding provisioned a home before unreadable registry refusal"
  [ ! -e "$home/data/design" ] || fail "home seeding created a brief before unreadable registry refusal"
  pass "home seeding refuses unreadable registries before provisioning"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two secondmates with the same home"
  fi
  grep -F 'duplicate secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same secondmate id"
  fi
  grep -F 'duplicate secondmate id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested secondmate homes"
  fi
  grep -F 'overlapping secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_returns_treehouse_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- dash ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err lease
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/tmux.log"
  lease="$TMP_ROOT/dash-return-fail-fake/lease"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to return treehouse-acquired home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when treehouse return failed"
  [ -f "$lease" ] || fail "failed rollback return did not preserve lease evidence"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt to return the acquired home"
  pass "home seed rollback warns when treehouse-acquired return fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home matching the active firstmate home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$descendant" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active descendant through treehouse"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_refuses_missing_filled_charter() {
  local home subhome err
  home="$TMP_ROOT/missing-charter-home"
  subhome="$TMP_ROOT/missing-charter-subhome"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled secondmate charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$subhome" ] || fail "missing charter seed left a generated subhome"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_projectless_conversion_of_populated_home() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-conversion-home"
  sub="$TMP_ROOT/no-projects-conversion-subhome"
  err="$TMP_ROOT/no-projects-conversion.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/existing-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$sub/projects/existing-clone"
  cat > "$sub/data/projects.md" <<EOF
- registry-only [direct-PR] - retained project entry (added 2026-06-22)
EOF
  registry_before=$(cat "$sub/data/projects.md")

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed converted a populated secondmate home"
  fi
  grep -F 'existing-clone' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the existing clone"
  grep -F 'registry-only' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the registry entry"
  grep -F 'retire or clean this home first' "$err" >/dev/null \
    || fail "project-less conversion refusal did not explain the required cleanup"
  assert_present "$sub/projects/existing-clone/.git" "project-less conversion refusal removed the existing clone"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less conversion refusal changed the project registry"
  assert_absent "$sub/.fm-secondmate-home" "project-less conversion refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less conversion refusal copied a charter"
  assert_absent "$sub/state" "project-less conversion refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less conversion refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less conversion of a populated home"
}

test_home_seed_refuses_projectless_home_with_uninspectable_projects() {
  local home sub err
  home="$TMP_ROOT/no-projects-uninspectable-home"
  sub="$TMP_ROOT/no-projects-uninspectable-subhome"
  err="$TMP_ROOT/no-projects-uninspectable.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/hidden-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$sub/projects/hidden-clone"
  chmod 311 "$sub/projects"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$sub/projects"
    fail "project-less seed accepted a home whose projects directory could not be inspected"
  fi
  chmod 700 "$sub/projects"
  grep -F 'cannot inspect existing projects directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the projects inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the inspection failure"
  assert_present "$sub/projects/hidden-clone/.git" "project-less inspection refusal removed the existing clone"
  assert_absent "$sub/.fm-secondmate-home" "project-less inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less inspection refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose projects directory cannot be inspected"
}

test_home_seed_refuses_projectless_home_with_symlinked_projects() {
  local home sub target err
  home="$TMP_ROOT/no-projects-symlinked-projects-home"
  sub="$TMP_ROOT/no-projects-symlinked-projects-subhome"
  target="$sub/retained-projects"
  err="$TMP_ROOT/no-projects-symlinked-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$target/hidden-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$target/hidden-clone"
  ln -s "$target" "$sub/projects"
  chmod 311 "$target"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$target"
    fail "project-less seed accepted a home whose projects directory is a symlink"
  fi
  chmod 700 "$target"
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the symlinked projects directory"
  grep -F 'it is a symlink' "$err" >/dev/null \
    || fail "project-less seed did not explain the symlinked projects directory refusal"
  assert_present "$target/hidden-clone/.git" "project-less symlink refusal removed the target clone"
  [ -L "$sub/projects" ] || fail "project-less symlink refusal changed the projects symlink"
  [ "$(readlink "$sub/projects")" = "$target" ] \
    || fail "project-less symlink refusal retargeted the projects symlink"
  assert_absent "$sub/.fm-secondmate-home" "project-less symlink refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less symlink refusal copied a charter"
  assert_absent "$sub/state" "project-less symlink refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less symlink refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with symlinked projects directories"
}

test_home_seed_refuses_projectless_home_with_non_directory_projects() {
  local home sub err projects_before
  home="$TMP_ROOT/no-projects-nondirectory-projects-home"
  sub="$TMP_ROOT/no-projects-nondirectory-projects-subhome"
  err="$TMP_ROOT/no-projects-nondirectory-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_firstmate_home "$sub"
  printf '%s\n' 'retained project path' > "$sub/projects"
  projects_before=$(cat "$sub/projects")

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed accepted a home whose projects path is not a directory"
  fi
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the non-directory projects path"
  grep -F 'it is not a directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the non-directory projects path refusal"
  [ "$projects_before" = "$(cat "$sub/projects")" ] \
    || fail "project-less non-directory refusal changed the projects path"
  assert_absent "$sub/.fm-secondmate-home" "project-less non-directory refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less non-directory refusal copied a charter"
  assert_absent "$sub/state" "project-less non-directory refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less non-directory refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with non-directory projects paths"
}

test_home_seed_refuses_projectless_home_with_uninspectable_registry() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-uninspectable-registry-home"
  sub="$TMP_ROOT/no-projects-uninspectable-registry-subhome"
  err="$TMP_ROOT/no-projects-uninspectable-registry.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_firstmate_home "$sub"
  printf '%s\n' '- hidden-registry [direct-PR] - retained project entry (added 2026-06-22)' > "$sub/data/projects.md"
  registry_before=$(cat "$sub/data/projects.md")
  chmod 000 "$sub/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 600 "$sub/data/projects.md"
    fail "project-less seed accepted a home whose project registry could not be inspected"
  fi
  chmod 600 "$sub/data/projects.md"
  grep -F 'cannot inspect existing project registry' "$err" >/dev/null \
    || fail "project-less seed did not explain the project registry inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the project registry inspection failure"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less inspection refusal changed the project registry"
  assert_absent "$sub/.fm-secondmate-home" "project-less registry inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less registry inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less registry inspection refusal left an operational directory"
  assert_absent "$sub/projects" "project-less registry inspection refusal created a projects directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less registry inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose project registry cannot be inspected"
}

test_home_seed_refuses_missing_projects_without_signal() {
  # Accidental omission of the project list, with no deliberate --no-projects
  # signal, must fail loudly and leave nothing behind, so a forgotten argument is
  # never mistaken for an intentional project-less seed.
  local home sub err
  home="$TMP_ROOT/missing-projects-home"
  sub="$TMP_ROOT/missing-projects-subhome"
  err="$TMP_ROOT/missing-projects.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='some scope' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" >/dev/null 2>"$err"; then
    fail "seed accepted a project-less home without the deliberate --no-projects signal"
  fi
  assert_absent "$sub" "loud-failure seed created a subhome"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "loud-failure seed left a registry route"
  fi

  # The deliberate signal is mutually exclusive with a project list.
  if FM_HOME="$home" FM_SECONDMATE_CHARTER='some scope' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects alpha >/dev/null 2>"$err"; then
    fail "seed accepted --no-projects combined with a project list"
  fi
  grep -F 'cannot be combined with a project list' "$err" >/dev/null \
    || fail "seed did not explain the --no-projects mutual-exclusion rejection"
  pass "home seeding fails loudly on accidental project omission and rejects mixed --no-projects"
}

test_home_seed_refuses_local_only_project() {
  local home subhome err
  home="$TMP_ROOT/local-only-seed-home"
  subhome="$TMP_ROOT/local-only-seed-subhome"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a secondmate home"
  fi
  grep -F 'project alpha is local-only; secondmate routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home subhome err
  home="$TMP_ROOT/delimiter-home"
  subhome="$TMP_ROOT/delimiter)subhome"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='delimiter charter' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'secondmate home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- design ' "$home/data/secondmates.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/secondmates.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.fm-secondmate-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_fm_send_refuses_bare_window_without_home_meta() {
  # With NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "fm-send sent to a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-send fell back to a foreign same-name window"
  pass "fm-send refuses a bare firstmate window with no metadata in this home"
}

test_secondmate_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="firstmate:fm-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=secondmate
home=$TMP_ROOT/watch-subhome
projects=alpha
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_LOG="$TMP_ROOT/watch-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle secondmate"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
  pass "idle kind=secondmate pane is healthy and not stale"
}

test_backlog_handoff_aborts_safely() {
  # The happy move is asserted in tests/fm-backlog-handoff.test.sh. Here: every
  # refusal path aborts atomically and mutates neither backlog.
  local home subhome subhome_abs before
  home="$TMP_ROOT/handoff-main"
  subhome="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" design
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item"

  # An in-flight item is refused (active ownership lives in tmux + state too).
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  [ ! -e "$subhome/data/backlog.md" ] || ! grep -F 'live-task' "$subhome/data/backlog.md" >/dev/null     || fail "in-flight refusal copied the live task into the secondmate backlog"

  # An unregistered secondmate id is refused.
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered secondmate id"
  fi
  pass "fm-backlog-handoff aborts atomically on unmatched, in-flight, and unregistered targets"
}

test_backlog_handoff_refuses_done_items_and_non_secondmate_homes() {
  local home subhome subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside before_main before_sub out
  home="$TMP_ROOT/handoff-safety-main"
  subhome="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  seed_secondmate_home_marker "$subhome" archive
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$subhome/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  printf '##\tDone\n- [x] shipped-task - shipped thing - local main (merged 2026-06-19)\n' > "$home/data/backlog.md"
  before_main="$TMP_ROOT/handoff-safety-main.before"
  before_sub="$TMP_ROOT/handoff-safety-sub.before"
  cp "$home/data/backlog.md" "$before_main"
  cp "$subhome/data/backlog.md" "$before_sub"
  if out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" archive shipped-task 2>&1); then
    fail "handoff accepted a Done backlog item"
  fi
  printf '%s\n' "$out" | grep -F 'shipped-task' >/dev/null \
    || fail "Done-item refusal did not name the selected item"
  printf '%s\n' "$out" | grep -F 'queued work only' >/dev/null \
    || fail "Done-item refusal did not state the queued-only contract"
  cmp -s "$before_main" "$home/data/backlog.md" \
    || fail "Done-item refusal mutated the main backlog"
  cmp -s "$before_sub" "$subhome/data/backlog.md" \
    || fail "Done-item refusal mutated the secondmate backlog"

  # A registered home that is not a seeded secondmate home (e.g. a project clone)
  # is refused, and nothing is written into it.
  fm_git_init_commit "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" proj-sm shipped-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded secondmate home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-secondmate home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-sm\n' > "$markerhome/.fm-secondmate-home"
  printf -- '- marker-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" marker-sm marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a secondmate home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_secondmate_home_marker "$symlinkhome" symlink-sm
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" symlink-sm symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a secondmate home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked secondmate data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "fm-backlog-handoff refuses Done items under whitespace section headings and unsafe homes"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_home_seed_validate_rejects_unparseable_registry_entry
test_home_seed_refuses_broken_registry_symlink
test_home_seed_refuses_unreadable_registry
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_projectless_conversion_of_populated_home
test_home_seed_refuses_projectless_home_with_uninspectable_projects
test_home_seed_refuses_projectless_home_with_symlinked_projects
test_home_seed_refuses_projectless_home_with_non_directory_projects
test_home_seed_refuses_projectless_home_with_uninspectable_registry
test_home_seed_refuses_missing_projects_without_signal
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_home_overlapping_registered_home
test_fm_send_refuses_bare_window_without_home_meta
test_secondmate_idle_pane_is_not_stale
test_backlog_handoff_aborts_safely
test_backlog_handoff_refuses_done_items_and_non_secondmate_homes
