#!/usr/bin/env bash
# Resolve a task's effective delivery mode and yolo flag: an explicit per-task
# override file first, falling through to the project's registry mode
# (bin/fm-project-mode.sh) when the override is absent or its mode token is
# "default". Prints two words to stdout: "<mode> <yolo>", the same shape
# fm-project-mode.sh prints.
#
# Override file: config/task-mode.<id>, one line, grammar "<mode> [+yolo]"
# using the exact same mode/yolo vocabulary fm-project-mode.sh parses
# (no-mistakes|direct-PR|local-only, optional +yolo). This mirrors the
# config/secondmate-harness precedent's per-id-then-global fallback shape
# (docs/configuration.md "Harness support").
#
# <id> is sanitized against [A-Za-z0-9_-]+ before being interpolated into a
# filename; an id containing any other character (e.g. "/" or "..") is
# treated as if no override file exists, so it can never escape config/ or
# read/write an unintended path.
#
# This override file is captain/firstmate-authored only - see
# docs/configuration.md "Delivery mode overrides" for the explicit-only,
# never-yolo-created authority rule. fm-project-mode.sh itself is unchanged
# and stays project-name-only. Neither fm-spawn.sh nor fm-brief.sh reads this
# override itself; both require an explicit --mode/--yolo at intake (AGENTS.md
# section 7), so the caller runs this script first and passes its result
# through those flags, keeping the brief text and state/<id>.meta agreeing.
#
# Usage: fm-task-mode.sh <task-id> <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

ID=${1:?usage: fm-task-mode.sh <task-id> <project-name>}
PROJ_NAME=${2:?usage: fm-task-mode.sh <task-id> <project-name>}

fallback() {
  "$SCRIPT_DIR/fm-project-mode.sh" "$PROJ_NAME"
}

case "$ID" in
  *[!A-Za-z0-9_-]*|'')
    fallback
    exit 0
    ;;
esac

OVERRIDE="$CONFIG/task-mode.$ID"
if [ ! -f "$OVERRIDE" ]; then
  fallback
  exit 0
fi

line=
while IFS= read -r raw || [ -n "$raw" ]; do
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [ -n "$raw" ] || continue
  case "$raw" in
    '#'*) continue ;;
  esac
  line="$raw"
  break
done < "$OVERRIDE"

if [ -z "$line" ]; then
  fallback
  exit 0
fi

# shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
set -- $line
mode=${1:-}
yolo=off
[ "${2:-}" = "+yolo" ] && yolo=on

if [ -z "$mode" ] || [ "$mode" = "default" ]; then
  fallback
  exit 0
fi

case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *)
    echo "warn: unknown mode \"$mode\" in $OVERRIDE; falling back to project default" >&2
    fallback
    exit 0
    ;;
esac

echo "$mode $yolo"
