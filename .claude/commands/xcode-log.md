---
description: Parse a pasted Xcode console dump — strip noise, surface real errors/faults and RevenueCat/StoreKit lines, and end with one specific next action.
argument-hint: "[paste the Xcode log here, or invoke bare and paste it as your next message]"
allowed-tools: Read, Grep, Glob
model: sonnet
---

You are triaging an Xcode console dump for the Execute app (bundle `com.executelabs.execute`).

The log is in `$ARGUMENTS`. If `$ARGUMENTS` is empty, reply only: "Paste the Xcode console output and I'll triage it." and stop — analyze it when it arrives.

## Filter (conservative — when unsure, KEEP the line)
Drop pure-noise lines: `CFPrefsPlistSource`, `RTIInputSystemClient`, UIScene/"Unbalanced calls to begin/end appearance", `nw_`/network-path chatter, `AudioToolbox`, "Could not signal service", haptics/keyboard layout spam.
NEVER drop a line containing: `error`, `fault`, `exception`, `crash`, `Thread N`, the Execute bundle id, or `RevenueCat` / `Purchases` / `StoreKit` / `Supabase`.

## Output (this exact shape, tight)
```
## Signal
⛔ Faults/errors:  <lines, with file:line if present>
🟣 RC/StoreKit:    <purchase/offering/entitlement lines>
🔵 App logs:       <Execute-namespaced lines worth seeing>
🟡 Warnings:       <only ones that matter>

## Diagnosis
<one or two sentences — the likely root cause>

## Next action
<a SPECIFIC step: a command (e.g. /iap-status, /ios-sync), a file:line to open, or a dashboard check — never "investigate further">
```
If a line references a source file, you may Read it to sharpen the diagnosis, but don't go exploring — keep this fast.
