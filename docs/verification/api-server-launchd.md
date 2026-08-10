# fm-api-server.sh launchd durable-restart verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence that `bin/fm-api-server.sh install-launchd` actually makes the network API self-heal under real launchd, not just under the stubbed `launchctl` the portable regression suite (`tests/fm-api-server.test.sh`) uses.
`docs/api-server.md`'s "Durable restart (macOS)" section owns current setup and behavior.
This page only records the dated evidence.

## Kill-and-recover, macOS 26.5.2 (BuildVersion 25F84)

Verified 2026-08-09 with `bin/fm-api-server.sh` from this change, against a disposable sandbox `FM_HOME` (never the operator's real fleet home), using the real `launchctl`.

```sh
FM_HOME="$SANDBOX" bin/fm-api-server.sh init-token
echo 127.0.0.1 > "$SANDBOX/config/api-host"
echo "$PORT" > "$SANDBOX/config/api-port"
FM_HOME="$SANDBOX" bin/fm-api-server.sh install-launchd
sleep 2
FM_HOME="$SANDBOX" bin/fm-api-server.sh status
curl -s "http://127.0.0.1:$PORT/healthz"
```

Observed output:

```text
running: pid 37786
durable restart: installed (launchd label com.firstmate.api-server.d8a610688c49)
{"status":"ok"}
```

`launchctl print "gui/$(id -u)/com.firstmate.api-server.d8a610688c49"` confirmed `state = running`, the expected `foreground` argument (never `start`), and the installed `EnvironmentVariables` `PATH`/`FM_HOME`.

Crash recovery:

```sh
OLD_PID=$(cat "$SANDBOX/state/api-server.pid")
kill -9 "$OLD_PID"
# poll until healthz responds again
FM_HOME="$SANDBOX" bin/fm-api-server.sh status
```

Observed: launchd relaunched the server roughly 12s after the `SIGKILL` (within the configured 30s `ThrottleInterval`), reporting a new pid distinct from `OLD_PID`, and `GET /healthz` answered `{"status":"ok"}` again with no manual intervention.

```text
running: pid 97755
durable restart: installed (launchd label com.firstmate.api-server.d8a610688c49)
{"status":"ok"}
```

Clean-stop is not auto-relaunched:

```sh
FM_HOME="$SANDBOX" bin/fm-api-server.sh stop
sleep 20
FM_HOME="$SANDBOX" bin/fm-api-server.sh status
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/healthz"
```

Observed: `status` stayed `stopped` for the full 20s wait (well past the point a crash-driven relaunch would have landed) and `healthz` returned exit status `7` (connection refused, i.e. `000`), confirming `KeepAlive`'s `SuccessfulExit: false` correctly treats a deliberate `SIGTERM` as a clean exit it must not relaunch, while a `SIGKILL` crash is relaunched.

Cleanup: `FM_HOME="$SANDBOX" bin/fm-api-server.sh uninstall-launchd` removed the plist, and `launchctl print` subsequently reported the label unknown.
The sandbox `FM_HOME` was deleted, and this verification leaves no launchd agent registered on the host it ran on.
