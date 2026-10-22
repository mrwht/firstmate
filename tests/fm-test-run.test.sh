#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  : >"$repo/tests/retired-fixture.sh"
  : >"$repo/tests/retired-helpers.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-session-start.test.sh" "shared helper selects session-bootstrap dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  git -C "$repo" rm -q tests/retired-fixture.sh tests/retired-helpers.sh
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || fail "a deleted test support file or shared helper must not fail changed selection"
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm retire-fixture
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD~1) >/dev/null \
    || fail "a committed test support file deletion must not fail changed selection"

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_run_env_banner() {
  local tmp out start_line end_line line env_re
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-env.XXXXXX")
  cat >"$tmp/ok.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
SH
  chmod +x "$tmp/ok.test.sh"
  out="$tmp/out.txt"
  "$RUNNER" "$tmp/ok.test.sh" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  env_re='^FM_TEST_ENV [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z phase=(start|end) load=([0-9.]+,[0-9.]+,[0-9.]+|unknown) ncpu=([0-9]+|unknown) sched_pri=(-?[0-9]+|unknown) stray_yes=([0-9]+|unknown)$'
  [ "$(grep -c '^FM_TEST_ENV ' "$out")" -eq 2 ] \
    || fail "expected exactly two FM_TEST_ENV lines: $(grep '^FM_TEST_ENV' "$out")"
  while IFS= read -r line; do
    printf '%s\n' "$line" | grep -Eq "$env_re" || fail "FM_TEST_ENV line missing keys: $line"
  done < <(grep '^FM_TEST_ENV ' "$out")
  start_line=$(grep -n '^FM_TEST_ENV .* phase=start ' "$out" | cut -d: -f1)
  end_line=$(grep -n '^FM_TEST_ENV .* phase=end ' "$out" | cut -d: -f1)
  [ -n "$start_line" ] && [ -n "$end_line" ] || fail "expected phase=start and phase=end lines"
  [ "$start_line" -lt "$(grep -n '^FM_TEST_BEGIN ' "$out" | head -1 | cut -d: -f1)" ] \
    || fail "phase=start must precede the first FM_TEST_BEGIN"
  [ "$end_line" -eq $(($(grep -n '^FM_TEST_SUMMARY ' "$out" | cut -d: -f1) + 1)) ] \
    || fail "phase=end must directly follow FM_TEST_SUMMARY"
  ! grep -q '^FM_TEST_ENV_TOP ' "$out" || fail "a green run must not print FM_TEST_ENV_TOP"

  for args in "--list --all" "--list-families" "--list-lanes"; do
    # shellcheck disable=SC2086 # deliberate word split of the flag set
    ! "$RUNNER" $args 2>/dev/null | grep -q '^FM_TEST_ENV' \
      || fail "$args must not print FM_TEST_ENV"
  done
  rm -rf "$tmp"
  pass "run env banner brackets the run with every key"
}

test_run_env_top_only_on_failure() {
  local tmp top_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-envtop.XXXXXX")
  printf '#!/usr/bin/env bash\necho "not ok - fixture"\nexit 1\n' >"$tmp/fail.test.sh"
  chmod +x "$tmp/fail.test.sh"
  "$RUNNER" "$tmp/fail.test.sh" >"$tmp/out.txt" 2>"$tmp/err.txt" \
    && { rm -rf "$tmp"; fail "runner should fail on a failing fixture"; }
  top_n=$(grep -c '^FM_TEST_ENV_TOP ' "$tmp/out.txt" || true)
  [ "$top_n" -ge 1 ] && [ "$top_n" -le 5 ] \
    || fail "failing run should print 1-5 FM_TEST_ENV_TOP lines, got $top_n"
  grep '^FM_TEST_ENV_TOP ' "$tmp/out.txt" | grep -Evq '^FM_TEST_ENV_TOP pcpu=[0-9.]+ pid=[0-9]+ comm=[^/]+$' \
    && fail "malformed FM_TEST_ENV_TOP line: $(grep '^FM_TEST_ENV_TOP' "$tmp/out.txt")"
  rm -rf "$tmp"
  pass "FM_TEST_ENV_TOP appears only on a failing run"
}

