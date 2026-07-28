#!/usr/bin/env node
// fm-api-server.mjs - network-facing HTTP API for one firstmate home.
//
// This is the single owner of firstmate's remote fleet API: the exact routes,
// request/response shapes, auth model, and bind-safety contract described here
// are not restated elsewhere. bin/fm-api-server.sh only manages this process's
// lifecycle (start/stop/status/foreground); it does not duplicate this
// contract. docs/api-server.md is the operator-facing summary and points back
// here for exact behavior.
//
// SCOPE: this process serves exactly one firstmate home - the FM_HOME it is
// started with, resolved exactly like every bin/*.sh script (FM_HOME env var,
// falling back to this repo root). It never accepts a client-supplied home or
// path outside the fixed set of arguments each wrapped script already takes.
// A second home (e.g. a secondmate) needs its own server instance on its own
// port; this file deliberately does not grow a home-selector endpoint.
//
// AUTH: every route except GET /healthz requires
//   Authorization: Bearer <token>
// where <token> is the contents of config/api-token (LOCAL, gitignored, no
// default - the server refuses to start without one). The comparison hashes
// both sides first so a length mismatch never leaks timing information, then
// uses crypto.timingSafeEqual. There is no per-client identity: this is a
// single shared secret for one trusted operator's own tooling, mirroring the
// existing FMX_PAIRING_TOKEN bearer-token pattern (docs/configuration.md,
// "X mode (.env)") rather than inventing a new auth idiom.
//
// BIND SAFETY: config/api-host (default 127.0.0.1) and config/api-port
// (default 8787) choose the listen address. Before binding, the server
// refuses to start unless the host is loopback or a recognized private range
// (RFC1918 10/8, 172.16/12, 192.168/16; Tailscale's CGNAT 100.64.0.0/10; IPv6
// ::1 and the fc00::/7 ULA range) - never a bare public-looking address by
// default. config/api-bind-override (presence-only, empty file) is the
// explicit operator acknowledgement that lifts this refusal for a host this
// classifier cannot verify (e.g. a VPN interface it does not recognize, or a
// deliberate 0.0.0.0); it still prints a loud warning rather than proceeding
// silently. This is Captain-decided Option B from the kanban-network-api
// decision: token auth plus an enforced-by-default private-bind guard.
//
// MUTATION SURFACE: exactly six routes wrap exactly six existing scripts by
// their own documented flags - never a generic command or path passthrough:
//   GET  /healthz                     liveness only, no auth, no fleet data
//   GET  /v1/snapshot                 bin/fm-fleet-snapshot.sh --json
//   POST /v1/send                     bin/fm-send.sh <target> <text|--key K>
//   POST /v1/decision-hold/resolve    bin/fm-decision-hold.sh resolve ...
//   POST /v1/promote                  bin/fm-promote.sh <task-id>
//   POST /v1/spawn                    bin/fm-spawn.sh <task-id> ...
//   POST /v1/pr-merge                 bin/fm-pr-merge.sh <task-id> <pr-url>
// Every script invocation uses child_process.execFile with an explicit
// argument array (never a shell string), so request content can never be
// interpreted as shell syntax regardless of validation. Validation below is
// therefore about honest error surfacing and about closing off fm-spawn.sh's
// own documented escape hatches (an unverified harness name, or a raw
// whitespace-containing launch command) rather than about injection safety.
//
// Request bodies are capped at MAX_BODY_BYTES and must be a JSON object.
// Every non-2xx response is JSON: {"error": "<message>"[, "stderr": "<...>"]}.
// A wrapped script's stderr is truncated to MAX_STDERR_BYTES before it is
// echoed back - this API has exactly one trusted caller (the token holder),
// so surfacing the real failure reason is more useful than hiding it.
//
// Config files (all under $FM_HOME/config, all LOCAL/gitignored):
//   api-token         required bearer token, no default
//   api-host          bind host, default 127.0.0.1
//   api-port          bind port, default 8787
//   api-bind-override presence-only flag lifting the private-bind refusal
//
// Env overrides for tests, matching the FM_*_OVERRIDE convention used across
// bin/*.sh: FM_HOME, FM_CONFIG_OVERRIDE.
//
// Verify syntax with: node --check bin/fm-api-server.mjs

