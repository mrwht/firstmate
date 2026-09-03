#!/usr/bin/env bash
# tests/fm-herdr-validation-attach-smoke.test.sh - real-herdr smoke test for
# bin/fm-herdr-validation-attach.sh, the companion validation-view opener a
# ship brief tells the crewmate to run right before invoking /no-mistakes.
#
# Two things are pinned here rather than in a hermetic stub test:
# - the backend no-op gate itself needs no herdr/jq at all and is exercised
#   unconditionally below, proving every non-herdr backend is left untouched;
# - the herdr path's actual tab/pane creation and command delivery are
#   proven against the REAL binary, on a private throwaway lab session, never
#   the default one (tests/herdr-test-safety.sh; the 2026-07-02 incident).
#
# Skips the herdr-path assertions cleanly when herdr or jq is missing; the
# no-op assertions still run either way since they touch neither tool.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/fm-herdr-validation-attach.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() { :; }
trap cleanup_all EXIT

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-validation-attach.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
cleanup_all() { rm -rf "$SCRATCH"; }
trap cleanup_all EXIT

# --- non-herdr backends no-op silently, no herdr/jq required ----------------

for BACKEND in tmux zellij orca cmux "" ; do
  META="$SCRATCH/nonherdr-${BACKEND:-absent}.meta"
  {
    echo "endpoint_task_id=nonherdr-${BACKEND:-absent}"
    echo "worktree=$SCRATCH"
    [ -z "$BACKEND" ] || echo "backend=$BACKEND"
  } > "$META"
  OUT=$("$HELPER" "$META" 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] || fail "backend='${BACKEND:-absent}' should exit 0, got $RC: $OUT"
  [ -z "$OUT" ] || fail "backend='${BACKEND:-absent}' should print nothing, got: $OUT"
done
pass "every non-herdr backend (including the implicit tmux default) no-ops silently"

# --- missing meta file is a loud, non-zero refusal ---------------------------

if OUT=$("$HELPER" "$SCRATCH/does-not-exist.meta" 2>&1); then
  fail "a missing meta file should refuse, not succeed"
fi
case "$OUT" in
  *"requires an existing meta file"*) : ;;
  *) fail "the missing-meta refusal should name the problem, got: $OUT" ;;
esac
pass "a missing meta file refuses loudly instead of silently no-oping"

# --- real herdr: opens a companion tab attached to the task's workspace -----

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found (herdr-path assertions skipped)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (herdr-path assertions skipped)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-validation-attach-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() { rm -rf "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b vattach "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-vattach" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TASK_TAB_ID TASK_PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TASK_TAB_ID" ] && [ -n "$TASK_PANE_ID" ] || fail "create_task did not return tab/pane ids"

META="$SCRATCH/vattach.meta"
{
  echo "endpoint_task_id=vattach"
  echo "worktree=$WT"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TASK_TAB_ID"
  echo "herdr_pane_id=$TASK_PANE_ID"
} > "$META"

TABS_BEFORE=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WORKSPACE_ID" 2>/dev/null | jq -r '.result.tabs | length')

OUT=$("$HELPER" "$META") || fail "the helper should succeed on a real herdr task: $OUT"
read -r VIEW_TAB_ID VIEW_PANE_ID <<EOF
$OUT
EOF
[ -n "$VIEW_TAB_ID" ] && [ -n "$VIEW_PANE_ID" ] || fail "the helper did not echo tab/pane ids, got: $OUT"
[ "$VIEW_TAB_ID" != "$TASK_TAB_ID" ] || fail "the companion tab must not reuse the task's own tab id"
[ "$VIEW_PANE_ID" != "$TASK_PANE_ID" ] || fail "the companion pane must not reuse the task's own pane id"

TABS_AFTER=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WORKSPACE_ID" 2>/dev/null | jq -r '.result.tabs | length')
[ "$TABS_AFTER" -eq "$((TABS_BEFORE + 1))" ] || fail "expected exactly one new tab, went from $TABS_BEFORE to $TABS_AFTER"

VIEW_LABEL=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WORKSPACE_ID" 2>/dev/null \
  | jq -r --arg id "$VIEW_TAB_ID" '.result.tabs[] | select(.tab_id == $id) | .label')
[ "$VIEW_LABEL" = "fm-vattach-view" ] || fail "expected label fm-vattach-view, got: $VIEW_LABEL"
pass "real herdr: opens exactly one new companion tab, distinct from the task's own tab/pane"

VIEW_CWD=$(fm_backend_herdr_cli "$SESSION" pane get "$VIEW_PANE_ID" 2>/dev/null | jq -r '.result.pane.cwd // empty')
[ "$VIEW_CWD" = "$WT" ] || fail "expected the companion tab cwd'd at the task worktree $WT, got: $VIEW_CWD"
pass "real herdr: the companion tab is cwd'd at the task's own worktree"

CAP=$(fm_backend_herdr_capture "$SESSION:$VIEW_PANE_ID" 20)
case "$CAP" in
  *"no-mistakes attach"*) : ;;
  *) fail "expected the companion pane to have run 'no-mistakes attach', captured: $CAP" ;;
esac
pass "real herdr: the companion pane was sent 'no-mistakes attach'"

# --- rerunning is safe: leaves the original task pane completely alone ------

herdr pane get "$TASK_PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the helper must never disturb the task's own pane"
[ -d "$WT" ] || fail "the helper must never touch the task's local worktree"
pass "real herdr: the task's own pane and worktree are untouched"
