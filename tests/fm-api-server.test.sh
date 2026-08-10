#!/usr/bin/env bash
# tests/fm-api-server.test.sh - bin/fm-api-server.mjs, the network-facing API
# for one firstmate home (docs/api-server.md).
#
# Covers: the two startup refusals (missing token, a bind host that is not
# loopback/private without an override), the override path actually lifting
# the refusal, bearer-token auth, routing (unknown route, wrong method,
# malformed body), the read-only snapshot endpoint against a real empty
# sandbox home, the snapshot cache's warm-hit latency and its cold-start
# single-flight warm-up contract, and every mutation endpoint's
# input-validation layer plus its honest 502 pass-through when the wrapped
# script fails against an empty sandbox (a nonexistent target/task/origin
# fails fast and side-effect-free in every wrapped script except
# fm-spawn.sh, so spawn is exercised at the validation layer only here - its
# own execution is already covered by the dedicated backend test suites),
# the bin/fm-api-server.sh lifecycle wrapper (init-token/start/status/stop),
# and install-launchd/uninstall-launchd's generated plist content and
# idempotency against a stubbed launchctl (real launchd behavior is recorded
# separately in docs/verification/api-server-launchd.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { pass "fm-api-server: node not available, skipping suite"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "fm-api-server: curl not available, skipping suite"; exit 0; }

SERVER_JS="$ROOT/bin/fm-api-server.mjs"
SERVER_PID=""
STREAM_SERVER_PID=""
PORT=$(( 20000 + (RANDOM % 20000) ))

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$STREAM_SERVER_PID" ] && kill "$STREAM_SERVER_PID" 2>/dev/null
  fm_test_cleanup
}
trap cleanup EXIT

new_sandbox() {
  local dir
  dir=$(fm_test_tmproot fm-api-server)
  mkdir -p "$dir/config"
  printf 'sandbox-token-%s\n' "$$" | tr -d '\n' > "$dir/config/api-token"
  printf '%s\n' "$dir"
}

start_server() {  # <sandbox> [extra env assignment]...
  local sandbox=$1
  shift
  env FM_HOME="$sandbox" "$@" node "$SERVER_JS" > "$sandbox/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited before becoming ready; log: $(cat "$sandbox/server.log")"
    sleep 0.1
  done
  fail "server never became ready on port $PORT; log: $(cat "$sandbox/server.log")"
}

start_stream_server() {  # <sandbox> <port>
  local sandbox=$1 port=$2
  env FM_HOME="$sandbox" FM_STREAM_POLL_MS_OVERRIDE=200 FM_STREAM_KEEPALIVE_MS_OVERRIDE=60000 \
    node "$SERVER_JS" > "$sandbox/stream-server.log" 2>&1 &
  STREAM_SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && return 0
    kill -0 "$STREAM_SERVER_PID" 2>/dev/null \
      || fail "stream server exited before becoming ready; log: $(cat "$sandbox/stream-server.log")"
    sleep 0.1
  done
  fail "stream server never became ready on port $port; log: $(cat "$sandbox/stream-server.log")"
}

stop_stream_server() {
  [ -n "${STREAM_SERVER_PID:-}" ] || return 0
  kill "$STREAM_SERVER_PID" 2>/dev/null || true
  wait "$STREAM_SERVER_PID" 2>/dev/null || true
  STREAM_SERVER_PID=""
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

TOKEN=""
BODY_FILE=""
LAST_CODE=""
LAST_BODY=""

http_req() {  # <method> <path> [token] [json-data]
  local method=$1 path=$2 token=${3:-} data=${4:-}
  BODY_FILE=$(mktemp)
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$method")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" -d "$data")
  fi
  args+=("http://127.0.0.1:$PORT$path")
  LAST_CODE=$(curl "${args[@]}")
  LAST_BODY=$(cat "$BODY_FILE")
  rm -f "$BODY_FILE"
}

# --- startup refusals (no long-lived server needed) -------------------------

test_refuses_to_start_without_token() {
  local sandbox out code
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  out=$(FM_HOME="$sandbox" node "$SERVER_JS" 2>&1); code=$?
  expect_code 1 "$code" "missing token"
  assert_contains "$out" "config/api-token is missing" "missing-token error message"
  pass "fm-api-server: refuses to start with no config/api-token"
}

