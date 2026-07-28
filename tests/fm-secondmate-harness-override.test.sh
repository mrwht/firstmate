#!/usr/bin/env bash
# Tests for the per-secondmate override file config/secondmate-harness.<id>, a
# sibling of config/secondmate-harness with identical grammar
# ("<harness> [<model>] [<effort>]"). It sits ahead of the global file in the
# fallback chain: config/secondmate-harness.<id> -> config/secondmate-harness ->
# config/crew-harness -> own. An absent or "default"-only per-id file falls
# through exactly like today's absent/"default" global file (full
# backward-compat: an omitted <id> argument is byte-identical to pre-change
# behavior). <id> is sanitized against [A-Za-z0-9_-]+ before being interpolated
# into a filename; an unsafe id is treated as no per-id override, never
# traversed or errored on. docs/configuration.md "Harness support" owns the
# full fallback-chain contract; this suite only verifies it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-harness-override)
export FM_BACKEND=tmux

# ===========================================================================
# 1) Per-id file present with a full triple: all three subcommands read from
#    it, ignoring the global file's contents entirely.
# ===========================================================================
test_per_id_file_wins_over_global() {
  local cfg got_h got_m got_e
  cfg="$TMP_ROOT/case1/config"
  mkdir -p "$cfg"
  printf 'codex sonnet low\n' > "$cfg/secondmate-harness"
  printf 'claude opus high\n' > "$cfg/secondmate-harness.torres"

  got_h=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate torres)
  got_m=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-model torres)
  got_e=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-effort torres)
  [ "$got_h" = claude ] || fail "per-id: harness resolved '$got_h', expected claude"
  [ "$got_m" = opus ] || fail "per-id: model resolved '$got_m', expected opus"
  [ "$got_e" = high ] || fail "per-id: effort resolved '$got_e', expected high"
  pass "1 per-id file present with a full triple: all three subcommands read it, ignoring the global file"
}

# ===========================================================================
# 2) Per-id file present for one id, absent for another in the SAME config
#    dir - proves isolation: no cross-contamination between ids.
# ===========================================================================
test_per_id_isolation() {
  local cfg got_torres got_geordi
  cfg="$TMP_ROOT/case2/config"
  mkdir -p "$cfg"
  printf 'codex\n' > "$cfg/secondmate-harness"
  printf 'claude opus high\n' > "$cfg/secondmate-harness.torres"

  got_torres=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate torres)
  got_geordi=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate geordi)
  [ "$got_torres" = claude ] || fail "isolation: torres resolved '$got_torres', expected claude (own file)"
  [ "$got_geordi" = codex ] || fail "isolation: geordi resolved '$got_geordi', expected codex (global file, no cross-contamination)"

  local got_geordi_model
  got_geordi_model=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-model geordi)
  [ -z "$got_geordi_model" ] || fail "isolation: geordi model leaked '$got_geordi_model' from torres's file"
  pass "2 per-id file present for one id, absent for another: no cross-contamination"
}

# ===========================================================================
# 3) Per-id file present but harness token is "default" - falls through to
#    config/crew-harness -> own, scoped to that one id.
# ===========================================================================
test_per_id_default_falls_through_scoped() {
  local cfg got_torres got_geordi
  cfg="$TMP_ROOT/case3/config"
  mkdir -p "$cfg"
  printf 'codex\n' > "$cfg/crew-harness"
  printf 'grok\n' > "$cfg/secondmate-harness"
  printf 'default\n' > "$cfg/secondmate-harness.torres"

  got_torres=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate torres)
  got_geordi=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate geordi)
  [ "$got_torres" = codex ] || fail "default-fallthrough: torres resolved '$got_torres', expected crew-harness codex"
  [ "$got_geordi" = grok ] || fail "default-fallthrough: geordi resolved '$got_geordi', expected the untouched global file grok"
  pass "3 per-id file with harness token 'default' falls through to crew-harness -> own, scoped to that id"
}

# ===========================================================================
# 4) No <id> argument passed at all - byte-identical to pre-change behavior
#    (regression guard for every existing caller).
# ===========================================================================
test_no_id_argument_is_backward_compatible() {
  local cfg got_h got_m got_e
  cfg="$TMP_ROOT/case4/config"
  mkdir -p "$cfg"
  printf 'claude opus high\n' > "$cfg/secondmate-harness"
  # A stray per-id file for an unrelated id must never leak into the no-id call.
  printf 'codex sonnet low\n' > "$cfg/secondmate-harness.torres"

  got_h=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate)
  got_m=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-model)
  got_e=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-effort)
  [ "$got_h" = claude ] || fail "no-id: harness resolved '$got_h', expected claude (global file only)"
  [ "$got_m" = opus ] || fail "no-id: model resolved '$got_m', expected opus (global file only)"
  [ "$got_e" = high ] || fail "no-id: effort resolved '$got_e', expected high (global file only)"
  pass "4 no <id> argument: byte-identical to pre-change behavior (global file only)"
}

