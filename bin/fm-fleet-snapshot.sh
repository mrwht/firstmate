#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v2`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind and
#     hold_reason when tasks-axi emits it. They also carry normalized current_role,
#     requires_child_metadata, blocked_by_ids, unresolved_blocker_ids, and
#     captain_actionable fields. Repeated blocker tokens remain ordered; a blocker
#     resolves only when its structured record is Done, and missing ids stay open.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks (orphan structured in-flight ids with no
#     state/<id>.meta, and unstructured current backlog rows). Does not invent
#     live tasks; meta remains truth for workers. Bearings maps failures into
#     omitted[] disclosure (and a Charted Next gate line) rather than silent
#     empty Underway.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATE_TIMEOUT=${FM_SNAPSHOT_SECONDMATE_TIMEOUT:-8}
# Bounds on how many per-task units run concurrently. The loop is otherwise
# embarrassingly parallel (no cross-unit state), so this exists only to cap
# simultaneous no-mistakes/crew-state fan-out against the shared daemon and
# process table, not to preserve correctness. The default is kept modest
# rather than maximizing throughput, since headroom should come from evidence
# (FM_SNAPSHOT_CONCURRENCY_LOG below) rather than a guess.
FM_SNAPSHOT_TASK_PARALLELISM=${FM_SNAPSHOT_TASK_PARALLELISM:-3}
# Debug-only concurrency/timing instrumentation, off by default (zero cost
# when unset). Set to a writable file path to have task_json_lines append one
# TSV sample per dispatched unit:
# <epoch>\ttask\t<id>\t<inflight-before-dispatch>\t<elapsed-seconds>
# so FM_SNAPSHOT_TASK_PARALLELISM can be tuned from observed concurrency and
# per-call latency against a real fleet, not guessed.
FM_SNAPSHOT_CONCURRENCY_LOG=${FM_SNAPSHOT_CONCURRENCY_LOG:-}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
validate_positive_bound FM_SNAPSHOT_SECONDMATE_TIMEOUT "$FM_SNAPSHOT_SECONDMATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_TASK_PARALLELISM "$FM_SNAPSHOT_TASK_PARALLELISM"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

The per-task loop runs concurrently, bounded by FM_SNAPSHOT_TASK_PARALLELISM
(default 3); output ordering is unaffected by concurrency.
Set FM_SNAPSHOT_CONCURRENCY_LOG to a writable file path to record one TSV
sample per dispatched unit (epoch, task label, id, observed in-flight count,
elapsed seconds) for tuning that bound from evidence; unset (the default)
adds no overhead.
EOF
}

case "${1:---json}" in
  --json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

# Portable (bash 3.2-safe, no `wait -n`) bounded-concurrency gate: block until
# this shell's own backgrounded job count drops below <max>. Callers background
# one unit of work per loop iteration right after calling this.
snapshot_wait_for_slot() {  # <max-concurrent>
  local max=$1
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$max" ]; do
    sleep 0.05
  done
}

# Debug-only: append one concurrency/timing sample when FM_SNAPSHOT_CONCURRENCY_LOG
# is set; a no-op otherwise so normal runs pay zero cost.
snapshot_log_sample() {  # <label> <id> <inflight> <elapsed-seconds>
  [ -n "$FM_SNAPSHOT_CONCURRENCY_LOG" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" >>"$FM_SNAPSHOT_CONCURRENCY_LOG"
}

# Debug-only: run <cmd...> (writing its stdout to nothing special - caller
# redirects), timing it and logging the sample when FM_SNAPSHOT_CONCURRENCY_LOG
# is set. When unset, this is exactly the direct call with no added overhead.
snapshot_timed_call() {  # <label> <id> <inflight> -- <cmd...>
  local label=$1 id=$2 inflight=$3 start end elapsed
  shift 3
  [ "$1" = -- ] && shift
  if [ -z "$FM_SNAPSHOT_CONCURRENCY_LOG" ]; then
    "$@"
    return $?
  fi
  start=$(date +%s.%N 2>/dev/null || date +%s)
  "$@"
  local rc=$?
  end=$(date +%s.%N 2>/dev/null || date +%s)
  elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}' 2>/dev/null || echo 0)
  snapshot_log_sample "$label" "$id" "$inflight" "$elapsed"
  return $rc
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .kind == "captain" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0)
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}