test_refuses_to_start_on_public_looking_bind_without_override() {
  local sandbox out code
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  echo token > "$sandbox/config/api-token"
  echo "0.0.0.0" > "$sandbox/config/api-host"
  out=$(FM_HOME="$sandbox" node "$SERVER_JS" 2>&1); code=$?
  expect_code 1 "$code" "unguarded public-looking bind"
  assert_contains "$out" "not loopback or a recognized private range" "bind-guard error message"
  pass "fm-api-server: refuses a non-private config/api-host without config/api-bind-override"
}

test_override_lifts_bind_guard_and_actually_listens() {
  local sandbox port
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  echo token > "$sandbox/config/api-token"
  echo "0.0.0.0" > "$sandbox/config/api-host"
  port=$(( 20000 + (RANDOM % 20000) ))
  echo "$port" > "$sandbox/config/api-port"
  : > "$sandbox/config/api-bind-override"
  FM_HOME="$sandbox" node "$SERVER_JS" > "$sandbox/server.log" 2>&1 &
  local pid=$!
  local ready=0
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && { ready=1; break; }
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$ready" -eq 1 ] || fail "override server never became ready; log: $(cat "$sandbox/server.log")"
  assert_contains "$(cat "$sandbox/server.log")" "config/api-bind-override is present" "override warning printed"
  pass "fm-api-server: config/api-bind-override lifts the guard and the server actually listens"
}

test_refuses_to_start_without_token
test_refuses_to_start_on_public_looking_bind_without_override
test_override_lifts_bind_guard_and_actually_listens

# --- long-lived server for the remaining suite -------------------------------

SANDBOX=$(new_sandbox)
TOKEN=$(cat "$SANDBOX/config/api-token")
echo "$PORT" > "$SANDBOX/config/api-port"
start_server "$SANDBOX"

test_healthz_requires_no_auth() {
  http_req GET /healthz
  expect_code 200 "$LAST_CODE" "healthz"
  assert_contains "$LAST_BODY" '"status":"ok"' "healthz body"
  pass "fm-api-server: GET /healthz needs no auth"
}

test_auth_required_on_protected_route() {
  http_req GET /v1/snapshot
  expect_code 401 "$LAST_CODE" "snapshot without auth"
  http_req GET /v1/snapshot "wrong-token"
  expect_code 401 "$LAST_CODE" "snapshot with wrong token"
  http_req GET /v1/snapshot "$TOKEN"
  expect_code 200 "$LAST_CODE" "snapshot with correct token"
  pass "fm-api-server: protected routes require the exact bearer token"
}

test_snapshot_returns_real_schema() {
  http_req GET /v1/snapshot "$TOKEN"
  expect_code 200 "$LAST_CODE" "snapshot"
  assert_contains "$LAST_BODY" '"schema":"fm-fleet-snapshot.v1"' "snapshot schema field"
  pass "fm-api-server: GET /v1/snapshot returns the real fm-fleet-snapshot.sh --json schema"
}

test_snapshot_served_from_cache_after_warmup() {
  # $SANDBOX's server already answered a GET /v1/snapshot above (test order,
  # not a fresh assumption here), so streamState.lastSnapshot is warm and this
  # request must be served from it with no per-request shell-out: a bare
  # JSON.stringify of a cached object, not a subprocess spawn, so it should
  # complete in well under the time a fresh bin/fm-fleet-snapshot.sh --json
  # shell-out takes (a bash process plus several jq invocations).
  local started ended elapsed_ms
  started=$(date +%s%N)
  http_req GET /v1/snapshot "$TOKEN"
  ended=$(date +%s%N)
  expect_code 200 "$LAST_CODE" "warm snapshot"
  elapsed_ms=$(( (ended - started) / 1000000 ))
  [ "$elapsed_ms" -lt 300 ] \
    || fail "warm GET /v1/snapshot took ${elapsed_ms}ms, expected well under 300ms for a cache hit"
  pass "fm-api-server: GET /v1/snapshot is served from the warm cache with no per-request shell-out"
}

