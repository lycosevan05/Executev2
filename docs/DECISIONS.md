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

## 2026-11-01 — Reconcile refund reversals from current provider state
**Type:** architecture · **Status:** active
**Context:** The webhook acknowledged `REFUND_REVERSED` without refreshing customer state, so a reversal could leave backend access stale.
**Decision:** Route refund reversals through the existing provider lookup and atomic reconciliation path, retaining authentication, gateway settings and restore policy. Do not grant access directly from the event payload.
**Why:** A delayed reversal may arrive after access has expired again; current provider truth preserves that later state, and lookup failures must retry without partial writes. Source/authentication/TEST verification and fixture passes remain distinct from real Apple refund-reversal acceptance.
**Touches:** `supabase/functions/revenuecatWebhook`, billing acceptance runbook and parity audit. The approved version 8 rollout is recorded in the function README.

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

## 2026-10-31 — Native billing identity and entitlement isolation
**Type:** architecture · **Status:** active
**Context:** Native purchases, auth callbacks and account changes can finish after a newer session starts; web subscribers also need their existing backend access.
**Decision:** Keep the existing email identity, serialize auth/RevenueCat mutations, discard stale session results, and clear access on sign-out. Native Premium resolves the exact `Execute Performance Premium` entitlement OR the authenticated account's active/trialing backend row. The device never writes subscription rows.
**Why:** Preserve the shared backend contract and legitimate web access while preventing an earlier account's asynchronous result from granting access to a later account. User-scoped cache cleanup targets the original UUID.
**Touches:** `ios-native/ExecuteNative/App`, `Core/Authentication`, `Core/Persistence`, `Core/RevenueCat`, `Features/Billing`.

## 2026-10-31 — Shared RevenueCat transfer reconciliation
**Type:** architecture · **Status:** active
**Context:** The prior webhook acknowledged TRANSFER without reconciling both account rows, leaving backend Premium stale after the receipt moved.
**Decision:** Read current provider state for both transfer sides and reconcile email-keyed rows atomically through a service-role-only, security-invoker RPC. Reject revision conflicts/provider failures for retry; preserve unrelated metadata and independently verified retained purchases. Retain the approved `verify_jwt=false` gateway with existing bearer-secret authentication and the existing project-wide restore policy.
**Why:** Event payloads cannot safely serve as current entitlement truth after transfers or delayed delivery. Atomic updates prevent partially moved access. Missing Stripe credentials fail closed for reconciliation rather than guessing a downgrade; later Stripe lifecycle projection remains a separate limitation.
**Touches:** `supabase/functions/revenuecatWebhook`, `supabase/migrations/20261021000000_reconcile_revenuecat_subscriptions.sql`. Scoped deployment, auth negatives and physical A → B acceptance are recorded in the native audit.

## 2026-10-31 — Separate native-dev store configuration and auth mail
**Type:** provider · **Status:** active
**Context:** Native subscription testing required its own Apple/RevenueCat app and the built-in Supabase mail quota repeatedly blocked disposable-account sign-in.
**Decision:** Preserve the original Execute app; use `com.executelabs.execute.native-dev`, verified team `58GZDC8UKY`, separate monthly/annual products and the matching public SDK key in ignored local configuration. With approval, route shared Supabase auth mail through Resend using verified `auth.executelabs.ca` and a domain-restricted Sending key stored privately in Supabase.
**Why:** Isolate development store records while retaining the shared entitlement contract, and provide reliable code delivery without bypassing email verification. Keep all private credentials out of mobile configuration, source and logs.
**Touches:** native build configuration and setup/audit documentation; provider settings were applied through the approved dashboard workflow.

