#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          The AXI-family floor policy is owned beside GH_AXI_MIN and
#          LAVISH_AXI_MIN below; the per-tool owners point there. An installed
#          build below its floor reports MISSING like no-mistakes, so the operator
#          is asked to upgrade rather than silently running an older tool.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in AGENTS.md section 4 and
#          .agents/skills/quota-array-dispatch/SKILL.md.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and secondmate homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the three MUTATING sweeps
#          (PR-check migration, x_mode_setup, fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, X-mode artifacts, project clones, or repair
#          instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#          Set FM_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half concurrently:
#            all  (default, and any unrecognized value) - everything, exactly as
#                 before. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status` and fleet_sync.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no PR-check migration, no
#                 x_mode_setup: those already ran on the local pass.
#          FM_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/fm-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER.
#          Set FM_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the fleet lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# fm-timing-lib.sh is inert unless FM_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/fm-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${FM_BOOTSTRAP_NETWORK:-all}" in
  skip|only) FM_BOOTSTRAP_NETWORK_PHASE=${FM_BOOTSTRAP_NETWORK:-all} ;;
  *) FM_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${FM_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    cursor-agent) echo "https://cursor.com/cli" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.31.2
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.29
LAVISH_AXI_MIN=0.1.46

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$FM_HOME" in
    /*) shim_home=$FM_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","muse"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A secondmate is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    return 0
  fi
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state, and the deferred network pass
# never repeats it: the local pass that ran first already closed that window.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
  startup_memory_budget_setup
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend actually requires treehouse (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if fm_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if command -v lavish-axi >/dev/null 2>&1 && ! tool_version_at_least lavish-axi "$LAVISH_AXI_MIN"; then
    echo "MISSING: lavish-axi (install: $(install_cmd lavish-axi))"
  fi
  if command -v quota-axi >/dev/null 2>&1 && ! fm_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
  # default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and secondmate homes never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${FM_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  # A configured cursor crew harness needs a cursor executable present, and
  # cursor ships under EITHER installed name. Resolution runs through the
  # verified owner rather than a bare `command -v`, so a home that merely has
  # some unrelated executable named `agent` on PATH is still reported missing
  # instead of failing at the first spawn.
  if [ "$crew" = cursor ] && ! fm_cursor_resolve_binary >/dev/null 2>&1; then
    echo "MISSING_MANUAL: cursor-agent (instructions: $(manual_install_url cursor-agent))"
  fi
  crew_dispatch_validate
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# fm-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly and in the same order, so nothing about
# what runs, in what sequence, or what it returns changes.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    __fm_timing_stamp=$(fm_timing_now_ms)
    fleet_sync
    fm_timing_record phase fleet-sync "$__fm_timing_stamp"
  fi
fi
exit 0
