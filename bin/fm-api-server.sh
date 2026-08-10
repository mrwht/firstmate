#!/usr/bin/env bash
# fm-api-server.sh - lifecycle wrapper for bin/fm-api-server.mjs.
#
# This script owns process lifecycle only (start/stop/status/foreground and
# one-time token generation). The API contract itself - routes, auth model,
# bind-safety guard, config files - is owned once by fm-api-server.mjs's own
# header comment; this file does not restate it.
#
# Usage:
#   fm-api-server.sh init-token       generate config/api-token if one is not already present
#   fm-api-server.sh start            launch the server in the background (pid + log under state/)
#   fm-api-server.sh stop             stop a background server started with 'start'
#   fm-api-server.sh status           print running/stopped and the pid when running
#   fm-api-server.sh foreground       run the server in the foreground (Ctrl-C to stop)
#   fm-api-server.sh install-launchd  macOS only: register a launchd user agent that runs
#                                     'foreground' with RunAtLoad + KeepAlive, so the server
#                                     comes back after a crash or a reboot with no manual step.
#                                     Re-running replaces any previously installed agent for
#                                     this FM_HOME, so this is safe to repeat.
#   fm-api-server.sh uninstall-launchd  macOS only: unload and remove that launchd agent.
#
# FM_HOME selects the home whose fleet this server exposes, exactly like every
# other bin/*.sh script; it is passed through to fm-api-server.mjs unchanged.
#
# install-launchd / uninstall-launchd notes:
# - The generated agent's Label and plist filename are derived from a hash of
#   this FM_HOME's resolved absolute path, so distinct homes (e.g. a
#   secondmate) each get their own independent agent under the same
#   ~/Library/LaunchAgents directory without colliding.
# - It runs 'foreground' (never 'start'): launchd tracks the long-lived node
#   process directly via exec, so a crash is visible to KeepAlive. Wrapping
#   'start' instead would make launchd track the short-lived backgrounding
#   shell, which exits immediately every time and would either stop the
#   daemon from ever getting reported healthy or thrash it in a tight loop.
# - KeepAlive only restarts on a non-clean exit (crash, kill, or a startup
#   config refusal); a deliberate 'stop' (SIGTERM) exits 0 and launchd leaves
#   it stopped until the next login or reboot, when RunAtLoad starts it again.
# - ThrottleInterval bounds the restart rate so a persistent startup refusal
#   (e.g. a missing config/api-token) retries periodically instead of
#   spinning; see FM_API_LAUNCHD_THROTTLE_OVERRIDE below.
# - 'status' also reports whether a launchd agent is currently registered.
#
# Test-only overrides (same FM_*_OVERRIDE convention as FM_STATE_OVERRIDE):
#   FM_LAUNCHD_DIR_OVERRIDE       directory to write/remove the plist in,
#                                 instead of ~/Library/LaunchAgents
#   FM_LAUNCHCTL_OVERRIDE         launchctl binary to invoke, instead of the
#                                 real 'launchctl' (point at a stub for tests
#                                 that must not touch a real launchd session)
#   FM_API_LAUNCHD_THROTTLE_OVERRIDE  ThrottleInterval seconds, instead of 30
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PIDFILE="$STATE/api-server.pid"
LOGFILE="$STATE/api-server.log"
SERVER_JS="$SCRIPT_DIR/fm-api-server.mjs"
LAUNCHCTL="${FM_LAUNCHCTL_OVERRIDE:-launchctl}"
LAUNCHD_DIR="${FM_LAUNCHD_DIR_OVERRIDE:-$HOME/Library/LaunchAgents}"
LAUNCHD_THROTTLE="${FM_API_LAUNCHD_THROTTLE_OVERRIDE:-30}"

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

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || {
    echo "error: install-launchd/uninstall-launchd are macOS-only (launchd is not available on $(uname -s))" >&2
    exit 1
  }
}

# launchd_label: derived from a hash of this FM_HOME's resolved absolute path
# (same cd+pwd resolution FM_ROOT uses) so distinct invocations that name the
# same physical home never collide on one shared ~/Library/LaunchAgents.
launchd_label() {
  command -v shasum >/dev/null 2>&1 || {
    echo "error: shasum is required to derive the launchd agent label" >&2
    exit 1
  }
  local resolved_home
  resolved_home="$(cd "$FM_HOME" 2>/dev/null && pwd)" || resolved_home="$FM_HOME"
  printf 'com.firstmate.api-server.%s' "$(printf '%s' "$resolved_home" | shasum -a 256 | cut -c1-12)"
}

