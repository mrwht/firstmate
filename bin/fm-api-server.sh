#!/usr/bin/env bash
# fm-api-server.sh - lifecycle wrapper for bin/fm-api-server.mjs.
#
# This script owns process lifecycle only (start/stop/status/foreground and
# one-time token generation). The API contract itself - routes, auth model,
# bind-safety guard, config files - is owned once by fm-api-server.mjs's own
# header comment; this file does not restate it.
#
# Usage:
#   fm-api-server.sh init-token   generate config/api-token if one is not already present
#   fm-api-server.sh start        launch the server in the background (pid + log under state/)
#   fm-api-server.sh stop         stop a background server started with 'start'
#   fm-api-server.sh status       print running/stopped and the pid when running
#   fm-api-server.sh foreground   run the server in the foreground (Ctrl-C to stop)
#
# FM_HOME selects the home whose fleet this server exposes, exactly like every
# other bin/*.sh script; it is passed through to fm-api-server.mjs unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PIDFILE="$STATE/api-server.pid"
LOGFILE="$STATE/api-server.log"
SERVER_JS="$SCRIPT_DIR/fm-api-server.mjs"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

require_node() {
  command -v node >/dev/null 2>&1 || {
    echo "error: node is required to run fm-api-server.mjs" >&2
    exit 1
  }
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

cmd_init_token() {
  local token_file="$CONFIG/api-token"
  if [ -f "$token_file" ]; then
    echo "error: $token_file already exists; refusing to overwrite. Remove it first if you want a fresh token." >&2
    exit 1
  fi
  require_node
  mkdir -p "$CONFIG"
  local token
  token=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))')
  ( umask 077 && printf '%s' "$token" > "$token_file" )
  echo "wrote $token_file"
}

cmd_status() {
  if is_running; then
    echo "running: pid $(cat "$PIDFILE")"
  else
    echo "stopped"
  fi
}

cmd_start() {
  require_node
  if is_running; then
    echo "error: already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  mkdir -p "$STATE"
  local pid
  FM_HOME="$FM_HOME" nohup node "$SERVER_JS" >> "$LOGFILE" 2>&1 &
  pid=$!
  echo "$pid" > "$PIDFILE"
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    echo "error: server exited immediately; see $LOGFILE" >&2
    exit 1
  fi
  echo "started: pid $pid (log: $LOGFILE)"
}

cmd_stop() {
  if ! is_running; then
    rm -f "$PIDFILE"
    echo "not running"
    return 0
  fi
  local pid attempt
  pid=$(cat "$PIDFILE")
  kill "$pid"
  attempt=0
  while [ "$attempt" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "error: pid $pid did not exit after SIGTERM" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
  echo "stopped"
}

cmd_foreground() {
  require_node
  exec node "$SERVER_JS"
}

case "${1:-}" in
  init-token) cmd_init_token ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  foreground) cmd_foreground ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