## 2026-11-08 — Reconcile both billing provider event paths from current truth
**Type:** architecture · **Status:** implemented locally; deployment review pending
**Context:** Stripe events could overwrite independently valid RevenueCat access,
replay stale subscription state or acknowledge an invoice after a provider failure.
**Decision:** Both event paths read current provider snapshots and apply shared
email-keyed effective access through the existing revision-checked atomic RPC.
Preserve RC exact-entitlement/grace rules and Stripe active/trialing eligibility;
provider errors and conflicts retry without writes. Track bounded known Stripe
links to retain replacement/independent purchases; keep the existing REST API and
authentication contracts. Refund-only Stripe revocation policy is unchanged.
**Why:** Either valid purchase must preserve access regardless of event order;
saved provider flags and historical event names cannot establish current access.
**Touches:** both webhook reconciliation modules, shared billing projection and
focused tests. See the [verification and rollout handoff](reports/2026-11-08-billing-review.md).


## 2026-11-08 — Reuse the published Recovery retry implementation
**Type:** architecture · **Status:** active
**Context:** PR #2 follow-up `6fa8528` and separate local fix `c301f6c` both address failed personalization invalidation after acknowledged Recovery saves.
**Decision:** Import the published native Recovery feature into an isolated integration branch, retain current billing source/documentation, and reuse its retry implementation rather than layering the older fix over it. Keep PR #2 draft until native and live acceptance pass; do not merge it under this checkpoint.
**Why:** The current 28 model methods and all five additional retry regressions from the separate fix pass on the published implementation. No remaining failing behavior justifies duplicating its retry state machinery. Model evidence remains distinct from native/device and live RLS/AI verification.
**Touches:** Native Recovery, project wiring, test helper and native README; canonical milestones remain in the Execute Document on Google Drive.

## 2026-11-08 — Preview native plan refinement before replacing the master plan
**Type:** architecture · **Status:** implemented locally; native/live acceptance pending
**Context:** The native Plan Adjustments destination displayed a placeholder while the reference app supports AI refinement of the active daily master plan.
**Decision:** Use the existing authenticated AI/entity services to generate a validated seven-day preview, then create the replacement before archiving earlier daily plans and linked workouts. Keep questionnaire, BYO context, unknown fields and weekday overrides. A stable revision batch is checked before retrying a create, including a lost response after commit. Preserve failed previews for retry, reject stale edits and stop late responses after account/navigation changes. Enforce Premium access at preview/save. Refresh personalization after persistence; report incomplete cleanup instead of claiming complete success.
**Why:** Generation and network failures must preserve the working plan and retries must not duplicate an acknowledged revision. Preview separates a proposed change from persistence. Ten source-bound Mac model methods exercise these paths; they do not establish native UI or live backend acceptance.
**Touches:** Native Plan model/view, refinement rules, project registration and focused tests. Onboarding, initial generation, live persistence and device acceptance remain open.

### Follow-up — paginate plan cleanup
Plan replacement cleanup reads every page rather than silently stopping at the first500 workouts or100 contexts. Stable creation-date/ID ordering prevents cleanup's update timestamps from shifting pages. Reads fail closed, check cancellation/session generation between pages, and retain the saved revision for cleanup retry. The eleventh focused model method exercises a second-page failure and successful retry over501 linked workouts without creating another master plan. Existing first-page callers keep their limit/ordering contract, with an ID tiebreaker added.

### Follow-up — preserve later revisions and recheck Premium after awaits
A retry that finds its committed batch must still confirm that batch is the active canonical plan. If another device has since created a newer plan, cleanup stops rather than archiving that plan. Premium is rechecked after the AI response and immediately before a new create, so revocation during a request cannot publish/save a new revision. Two additional regression methods reproduce these timings; the focused model total is13.