test_run_env_high_load_warning_and_degrade() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-envload.XXXXXX")
  mkdir -p "$tmp/high" "$tmp/broken" "$tmp/linux"
  printf '#!/usr/bin/env bash\necho " 16:31:28 up 3 days,  2:01,  1 user,  load average: 0.52, 0.58, 0.59"\n' >"$tmp/linux/uptime"
  printf '#!/usr/bin/env bash\necho " 10:00  up 1 day, 2 users, load averages: 9999.50 9000.00 8000.00"\n' >"$tmp/high/uptime"
  printf '#!/usr/bin/env bash\necho "uptime: unavailable" >&2\nexit 1\n' >"$tmp/broken/uptime"
  printf '#!/usr/bin/env bash\necho "ok - fixture"\n' >"$tmp/ok.test.sh"
  chmod +x "$tmp/high/uptime" "$tmp/broken/uptime" "$tmp/linux/uptime" "$tmp/ok.test.sh"

  set +e
  PATH="$tmp/high:$PATH" "$RUNNER" "$tmp/ok.test.sh" >"$tmp/high.out" 2>"$tmp/high.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "high-load warning must not change a green exit code, got $rc"; }
  grep -Eq '^FM_TEST_ENV .* phase=start load=9999.50,9000.00,8000.00 ncpu=[0-9]+ ' "$tmp/high.out" \
    || fail "stubbed load not reported: $(grep '^FM_TEST_ENV' "$tmp/high.out")"
  grep -Eq '^FM_TEST_WARNING high load 9999.50 on [0-9]+ CPUs; timing-sensitive tests may fail for environmental reasons$' "$tmp/high.out" \
    || fail "expected high-load warning: $(grep '^FM_TEST_WARNING' "$tmp/high.out")"
  [ "$(grep -c '^FM_TEST_WARNING ' "$tmp/high.out")" -eq 1 ] \
    || fail "high-load warning must print once, at start"

  PATH="$tmp/linux:$PATH" "$RUNNER" "$tmp/ok.test.sh" >"$tmp/linux.out" 2>"$tmp/linux.err" \
    || { rm -rf "$tmp"; fail "runner should pass with Linux-format uptime"; }
  grep -Eq '^FM_TEST_ENV .* phase=start load=0.52,0.58,0.59 ' "$tmp/linux.out" \
    || fail "Linux uptime format not parsed: $(grep '^FM_TEST_ENV' "$tmp/linux.out")"

  set +e
  PATH="$tmp/broken:$PATH" "$RUNNER" "$tmp/ok.test.sh" >"$tmp/broken.out" 2>"$tmp/broken.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "a failing uptime must not fail the run, got $rc"; }
  grep -Eq '^FM_TEST_ENV .* phase=start load=unknown ' "$tmp/broken.out" \
    || fail "failing uptime should degrade load to unknown: $(grep '^FM_TEST_ENV' "$tmp/broken.out")"
  ! grep -q '^FM_TEST_WARNING ' "$tmp/broken.out" || fail "unknown load must not warn"
  rm -rf "$tmp"
  pass "load parses macOS and Linux uptime; high-load warning and missing-tool degrade keep the exit code"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_refuses_portable_serial_lanes() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'is a portable serial lane and stays strictly serial' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  ! grep -q '^FM_TEST_BEGIN ' "$tmp/out" \
    || fail "--jobs portable-serial refusal must come before any script starts"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'is a portable serial lane and stays strictly serial' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses portable serial lanes and their shards"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates"
}

# Line number of the first stdout line matching an ERE, or 0 when absent.
first_line_matching() {
  grep -n -E -m1 "$2" "$1" | cut -d: -f1 || true
}

