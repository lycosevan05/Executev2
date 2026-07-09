---
description: Build the web app and copy it into the iOS project (one clean attempt, then diagnose). Replaces freeform "build then sync" turns. Never starts a dev server.
argument-hint: "[sync]   (default copies web assets; 'sync' runs full cap sync incl. plugins)"
allowed-tools: Bash, Read
model: sonnet
---

Run the Execute iOS build pipeline. Make ONE clean attempt per stage, then diagnose — never blind-retry.

## Hard rules (the reason this command exists)
- NEVER run `npm run dev`, and NEVER curl-probe / `sleep` / `pkill` / `lsof` / `kill` a dev server. An iOS build does not need a running dev server. If you feel the urge to wait on `localhost`, stop — that is the anti-pattern this command replaces.
- One attempt per stage. On failure, surface the real error and STOP. Do not loop.
- Run EVERY stage in the FOREGROUND. NEVER pass `run_in_background: true` and never append `&`. The build is a ~3s command; backgrounding it has no benefit and causes the command to wedge in a "Task Output" poll loop on a task that already finished. Each stage is a single blocking Bash call whose result you read directly — no polling, no `TaskOutput`.

## Steps
1. **Build:** run `npm run build` as one foreground Bash call (set the tool's `timeout` to 180000; do NOT background it). If it exits non-zero, print the actual failing file/line from the output and stop with: "Fix and re-run /ios-sync." Do not proceed.
2. **Copy/sync:** if `$ARGUMENTS` is `sync`, run `npx cap sync ios`; otherwise run `npx cap copy ios`.
3. **On copy/sync failure:** run `npx cap doctor` ONCE, read `ios/App/CapApp-SPM/Package.swift`, and report the specific error + the most likely cause (SPM resolution, missing plugin, stale Pods). Then stop — do not retry the sync.
4. **On success:** print a one-line summary with stage timings and the next manual step:
   `✅ build → ✅ cap copy ios. Next: open Xcode, run on device/archive.`

Keep all output to a few lines. No narration of the rules themselves.
