#!/usr/bin/env bash
# Behavior tests for the bearings projection wrapper over fm-fleet-snapshot.sh.
# Covers the output/token bound, TOON/JSON parity, the local-only default (zero
# GitHub/network calls), the --include-prs opt-in path, graceful degradation on a
# partial PR-fetch failure, end-to-end unresolved-decision durability, and current
# report pointers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)
# Keep disposable homes outside the snapshot's fixture repo boundary even when
# TMPDIR is inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for, plus a
# gh/gh-axi that RECORDS every call to $NET_LOG so a test can prove the default path
# makes no network call. gh returns one fixture open PR keyed to the ship task.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NM_SLEEP:-0}" = 1 ] && sleep 30
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane)
    case "$*" in
      *fm-domain-alpha*) printf 'stale terminal summary: Phase 7 started\n> \n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GH_SLEEP:-0}" = 1 ]; then sleep 30; fi
if [ "${FAKE_GH_MANY:-0}" = 1 ]; then
  cat <<'JSON'
[{"number":1,"title":"One","url":"https://github.com/acme/repo/pull/1","headRefName":"fm/one","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Two","url":"https://github.com/acme/repo/pull/2","headRefName":"fm/two","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":3,"title":"Three","url":"https://github.com/acme/repo/pull/3","headRefName":"fm/three","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
  exit 0
fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fm/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi" "$fb/curl"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic_state=$3 gen event
  case "$semantic_state" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported semantic fixture state: $semantic_state" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic_state" --gen "$gen" \
    --source claude-hook --event "$event"
}

fixture_mate_home() {  # <parent-home>
  printf '%s/%s-secondmate-home\n' "$TMP_ROOT" "$(basename "$1")"
}

# Standard fixture: a ship task with a recorded PR, a scout task with a report, a
# secondmate with a MASKED open decision (needs-decision then a later unrelated
# done), and a backlog with a superseded queued item.
write_fixture() {  # <home>
  local home=$1 mate
  mate=$(fixture_mate_home "$home")
  mkdir -p "$home/projects/ship-wt" "$home/data/scout-x" "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] scout-x - Investigate the thing data/scout-x/report.md (repo: firstmate) (kind: scout) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] dead-gate - Old conditional work (repo: firstmate) (kind: scout)
  NOT REQUIRED - superseded 2026-07-11; kept as reference only.

## Done
- [x] done-a - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  printf '# Scout X\n' > "$home/data/scout-x/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  record_claude_state "$home/state" ship-task busy
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-x.meta" \
    "window=firstmate:fm-scout-x" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_state "$home/state" scout-x idle
  printf 'done: report ready\n' > "$home/state/scout-x.status"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$mate" \
    "project=$mate" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$mate" \
    "projects=firstmate"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$home/state/mate.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/mate.status"
  fm_write_meta "$home/state/external-wait.meta" \
    "window=firstmate:fm-external-wait" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_state "$home/state" external-wait idle
  printf 'paused: declared external-wait for upstream release\n' > "$home/state/external-wait.status"
  # The secondmate's OWN home backlog records a merge it managed. This lands in the
  # secondmate home, never the main backlog; no remaining test in this file reads it.
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Decide subscription order (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] mate-decision-race - Choose subscription order (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] mate-landed - Secondmate-managed fix https://github.com/kunchenguid/firstmate/pull/50 (repo: firstmate) (kind: ship) (merged 2026-07-11)
EOF
  mkdir -p "$mate/projects/mate"
  fm_write_meta "$mate/state/mate.meta" \
    "window=firstmate:fm-mate" "worktree=$mate/projects/mate" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" mate idle
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$mate/state/mate.status"
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$BEARINGS" "$@"
}

test_current_landed_baseline_is_repeatable_and_prior_report_independent() {
  local home fakebin one two
  home=$(make_home standalone-baseline); write_fixture "$home"
  cat > "$home/data/status-report-2026-07-10.md" <<'EOF'
# Misleading old report

## Recently Landed
- fake-old-item

## Underway
- Phase 7 started
EOF
  fakebin=$(make_fakebin "$home")
  one=$(run "$home" "$fakebin" --json)
  two=$(run "$home" "$fakebin" --json)
  [ "$(printf '%s' "$one" | jq -c '.landed')" = "$(printf '%s' "$two" | jq -c '.landed')" ] \
    || fail "the same structured state produced different recent-completion baselines"
  printf '%s' "$two" | jq -e '
    (.landed | any(.id == "done-a"))
      and (.landed | any(.id == "fake-old-item") | not)
      and (.in_flight | any(.doing == "Phase 7 started") | not)
  ' >/dev/null || fail "prior status report influenced the standalone snapshot: $two"
  pass "repeated snapshots keep the same current landed baseline and ignore prior reports"
}

test_default_is_bounded_and_local_only() {
  local home fakebin toon json
  home=$(make_home bounded); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Bound: well under the ~50 KB tool-display limit.
  [ "${#toon}" -lt 50000 ] || fail "default TOON must stay under the display bound, got ${#toon}"
  # TOON is materially smaller than the canonical snapshot it projects.
  local canon; canon=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "${#toon}" -lt "${#canon}" ] || fail "projection must be smaller than the canonical snapshot"
  # Local-only: no GitHub/network call on the default path.
  [ ! -s "$home/net.log" ] || fail "default run must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  # Definitive not-requested PR state, never a silent omission.
  assert_contains "$toon" 'prs: "not_requested' "default must state PR checks were not requested"
  assert_contains "$toon" "live PR discovery + checks,\"--include-prs\"" "omitted must mark the dropped live-PR surface"
  # Valid JSON, correct schema.
  printf '%s' "$json" | jq -e '.schema == "fm-bearings.v1"' >/dev/null || fail "json schema wrong"
  pass "default output is bounded, local-only, and marks omitted surfaces"
}