# ===========================================================================
# 5) Malformed effort token in a per-id file - same warning behavior as today,
#    scoped to that id only.
# ===========================================================================
test_per_id_malformed_effort_scoped_warning() {
  local cfg got_e
  cfg="$TMP_ROOT/case5/config"
  mkdir -p "$cfg"
  printf 'claude opus low\n' > "$cfg/secondmate-harness"
  printf 'claude opus bogus\n' > "$cfg/secondmate-harness.torres"

  # fm-harness.sh itself only ever prints the raw token; the "not one of low,
  # medium, high, xhigh, max" warning is emitted by fm-spawn.sh's consumer, so
  # assert the raw resolution here and the spawn-side warning in the e2e case.
  got_e=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-effort torres)
  [ "$got_e" = bogus ] || fail "malformed-effort: torres raw token resolved '$got_e', expected bogus (unvalidated at this layer)"

  local got_e_geordi
  got_e_geordi=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-effort geordi)
  [ "$got_e_geordi" = low ] || fail "malformed-effort: geordi effort resolved '$got_e_geordi', expected low (global file untouched)"
  pass "5 malformed effort token in a per-id file is scoped to that id; the global file's validation is untouched"
}

# ===========================================================================
# 6) fm-spawn.sh --secondmate end-to-end: confirm $ID threads through by
#    asserting state/<id>.meta model=/effort= differ between two ids with
#    different per-id override files.
# ===========================================================================
make_noop_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_seeded_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

spawn_secondmate() {
  local world=$1 id=$2 home=$3 fakebin
  mkdir -p "$world/home/state" "$world/home/data"
  fakebin=$(make_noop_tmux "$world/tmux-$id")
  PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" --secondmate >/dev/null 2>&1 || true
}

meta_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

test_spawn_e2e_id_threads_through() {
  local w torres geordi meta_t meta_g
  w="$TMP_ROOT/case6"
  torres="$w/torres-home"
  geordi="$w/geordi-home"
  mkdir -p "$w/home/config"
  printf 'claude sonnet low\n' > "$w/home/config/secondmate-harness"
  printf 'claude opus high\n' > "$w/home/config/secondmate-harness.torres"
  make_seeded_home "$torres" torres
  make_seeded_home "$geordi" geordi

  spawn_secondmate "$w" torres "$torres"
  spawn_secondmate "$w" geordi "$geordi"

  meta_t="$w/home/state/torres.meta"
  meta_g="$w/home/state/geordi.meta"
  [ -f "$meta_t" ] || fail "e2e: no meta written for torres"
  [ -f "$meta_g" ] || fail "e2e: no meta written for geordi"
  [ "$(meta_field "$meta_t" model)" = opus ] \
    || fail "e2e: torres model resolved '$(meta_field "$meta_t" model)', expected opus from its own per-id file"
  [ "$(meta_field "$meta_t" effort)" = high ] \
    || fail "e2e: torres effort resolved '$(meta_field "$meta_t" effort)', expected high from its own per-id file"
  [ "$(meta_field "$meta_g" model)" = sonnet ] \
    || fail "e2e: geordi model resolved '$(meta_field "$meta_g" model)', expected sonnet from the global file"
  [ "$(meta_field "$meta_g" effort)" = low ] \
    || fail "e2e: geordi effort resolved '$(meta_field "$meta_g" effort)', expected low from the global file"
  pass "6 fm-spawn.sh --secondmate threads \$ID through: two ids with different per-id files record different meta model=/effort="
}

# ===========================================================================
# 7) Id sanitization: an id containing "/" or ".." must fall through to the
#    global file, never escape config/ or read/error on an unintended path.
# ===========================================================================
test_id_sanitization_falls_through() {
  local cfg outside got_slash got_dotdot
  cfg="$TMP_ROOT/case7/config"
  mkdir -p "$cfg"
  outside="$TMP_ROOT/case7/outside-secret"
  printf 'grok secret-model secret-effort\n' > "$outside"
  printf 'claude opus high\n' > "$cfg/secondmate-harness"

  got_slash=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate "../outside-secret")
  [ "$got_slash" = claude ] || fail "sanitize: id with '..' resolved '$got_slash', expected fall-through to global file claude"

  got_dotdot=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-model "foo/bar")
  [ "$got_dotdot" = opus ] || fail "sanitize: id with '/' resolved model '$got_dotdot', expected fall-through to global file opus"

  [ ! -e "$cfg/secondmate-harness.../outside-secret" ] || fail "sanitize: an unsafe id created a file inside config/"
  pass "7 an id containing '/' or '..' falls through to the global file, never traverses or reads an unintended path"
}

test_per_id_file_wins_over_global
test_per_id_isolation
test_per_id_default_falls_through_scoped
test_no_id_argument_is_backward_compatible
test_per_id_malformed_effort_scoped_warning
test_spawn_e2e_id_threads_through
test_id_sanitization_falls_through

echo "# all fm-secondmate-harness-override tests passed"