test_snapshot_cold_start_single_flight() {
  # A fresh server has no warm streamState.lastSnapshot yet. The first
  # request(s) after start must block on the real snapshot (never serve a
  # placeholder), and concurrent first requests must share exactly one
  # warm-up shell-out rather than each triggering their own. A large poll
  # interval keeps the background poll from also firing during the window.
  local sandbox port
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  printf 'cold-token-%s' "$$" > "$sandbox/config/api-token"
  port=$(( 20000 + (RANDOM % 20000) ))
  echo "$port" > "$sandbox/config/api-port"
  env FM_HOME="$sandbox" FM_STREAM_POLL_MS_OVERRIDE=60000 \
    node "$SERVER_JS" > "$sandbox/cold-server.log" 2>&1 &
  local pid=$!
  local ready=0
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && { ready=1; break; }
    kill -0 "$pid" 2>/dev/null || fail "cold-start server exited before becoming ready; log: $(cat "$sandbox/cold-server.log")"
    sleep 0.1
  done
  [ "$ready" -eq 1 ] || fail "cold-start server never became ready; log: $(cat "$sandbox/cold-server.log")"
  local token
  token=$(cat "$sandbox/config/api-token")

  local out1 out2 out3
  out1=$(mktemp); out2=$(mktemp); out3=$(mktemp)
  curl -s -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot" > "$out1" &
  local p1=$!
  curl -s -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot" > "$out2" &
  local p2=$!
  curl -s -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot" > "$out3" &
  local p3=$!

  # Direct children of the server's own pid, so this only ever counts
  # subprocesses this test's own server spawned, never another lane's work.
  local max_seen=0 n
  for _ in $(seq 1 100); do
    n=$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt "$max_seen" ] && max_seen=$n
    kill -0 "$p1" 2>/dev/null || kill -0 "$p2" 2>/dev/null || kill -0 "$p3" 2>/dev/null || break
    sleep 0.02
  done

  wait "$p1" "$p2" "$p3" 2>/dev/null
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local b1 b2 b3
  b1=$(cat "$out1"); b2=$(cat "$out2"); b3=$(cat "$out3")
  rm -f "$out1" "$out2" "$out3"

  assert_contains "$b1" '"schema":"fm-fleet-snapshot.v1"' "cold-start request got the real snapshot, not a placeholder"
  [ "$b1" = "$b2" ] && [ "$b2" = "$b3" ] || fail "concurrent cold-start requests returned different bodies"
  [ "$max_seen" -le 1 ] \
    || fail "expected at most 1 concurrent warm-up subprocess during cold start, saw $max_seen"

  pass "fm-api-server: concurrent cold-start GET /v1/snapshot requests await one shared warm-up, never a placeholder"
}

test_snapshot_backoff_on_sustained_failure() {
  # When bin/fm-fleet-snapshot.sh keeps failing, streamState.lastSnapshot
  # never warms up, so every GET /v1/snapshot would otherwise re-trigger its
  # own warm-up shell-out (a thundering herd on sustained failure). A broken
  # jq placed ahead of the real one on PATH makes the wrapped script fail
  # fast and deterministically, and each real invocation appends a line to
  # $jq_log, so counting that log's lines tells us whether a request
  # actually re-ran the script or was served from the in-flight backoff skip.
  local sandbox port
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config" "$sandbox/fakebin"
  printf 'backoff-token-%s' "$$" > "$sandbox/config/api-token"
  port=$(( 20000 + (RANDOM % 20000) ))
  echo "$port" > "$sandbox/config/api-port"

  local jq_log="$sandbox/jq-calls.log"
  : > "$jq_log"
  cat > "$sandbox/fakebin/jq" <<EOF
#!/bin/sh
echo x >> "$jq_log"
exit 1
EOF
  chmod +x "$sandbox/fakebin/jq"

  env FM_HOME="$sandbox" FM_STREAM_POLL_MS_OVERRIDE=800 \
    PATH="$sandbox/fakebin:$PATH" \
    node "$SERVER_JS" > "$sandbox/backoff-server.log" 2>&1 &
  local pid=$!
  local ready=0
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && { ready=1; break; }
    kill -0 "$pid" 2>/dev/null || fail "backoff server exited before becoming ready; log: $(cat "$sandbox/backoff-server.log")"
    sleep 0.1
  done
  [ "$ready" -eq 1 ] || fail "backoff server never became ready; log: $(cat "$sandbox/backoff-server.log")"
  local token
  token=$(cat "$sandbox/config/api-token")

  local code1
  code1=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot")
  local calls_after_first
  calls_after_first=$(wc -l < "$jq_log" | tr -d ' ')
  [ "$calls_after_first" -gt 0 ] || fail "expected the broken jq to be invoked by the first failing snapshot warm-up"

  # Immediately re-request, still well inside the 800ms backoff window: must
  # not spawn another bin/fm-fleet-snapshot.sh warm-up.
  local code2
  code2=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot")
  local calls_after_second
  calls_after_second=$(wc -l < "$jq_log" | tr -d ' ')

  sleep 0.9

  local code3
  code3=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/snapshot")
  local calls_after_third
  calls_after_third=$(wc -l < "$jq_log" | tr -d ' ')

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  expect_code 502 "$code1" "sustained-failure snapshot (first)"
  expect_code 502 "$code2" "sustained-failure snapshot (immediate retry)"
  expect_code 502 "$code3" "sustained-failure snapshot (after backoff window)"
  [ "$calls_after_second" -eq "$calls_after_first" ] \
    || fail "expected no new warm-up during the backoff window, but jq call count went from $calls_after_first to $calls_after_second"
  [ "$calls_after_third" -gt "$calls_after_second" ] \
    || fail "expected a fresh warm-up attempt once the backoff window elapsed, but jq call count stayed at $calls_after_second"

  pass "fm-api-server: GET /v1/snapshot backs off repeated warm-up retries during sustained failure, then retries after the poll interval"
}