test_nomistakes_stats_parsed_when_available() {
  local home fakebin json
  home=$(make_home nmstats); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NM_SLEEP:-0}" = 1 ] && sleep 30
if [ "${1:-}" = "stats" ]; then
  cat <<'OUT'
│   Total changes       72   across 15 repos                │
│   Rescued changes     23   mistake caught + fixed         │
│   Rescue rate        32%   ██████████░░░░░░░░░░░░░░░░░░░░ │
│   Reported            84   ██████████████████████████████ │
│   Fixed              61%   ██████████████████░░░░░░░░░░░░ │
│   review              44   ██████████████████████████████ │
│   test                 6   ████░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│   document             1   █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│   distractions         9 rescue    24 fixes   ██████████  │
│   chef                 8 rescue    19 fixes   ████████░░  │
│   kanban                5 rescue     6 fixes   ███░░░░░░░  │
OUT
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .nm_status == "available"
      and .nm_total_changes == 72
      and .nm_total_repos == 15
      and .nm_rescued_changes == 23
      and .nm_rescue_rate_pct == 32
      and .nm_mistakes_reported == 84
      and .nm_mistakes_fixed_pct == 61
      and .nm_fixes_review == 44
      and .nm_fixes_test == 6
      and .nm_fixes_document == 1
      and (.nm_top_repos | length) == 3
      and (.nm_top_repos[0] == {repo:"distractions", rescue:9, fixes:24})' >/dev/null \
    || fail "no-mistakes stats not parsed correctly: $json"
  pass "no-mistakes pipeline benefit stats are parsed into the snapshot"
}