import http from "node:http";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const FM_ROOT = path.resolve(SCRIPT_DIR, "..");
export const FM_HOME = process.env.FM_HOME
  ? path.resolve(process.env.FM_HOME)
  : FM_ROOT;
export const CONFIG_DIR = process.env.FM_CONFIG_OVERRIDE
  ? path.resolve(process.env.FM_CONFIG_OVERRIDE)
  : path.join(FM_HOME, "config");

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 8787;
const MAX_BODY_BYTES = 65536;
const MAX_STDERR_BYTES = 4096;
const SLUG_RE = /^[A-Za-z0-9._-]+$/;
const EFFORT_VALUES = new Set(["low", "medium", "high", "xhigh", "max"]);
const SEND_KEYS = new Set(["Enter", "Escape", "C-c"]);
// The verified harness set from AGENTS.md section 4 - never dispatch on an
// unverified adapter, and never accept fm-spawn.sh's whitespace-containing
// raw-launch-command escape hatch from a remote caller.
const VERIFIED_HARNESSES = new Set([
  "claude",
  "codex",
  "opencode",
  "pi",
  "pi-signed",
  "grok",
  "kimi",
]);
const BACKEND_VALUES = new Set(["tmux", "herdr", "zellij", "orca", "cmux"]);
const KNOWN_ROUTES = new Set([
  "/v1/snapshot",
  "/v1/send",
  "/v1/decision-hold/resolve",
  "/v1/promote",
  "/v1/spawn",
  "/v1/pr-merge",
]);

// --- config -----------------------------------------------------------------

function readConfigValue(name) {
  try {
    return fs.readFileSync(path.join(CONFIG_DIR, name), "utf8").trim();
  } catch (err) {
    if (err.code === "ENOENT") return "";
    throw err;
  }
}

function configPresent(name) {
  return fs.existsSync(path.join(CONFIG_DIR, name));
}

// --- bind-safety classifier ---------------------------------------------------

function parseIPv4(ip) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
  if (!m) return null;
  const parts = [m[1], m[2], m[3], m[4]].map(Number);
  if (parts.some((n) => n > 255)) return null;
  return parts;
}

export function isPrivateOrLoopbackIPv4(ip) {
  const p = parseIPv4(ip);
  if (!p) return false;
  const [a, b] = p;
  if (a === 127) return true; // loopback
  if (a === 10) return true; // RFC1918
  if (a === 172 && b >= 16 && b <= 31) return true; // RFC1918
  if (a === 192 && b === 168) return true; // RFC1918
  if (a === 100 && b >= 64 && b <= 127) return true; // Tailscale/CGNAT 100.64.0.0/10
  return false;
}

// isPrivateOrLoopback: true only for an address this server can itself verify
// is loopback or a recognized private range. "localhost" is treated as
// loopback; 0.0.0.0/:: ("any interface") is deliberately NOT private, since it
// may include a public interface - it requires the explicit override.
export function isPrivateOrLoopback(host) {
  if (host === "localhost" || host === "127.0.0.1" || host === "::1") return true;
  const mapped = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i.exec(host);
  if (mapped) return isPrivateOrLoopbackIPv4(mapped[1]);
  if (host.includes(":")) {
    const first = host.split(":")[0];
    return /^f[cd][0-9a-f]{0,2}$/i.test(first); // fc00::/7 ULA range
  }
  return isPrivateOrLoopbackIPv4(host);
}

export class ConfigError extends Error {}

