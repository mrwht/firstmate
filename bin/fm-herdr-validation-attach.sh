#!/usr/bin/env bash
# fm-herdr-validation-attach.sh - open a disposable, read-only companion
# herdr tab attached to a task's active `no-mistakes` validation run.
#
# Usage: fm-herdr-validation-attach.sh <meta-file>
#
# Reads <meta-file> (a task's state/<id>.meta) and no-ops silently (exit 0,
# no output) unless its recorded `backend=` is `herdr` - every other backend
# (the tmux default, zellij, orca, cmux) is intentionally left untouched.
# On herdr, it opens a new tab labeled `fm-<id>-view`, cwd'd at the task's
# recorded `worktree=`, in the SAME herdr workspace as the task's own
# working pane (`herdr_session=`/`herdr_workspace_id=` from the same meta),
# then runs `no-mistakes attach` in it: a live, read-only companion view of
# whatever validation run the crewmate starts next in its own pane.
#
# This tab is intentionally untracked: it is never written back into the
# task's meta, never reconciled by recovery, and never closed by
# bin/fm-teardown.sh. It is always safe to discard, whether the validation
# run it was watching is still active or already finished by the time the
# task is torn down; an abandoned copy is harmless clutter, never a blocker.
#
# Intended caller: the crewmate itself, per its own no-mistakes-mode ship
# brief, right before invoking /no-mistakes - see bin/fm-brief.sh. Never
# call this for scout, direct-PR, or local-only tasks, which never run a
# validation pipeline.
#
# Failure here (missing herdr, a herdr CLI error, an unparsable tab create
# response, or a meta file missing herdr_session/herdr_workspace_id/
# worktree) is reported on stderr with a non-zero exit, but is deliberately
# never fatal to the caller's real work: a missing companion view is a lost
# convenience, never a reason to block validation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

META=${1:-}
if [ -z "$META" ] || [ ! -f "$META" ]; then
  echo "error: fm-herdr-validation-attach.sh requires an existing meta file" >&2
  exit 1
fi

BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = herdr ] || exit 0

ID=$(fm_meta_get "$META" endpoint_task_id)
[ -n "$ID" ] || ID=$(basename "$META" .meta)
SESSION=$(fm_meta_get "$META" herdr_session)
WORKSPACE_ID=$(fm_meta_get "$META" herdr_workspace_id)
WORKTREE=$(fm_meta_get "$META" worktree)

if [ -z "$SESSION" ] || [ -z "$WORKSPACE_ID" ] || [ -z "$WORKTREE" ]; then
  echo "error: meta file '$META' is missing herdr_session, herdr_workspace_id, or worktree; cannot open a validation view" >&2
  exit 1
fi

fm_backend_source herdr || {
  echo "error: herdr backend adapter is unavailable; cannot open a validation view for $ID" >&2
  exit 1
}

fm_backend_herdr_create_validation_view "$SESSION:$WORKSPACE_ID" "fm-$ID-view" "$WORKTREE"