test_jobs_mixed_selection_runs_parallel_then_serial() {
  local tmp repo runner evidence a b s rc par_ln ser_ln a_end b_end s_begin first_begin
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-mixed.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  s=tests/fm-watcher-lock.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$runner"
  # The first proven fixture finishes only once the second has started, so it
  # passes only when both run at the same time. The bounded deadline is there
  # so a scheduler that serializes them still reports instead of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
waited=0
while [ ! -e "$MIXED_EVIDENCE/b-started" ] && [ "$waited" -lt 600 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
if [ ! -e "$MIXED_EVIDENCE/b-started" ]; then
  echo "not ok - proven fixtures did not run concurrently"
  exit 1
fi
touch "$MIXED_EVIDENCE/a-done"
echo "ok - proven fixture a"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
touch "$MIXED_EVIDENCE/b-started"
touch "$MIXED_EVIDENCE/b-done"
echo "ok - proven fixture b"
SH
  # The non-proven fixture is listed first but must run last, after both
  # parallel workers finished.
  cat >"$repo/$s" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$MIXED_EVIDENCE/a-done" ] || [ ! -e "$MIXED_EVIDENCE/b-done" ]; then
  echo "not ok - serial-phase script started before the parallel phase finished"
  exit 1
fi
touch "$MIXED_EVIDENCE/s-done"
echo "ok - serial fixture ran after the parallel phase"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$s"
  set +e
  MIXED_EVIDENCE="$evidence" "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$s" "$a" "$b" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "mixed --jobs selection must run and pass, got $rc"; }
  [ -e "$evidence/s-done" ] || { rm -rf "$tmp"; fail "serial-phase fixture never ran"; }
  par_ln=$(first_line_matching "$tmp/out" '^FM_TEST_PHASE parallel jobs=2 scripts=2$')
  ser_ln=$(first_line_matching "$tmp/out" '^FM_TEST_PHASE serial scripts=1$')
  first_begin=$(first_line_matching "$tmp/out" '^FM_TEST_BEGIN ')
  a_end=$(first_line_matching "$tmp/out" "^FM_TEST_END .+ $a exit=0 ")
  b_end=$(first_line_matching "$tmp/out" "^FM_TEST_END .+ $b exit=0 ")
  s_begin=$(first_line_matching "$tmp/out" "^FM_TEST_BEGIN .+ $s ")
  { [ "${par_ln:-0}" -gt 0 ] && [ "${ser_ln:-0}" -gt 0 ]; } \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "mixed run must print both FM_TEST_PHASE markers"; }
  [ "$par_ln" -lt "$first_begin" ] \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "parallel phase marker must precede the first script"; }
  { [ "${a_end:-0}" -gt 0 ] && [ "${b_end:-0}" -gt 0 ] \
    && [ "$a_end" -lt "$ser_ln" ] && [ "$b_end" -lt "$ser_ln" ] && [ "$ser_ln" -lt "${s_begin:-0}" ]; } \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "serial phase must start only after every parallel worker ended"; }
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || { rm -rf "$tmp"; fail "mixed summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out")"; }
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["selection"]=="scripts;jobs=2", doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "mixed jobs JSON artifact wrong"; }

  # A serial-only selection under --jobs still runs, with only the serial marker.
  set +e
  MIXED_EVIDENCE="$evidence" "$runner" --jobs 2 "$s" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out2" "$tmp/err2"; rm -rf "$tmp"; fail "serial-only --jobs selection must run, got $rc"; }
  grep -q '^FM_TEST_PHASE serial scripts=1$' "$tmp/out2" \
    || { rm -rf "$tmp"; fail "serial-only --jobs run must print the serial phase marker"; }
  ! grep -q '^FM_TEST_PHASE parallel ' "$tmp/out2" \
    || { rm -rf "$tmp"; fail "an empty parallel phase must print no marker"; }
  rm -rf "$tmp"
  pass "mixed --jobs selection runs proven scripts concurrently, then the rest serially"
}