## 2026-11-09 — Require a persisted session before completing email sign-in
**Type:** architecture · **Status:** active; live Recovery acceptance in progress
**Context:** An unsigned simulator test artifact could verify an email code and show Home even though Keychain rejected storage. Supabase's SDK suppresses session-storage write errors; Recovery correctly refused to operate without an SDK session, and app relaunch returned to sign-in. A non-secret marker reproduced Keychain status-34018 in that artifact and0/0 with normal Xcode signing.
**Decision:** Run live account checks with a normally signed app and retain Keychain storage. Email verification must return a session and the SDK must read back a valid persisted session for the same user before AppState activates the account. Do not weaken Recovery identity checks or substitute insecure token storage. Use neutral email-code copy and allow requesting a fresh code.
**Why:** A server user response alone does not establish usable local authentication. Three real-SDK/local HTTP-storage fixture regressions cover rejected writes, user-only responses and restoration through a new client;16 existing startup/authentication-race methods remain passing. The corrected live app has also restored the designated account after termination/relaunch without another code. Temporary diagnostics and the non-secret Keychain probe are removed from source.
**Touches:** SupabaseAuthService, AuthenticationView, focused native tests and QA signing instructions. This is not live Recovery/Plan persistence acceptance or a provider billing grant.

## 2026-11-09 — Stage an RLS-preserving atomic entity update helper
**Type:** architecture · **Status:** implemented and tested locally; shared-backend deployment approval pending
**Context:** Real native Recovery created one check-in and one DailyLog and restored them after app relaunch, but guidance persistence failed because the shared backend has no `patch_record` RPC. The web client has a read/merge/write fallback; the native client requires the atomic helper. Catalog metadata confirms absence, and all18 allowed entity tables already have RLS and authenticated UPDATE privileges.
**Decision:** Stage one migration with the expected RPC signature/JSON envelope, caller privileges, a fixed search path and a finite entity allowlist. Merge only JSON object patches, maintain updated_date, preserve ownership/attribution columns, revoke anonymous/default-public execution and exclude provider-owned subscription truth. Deploy only this reviewed SQL file after scoped approval, rather than applying other pending migrations.
**Why:** Native partial-success retry must update acknowledged rows without losing unrelated fields, duplicating records or bypassing RLS. Twenty local PostgreSQL/RLS groups cover row isolation, ACL hardening, invalid inputs, attribution, atomic merging and rollback. A rollback drops only the new helper and leaves data/RLS intact. Live guidance persistence remains blocked until deployment and native retry are verified.
**Touches:** Migration20261109000000, isolated PGlite test package under supabase/tests/patch-record, and the chat's exact deployment/rollback/review artifacts. No shared-backend DDL has been applied in this checkpoint.

## 2026-11-09 — Verify atomic updates through the native transport
**Type:** architecture · **Status:** approved helper deployed; scoped live persistence verified
**Context:** The user approved only the reviewed helper on the shared app backend. The first native retry committed the update but failed to decode its acknowledgment; the helper was immediately rolled back, preserving records and RLS.
**Decision:** Decode the RPC's default JSON response without forcing singular representation. Normalize one returned row, require its UUID to match the requested record, and use the SDK's timestamp decoder. Reject empty, multiple or mismatched acknowledgments. Redeploy the exact approved SQL after the client fix; do not broaden the migration or change RLS/grants.
**Why:** A committed write must be distinguished from a usable acknowledgment so retry does not duplicate records. Six actual-SDK/local HTTP transport regressions pass. The normally signed native app then acknowledged the existing check-in/DailyLog re-save, persisted real generated guidance, and restored it after termination/relaunch. Read-only database verification confirms the same one-plus-one IDs and unchanged guidance hash. The re-save retained synthetic energy8; changed-value editing, limitations/tasks/date-switch, Plan and device gates are not established by this result.
**Touches:** SupabaseDataService, JSONBCompatibilityTests and the single approved helper rollout. Final helper readback matches the reviewed body and invoker ACL. No bulk migration or migration-history registration, manual data/entitlement writes, PR merge or distribution occurred.