export function loadConfig() {
  const token = readConfigValue("api-token");
  if (!token) {
    throw new ConfigError(
      "config/api-token is missing or empty; generate one with " +
        "'bin/fm-api-server.sh init-token' before starting",
    );
  }
  const host = readConfigValue("api-host") || DEFAULT_HOST;
  const portRaw = readConfigValue("api-port") || String(DEFAULT_PORT);
  const port = Number(portRaw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ConfigError(`config/api-port must be an integer 1-65535, got '${portRaw}'`);
  }
  const override = configPresent("api-bind-override");
  if (!isPrivateOrLoopback(host)) {
    if (!override) {
      throw new ConfigError(
        `config/api-host '${host}' is not loopback or a recognized private range ` +
          "(RFC1918, Tailscale's 100.64.0.0/10, or an IPv6 ULA). This server refuses " +
          "to bind somewhere that might be reachable from the public internet. If " +
          `'${host}' is genuinely private (e.g. a VPN interface this check does not ` +
          "recognize, or a deliberate all-interfaces bind), create an empty " +
          "config/api-bind-override file to acknowledge the risk and retry.",
      );
    }
    console.error(
      `warning: config/api-bind-override is present; binding to '${host}', which this ` +
        "server cannot verify is private. Proceeding because the operator explicitly " +
        "acknowledged the risk.",
    );
  }
  return { token, host, port };
}

// --- auth ---------------------------------------------------------------------

export function timingSafeTokenMatch(provided, expected) {
  if (typeof provided !== "string" || typeof expected !== "string") return false;
  const a = crypto.createHash("sha256").update(provided, "utf8").digest();
  const b = crypto.createHash("sha256").update(expected, "utf8").digest();
  return crypto.timingSafeEqual(a, b);
}

function checkAuth(req, token) {
  const header = req.headers.authorization || "";
  const m = /^Bearer (.+)$/.exec(header);
  if (!m) return false;
  return timingSafeTokenMatch(m[1], token);
}

// --- validation helpers ---------------------------------------------------

export function isSlug(v) {
  return typeof v === "string" && SLUG_RE.test(v);
}

export function isSafePathLike(v) {
  return (
    typeof v === "string" &&
    v.length > 0 &&
    v.length <= 4096 &&
    !/[\0\r\n]/.test(v) &&
    !v.split("/").includes("..")
  );
}

// --- request plumbing -------------------------------------------------------

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(Object.assign(new Error("body too large"), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function readJsonBody(req, res) {
  let raw;
  try {
    raw = await readBody(req);
  } catch (err) {
    sendJson(res, err.statusCode || 400, { error: "failed to read request body" });
    return undefined;
  }
  if (raw.length === 0) return {};
  let parsed;
  try {
    parsed = JSON.parse(raw.toString("utf8"));
  } catch {
    sendJson(res, 400, { error: "request body must be valid JSON" });
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    sendJson(res, 400, { error: "request body must be a JSON object" });
    return undefined;
  }
  return parsed;
}

function runScript(scriptName, args, { timeoutMs = 30000 } = {}) {
  return new Promise((resolve) => {
    const scriptPath = path.join(FM_ROOT, "bin", scriptName);
    execFile(
      scriptPath,
      args,
      {
        cwd: FM_ROOT,
        env: { ...process.env, FM_HOME },
        timeout: timeoutMs,
        maxBuffer: 8 * 1024 * 1024,
      },
      (error, stdout, stderr) => {
        resolve({
          ok: !error,
          timedOut: Boolean(error && error.killed && error.signal),
          stdout: stdout ? stdout.toString("utf8") : "",
          stderr: stderr ? stderr.toString("utf8").slice(0, MAX_STDERR_BYTES) : "",
        });
      },
    );
  });
}

// --- route handlers ---------------------------------------------------------

async function handleSnapshot(res) {
  const result = await runScript("fm-fleet-snapshot.sh", ["--json"], { timeoutMs: 20000 });
  if (!result.ok) {
    sendJson(res, 502, { error: "snapshot failed", stderr: result.stderr });
    return;
  }
  try {
    sendJson(res, 200, JSON.parse(result.stdout));
  } catch {
    sendJson(res, 502, { error: "snapshot produced invalid JSON" });
  }
}

async function handleSend(body, res) {
  const target = body.target;
  if (typeof target !== "string" || target.length === 0 || target.length > 256 || /[\0\r\n]/.test(target)) {
    sendJson(res, 400, { error: "target must be a non-empty single-line string (max 256 chars)" });
    return;
  }
  let args;
  if (body.key !== undefined) {
    if (!SEND_KEYS.has(body.key)) {
      sendJson(res, 400, { error: `key must be one of ${[...SEND_KEYS].join(", ")}` });
      return;
    }
    args = [target, "--key", body.key];
  } else {
    const text = body.text;
    if (typeof text !== "string" || text.length === 0) {
      sendJson(res, 400, { error: "text must be a non-empty string" });
      return;
    }
    if (/[\r\n]/.test(text)) {
      sendJson(res, 400, { error: "text must be a single line; call /v1/send once per line" });
      return;
    }
    args = [target, text];
  }
  const result = await runScript("fm-send.sh", args, { timeoutMs: 20000 });
  if (!result.ok) {
    sendJson(res, 502, { error: "send failed", stderr: result.stderr });
    return;
  }
  sendJson(res, 200, { ok: true, stdout: result.stdout.trim() });
}

async function handleDecisionResolve(body, res) {
  const { originId, decisionKey, decision, routedTo } = body;
  if (!isSlug(originId)) return sendJson(res, 400, { error: "originId must be a slug" });
  if (!isSlug(decisionKey)) return sendJson(res, 400, { error: "decisionKey must be a slug" });
  if (typeof decision !== "string" || decision.length === 0) {
    return sendJson(res, 400, { error: "decision must be a non-empty string" });
  }
  if (Buffer.byteLength(decision, "utf8") > 8192) {
    return sendJson(res, 400, { error: "decision must be at most 8192 bytes" });
  }
  if (!Array.isArray(routedTo) || routedTo.length === 0 || !routedTo.every(isSlug)) {
    return sendJson(res, 400, { error: "routedTo must be a non-empty array of task-id slugs" });
  }
  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), "fm-api-decision-"));
  try {
    const tmpFile = path.join(tmpDir, "decision.txt");
    await fsp.writeFile(tmpFile, decision, { mode: 0o600 });
    const args = ["resolve", originId, decisionKey, "--decision-file", tmpFile];
    for (const id of routedTo) args.push("--routed-to", id);
    const result = await runScript("fm-decision-hold.sh", args, { timeoutMs: 20000 });
    if (!result.ok) {
      sendJson(res, 502, { error: "decision-hold resolve failed", stderr: result.stderr });
      return;
    }
    sendJson(res, 200, { ok: true, stdout: result.stdout.trim() });
  } finally {
    await fsp.rm(tmpDir, { recursive: true, force: true });
  }
}