test_unknown_route_and_wrong_method() {
  http_req GET /nope "$TOKEN"
  expect_code 404 "$LAST_CODE" "unknown route"
  http_req POST /v1/snapshot "$TOKEN"
  expect_code 405 "$LAST_CODE" "wrong method on known route"
  pass "fm-api-server: unknown routes 404, wrong methods on known routes 405"
}

test_malformed_json_body_is_400() {
  http_req POST /v1/send "$TOKEN" "not json"
  expect_code 400 "$LAST_CODE" "malformed json"
  assert_contains "$LAST_BODY" "valid JSON" "malformed json message"
  pass "fm-api-server: a malformed JSON body is 400"
}

test_send_validation_and_pass_through() {
  http_req POST /v1/send "$TOKEN" '{"text":"hi"}'
  expect_code 400 "$LAST_CODE" "send missing target"
  http_req POST /v1/send "$TOKEN" '{"target":"nope","text":"line one\nline two"}'
  expect_code 400 "$LAST_CODE" "send multi-line text"
  http_req POST /v1/send "$TOKEN" '{"target":"nope","text":"hi"}'
  expect_code 502 "$LAST_CODE" "send against nonexistent target"
  assert_contains "$LAST_BODY" "stderr" "send 502 carries stderr"
  pass "fm-api-server: /v1/send validates input and surfaces real fm-send.sh failures"
}

test_promote_validation_and_pass_through() {
  http_req POST /v1/promote "$TOKEN" '{"taskId":"not a slug"}'
  expect_code 400 "$LAST_CODE" "promote bad slug"
  http_req POST /v1/promote "$TOKEN" '{"taskId":"nonexistent-task"}'
  expect_code 502 "$LAST_CODE" "promote nonexistent task"
  assert_contains "$LAST_BODY" "no meta for task" "promote 502 stderr detail"
  pass "fm-api-server: /v1/promote validates input and surfaces real fm-promote.sh failures"
}

test_pr_merge_validation_and_pass_through() {
  http_req POST /v1/pr-merge "$TOKEN" '{"taskId":"a","prUrl":"not-a-url"}'
  expect_code 400 "$LAST_CODE" "pr-merge bad url"
  http_req POST /v1/pr-merge "$TOKEN" '{"taskId":"nonexistent","prUrl":"https://github.com/o/r/pull/1"}'
  expect_code 502 "$LAST_CODE" "pr-merge nonexistent task"
  pass "fm-api-server: /v1/pr-merge validates the PR URL and surfaces real fm-pr-merge.sh failures"
}

test_decision_hold_validation_and_pass_through() {
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"a","decisionKey":"k","decision":"x"}'
  expect_code 400 "$LAST_CODE" "decision-hold missing routedTo"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"nope","decisionKey":"k","decision":"x","routedTo":["a"]}'
  expect_code 502 "$LAST_CODE" "decision-hold nonexistent origin"
  assert_contains "$LAST_BODY" "absent from" "decision-hold 502 stderr detail"
  pass "fm-api-server: /v1/decision-hold/resolve validates input and surfaces real fm-decision-hold.sh failures"
}

