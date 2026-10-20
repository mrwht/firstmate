# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-10-15.
Shell: GNU bash 3.2.57 (macOS).
Comparison base: `main` at `ef7bdeb`.

The colocated unit suite `tests/fm-trace-context-lib.test.sh` (23 assertions) exercises validation (valid accepted; malformed, wrong-length, uppercase, all-zero, `ff` version, and shell-metacharacter values rejected), root minting with every mint a distinct sampled root and no parent-adoption input, the recovery reuse path with the recorded carrier winning over the ambient environment, default-off omission, the enable precedence of `FM_TRACE_CONTEXT` over `config/trace-context` with unset or empty deferring to the file, normalized home-session state, atomic replacement of a read-only prior record, stale-session rejection after failed publication, missing or invalid state defaulting off, the home-session boundary with later file state plus the per-task trace boundary (two resolves under one persistent ambient `TRACEPARENT` root two distinct traces and adopt neither), forced entropy failure omitting safely, and the minted-root fixed-shape check.

The spawn-path integration suite `tests/fm-trace-context-spawn.test.sh` (8 assertions), hermetic against an ambient `FM_TRACE_CONTEXT`, drives `bin/fm-spawn.sh` end to end with a fake tmux pane and a real isolated git worktree: enabled, one resolved carrier is recorded as `traceparent=` in the meta only after the identical `TRACEPARENT` export is sent before the launch literal; disabled, neither is written nor sent (only `GOTMPDIR` is); a failed carrier delivery leaves no `traceparent=` claim while the source task still launches; an unsafe delivery whose partial input cannot be cleared stops before appending the launch command; a failed metadata append removes the carrier from the launched task without aborting it; a relaunch reuses the recorded carrier verbatim; and spawns ignore later config and environment edits in favor of the frozen home-session decision.
The per-task boundary regression models a long-lived supervisor exactly: two unrelated tasks spawned sequentially from one home while the same fixed `TRACEPARENT` sits in the spawning environment (the supervisor's own launch-time carrier) record and inject valid carriers whose trace ids differ from each other and from the ambient carrier, and a relaunch of the first task reuses its original carrier verbatim for both the meta record and the injected export.
The suite touches no real harness or live fleet.
`tests/fm-session-start.test.sh` additionally proves only a lock-owning session start writes the effective state and a lock-refused read-only start leaves it unchanged.

```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
```

Run both trace-context suites from the repo root; each prints one `ok - ...` per assertion.
A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running fleet.
