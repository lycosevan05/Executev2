---
description: Snapshot the Execute IAP/RevenueCat wiring from the codebase (SDK init, package IDs, entitlement, offering, gate, webhook) and flag what must be verified manually.
argument-hint: "(no arguments)"
allowed-tools: Bash, Read, Grep, Glob
model: sonnet
---

Report the current IAP/RevenueCat state of the Execute repo, grounded in what is actually in the code — not from memory. Read-only.

## Gather (grep/read the source of truth)
- **SDK init:** find `Purchases.configure` (expected: `ios/App/App/AppDelegate.swift`, native — not JS). Report file:line and confirm it's native.
- **Package IDs:** grep for `execute_premium_month` and `execute_premium_annual` (and `$rc_monthly` / `$rc_annual` aliases). Report where defined.
- **Entitlement / offering:** grep for the entitlement key (`premium`) and offering (`default`).
- **Unlock gate:** locate the OR-gate logic across `src/lib/revenuecat.js`, `src/lib/subscription.js`, `src/hooks/useSubscription.js` (adjust paths to what exists). Confirm the device does NOT write `user_subscription`.
- **Webhook:** find `supabase/functions/revenuecatWebhook/index.ts` (or similar). Confirm it exists in the repo.

## Output (compact table)
```
SDK init      <✅/❌ + file:line + native?>
Packages      <ids found, and where>
Entitlement   <key>     Offering <name>
Gate (OR)     <files implementing the OR-gate, read order>
Webhook fn    <path>    ⚠️ deploy + auth secret NOT verifiable from repo
```

## Drift & manual checks
- Flag any mismatch between the code and the documented contract (entitlement string, package ids, "device never writes user_subscription").
- List what you CANNOT see from the repo and must be checked by hand: live offering/products in the RevenueCat dashboard, App Store Connect product status, whether the webhook is deployed with the right signing secret, and a sandbox-tester purchase.

Be honest about the repo/live boundary — that boundary is the point of this command.
