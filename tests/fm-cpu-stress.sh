#!/usr/bin/env bash
# fm-cpu-stress.sh - bounded, self-expiring CPU load for reproducing
# load-sensitive test failures.
#
# Never start CPU load with `yes &` or unbounded loops; use this helper.
# Background cleanup such as `(yes & ...; sleep N; kill $(jobs -p)) &` is a
# no-op under zsh, and an agent's tool command runs in its own process group,
# so a killed caller leaks those workers indefinitely.
#
# Usage:
#   tests/fm-cpu-stress.sh [--workers N] [--seconds S]
#
#   --workers N   busy workers to start (default: logical CPU count;
#                 1 <= N <= 2x logical CPU count)
#   --seconds S   lifetime of every worker in seconds (default: 120;
#                 1 <= S <= 900)
#   -h, --help    print this header
#
# Each worker is `perl -e 'alarm shift; 1 while 1' S`, so the kernel ends it at
# the deadline even if this helper, the calling agent, or the pipeline is
# killed and the worker is reparented. The helper stays in the foreground,
# kills its workers on INT, TERM, or EXIT, and otherwise waits for them.
#
# Run the load in one terminal (or a backgrounded tool command) and the
# suspect test in another, for example:
#   tests/fm-cpu-stress.sh --workers 16 --seconds 300 &
#   bin/fm-test-run.sh tests/<subject>.test.sh
#
# Exit status: 0 after the workers expire or are stopped, 2 on bad arguments.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die_usage() {
  printf 'fm-cpu-stress: %s\n' "$*" >&2
  usage
  exit 2
}

cpu_count() {
  local n=
  case "$(uname -s)" in
    Darwin) n=$(sysctl -n hw.ncpu 2>/dev/null || true) ;;
    *) n=$(nproc 2>/dev/null || true) ;;
  esac
  case "$n" in
    '' | *[!0-9]* | 0) n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1) ;;
  esac
  printf '%s\n' "$n"
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

CPUS=$(cpu_count)
WORKERS=$CPUS
SECONDS_LIMIT=120

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workers)
      [ "$#" -ge 2 ] || die_usage "--workers requires a value"
      WORKERS=$2
      shift 2
      ;;
    --seconds)
      [ "$#" -ge 2 ] || die_usage "--seconds requires a value"
      SECONDS_LIMIT=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

is_uint "$WORKERS" || die_usage "--workers must be a positive integer, got: $WORKERS"
is_uint "$SECONDS_LIMIT" || die_usage "--seconds must be a positive integer, got: $SECONDS_LIMIT"
# Strip leading zeros so arithmetic never reads the values as octal.
WORKERS=$((10#$WORKERS))
SECONDS_LIMIT=$((10#$SECONDS_LIMIT))
max_workers=$((CPUS * 2))
if [ "$WORKERS" -lt 1 ] || [ "$WORKERS" -gt "$max_workers" ]; then
  die_usage "--workers must be between 1 and $max_workers (2x $CPUS CPUs), got: $WORKERS"
fi
if [ "$SECONDS_LIMIT" -lt 1 ] || [ "$SECONDS_LIMIT" -gt 900 ]; then
  die_usage "--seconds must be between 1 and 900, got: $SECONDS_LIMIT"
fi
command -v perl >/dev/null 2>&1 || {
  printf 'fm-cpu-stress: perl is required\n' >&2
  exit 2
}

PIDS=()

# shellcheck disable=SC2329 # invoked through the traps below
stop_workers() {
  trap - INT TERM EXIT
  if [ "${#PIDS[@]}" -gt 0 ]; then
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
}

trap stop_workers EXIT
trap 'stop_workers; exit 130' INT
trap 'stop_workers; exit 143' TERM

for _ in $(seq 1 "$WORKERS"); do
  perl -e 'alarm shift; 1 while 1' "$SECONDS_LIMIT" &
  PIDS+=("$!")
done

printf 'fm-cpu-stress: %s workers for %ss (pids %s)\n' \
  "$WORKERS" "$SECONDS_LIMIT" "${PIDS[*]}" >&2

# A worker ends by SIGALRM, so its non-zero status is the expected outcome.
wait "${PIDS[@]}" 2>/dev/null || true
PIDS=()
exit 0