test_nomistakes_stats_degrades_when_unavailable() {
  local home fakebin json
  home=$(make_home nmmissing); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  # Simulate an errored/absent no-mistakes: a fakebin entry earlier on PATH
  # that always fails, rather than deleting the file (a real no-mistakes may
  # still be present later on the test runner's own PATH).
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.nm_status | contains("unavailable"))
      and .nm_total_changes == null
      and .nm_top_repos == []' >/dev/null \
    || fail "missing no-mistakes must degrade gracefully, not block the snapshot: $json"
  printf '%s' "$json" | jq -e '.schema == "fm-bearings.v1"' >/dev/null \
    || fail "rest of the snapshot must still be produced when no-mistakes errors"
  pass "an errored no-mistakes stats call degrades the stats field without blocking the snapshot"
}

test_nomistakes_stats_times_out_bounded() {
  local home fakebin json start end elapsed
  home=$(make_home nmtimeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  start=$(date +%s)
  json=$(FAKE_NM_SLEEP=1 FM_BEARINGS_NM_TIMEOUT=1 run "$home" "$fakebin" --json)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 10 ] || fail "no-mistakes stats call must be bounded by the timeout, took ${elapsed}s"
  printf '%s' "$json" | jq -e '.nm_status | contains("unavailable")' >/dev/null \
    || fail "timed-out no-mistakes stats must report unavailable"
  pass "a stalled no-mistakes stats call stays bounded by the timeout"
}

test_toon_json_parity() {
  local home fakebin toon json keys k
  home=$(make_home parity); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Same top-level keys in both representations.
  keys=$(printf '%s' "$json" | jq -r 'keys_unsorted[]')
  for k in $keys; do
    if printf '%s' "$json" | jq -e --arg k "$k" '.[$k] | type == "array"' >/dev/null; then
      local n hdr
      n=$(printf '%s' "$json" | jq --arg k "$k" '.[$k] | length')
      if [ "$n" = 0 ]; then
        assert_contains "$toon" "$k: []" "empty array $k must render as 'key: []'"
      else
        # Header must declare the same count and the same field set.
        hdr=$(printf '%s' "$toon" | grep -E "^$k\[[0-9]+\]\{" || true)
        [ -n "$hdr" ] || fail "TOON missing tabular header for $k"
        assert_contains "$hdr" "[$n]" "TOON $k row count must equal JSON length $n"
        local jfields tfields
        jfields=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k][0] | keys_unsorted | join(",")')
        tfields=$(printf '%s' "$hdr" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
        [ "$jfields" = "$tfields" ] || fail "TOON $k fields ($tfields) must equal JSON fields ($jfields)"
      fi
    else
      # Scalar: the key must appear as a "key: value" line.
      assert_contains "$toon" "$k: " "TOON must carry scalar field $k"
    fi
  done
  pass "TOON and JSON are parity representations of the same model"
}

test_report_pointers_surface() {
  local home fakebin json
  home=$(make_home reports); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e --arg p "$home/data/scout-x/report.md" '
    .reports | any(.[]; .id == "scout-x" and .path == $p)
  ' >/dev/null || fail "current scout report pointer must surface: $json"
  pass "current report pointers surface"
}

test_superseded_queued_item_dropped_by_default() {
  local home fakebin json
  home=$(make_home superseded); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "live-gate")) and (.gates | any(.[]; .id == "dead-gate") | not)
  ' >/dev/null || fail "default gates must include live and drop superseded: $json"
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '.gates | any(.[]; .id == "dead-gate")' >/dev/null \
    || fail "--all-queued must restore the superseded item"
  pass "superseded queued items are dropped by default and restored with --all-queued"
}

test_include_prs_is_the_only_fetch_path() {
  local home fakebin json
  home=$(make_home prs); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --include-prs --json)
  # Now gh WAS called, exactly for pr list.
  grep -q '^gh pr list ' "$home/net.log" || fail "--include-prs must call gh pr list"
  printf '%s' "$json" | jq -e '
    .prs | startswith("checked")
  ' >/dev/null || fail "--include-prs must report checked PR state"
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task" and .checks == "passing" and .review == "APPROVED")
  ' >/dev/null || fail "candidate_prs must carry the fetched PR cross-referenced to its task: $json"
  pass "--include-prs is the only path that fetches, and it enriches correctly"
}