async function handlePromote(body, res) {
  const taskId = body.taskId;
  if (!isSlug(taskId)) return sendJson(res, 400, { error: "taskId must be a slug" });
  const result = await runScript("fm-promote.sh", [taskId], { timeoutMs: 20000 });
  if (!result.ok) {
    sendJson(res, 502, { error: "promote failed", stderr: result.stderr });
    return;
  }
  sendJson(res, 200, { ok: true, stdout: result.stdout.trim() });
}

async function handleSpawn(body, res) {
  const { taskId, projectDir, secondmate, firstmateHome, harness, model, effort, backend, scout } = body;
  if (!isSlug(taskId)) return sendJson(res, 400, { error: "taskId must be a slug" });
  if (harness !== undefined && !VERIFIED_HARNESSES.has(harness)) {
    return sendJson(res, 400, { error: `harness must be one of ${[...VERIFIED_HARNESSES].join(", ")}` });
  }
  if (model !== undefined && !isSlug(model)) {
    return sendJson(res, 400, { error: "model must be a slug" });
  }
  if (effort !== undefined && !EFFORT_VALUES.has(effort)) {
    return sendJson(res, 400, { error: `effort must be one of ${[...EFFORT_VALUES].join(", ")}` });
  }
  if (backend !== undefined && !BACKEND_VALUES.has(backend)) {
    return sendJson(res, 400, { error: `backend must be one of ${[...BACKEND_VALUES].join(", ")}` });
  }

  const args = [taskId];
  if (secondmate) {
    if (firstmateHome !== undefined) {
      if (!isSafePathLike(firstmateHome)) {
        return sendJson(res, 400, { error: "firstmateHome must be a safe path" });
      }
      args.push(firstmateHome);
    }
  } else {
    if (!isSafePathLike(projectDir)) {
      return sendJson(res, 400, { error: "projectDir must be a safe path" });
    }
    args.push(projectDir);
  }
  if (harness !== undefined) args.push("--harness", harness);
  if (model !== undefined) args.push("--model", model);
  if (effort !== undefined) args.push("--effort", effort);
  if (backend !== undefined) args.push("--backend", backend);
  if (secondmate) args.push("--secondmate");
  else if (scout) args.push("--scout");

  const result = await runScript("fm-spawn.sh", args, { timeoutMs: 180000 });
  if (!result.ok) {
    sendJson(res, 502, { error: "spawn failed", stderr: result.stderr, timedOut: result.timedOut });
    return;
  }
  sendJson(res, 200, { ok: true, stdout: result.stdout.trim() });
}