test_spawn_rejects_unverified_harness_and_raw_command() {
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"foo","harness":"; rm -rf /"}'
  expect_code 400 "$LAST_CODE" "spawn raw-command harness"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"foo","harness":"unverified-thing"}'
  expect_code 400 "$LAST_CODE" "spawn unverified harness"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"foo","effort":"ludicrous"}'
  expect_code 400 "$LAST_CODE" "spawn bad effort"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"../../etc"}'
  expect_code 400 "$LAST_CODE" "spawn path traversal"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a"}'
  expect_code 400 "$LAST_CODE" "spawn missing projectDir"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"..","projectDir":"foo"}'
  expect_code 400 "$LAST_CODE" "spawn taskId dot-dot"
  pass "fm-api-server: /v1/spawn never lets a raw launch command, unverified harness, bad effort, or path traversal through"
}

test_slug_fields_reject_dot_segments() {
  http_req POST /v1/promote "$TOKEN" '{"taskId":".."}'
  expect_code 400 "$LAST_CODE" "promote taskId dot-dot"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"..","decisionKey":"k","decision":"x","routedTo":["a"]}'
  expect_code 400 "$LAST_CODE" "decision-hold originId dot-dot"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"a","decisionKey":"..","decision":"x","routedTo":["a"]}'
  expect_code 400 "$LAST_CODE" "decision-hold decisionKey dot-dot"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"a","decisionKey":"k","decision":"x","routedTo":[".."]}'
  expect_code 400 "$LAST_CODE" "decision-hold routedTo dot-dot"
  pass "fm-api-server: taskId/originId/decisionKey/routedTo slug fields reject the literal '..' segment"
}

test_stream_requires_auth() {
  http_req GET /v1/stream
  expect_code 401 "$LAST_CODE" "stream without auth"
  http_req GET /v1/stream "wrong-token"
  expect_code 401 "$LAST_CODE" "stream with wrong token"
  pass "fm-api-server: GET /v1/stream requires the same bearer auth as every other route"
}

test_stream_emits_changed_on_snapshot_mutation() {
  local sandbox port out
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  printf 'stream-token-%s' "$$" > "$sandbox/config/api-token"
  port=$(( 20000 + (RANDOM % 20000) ))
  echo "$port" > "$sandbox/config/api-port"
  start_stream_server "$sandbox" "$port"
  local token
  token=$(cat "$sandbox/config/api-token")

  local stream_out
  stream_out=$(mktemp)
  (
    curl -s -N --max-time 5 \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:$port/v1/stream" > "$stream_out"
  ) &
  local curl_pid=$!

  sleep 0.5
  mkdir -p "$sandbox/data"
  printf '## Queued\n- mutation-%s - test mutation (added 2026-01-01)\n' "$$" > "$sandbox/data/backlog.md"

  wait "$curl_pid" 2>/dev/null
  out=$(cat "$stream_out")
  rm -f "$stream_out"
  stop_stream_server

  assert_contains "$out" "event: changed" "stream emitted a changed event after a snapshot-visible mutation"
  pass "fm-api-server: GET /v1/stream pushes event: changed after fleet state changes"
}

test_stream_enforces_connection_cap() {
  local sandbox port pids code
  sandbox=$(fm_test_tmproot fm-api-server)
  mkdir -p "$sandbox/config"
  printf 'cap-token-%s' "$$" > "$sandbox/config/api-token"
  port=$(( 20000 + (RANDOM % 20000) ))
  echo "$port" > "$sandbox/config/api-port"
  start_stream_server "$sandbox" "$port"
  local token
  token=$(cat "$sandbox/config/api-token")

  pids=()
  for _ in $(seq 1 8); do
    curl -s -N --max-time 5 -H "Authorization: Bearer $token" \
      "http://127.0.0.1:$port/v1/stream" > /dev/null &
    pids+=("$!")
  done
  sleep 0.5

  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
    "http://127.0.0.1:$port/v1/stream")

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null
  done
  stop_stream_server

  expect_code 503 "$code" "stream beyond the connection cap"
  pass "fm-api-server: GET /v1/stream enforces its connection cap"
}