test_partial_github_failure_degrades() {
  local home fakebin json rc
  home=$(make_home partial); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --include-prs --json); rc=$?
  expect_code 0 "$rc" "a PR-fetch failure must not crash the view"
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.candidate_prs | length) == 0
      and (.prs | test("unavailable"))
      and (.in_flight | length) > 0
  ' >/dev/null || fail "on gh failure the view must still emit, with an unavailable note: $json"
  pass "a partial GitHub failure degrades gracefully"
}

test_perl_fallback_bounds_github_call() {
  local home fakebin toolbin cmd json started elapsed
  home=$(make_home perl-timeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq date sed git grep tail cut tr head sort wc perl sleep cat find mktemp chmod rm; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  started=$(date +%s)
  json=$(PATH="$fakebin:$toolbin" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    FM_BEARINGS_PR_TIMEOUT=1 NET_LOG="$home/net.log" FAKE_GH_SLEEP=1 "$BEARINGS" --include-prs --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "Perl fallback did not bound a stalled gh call (${elapsed}s)"
  printf '%s' "$json" | jq -e '.prs | test("unavailable")' >/dev/null \
    || fail "timed-out gh call did not fail soft: $json"
  pass "Perl fallback bounds stalled GitHub calls without coreutils timeout"
}

write_large_fixture() {  # <home> <count>
  local home=$1 count=$2 i id
  : > "$home/data/backlog.md"
  printf '## Queued\n' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="dead-$i"
    mkdir -p "$home/projects/$id" "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
    printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$home/data/backlog.md"
    printf -- '- [ ] decision-%s - Decision %s (repo: repo-%s) (kind: captain) (hold: captain choice pending) (hold-kind: captain)\n' "$i" "$i" "$i" >> "$home/data/backlog.md"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=scout" \
      "mode=scout" \
      "pr=https://github.com/acme/repo-$i/pull/$i"
    printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$home/state/$id.status"
    i=$((i + 1))
  done
}

test_section_caps_and_expansion_flags() {
  local home fakebin json expanded
  home=$(make_home caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight|length) == 2 and (.decisions_open|length) == 2 and (.gates|length) == 2
    and (.reports|length) == 2 and (.recorded_prs|length) == 2 and (.unhealthy_endpoints|length) == 2
    and ([.omitted[].surface] | index("in_flight showing 2 of 5") != null)
    and ([.omitted[].surface] | index("decisions_open showing 2 of 5") != null)
    and ([.omitted[].surface] | index("gates showing 2 of 5") != null)
    and ([.omitted[].surface] | index("reports showing 2 of 5") != null)
    and ([.omitted[].surface] | index("recorded_prs showing 2 of 5") != null)
    and ([.omitted[].surface] | index("unhealthy_endpoints showing 2 of 5") != null)
  ' >/dev/null || fail "section caps or counted omissions are wrong: $json"
  expanded=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json --all-in-flight --all-decisions --all-queued \
      --all-reports --all-recorded-prs --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    (.in_flight|length) == 5 and (.decisions_open|length) == 5 and (.gates|length) == 5
    and (.reports|length) == 5 and (.recorded_prs|length) == 5 and (.unhealthy_endpoints|length) == 5
  ' >/dev/null || fail "section expansion flags did not reveal full sets: $expanded"
  pass "all fleet-sized sections are capped with counted opt-in expansion"
}

test_pr_repository_cap_and_expansion() {
  local home fakebin json expanded
  home=$(make_home repo-caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 2 ] || fail "default PR repository cap was not enforced"
  printf '%s' "$json" | jq -e '
    [.omitted[] | select(.surface == "PR repositories showing 2 of 5" and .reveal == "--all-pr-repos")] | length == 1
  ' >/dev/null || fail "PR repository truncation was not recorded: $json"
  : > "$home/net.log"
  expanded=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --all-pr-repos --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 5 ] || fail "--all-pr-repos did not reveal every repository"
  printf '%s' "$expanded" | jq -e '.candidate_prs | length == 5' >/dev/null \
    || fail "expanded PR repository set did not enrich every repository: $expanded"
  pass "live PR enrichment caps repositories with counted expansion"
}

test_per_repository_pr_cap_is_disclosed() {
  local home fakebin json toon
  home=$(make_home pr-row-cap); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs --json)
  toon=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs)
  printf '%s' "$json" | jq -e '
    (.candidate_prs | length) == 2
    and (.prs | test("2 shown, at least 3 open; capped in 1 repo"))
    and ([.omitted[] | select(.surface == "candidate_prs showing 2 of at least 3; capped in 1 repo(s)" and .reveal == "raise FM_BEARINGS_PR_LIMIT")] | length) == 1
  ' >/dev/null || fail "per-repository PR truncation was not disclosed: $json"
  assert_contains "$toon" 'candidate_prs showing 2 of at least 3' "TOON did not preserve PR truncation disclosure"
  pass "per-repository open-PR caps are disclosed with an expansion knob"
}