test_jobs_worker_isolation_tmux_and_xdg() {
  local tmp repo runner evidence a rc tmux_root xdg_state worker_tmp probe_secs leftover waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-iso.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  a=tests/fm-tmux-submit-busy.test.sh
  probe_secs="300.$$4"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$runner"
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TMUX_TMPDIR-}" >"$ISO_EVIDENCE/tmux_tmpdir"
printf '%s\n' "${XDG_STATE_HOME-}" >"$ISO_EVIDENCE/xdg_state"
printf '%s\n' "${TMPDIR-}" >"$ISO_EVIDENCE/tmpdir"
printf '%s\n' "${TMUX-unset}" >"$ISO_EVIDENCE/tmux_env"
printf '%s\n' "${HERDR_ENV-unset}" >"$ISO_EVIDENCE/herdr_env"
printf '%s\n' "$HOME" >"$ISO_EVIDENCE/home"
if command -v tmux >/dev/null 2>&1; then
  tmux -L probe new-session -d -s probe "sleep $ISO_PROBE_SECS" \
    || { echo "not ok - tmux probe server did not start"; exit 1; }
  tmux -L probe has-session -t probe \
    || { echo "not ok - tmux probe session missing"; exit 1; }
  touch "$ISO_EVIDENCE/tmux_started"
fi
echo "ok - isolation probe"
SH
  chmod +x "$runner" "$repo/$a"
  set +e
  ISO_EVIDENCE="$evidence" ISO_PROBE_SECS="$probe_secs" \
    TMUX=/nonexistent/fm-test-run-outer,1,0 TMUX_PANE=%999 HERDR_ENV=1 \
    XDG_STATE_HOME="$tmp/outer-xdg-state" \
    "$runner" --jobs 2 "$a" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  # Sample before the safety net, waiting on the condition with a generous
  # ceiling because a killed server's pane processes exit asynchronously.
  leftover=
  if [ -e "$evidence/tmux_started" ]; then
    waited=0
    while leftover=$(pgrep -f "sleep $probe_secs" || true); [ -n "$leftover" ] && [ "$waited" -lt 200 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    pkill -f "sleep $probe_secs" 2>/dev/null || true
  fi
  tmux_root=$(cat "$evidence/tmux_tmpdir" 2>/dev/null || true)
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "isolation probe run must pass, got $rc"; }
  case "$tmux_root" in
    /tmp/fmx.*) ;;
    *) rm -rf "$tmp"; fail "worker TMUX_TMPDIR must be a private /tmp/fmx.* root, got '$tmux_root'" ;;
  esac
  [ "${#tmux_root}" -lt 40 ] \
    || { rm -rf "$tmp"; fail "worker TMUX_TMPDIR must stay short for AF_UNIX socket paths, got ${#tmux_root} bytes"; }
  [ ! -e "$tmux_root" ] \
    || { rm -rf "$tmp"; fail "worker TMUX_TMPDIR $tmux_root must be removed after the run"; }
  [ -z "$leftover" ] \
    || { rm -rf "$tmp"; fail "tmux server started under --jobs still running after the run: $leftover"; }
  [ "$(cat "$evidence/tmux_env")" = unset ] || { rm -rf "$tmp"; fail "worker must unset TMUX"; }
  [ "$(cat "$evidence/herdr_env")" = unset ] || { rm -rf "$tmp"; fail "worker must unset HERDR_ENV"; }
  [ "$(cat "$evidence/home")" = "$HOME" ] || { rm -rf "$tmp"; fail "worker must not change HOME"; }
  xdg_state=$(cat "$evidence/xdg_state")
  worker_tmp=$(cat "$evidence/tmpdir")
  [ -n "$xdg_state" ] && [ "$xdg_state" != "$tmp/outer-xdg-state" ] \
    || { rm -rf "$tmp"; fail "worker XDG_STATE_HOME must be private, got '$xdg_state'"; }
  [ "${xdg_state%/xdg/state}" = "${worker_tmp%/tmp}" ] \
    || { rm -rf "$tmp"; fail "worker XDG_STATE_HOME $xdg_state must sit under the worker root of TMPDIR $worker_tmp"; }
  rm -rf "$tmp"
  pass "--jobs workers get a short private tmux root that is cleaned up, private XDG roots, and no ambient TMUX/HERDR session"
}