# xml_escape: escape XML-significant characters for safe interpolation into
# generated plist text content and attribute values.
xml_escape() {
  local s="$1"
  # bash's ${var//pat/repl} treats a literal '&' in repl as "the matched
  # text" (like sed), so every entity replacement below must escape its own
  # '&' as '\&' or it would reinsert the just-matched character instead of
  # the entity name.
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  s="${s//\'/\&apos;}"
  printf '%s' "$s"
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
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ -f "$LAUNCHD_DIR/$(launchd_label).plist" ]; then
      echo "durable restart: installed (launchd label $(launchd_label))"
    else
      echo "durable restart: not installed (run 'fm-api-server.sh install-launchd' to survive a crash or reboot)"
    fi
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
  if is_running; then
    echo "error: already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  mkdir -p "$STATE"
  # Record our own pid before exec so 'status' can see this process the same
  # way it sees one started with 'start' - exec replaces the process image
  # without forking, so $$ here is still the node process's pid afterward.
  # A launchd-managed agent runs this same path, so this is also what makes
  # 'status' reflect a launchd-supervised server.
  echo "$$" > "$PIDFILE"
  exec node "$SERVER_JS"
}

cmd_install_launchd() {
  require_macos
  require_node
  local label plist_path node_dir esc_label esc_script_dir esc_fm_home esc_node_dir esc_logfile
  label="$(launchd_label)"
  plist_path="$LAUNCHD_DIR/$label.plist"
  node_dir="$(dirname "$(command -v node)")"
  mkdir -p "$LAUNCHD_DIR"

  # The agent runs 'foreground' with RunAtLoad, so a still-running 'start'
  # instance would race it for the same port; stop it first, the same way
  # 'stop' would, so installing never leaves two servers contending.
  if is_running; then
    echo "stopping existing background instance (pid $(cat "$PIDFILE")) before installing durable restart..."
    cmd_stop
  fi

  # Idempotent reinstall: unload any previously installed agent for this
  # FM_HOME first so re-running this command safely picks up a changed
  # FM_HOME resolution, node path, or throttle setting.
  "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true

  esc_label="$(xml_escape "$label")"
  esc_script_dir="$(xml_escape "$SCRIPT_DIR")"
  esc_fm_home="$(xml_escape "$FM_HOME")"
  esc_node_dir="$(xml_escape "$node_dir")"
  esc_logfile="$(xml_escape "$LOGFILE")"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$esc_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$esc_script_dir/fm-api-server.sh</string>
    <string>foreground</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$esc_fm_home</string>
    <key>PATH</key>
    <string>$esc_node_dir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$esc_fm_home</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>$LAUNCHD_THROTTLE</integer>
  <key>StandardOutPath</key>
  <string>$esc_logfile</string>
  <key>StandardErrorPath</key>
  <string>$esc_logfile</string>
</dict>
</plist>
PLIST
  chmod 644 "$plist_path"
  mkdir -p "$STATE"

  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$plist_path"
  "$LAUNCHCTL" enable "gui/$(id -u)/$label"

  echo "installed: $plist_path (label $label)"
  echo "the server now restarts automatically on crash and after login/reboot; log: $LOGFILE"
  if [ ! -f "$CONFIG/api-token" ]; then
    echo "warning: $CONFIG/api-token does not exist yet; the agent will retry every ${LAUNCHD_THROTTLE}s" >&2
    echo "         and log a config error until you run 'fm-api-server.sh init-token'." >&2
  fi
}

cmd_uninstall_launchd() {
  require_macos
  local label plist_path
  label="$(launchd_label)"
  plist_path="$LAUNCHD_DIR/$label.plist"

  if [ ! -f "$plist_path" ]; then
    echo "not installed: $plist_path"
    return 0
  fi

  "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist_path"
  echo "uninstalled: $plist_path (label $label)"
}

case "${1:-}" in
  init-token) cmd_init_token ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  foreground) cmd_foreground ;;
  install-launchd) cmd_install_launchd ;;
  uninstall-launchd) cmd_uninstall_launchd ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