install_failing_jq() {  # <fakebin> <model|toon>
  local fakebin=$1 phase=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'def trunc'*) [ "$phase" = model ] && exit 9 ;;
  *'def q:'*) [ "$phase" = toon ] && exit 9 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_projection_and_toon_fail_closed() {
  local home fakebin out err rc
  home=$(make_home fail-closed); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  install_failing_jq "$fakebin" model
  err="$home/model.err"
  out=$(run "$home" "$fakebin" --json 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "projection failure exited successfully"
  [ -z "$out" ] || fail "projection failure emitted output"
  grep -F 'projection failed' "$err" >/dev/null || fail "projection failure lacked a diagnostic"
  install_failing_jq "$fakebin" toon
  err="$home/toon.err"
  out=$(run "$home" "$fakebin" 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "TOON rendering failure exited successfully"
  [ -z "$out" ] || fail "TOON rendering failure emitted output"
  grep -F 'TOON rendering failed' "$err" >/dev/null || fail "TOON failure lacked a diagnostic"
  pass "projection and TOON rendering failures exit nonzero with diagnostics"
}

# The Lavish-103 defect, end to end: a COMPLETED scout that raised a decision and
# then finished (done), whose report body reads like that decision, must surface as
# a report POINTER only - never in decisions_open. Report prose must never open or
# reopen a pending decision; only the keyed durable state does.
test_completed_scout_report_not_pending() {
  local home fakebin json
  home=$(make_home completed-scout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/lav-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/lav-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B; this needs a captain decision.\n' > "$home/data/lavish-103/report.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "lavish-103") | not)
      and (.reports | any(.[]; .id == "lavish-103"))
  ' >/dev/null || fail "completed scout must be a report pointer, never a pending decision: $json"
  pass "a completed scout with decision-like report prose is a pointer, not pending"
}

test_landed_default_handles_no_landed_items() {
  local home fakebin json
  home=$(make_home landed-empty)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.landed | length) == 0
      and ([.omitted[].surface] | any(test("landed")) | not)
  ' >/dev/null || fail "empty landed set was not handled cleanly: $json"
  pass "landed selection handles no landed items"
}

# The roll-up stays bounded by an overall cap, disclosed in omitted[], with
# --all-landed as the counted expansion knob.
test_landed_bounded_and_disclosed() {
  local home fakebin json i expected actual
  home=$(make_home landed-caps)
  {
    printf '## In flight\n\n## Queued\n\n## Done\n'
    i=1
    while [ "$i" -le 12 ]; do
      printf -- '- [x] landed-%02d - Landed thing %02d (repo: firstmate) (kind: ship) (merged 2026-06-%02d)\n' \
        "$i" "$i" "$((13 - i))"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_LANDED=5 FM_BEARINGS_LANDED_PER_HOME=20 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.landed | length) == 5
      and ([.omitted[].surface] | any(test("landed showing 5 of 12")))
  ' >/dev/null || fail "default landed path did not cap and disclose the overall bound: $json"
  json=$(FM_BEARINGS_LANDED=1 FM_BEARINGS_LANDED_PER_HOME=20 run "$home" "$fakebin" --json --all-landed)
  expected=$(i=1; while [ "$i" -le 12 ]; do printf 'landed-%02d\n' "$i"; i=$((i + 1)); done | LC_ALL=C sort)
  actual=$(printf '%s' "$json" | jq -r '.landed[].id' | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || fail "--all-landed returned wrong identities: $actual"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 12
      and ([.omitted[].surface] | any(test("landed")) | not)
  ' >/dev/null || fail "--all-landed must reveal the exact full landed set: $json"
  pass "landed stays bounded with an overall cap and omitted[] disclosure, and --all-landed reveals everything"
}

# Bearings projects authoritative structured state rather than inventing return
# policy. A live blocked child remains a live in-flight record with state=blocked
# and an open blocker; it must never be converted into a queued `gates` record.
# The return-catch-up owner prevents this state from reaching ordinary rendering
# during an away return, while this test pins Bearings' own projection boundary.
test_live_blocker_is_not_charted_queue_work() {
  local home fakebin json
  home=$(make_home live-blocker); write_fixture "$home"
  printf 'blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token\n' > "$home/state/ship-task.status"
  record_claude_state "$home/state" ship-task idle
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.[]; .id == "ship-task" and .state == "blocked"))
      and (.decisions_open | any(.[]; .id == "ship-task") | not)
      and (.gates | any(.[]; .id == "ship-task") | not)
  ' >/dev/null || fail "live blocked work was projected as queued/deferred work: $json"
  pass "Bearings keeps a live blocker in structured live state and never converts it to Charted Next queue work"
}

test_main_orphan_in_flight_is_disclosed_not_invented() {
  local home fakebin json canonical
  home=$(make_home main-orphan)
  : > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] only-orphan - Structured in flight without meta (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "in-flight backlog item has no child metadata"
      and (.main_inventory.orphan_in_flight == ["only-orphan"])
      and .main_inventory.unstructured_current_count == 0
      and (.tasks | length) == 0
  ' >/dev/null || fail "canonical main inventory missed orphan: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | length) == 0
      and ([.in_flight[].id] | index("only-orphan") | not)
      and ([.decisions_open[].id] | index("only-orphan") | not)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("in-flight backlog item has no child metadata"))))
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
  ' >/dev/null || fail "orphan in-flight was invented or not disclosed: $json"
  pass "main orphan in-flight stays out of Underway and is disclosed in omitted/gates"
}