# Write a leaking fixture (background sleep, exit 0) and a tidy fixture (waits
# for its own child) at the given paths. The sleep duration is unique to this
# test process so pgrep can prove the runner stopped exactly that process, and
# is bounded so a broken runner cannot leave it running for long.
write_leak_fixtures() {
  local leaky=$1 tidy=$2 leak_secs=$3
  cat >"$leaky" <<SH
#!/usr/bin/env bash
sleep $leak_secs &
echo "ok - leaky fixture"
exit 0
SH
  cat >"$tidy" <<'SH'
#!/usr/bin/env bash
sleep 0.2 &
wait
echo "ok - tidy fixture"
SH
  chmod +x "$leaky" "$tidy"
}

# Assert one leak run: the leaky script is reported, failed, and stopped; the
# tidy one passes with no leak line.
assert_leak_run() {
  local label=$1 out=$2 rc=$3 leaky=$4 tidy=$5 leftover=$6
  [ "$rc" -ne 0 ] || fail "$label: a leaking script must fail the run"
  grep -Eq "^FM_TEST_LEAK $leaky pids=[0-9]+(,[0-9]+)* commands=sleep\$" "$out" \
    || fail "$label: expected FM_TEST_LEAK for $leaky: $(grep '^FM_TEST_LEAK' "$out")"
  grep -Eq "^FM_TEST_END .+ $leaky exit=1 " "$out" \
    || fail "$label: leaking script must end exit=1: $(grep '^FM_TEST_END' "$out")"
  grep -Eq "^FM_TEST_END .+ $tidy exit=0 " "$out" \
    || fail "$label: tidy script must pass: $(grep '^FM_TEST_END' "$out")"
  ! grep -q "^FM_TEST_LEAK $tidy " "$out" \
    || fail "$label: a script that waits for its child must not report a leak"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$out" \
    || fail "$label: leak must count in failed: $(grep FM_TEST_SUMMARY "$out")"
  [ -z "$leftover" ] \
    || fail "$label: leaked fixture process still running after the run: $leftover"
}

test_leaked_children_are_reported_reaped_and_failed() {
  local tmp leaky tidy leak_secs rc leftover
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-leak.XXXXXX")
  leaky="$tmp/leaky.test.sh"
  tidy="$tmp/tidy.test.sh"
  leak_secs="300.$$1"
  write_leak_fixtures "$leaky" "$tidy" "$leak_secs"
  set +e
  "$RUNNER" "$leaky" "$tidy" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  # Sample before the safety-net pkill so the assertion sees the runner's work.
  leftover=$(pgrep -f "sleep $leak_secs" || true)
  pkill -f "sleep $leak_secs" 2>/dev/null || true
  assert_leak_run serial "$tmp/out" "$rc" "$leaky" "$tidy" "$leftover"
  rm -rf "$tmp"
  pass "serial run reports, stops, and fails a script that leaks a child"
}

test_jobs_leaked_children_are_reported_reaped_and_failed() {
  local tmp repo runner a b leak_secs rc leftover
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-leak.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  leak_secs="300.$$2"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  chmod +x "$runner"
  write_leak_fixtures "$repo/$a" "$repo/$b" "$leak_secs"
  set +e
  "$runner" --jobs 2 "$a" "$b" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  leftover=$(pgrep -f "sleep $leak_secs" || true)
  pkill -f "sleep $leak_secs" 2>/dev/null || true
  assert_leak_run jobs "$tmp/out" "$rc" "$a" "$b" "$leftover"
  rm -rf "$tmp"
  pass "--jobs run reports, stops, and fails a script that leaks a child"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_run_env_banner
test_run_env_top_only_on_failure
test_run_env_high_load_warning_and_degrade
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_refuses_portable_serial_lanes
test_jobs_parallel_scheduler_and_failure_propagation
test_jobs_mixed_selection_runs_parallel_then_serial
test_jobs_worker_isolation_tmux_and_xdg
test_leaked_children_are_reported_reaped_and_failed
test_jobs_leaked_children_are_reported_reaped_and_failed
test_aggregate_json
