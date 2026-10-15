#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Scalar at <path> inside the top-level TOON block <block> of output $1, where
# <path> is a direct child key ("branch") or a child of a direct child
# ("local.head"). TOON nests by two spaces; the block ends at the next
# top-level key. Empty when absent.
fm_nm_block_field() {  # <toon-output> <block> <path>
  printf '%s\n' "$1" | awk -v block="$2" -v want="$3" '
    $0 ~ "^" block ":[[:space:]]*$" { inblock = 1; next }
    inblock && /^[^[:space:]]/ { exit }
    inblock {
      line = $0
      sub(/^ +/, "", line)
      indent = length($0) - length(line)
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
      if (indent == 2) { section = key; path = key }
      else if (indent == 4) { path = section "." key }
      else next
      if (path == want) { print val; exit }
    }'
}

# 0 if the run in bare `axi status` output $3 is worktree $1's current run on
# branch $2. This is the ONE attribution predicate for that output. The run's
# own branch must equal $2, and then either:
#   - its head matches the worktree per fm_nm_head_matches_worktree, or
#   - no-mistakes itself binds the run to this worktree: branch_sync reports
#     state pipeline_owned for this same run id, on this branch, at exactly the
#     worktree's local HEAD. This covers an active run whose head advanced
#     with gate fix commits that exist only in the pipeline's own copy, so the
#     worktree cannot resolve that head locally.
# Run identity is read from the run: block only, so a branch_sync block can
# never stand in for a missing run.
fm_nm_status_binds_worktree() {  # <worktree> <branch> <axi-status-output>
  local wt=$1 branch=$2 out=$3 run_id sync_head local_full sync_full
  [ -n "$branch" ] && [ -n "$out" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" run branch)")" = "$branch" ] || return 1
  fm_nm_head_matches_worktree "$wt" "$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" run head)")" && return 0
  run_id=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" run id)")
  [ -n "$run_id" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync state)")" = pipeline_owned ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync pipeline.run)")" = "$run_id" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync local.branch)")" = "$branch" ] || return 1
  sync_head=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync local.head)")
  [ -n "$sync_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  sync_full=$(git -C "$wt" rev-parse --verify "${sync_head}^{commit}" 2>/dev/null) || return 1
  [ "$sync_full" = "$local_full" ]
}