test_main_unstructured_current_is_disclosed_with_structured_sibling() {
  local home fakebin json canonical
  home=$(make_home main-unstructured)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/structured-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
this current row is not structured
- [ ] structured-ship - Visible structured sibling (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
another free-form note without checkbox
- [ ] structured-queued - Structured queued (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/structured-ship.meta" \
    "window=firstmate:fm-structured-ship" \
    "worktree=$home/projects/structured-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: structured sibling still projects\n' > "$home/state/structured-ship.status"
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight | length) == 0
  ' >/dev/null || fail "canonical main inventory missed unstructured current: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] == ["structured-ship"])
      and ([.gates[].id] | index("structured-queued") != null)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("unstructured current backlog row"))))
      and (.omitted | any(.surface == "main unstructured current backlog row(s): 2"))
      and ([.decisions_open[].id] | index("(main-inventory)") | not)
  ' >/dev/null || fail "unstructured current not disclosed or structured sibling lost: $json"
  pass "main unstructured current is disclosed while structured siblings still project"
}

test_main_orphan_counterfactual_meta_clears_inventory_warning() {
  local home fakebin json_before json_after
  home=$(make_home main-orphan-counterfactual)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/orphan-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Gains meta in counterfactual (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Already live (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Ordinary queue (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: visible sibling\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  json_before=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_before" | jq -e '
    ([.in_flight[].id] == ["visible-ship"])
      and ([.in_flight[].id] | index("orphan-ship") | not)
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
      and (.gates | any(.id == "(main-inventory)"))
      and ([.gates[].id] | index("queued-ship") != null)
  ' >/dev/null || fail "pre-meta orphan fixture failed: $json_before"
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: orphan now has meta\n' > "$home/state/orphan-ship.status"
  json_after=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_after" | jq -e '
    ([.in_flight[].id] | sort) == ["orphan-ship", "visible-ship"]
      and ([.omitted[].surface] | any(test("main in-flight backlog item")) | not)
      and ([.gates[].id] | index("(main-inventory)") | not)
      and ([.decisions_open[].id] | index("orphan-ship") | not)
  ' >/dev/null || fail "adding meta did not clear inventory warning or project orphan: $json_after"
  pass "counterfactual meta clears main inventory warning and projects the live task"
}

test_main_captain_readiness_uses_blocker_resolution() {
  local home fakebin json
  home=$(make_home main-captain-readiness)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/prep" "$home/projects/observation"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] observation - Held observation (repo: firstmate) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] prep - Prepare canary (repo: firstmate) (kind: ship)

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/prep.meta" \
    "window=firstmate:fm-prep" "worktree=$home/projects/prep" "project=firstmate" \
    "harness=codex" "kind=ship" "mode=no-mistakes"
  printf 'working: preparing main canary\n' > "$home/state/prep.status"
  fm_write_meta "$home/state/observation.meta" \
    "window=firstmate:fm-observation" "worktree=$home/projects/observation" "project=firstmate" \
    "harness=codex" "kind=scout" "mode=scout"
  printf 'paused: observation is deliberately held\n' > "$home/state/observation.status"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.id == "prep"))
      and (.in_flight | any(.id == "observation") | not)
      and ([.gates[] | select(.id == "observation" and .reason == "watch production")] | length) == 1
      and (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "prep,review"))
  ' >/dev/null || fail "main blocked captain action or held-child projection was wrong: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/prep.meta" "$home/state/prep.status" \
    "$home/state/observation.meta" "$home/state/observation.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "review"))
  ' >/dev/null || fail "main one-blocker captain action became premature: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[] | select(.id == "captain-run")] | length) == 1
      and (.gates | any(.id == "captain-run") | not)
  ' >/dev/null || fail "main zero-blocker captain action was not projected exactly once: $json"
  pass "main captain actionability follows blocker resolution"
}

test_current_landed_baseline_is_repeatable_and_prior_report_independent
test_default_is_bounded_and_local_only
test_nomistakes_stats_parsed_when_available
test_nomistakes_stats_degrades_when_unavailable
test_nomistakes_stats_times_out_bounded
test_toon_json_parity
test_report_pointers_surface
test_superseded_queued_item_dropped_by_default
test_include_prs_is_the_only_fetch_path
test_partial_github_failure_degrades
test_perl_fallback_bounds_github_call
test_section_caps_and_expansion_flags
test_pr_repository_cap_and_expansion
test_per_repository_pr_cap_is_disclosed
test_projection_and_toon_fail_closed
test_completed_scout_report_not_pending
test_landed_default_handles_no_landed_items
test_landed_bounded_and_disclosed
test_live_blocker_is_not_charted_queue_work
test_main_orphan_in_flight_is_disclosed_not_invented
test_main_unstructured_current_is_disclosed_with_structured_sibling
test_main_orphan_counterfactual_meta_clears_inventory_warning
test_main_captain_readiness_uses_blocker_resolution