test_slug_and_path_fields_reject_leading_dash() {
  http_req POST /v1/promote "$TOKEN" '{"taskId":"--help"}'
  expect_code 400 "$LAST_CODE" "promote taskId leading dash"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"--foo","decisionKey":"k","decision":"x","routedTo":["a"]}'
  expect_code 400 "$LAST_CODE" "decision-hold originId leading dash"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"a","decisionKey":"--foo","decision":"x","routedTo":["a"]}'
  expect_code 400 "$LAST_CODE" "decision-hold decisionKey leading dash"
  http_req POST /v1/decision-hold/resolve "$TOKEN" '{"originId":"a","decisionKey":"k","decision":"x","routedTo":["--foo"]}'
  expect_code 400 "$LAST_CODE" "decision-hold routedTo leading dash"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"--verbose"}'
  expect_code 400 "$LAST_CODE" "spawn projectDir leading dash"
  http_req POST /v1/spawn "$TOKEN" '{"taskId":"a","projectDir":"foo","model":"--bar"}'
  expect_code 400 "$LAST_CODE" "spawn model leading dash"
  pass "fm-api-server: taskId/originId/decisionKey/routedTo/projectDir/model fields reject a leading '-'"
}

test_healthz_requires_no_auth
test_auth_required_on_protected_route
test_snapshot_returns_real_schema
test_snapshot_served_from_cache_after_warmup
test_snapshot_cold_start_single_flight
test_snapshot_backoff_on_sustained_failure
test_unknown_route_and_wrong_method
test_malformed_json_body_is_400
test_send_validation_and_pass_through
test_promote_validation_and_pass_through
test_pr_merge_validation_and_pass_through
test_decision_hold_validation_and_pass_through
test_spawn_rejects_unverified_harness_and_raw_command
test_stream_requires_auth
test_stream_emits_changed_on_snapshot_mutation
test_stream_enforces_connection_cap
test_slug_fields_reject_dot_segments
test_slug_and_path_fields_reject_leading_dash

stop_server

# --- bin/fm-api-server.sh lifecycle wrapper ---------------------------------

test_sh_wrapper_lifecycle() {
  local sandbox wrapper_port wrapper out ready
  sandbox=$(fm_test_tmproot fm-api-server)
  wrapper="$ROOT/bin/fm-api-server.sh"
  wrapper_port=$(( 20000 + (RANDOM % 20000) ))

  FM_HOME="$sandbox" "$wrapper" init-token >/dev/null \
    || fail "init-token should succeed when no token exists yet"
  assert_present "$sandbox/config/api-token" "init-token should write config/api-token"
  FM_HOME="$sandbox" "$wrapper" init-token >/dev/null 2>&1 \
    && fail "init-token should refuse to overwrite an existing token"

  echo "$wrapper_port" > "$sandbox/config/api-port"

  out=$(FM_HOME="$sandbox" "$wrapper" status)
  assert_contains "$out" "stopped" "status should report stopped before start"

  FM_HOME="$sandbox" "$wrapper" start >/dev/null \
    || fail "start should succeed"
  assert_present "$sandbox/state/api-server.pid" "start should write a pid file"

  ready=0
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$wrapper_port/healthz" 2>/dev/null && { ready=1; break; }
    sleep 0.1
  done
  [ "$ready" -eq 1 ] || fail "server started via fm-api-server.sh start never became healthy"

  out=$(FM_HOME="$sandbox" "$wrapper" status)
  assert_contains "$out" "running" "status should report running while the server is up"

  FM_HOME="$sandbox" "$wrapper" start >/dev/null 2>&1 \
    && fail "start should refuse to launch a second instance"

  FM_HOME="$sandbox" "$wrapper" stop >/dev/null \
    || fail "stop should succeed"
  curl -s -o /dev/null "http://127.0.0.1:$wrapper_port/healthz" 2>/dev/null \
    && fail "server should no longer respond after stop"
  out=$(FM_HOME="$sandbox" "$wrapper" status)
  assert_contains "$out" "stopped" "status should report stopped after stop"

  pass "fm-api-server.sh: init-token, start, status, and stop behave correctly"
}

test_sh_wrapper_lifecycle

# --- bin/fm-api-server.sh install-launchd / uninstall-launchd --------------
#
# These exercise only the plist-generation and launchctl-invocation logic,
# against FM_LAUNCHD_DIR_OVERRIDE and a stubbed FM_LAUNCHCTL_OVERRIDE, so the
# suite never touches a real launchd session. A real kill -9-and-recover
# verification against actual launchd lives in
# docs/verification/api-server-launchd.md.