async function handlePrMerge(body, res) {
  const { taskId, prUrl } = body;
  if (!isSlug(taskId)) return sendJson(res, 400, { error: "taskId must be a slug" });
  if (typeof prUrl !== "string" || !/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+$/.test(prUrl)) {
    return sendJson(res, 400, { error: "prUrl must be a full https://github.com/<owner>/<repo>/pull/<n> URL" });
  }
  const result = await runScript("fm-pr-merge.sh", [taskId, prUrl], { timeoutMs: 30000 });
  if (!result.ok) {
    sendJson(res, 502, { error: "pr-merge failed", stderr: result.stderr });
    return;
  }
  sendJson(res, 200, { ok: true, stdout: result.stdout.trim() });
}

// --- server -----------------------------------------------------------------

function logLine(req, res, startedAt) {
  const ms = Date.now() - startedAt;
  console.log(`${new Date().toISOString()} ${req.method} ${req.url} ${res.statusCode} ${ms}ms`);
}

export function createApp(config) {
  return http.createServer((req, res) => {
    const startedAt = Date.now();
    void (async () => {
      try {
        const url = new URL(req.url, "http://internal");
        const routeKey = `${req.method} ${url.pathname}`;

        if (routeKey === "GET /healthz") {
          sendJson(res, 200, { status: "ok" });
          return;
        }

        if (!checkAuth(req, config.token)) {
          sendJson(res, 401, { error: "unauthorized" });
          return;
        }

        if (routeKey === "GET /v1/snapshot") {
          await handleSnapshot(res);
          return;
        }
        if (routeKey === "POST /v1/send") {
          const body = await readJsonBody(req, res);
          if (body === undefined) return;
          await handleSend(body, res);
          return;
        }
        if (routeKey === "POST /v1/decision-hold/resolve") {
          const body = await readJsonBody(req, res);
          if (body === undefined) return;
          await handleDecisionResolve(body, res);
          return;
        }
        if (routeKey === "POST /v1/promote") {
          const body = await readJsonBody(req, res);
          if (body === undefined) return;
          await handlePromote(body, res);
          return;
        }
        if (routeKey === "POST /v1/spawn") {
          const body = await readJsonBody(req, res);
          if (body === undefined) return;
          await handleSpawn(body, res);
          return;
        }
        if (routeKey === "POST /v1/pr-merge") {
          const body = await readJsonBody(req, res);
          if (body === undefined) return;
          await handlePrMerge(body, res);
          return;
        }
        if (KNOWN_ROUTES.has(url.pathname)) {
          sendJson(res, 405, { error: "method not allowed" });
        } else {
          sendJson(res, 404, { error: "not found" });
        }
      } catch (err) {
        if (!res.headersSent) {
          sendJson(res, 500, { error: "internal error", detail: String((err && err.message) || err) });
        }
      } finally {
        logLine(req, res, startedAt);
      }
    })();
  });
}

function main() {
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    if (err instanceof ConfigError) {
      console.error(`error: ${err.message}`);
      process.exitCode = 1;
      return;
    }
    throw err;
  }
  const server = createApp(config);
  server.on("error", (err) => {
    console.error(`error: ${err.message}`);
    process.exitCode = 1;
  });
  server.listen(config.port, config.host, () => {
    console.log(`fm-api-server listening on ${config.host}:${config.port} (FM_HOME=${FM_HOME})`);
  });
  const shutdown = (signal) => {
    console.log(`fm-api-server received ${signal}, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

// CLI entry point only when invoked directly, never on import - the same
// pattern bin/fm-arm-command-policy.mjs uses so its exports stay import-safe.
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
