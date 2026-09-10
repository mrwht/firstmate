---
name: updatefirstmate
description: >-
  Self-update a running firstmate to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md so the running firstmate runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
It never forces, never creates a merge commit, never stashes, and advances the target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
This touches only the firstmate repo, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin.
   It prints one status line for the target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by one action line that tells you exactly what to do next:
   - `reread-firstmate: yes|no`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: whether firstmate is now on the latest, or was left as-is and why.
   For example: "Captain, firstmate is now on the latest."
   Surface a skipped update whose reason needs the captain's attention - for instance un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo** is touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
