# Decision Log — Execute (Executev3)

> **What this is:** the living record of *why* the project is the way it is — architecture calls,
> provider choices, direction pivots, and compliance decisions — captured at the moment they're made.
>
> **What this is NOT:** a code changelog. *What* changed lives in git + `docs/reports/` (generated).
> This file is for the reasoning that git can't hold.
>
> ### Lanes (don't duplicate across them)
> | This file | `CLAUDE.md` | git log / `docs/reports/` |
> |---|---|---|
> | *why & how we got here* | *the current rule (one-liner)* | *what changed, mechanically* |
>
> ### How to add an entry
> - Newest on top. **Append-only** — never delete. When you reverse a call, leave the old entry and
>   add `**Status:** superseded by → <date/title>` to it, then write the new one.
> - Trigger: any commit that encodes a *decision* (provider swap, architecture, scope, compliance) —
>   not typo/format fixes. Run `/log-decision` to draft an entry from your working diff.
> - Keep it short. Template:
>
> ```markdown
> ## YYYY-MM-DD — <short title>
> **Type:** architecture | provider | direction | compliance | dependency · **Status:** active
> **Context:** <the situation forcing a choice — 1–2 lines>
> **Decision:** <what we decided>
> **Why:** <the reasoning — the part git can't hold>
> **Rejected:** <alternatives considered and why not> (optional)
> **Touches:** <files / areas> · **Commit:** <hash> (optional)
> ```

---

## 2026-06-08 — "Any active entitlement = premium" assumption made explicit
**Type:** architecture · **Status:** active
**Context:** The OR-gate unlock checks `customerInfo.entitlements.active` but the app only defines
one entitlement (`premium`). Wanted the intent documented so a future second entitlement doesn't
silently grant premium.
**Decision:** Treat a non-empty `entitlements.active` map as premium (count-based check), and record
that this is an explicit assumption tied to there being exactly one entitlement today.
**Why:** Cheaper/safer than name-matching `"premium"` on the hot path; flagged so it's revisited if
entitlements ever multiply.
**Touches:** `src/hooks/useSubscription.js` · **Commit:** d48be21

## 2026-06-08 — Device never writes the subscription row (webhook is sole writer)
**Type:** architecture · **Status:** active
**Context:** Both the client (after purchase) and the RevenueCat webhook could write
`user_subscription`, creating a race and a spoofing surface.
**Decision:** The `revenuecatWebhook` edge function is the **sole writer** of the subscription row.
The client only ever *reads* it, OR-gated against live `customerInfo` entitlements. Removed the
unused client-side `upsertUserSubscription`.
**Why:** Client writes race the webhook and are trivially spoofable; a single server-side writer keeps
subscription truth authoritative. Live-entitlement OR-gate covers the lag before the webhook lands.
**Rejected:** client upsert after purchase (the removed path).
**Touches:** `src/lib/subscription.js`, `src/hooks/useSubscription.js`, `supabase/functions/revenuecatWebhook/` · **Commit:** 5bfe8d8

## 2026-06-03 — Configure RevenueCat from JS, not natively in AppDelegate
**Type:** architecture · **Status:** active
**Context:** RevenueCat can be configured either natively (AppDelegate) or from JS via the Capacitor
plugin. Native configuration caused `logIn`/`getOfferings` to `fatalError`.
**Decision:** Call `Purchases.configure` from JS only, behind `ensureConfigured()` in
`src/lib/revenuecat.js`. No native configure in AppDelegate.
**Why:** Native configure initializes the *app-target* Purchases instance, leaving the Capacitor
plugin's `PurchasesHybridCommon` instance unconfigured → fatalError. JS-side config initializes the
instance the plugin actually uses.
**Touches:** `src/lib/revenuecat.js`, `ios/App/App/AppDelegate.swift` · **Commit:** 5ade1b6

## 2026-06-03 — Bundle web assets locally; no `server.url`
**Type:** compliance · **Status:** active
**Context:** Capacitor can load the app from a remote `server.url` or from locally-bundled assets.
**Decision:** Ship the built `dist/` inside the app (`webDir: 'dist'`, no `server.url`).
**Why:** A remote-loaded shell trips App Store Guideline 4.2 (minimum functionality / web wrapper).
Local bundling keeps it a "real" native app.
**Touches:** `capacitor.config.ts` · **Commit:** ~2c2a8b8

## 2026-06-03 — IAP via RevenueCat/StoreKit on iOS; Stripe web-only
**Type:** provider · **Status:** active
**Context:** Need payments on both web and iOS without violating Apple's IAP rules.
**Decision:** Platform gate (`getPlatform()`): iOS purchases go through RevenueCat/StoreKit IAP; web
uses Stripe. Apple Pay / Stripe Wallet button returns `null` on iOS so it never renders natively.
**Why:** Apple Guideline 3.1.1 requires digital goods to use IAP on iOS; Stripe on web avoids Apple's
cut where allowed. A single `paymentClient.js` facade hides the split from callers.
**Touches:** `src/lib/paymentClient.js`, `src/lib/platform.js`, `src/components/billing/ApplePayButton.jsx` · **Commit:** 657cd47 / 5ade1b6

## 2026-06-03 — App Store compliance hardening pass
**Type:** compliance · **Status:** active
**Context:** First App Store audit surfaced multiple rejection risks.
**Decision:** Removed the test-access bypass; removed the fake Apple Health/HealthKit integration;
added Privacy Policy + Terms pages (routed + linked in paywall); added PrivacyInfo.xcprivacy +
`ITSAppUsesNonExemptEncryption=false`; added `NSCameraUsageDescription` (barcode + meal-photo capture
are real); declared collected data types; localized paywall pricing from live StoreKit; set Terms
governing law to British Columbia, Canada.
**Why:** Each maps to a specific guideline (2.1 incomplete content, 5.1 privacy, 3.1.1, 4.2). Health +
Fitness data types are *kept* in the manifest by decision (nutrition=Health, workouts=Fitness) — the
ASC Nutrition Label must match.
**Touches:** `ios/App/App/Info.plist`, `PrivacyInfo.xcprivacy`, `src/pages/PrivacyPolicy.jsx`, `src/pages/Terms.jsx`, `src/components/premium/PremiumPaywall.jsx` · **Commits:** 6f11429, 2c2a8b8, 259f249, 67a3fa4, 20649f5

## 2026-05-27 — Stack baseline: Capacitor 8 + React/Vite, Supabase backend
**Type:** architecture · **Status:** active
**Context:** Initial project shape.
**Decision:** Capacitor-wrapped React 18 + Vite 6 (ESM) iOS app; Supabase for auth + edge functions;
TanStack Query / react-hook-form / react-router v6; Tailwind + Radix + framer-motion.
**Why:** Reuse one React codebase for web and the iOS shell; Supabase gives auth + serverless without
standing up a backend. Recorded as the baseline all later decisions build on.
**Touches:** whole repo · **Commit:** 5c9149a