test_launchd_non_macos_refusal() {
  if [ "$(uname -s)" = "Darwin" ]; then
    pass "fm-api-server.sh: install-launchd non-macOS refusal not exercised on Darwin"
    return 0
  fi
  local sandbox wrapper out
  sandbox=$(fm_test_tmproot fm-api-server)
  wrapper="$ROOT/bin/fm-api-server.sh"
  out=$(FM_HOME="$sandbox" "$wrapper" install-launchd 2>&1) \
    && fail "install-launchd should refuse on non-macOS"
  assert_contains "$out" "macOS-only" "install-launchd should explain the macOS-only refusal"
  pass "fm-api-server.sh: install-launchd refuses cleanly on non-macOS"
}

test_launchd_plist_and_lifecycle() {
  if [ "$(uname -s)" != "Darwin" ]; then
    pass "fm-api-server.sh: launchd plist generation skipped (not macOS)"
    return 0
  fi
  command -v shasum >/dev/null 2>&1 || { pass "fm-api-server.sh: launchd plist generation skipped (no shasum)"; return 0; }

  local sandbox wrapper launchd_dir fake_launchctl out label plist
  sandbox=$(fm_test_tmproot fm-api-server)
  wrapper="$ROOT/bin/fm-api-server.sh"
  launchd_dir="$sandbox/launchagents"
  mkdir -p "$launchd_dir"

  fake_launchctl="$sandbox/fake-launchctl"
  cat > "$fake_launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/launchctl.log"
exit 0
FAKE
  chmod +x "$fake_launchctl"

  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" FM_LAUNCHCTL_OVERRIDE="$fake_launchctl" "$wrapper" install-launchd 2>&1) \
    || fail "install-launchd should succeed with a stubbed launchctl"
  assert_contains "$out" "installed:" "install-launchd should report the installed plist path"
  assert_contains "$out" "config/api-token" "install-launchd should warn about a missing api-token"

  plist=$(find "$launchd_dir" -name '*.plist')
  [ -n "$plist" ] || fail "install-launchd should write exactly one plist"
  label=$(basename "$plist" .plist)

  assert_grep "<string>$sandbox</string>" "$plist" "plist should bind FM_HOME to this sandbox"
  assert_grep "<string>foreground</string>" "$plist" "plist should launch the foreground subcommand, not start"
  assert_grep "<key>RunAtLoad</key>" "$plist" "plist should set RunAtLoad"
  assert_grep "<key>KeepAlive</key>" "$plist" "plist should set KeepAlive"
  assert_grep "<key>SuccessfulExit</key>" "$plist" "plist KeepAlive should key off SuccessfulExit so a clean stop is not relaunched"
  assert_grep "<key>ThrottleInterval</key>" "$plist" "plist should set a ThrottleInterval to bound the restart rate"

  assert_grep "bootstrap gui/$(id -u) $plist" "$sandbox/launchctl.log" "install-launchd should bootstrap the agent"
  assert_grep "enable gui/$(id -u)/$label" "$sandbox/launchctl.log" "install-launchd should enable the agent"

  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" "$wrapper" status)
  assert_contains "$out" "durable restart: installed" "status should report the agent as installed"

  : > "$sandbox/launchctl.log"
  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" FM_LAUNCHCTL_OVERRIDE="$fake_launchctl" "$wrapper" install-launchd) \
    || fail "re-running install-launchd should be idempotent"
  assert_grep "bootout gui/$(id -u)/$label" "$sandbox/launchctl.log" "reinstalling should bootout the previous agent first"

  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" FM_LAUNCHCTL_OVERRIDE="$fake_launchctl" "$wrapper" uninstall-launchd) \
    || fail "uninstall-launchd should succeed"
  assert_contains "$out" "uninstalled:" "uninstall-launchd should report removal"
  assert_absent "$plist" "uninstall-launchd should remove the plist file"

  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" "$wrapper" status)
  assert_contains "$out" "durable restart: not installed" "status should report the agent as not installed after uninstall"

  out=$(FM_HOME="$sandbox" FM_LAUNCHD_DIR_OVERRIDE="$launchd_dir" FM_LAUNCHCTL_OVERRIDE="$fake_launchctl" "$wrapper" uninstall-launchd) \
    || fail "uninstall-launchd should be a no-op success when nothing is installed"
  assert_contains "$out" "not installed:" "uninstall-launchd should report nothing to remove"

  pass "fm-api-server.sh: install-launchd/uninstall-launchd generate a correct, idempotent launchd agent"
}

test_launchd_non_macos_refusal
test_launchd_plist_and_lifecycle
