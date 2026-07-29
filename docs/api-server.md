# Network API (bin/fm-api-server.mjs)

`bin/fm-api-server.mjs` is the single owner of the request/response contract, auth model, and bind-safety guard; this page is the operator-facing summary of setup and current behavior.
It serves exactly one firstmate home over HTTP, so a remote client - the kanban board's server, running on separate hardware such as a homelab Pi - can read the fleet snapshot and drive the same five mutations a local crewmate would, without shelling out to `bin/*.sh` on this machine directly.
`bin/fm-api-server.sh` manages the process (start/stop/status/foreground); it owns no part of the contract itself.

This reverses a deliberate local-only, no-auth design that predated it: a remote caller now needs a bearer token and a private-range bind address, where before there was no network surface at all.

## Setup

```sh
bin/fm-api-server.sh init-token   # writes config/api-token (0600, gitignored)
echo 100.x.y.z > config/api-host  # your Tailscale/VPN/private-LAN address; defaults to 127.0.0.1
echo 8787 > config/api-port       # optional; 8787 is the default
bin/fm-api-server.sh start        # background, pid+log under state/
bin/fm-api-server.sh status
bin/fm-api-server.sh stop
```

`bin/fm-api-server.sh foreground` runs it attached, for debugging or under an external process supervisor.

## Auth and reachability

Every route except `GET /healthz` requires `Authorization: Bearer <config/api-token contents>`.
Before binding, the server refuses to start unless `config/api-host` is loopback or a recognized private range (RFC1918, Tailscale's `100.64.0.0/10` CGNAT range, or an IPv6 ULA) - it will not silently listen on a bare public-looking address.
An empty `config/api-bind-override` file lifts that refusal for a host this classifier cannot verify (e.g. a VPN interface it does not recognize), printing a loud warning instead of proceeding silently.
This pairing - a shared token plus an enforced-by-default private-bind guard - is the captain-approved posture for a two-machine, single-operator setup: not a multi-tenant auth system, but not an unauthenticated endpoint reachable from the wider LAN either.

Token and bind config live under `$FM_HOME/config` (LOCAL, gitignored), exactly like every other per-home config item in `AGENTS.md` section 2.

## Surface

Read `bin/fm-api-server.mjs`'s own header comment for the exact route list, request/response shapes, and every wrapped script's flag mapping - it is the single source of truth and is not restated here.
In short: one read-only snapshot route, a ping-only live-update stream (see "Live updates" below), and five mutation routes, each wrapping one existing `bin/fm-*.sh` script by its own documented flags.
There is no generic command or path passthrough; an unverified harness name or a raw whitespace launch command (`bin/fm-spawn.sh`'s own escape hatch) is rejected before it ever reaches a script.

## Live updates

`GET /v1/stream` is a ping-only Server-Sent Events channel, gated by the exact same bearer token as every other route.
It never carries the snapshot payload itself: on a fleet-state change it emits `event: changed\ndata: {}\n\n`, and the client re-fetches `GET /v1/snapshot` to get the actual data.
This keeps `/v1/stream` a thin "wake me up" channel with no second serialization path to drift from `/v1/snapshot`'s own schema.
A comment-only `: ping\n\n` line every ~25s keeps idle-timeout network paths (VPN, proxies) from silently killing the connection; a client should treat any read timeout as a signal to reconnect and re-fetch the snapshot once, since a missed `changed` event during a drop is otherwise invisible.
Concurrent streams are capped at 8; a connection beyond the cap gets `503` instead of a stream.
This is the captain-confirmed tradeoff for the first cut (simplicity over pushing a full diff payload); revisit only if polling `/v1/snapshot` on every `changed` event proves costly in practice.

`GET /v1/snapshot` is served from the same background poll's cached snapshot rather than shelling out per request, so its response can lag real fleet state by up to the poll interval (currently 3s, the same `STREAM_POLL_MS` this section's poll uses for change detection).
The only shell-out on the snapshot path is a warm-up on the first request after server start; every request after that is served from cache.
If that warm-up fails, a later request retries it, backed off to at most once per poll interval so a sustained failure cannot pile up concurrent shell-outs.

## Verification

`tests/fm-api-server.test.sh` covers both startup refusals, the override path actually lifting the guard and listening, bearer-token auth, routing (unknown route, wrong method, malformed body), a real `GET /v1/snapshot` against an empty sandbox home, every mutation endpoint's validation layer plus its honest 502 pass-through from the real wrapped script, and `GET /v1/stream`'s auth gate, `changed` event, and connection cap.
`node --check bin/fm-api-server.mjs` verifies syntax; `bin/fm-lint.sh bin/fm-api-server.sh tests/fm-api-server.test.sh` covers the shell side.
