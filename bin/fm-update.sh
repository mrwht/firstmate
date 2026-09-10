#!/usr/bin/env bash
# Self-update a running firstmate to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance the target only when it is a clean fast-forward, otherwise skip and
# report.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh.
#
# It does NOT re-read AGENTS.md itself - that is an LLM action the skill
# performs. The script's job is the safe git mechanics plus a parseable
# summary telling the caller what to do next:
#   - one status line for the target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