## 2026-11-11 — Build the first native plan through preview and acknowledged save
**Type:** architecture · **Status:** initial AI overview implemented; native/live scoped acceptance passed
**Context:** Native Plan had no questionnaire or generation controls, preventing first-plan use and further Recovery task testing.
**Decision:** Collect first-plan answers with existing profile/allergy prefill, use the existing authenticated AI endpoint, validate seven ordered local dates, and require explicit Save. Match the web deterministic starting-target calculation rather than accepting model drift. Persist the questionnaire in the master payload and update user/training/nutrition profiles and questionnaire goal after acknowledgment. Reuse stable-batch retry, concurrency, account-generation and Premium guards; preserve a saved preview for incomplete related updates.
**Why:** Generation must not write a plan, and a lost create response must not duplicate one or replace another device's newer plan. The first real preview was rejected by validation with zero plans persisted. A complete nested schema and legacy response-envelope support then produced a valid preview; explicit native Save created one plan, and termination/relaunch restored it and Home targets. Read-only database checks confirmed the same ID and payload hash, seven Nov11–17 dates, and one profile/goal set. Twenty-four native Plan methods pass, including eleven initial-generation regressions. The exact rejected response was not captured, so schema/envelope changes are a tested fix rather than proof of its individual missing field.
**Touches:** Plan generation model/view, shared refinement schema/normalization and native project/tests. This accepts the initial AI overview path only; BYO/PDF, draft resumption, broader onboarding/regeneration, live refinement, daily projection/task completion and device/release gates remain separate. No new backend deployment or manual entitlement/data writes.

## 2026-11-11 — Project selected-day Recovery tasks from the master overview
**Type:** architecture · **Status:** implemented; 55 combined native methods pass; live projection acceptance pending
**Context:** The first real native master plan was saved, but Recovery could not display planned tasks because no native path populated DailyLog planning fields from the lightweight overview.
**Decision:** Mirror the reference ensureDailyLogForDate planning projection when Recovery loads a date present in the active master overview. Update the existing canonical DailyLog or create the selected day's record through the ordinary authenticated repository. Preserve tracked/completion/unknown fields, use stable reference task IDs, skip identical projections and out-of-week dates, and fail closed on reads/writes. A retry re-reads rows before creating, including after a committed write loses its response.
**Why:** Task completion must operate on real native-generated planning data rather than SQL-seeded acceptance fixtures. Three new native methods cover preservation/reload completion, committed-create retry without duplication, and unscheduled/stopped-identity protection. All31 Recovery plus24 Plan methods pass on a separate temporary simulator, now removed. This does not establish live task completion; installation/live verification waits for the open changed-input QA handoff.
**Touches:** Recovery models/load flow, DEBUG failure fixture and tests. No backend deployment or RLS/table/entitlement changes. Historical Nov9 guidance/limitation/date acceptance remains distinct from the still-unverified energy8→9 edit.

## 2026-11-11 — Accept the shared planning checklist in Home
**Type:** compatibility · **Status:** fixed; scoped Recovery/Plan live acceptance passed
**Context:** Real native task projection and completion succeeded, but full relaunch exposed Home's synthesized decoder requiring native-only source/completed properties absent from the canonical web planning checklist.
**Decision:** Decode shared checklist id/type/title as required, with optional description and native UI metadata defaulting safely. Keep native item encoding and explicit completion fields intact. Do not alter shared records to satisfy one client's decoder.
**Why:** Every destination must consume the same persisted checklist contract. The regression decodes actual RecoveryDailyProjection output as HomeDailyLog and round-trips a fully populated native item. All61 affected methods pass (Home6, Recovery31, Plan24). The corrected live app restores Home, one completed Nov11 task on the same DailyLog, and the updated Nov9 guidance after relaunch. User-assisted slider input changed Energy8→9; independent SELECT confirms the original check-in/DailyLog IDs with energy9 and guidance_inputs9, without duplicates. The Nov11 projection is a separate expected DailyLog for another date.
**Touches:** HomeModels compatibility decoder and JSONB compatibility tests. This supersedes the live-pending projection/handoff status above. Initial AI overview and these Recovery checks are verified; BYO/PDF, draft resumption, broader onboarding/regeneration, live Plan refinement and device/release acceptance remain separate. No new backend deployment, PR merge or distribution.
