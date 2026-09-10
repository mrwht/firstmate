# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch) follows the
#     PRIMARY checkout's current default-branch commit: base_mode is that
#     local commit, with NO fetch and no origin dependency.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
# fm-spawn.sh's --secondmate path calls secondmate_registry_* functions without
# sourcing this lib itself, relying on this transitive source; keep it even
# though ff_target no longer uses it directly.
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md symlinks), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
# shellcheck disable=SC2034  # FF_STATUS/FF_INSTR are read by callers (fm-spawn.sh, fm-update.sh) after ff_target returns
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  # shellcheck disable=SC2034  # FF_STATUS/FF_INSTR are read by callers (fm-spawn.sh, fm-update.sh) after ff_target returns
  FF_STATUS="updated"
  # shellcheck disable=SC2034
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}