# One task's row, run standalone so task_json_lines can background it.
# No shared mutable state crosses tasks: every value here is either derived
# purely from <meta>/<id> or read-only global config, so concurrent instances
# never interact.
task_json_one() {  # <meta> <id>
  local meta=$1 id=$2 kind harness mode yolo project worktree home projects backend target status_log report_path
  local remote_host remote_root remote_state remote_rc remote_home_present
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  harness=$(meta_value "$meta" harness)
  mode=$(meta_value "$meta" mode)
  yolo=$(meta_value "$meta" yolo)
  project=$(meta_value "$meta" project)
  worktree=$(meta_value "$meta" worktree)
  home=$(meta_value "$meta" home)
  projects=$(meta_value "$meta" projects)
  remote_host=$(meta_value "$meta" remote_host)
  remote_root=$(meta_value "$meta" remote_root)
  remote_home_present=null
  if [ -n "$remote_host" ]; then
    backend=$(meta_value "$meta" remote_backend)
    [ -n "$backend" ] || backend=unknown
    target=$(meta_value "$meta" remote_target)
  else
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
  fi
  status_log="$STATE/$id.status"
  report_path="$DATA/$id/report.md"
  pr=$(meta_value "$meta" pr)
  pr_source=meta
  if [ -z "$pr" ]; then
    pr_from_status=$(first_pr_url_in_file "$status_log" || true)
    pr=$pr_from_status
    pr_source=status_event
  fi
  if [ -z "$pr" ]; then
    pr_source=absent
  fi

  current_json=$(crew_state_json "$id")
  event_json=$(status_event_json "$status_log")
  last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
  current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
  current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')

  # Durable keyed open-decision set: fold the WHOLE status stream
  # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
  # never mask a still-open captain decision. The set is derived purely from the
  # keyed fold - never from report bodies or decision-like prose - and then
  # reconciled against the crew LIFECYCLE, which only clears a stale decision the
  # crew has provably moved past. Two lifecycle signals clear it, neither of which
  # reads any report content:
  #   - a live activity read (run-step or busy pane) that is working/done, so a
  #     crew that resumed past a gate is not still reported as parked; and
  #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
  #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
  #     report POINTER, never as a reopened pending decision.
  # Secondmates are excluded from lifecycle clearing: they are persistent and
  # multiplex many concerns onto one stream, so activity on one concern must
  # never clear another concern's keyed decision. A parked/blocked state, or a
  # non-authoritative status-log/none read on a still-live task, keeps the fold's
  # open decision surfacing.
  open_decisions_tsv=$(status_open_decisions "$status_log")
  if [ "$kind" != secondmate ] && \
     { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
         && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
       || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
    open_decisions_tsv=""
  fi
  open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
    [ splits("\n") | select(length > 0)
      | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
      | select(. != null) ]')
  pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
  blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

  endpoint_exists=null
  agent_alive=not_checked
  if [ -n "$remote_host" ]; then
    if remote_state=$(fm_run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
      "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 0 ]; then
      remote_home_present=true
      remote_state=$(printf '%s\n' "$remote_state" | tail -1)
      case "$remote_state" in
        alive) endpoint_exists=true; agent_alive=alive ;;
        dead) endpoint_exists=true; agent_alive=dead ;;
        missing) endpoint_exists=false; agent_alive=dead ;;
        *) endpoint_exists=null; agent_alive=unknown ;;
      esac
    else
      endpoint_exists=null
      agent_alive=unknown
    fi
  else
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi
  fi

  [ -f "$report_path" ] && report_present=1 || report_present=0
  meta_json=$(path_present_json "$meta")
  status_json=$event_json
  report_json=$(path_present_json "$report_path")
  if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
  if [ -n "$home" ] && [ -n "$remote_host" ]; then
    home_json=$(jq -n --arg path "$home" --argjson present "$remote_home_present" '{path:$path,present:$present}')
  elif [ -n "$home" ]; then
    home_json=$(path_present_json "$home")
  else
    home_json=$(jq -n '{path:null,present:false}')
  fi

  jq -n \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg harness "$harness" \
    --arg mode "$mode" \
    --arg yolo "$yolo" \
    --arg project "$project" \
    --arg worktree "$worktree" \
    --arg home "$home" \
    --arg projects "$projects" \
    --arg backend "$backend" \
    --arg target "$target" \
    --arg remote_host "$remote_host" \
    --arg remote_root "$remote_root" \
    --arg pr "$pr" \
    --arg pr_source "$pr_source" \
    --arg agent_alive "$agent_alive" \
    --arg observed_at "$SNAPSHOT_NOW" \
    --arg last_event_raw "$last_event_raw" \
    --argjson current_state "$current_json" \
    --argjson meta_path "$meta_json" \
    --argjson status_log "$status_json" \
    --argjson report "$report_json" \
    --argjson worktree_path "$worktree_json" \
    --argjson home_path "$home_json" \
    --argjson endpoint_exists "$endpoint_exists" \
    --argjson open_decisions "$open_decisions_json" \
    --argjson pending_decision "$(bool_json "$pending_decision")" \
    --argjson blocked_event "$(bool_json "$blocked_event")" \
    --argjson report_present "$(bool_json "$report_present")" \
    '{
      id:$id,
      kind:$kind,
      harness:($harness // ""),
      mode:($mode // ""),
      yolo:($yolo // ""),
      project:($project // ""),
      backend:$backend,
      remote:(if $remote_host == "" then null else {host:$remote_host,root:$remote_root} end),
      paths:{
        meta:$meta_path,
        status_log:$status_log,
        worktree:$worktree_path,
        home:$home_path,
        report:$report
      },
      secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
      current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
      endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
        status:(if $endpoint_exists == false then "absent"
                elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                else "unknown" end),
        observed_at:$observed_at,freshness:"fresh"},
      pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
      hints:{
        pending_decision:$pending_decision,
        blocked_event:$blocked_event,
        open_decisions:$open_decisions,
        scout_report_present:$report_present,
        last_event_text:$last_event_raw
      },
      actions:(
        if $kind == "secondmate" then
          {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
           watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
           return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
        else
          {watch:"bin/fm-peek.sh fm-\($id)",
           steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
           return_channel_note:null}
        end)
    }'
}

# Dispatch task_json_one across every state/<id>.meta concurrently (bounded by
# FM_SNAPSHOT_TASK_PARALLELISM), then collect and sort - the previous serial
# `for ... | jq -s 'sort_by(.id)'` pipeline's output contract, unchanged.
task_json_lines() {
  local meta id tmpdir lines max_parallel inflight
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-snapshot-tasks.XXXXXX") || return 1
  chmod 700 "$tmpdir"

  max_parallel=$FM_SNAPSHOT_TASK_PARALLELISM

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    snapshot_wait_for_slot "$max_parallel"
    inflight=0
    [ -n "$FM_SNAPSHOT_CONCURRENCY_LOG" ] && inflight=$(jobs -rp | wc -l | tr -d ' ')
    snapshot_timed_call task "$id" "$inflight" -- task_json_one "$meta" "$id" >"$tmpdir/$id.json" &
  done
  wait

  lines=$(cat "$tmpdir"/*.json 2>/dev/null | jq -s 'sort_by(.id)') || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  printf '%s\n' "$lines"
}

# Main-home current-inventory validity: orphan / unstructured-current checks,
# without inventing live task rows. Meta inventory remains the sole source of
# live workers; this object only discloses backlog↔task inconsistency for
# renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --argjson backlog "$1" \
    --argjson tasks "$2" '
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

SCOUT_REPORTS_JSON=$(scout_report_lines)
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }

jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson main_inventory "$MAIN_INVENTORY_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v2",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)}))
   }'
