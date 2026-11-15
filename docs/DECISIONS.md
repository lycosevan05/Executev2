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

## 2026-11-11 — Preserve supplied plans and account-scoped setup drafts
**Type:** architecture · **Status:** implemented; 91 affected native methods pass; local PDF/draft live acceptance passed; BYO save/scan AI acceptance pending
**Context:** Native setup supported only AI-authored first plans, lost questionnaire/import text on navigation or relaunch, and the onboarding route still used a placeholder.
**Decision:** Add training/nutrition/both BYO inputs, one structuring call with explicit clarification rather than silent fallback, canonical weekly/rotating cadence mapping and stated nutrition-target preservation. Keep raw and structured BYO data with the master and each overview day. Add selected-side PDFKit extraction capped at8MB/30pages/12,000characters; unreadable files wait for an explicit consent action before using the existing secure AI input_file path. PDF bytes stay in memory and never enter drafts. Route onboarding into setup and let existing-plan users preview replacements before create-then-archive.
**Why:** Preserve what the user supplied and distinguish document extraction from plan generation. Durable drafts use explicit account keys under the existing deletion-purge prefix; answers/previews expire after30minutes while raw BYO text survives locally until successful commit or discard. Pending preview/batch/baseline persist so a lost create response can be retried after relaunch without another master. Reject stale/newer plans and stop late account/Premium responses. Block draft writes during deletion and after account changes so a disappearing screen cannot recreate purged data. Fresh profile context prefills missing details, not the stored draft's explicit answers.
**Validation:** All91 affected native methods pass, including13 import/draft regressions, startup/deletion failure recovery and billing auth races. Selectable-text training PDF was imported through the real system picker (user-assisted because desktop control cannot operate its controls), then restored with scope/text/body fields after full relaunch. Synthetic training/nutrition fixtures were rendered and visually checked. The first expanded compile fixtures were corrected; an initial90/91 run had a mistaken scope expectation, corrected before the final91/91 pass. BYO master save and scanned-PDF AI are still pending at this entry.
**Limits:** Local same-install drafts, not cross-device/reinstall; reselect unreadable PDFs after relaunch. Rotating schedules re-anchor on generation day, matching the reference's accepted seam limitation. No new backend deployment, entitlement grant, PR merge or distribution.


## 2026-11-13 — Verify scanned PDFs through the deployed boundary and keep supplied schedules coherent
**Type:** architecture · **Status:** scoped live BYO/PDF/draft acceptance passed
**Context:** Explicit native AI extraction of the synthetic scan failed because shared `invoke-llm` v6 ignored PDF input. The first BYO preview also retained model-written day descriptions after supplied weekday remapping, and live Discard/navigation recreated an empty draft.
**Decision:** After separate user approval, deploy only a PDF validator/content change against the downloaded v6 baseline, preserving auth/JWT, shared modules, model and credentials. Accept base64 PDF-signature input up to8MB and reject malformed inputs before provider fetch. Keep the local handler's pre-existing retry code separate from the reviewed deployment. Derive supplied-training priority/recovery text from mapped sessions/rest days, remove stale rest-day sessions, and block PDF extraction while generating/saving or after preview. Discard closes existing-plan setup, clears errors and skips all-default draft persistence.
**Validation:** Exact v7 readback SHA256 matches8d5e512cab71c47c6b358a0f7195125bc61c5c40399ef3ea66fd289de5ad1d00, ACTIVE and verify_jwt=true. Ten source-bound mocked handler tests pass; v6 reproduces seven failures. Real signed native scan extraction preserved training and imported exact2200/160/255/60 targets. Corrected preview and both imported texts survived relaunch without writes; explicit Save created one replacement, archived the prior master, preserved exercises/meals/raw+structured data, and restored Plan/Home after relaunch. Profiles/goals remain one each. Fresh setup prefill, missing-required-input rejection and fixed Discard/navigation pass live. Final40 affected Plan methods pass; an older rotation test needed fixed calendar dates after a Nov13 run exposed its Wednesday assumption.
**Limits:** Native30page cap remains client-side; the server validates bytes/signature, not page count. Guard/Premium/account/deletion failure cases remain fixture coverage. No real account deletion, other backend deployment, billing mutation, merge or distribution. Canonical Execute document is maintained by the separate writer; private evidence is under the chat workspace's work/byo-acceptance-20261113.

## 2026-11-13 — Replace four native route placeholders with saved performance data
**Type:** architecture · **Status:** implemented; scoped simulator acceptance passed; full feature parity remains open
**Context:** Live Plan refinement now previews, acknowledges Save and restores after full app close/relaunch. The controlled request retained the visible 2200/160/255/60 targets and Fri C/Mon A/Wed B schedule while adding rest-day evening mobility. My Week, Goals, Progress and Insights still routed to placeholders.
**Decision:** Route those four destinations to native screens using the authenticated entity service. My Week reads the active master and saved task completion, and links to existing date-specific Recovery and Food Log flows. Goals supports creation, exact/additive progress, completion, pause and resume. Progress charts saved entries for 7/30/90 days and handles increasing/decreasing targets. Insights aggregates saved steps, sleep, water, energy and completed workouts for seven local dates. Keep missing metrics absent rather than inventing zero-valued observations; choose the newest daily record per date.
**Persistence:** Save goal intentions under the existing account-deletion cache prefix before the first request. Stable mutation identifiers and frozen progress dates survive navigation/relaunch; retries reconcile acknowledged goal and history writes without repeating them. Re-read the goal baseline before updates and preserve unknown JSON fields. Stop late responses after account/navigation changes and gate new writes during deletion. These client checks do not make a read followed by a patch an atomic compare-and-swap. Pending saves require explicit Retry after restart. Pause preserves history; a highlighted paused goal still shows its trend with logging disabled. Home excludes paused and completed goals from its active snapshot. Plan refinement previews now show recovery/nutrition guidance alongside session details.
**Validation:** Final 31 affected native methods pass: PerformanceDestination12, PlanRefinement13, Home6. The initial test compile found a UserDefaults actor-transfer fixture error; the next run was23/24 because the daylight-saving fixture assumed a Vancouver transition. A transition-observing fixture then passed24/24; the final integration run passed31/31. In the normally signed live QA simulator, the four routes load real data. Empty goal submission rejects; one synthetic goal progresses0→1→2→3/3 through exact/additive saves, displays its Nov13 trend, restores Complete after full close/relaunch, and pauses/resumes without losing3/3. It is left paused. Home returns to the original one active qualitative goal. Insights displays historical Nov9 energy9 as90/100 while steps/sleep/water remain unlogged.
**Limits:** Live evidence is UI/acknowledgment/relaunch, without a new independent SQL/hash/count readback or exact exercise/meal-persistence proof. Failure, retry, account isolation and deletion cases are fixtures. Automatic goal synchronization/tracking, AI-generated Insights, richer nutrient analytics, on-demand workout/meal generation, camera/barcode, provider/account-deletion acceptance and physical-device/release parity remain separate work. No new backend deployment, billing mutation, real deletion, merge, push or distribution. Evidence is in the continuation chat workspace's work/native-destinations-20261113 and outputs/Execute-native-destinations-evidence-20261113.zip.

## 2026-11-13 — Build and save individual workout and meal days on demand
**Type:** architecture · **Status:** implemented; scoped signed simulator generation/save/relaunch acceptance passed
**Context:** Native master plans and dashboards existed, but build actions could not create daily workout/meal children. Home's build checklist labels also used its generic completion handler.
**Decision:** Add one date-specific native builder for workouts/meals, reachable from Home, Train, Nutrition and My Week. Opening only reads; Generate produces a reviewable preview through the existing authenticated `invoke-llm`; explicit Save creates only the requested child. Rest days block workout generation. Never create or patch the master, DailyLog, FoodLog or WorkoutLog from the builder. Reuse usable children belonging to the current master, compare UUIDs without case sensitivity, prefer current/newest plans and prevent archived, other-master or incomplete children from shadowing them. Leave historical incomplete rows stored. Home build placeholders navigate before the completion handler runs.
**Context and preservation:** Read supporting profiles, active limitations, dated/latest readiness and selected-date food context before generation; fail closed on failed/paginated reads. Use manual nutrition targets over master targets. Inject only the authoritative supplied date slice, with weekly/rotating cadence and weekday override precedence; omit full BYO text from questionnaire context. Preserve supplied exercise count/order/names/sets/reps/notes and exact meal names/count. Recompute meal totals from generated per-meal values and reject target drift above15% (one-unit rounding floor). One structured content correction is allowed after validation failure; genuine clarification and network errors stop. This is arithmetic/contract validation, not independent ingredient nutrient calibration. The UI labels meal nutrition as estimates.
**Persistence:** Store previews under account/date/kind keys within the existing deletion-purge prefix before publishing them. Stable save tokens survive process relaunch and reconcile a committed create whose response was lost. Re-read master/context and children before a new create; refuse stale context or previews over30minutes old, while allowing acknowledgment reconciliation. Stop late identity/navigation responses and gate writes during Premium revocation or account deletion. Invalidate relevant Home/Nutrition caches after acknowledgment. These client reads/checks do not supply atomic cross-device uniqueness or compare-and-swap.
**Validation:** Final52 affected native methods passed,0fail/0skip: DayPlan21, Home6, Navigation4, Nutrition4, PlanRefinement13 and WorkoutSession4. Earlier test compiles corrected a malformed cadence fixture and a Home fixture using the wrong concrete data-service type. Intermediate44/44,50/50 and51/51 passes preceded the final incomplete-row regression. Final signed build and simulator relaunch passed.
**Live scope:** Workout C preview retained Incline push-ups3×10 and Dead bugs3×8eachside, restored unsaved after full app close, acknowledged Save and loaded in Home/Train. Three initial meal attempts were rejected (protein drift, exact-name mismatch, protein drift) without a saved preview/meal. Explicit name/target instructions plus the bounded correction path then returned the three supplied names and model-estimated2200/160/255/60, matching the saved targets. The UI alone does not establish whether that successful attempt used its correction call. Meal preview restored unsaved after full close; explicit Save acknowledged; Nutrition retained0foodentries/0intake/0of3mealscomplete. After full close and final build installation, both saved days restored; My Week's current workout and Nutrition meal details reused saved data without Generate/Save controls. Nov14 rest route showed no workout generation action. No workout was started or completed. App is left on authenticated Home with both saved-day summaries.
**Limits and exploratory write:** The initial Home build-label click toggled generic checklist completion; it was immediately toggled back off, then corrected and regression-tested. That exploration may have created/updated the Nov13 DailyLog, so no overall no-log-write live claim is made. Builder no-log/master-write behavior, failure retries, account/deletion and concurrency cases are fixture coverage. A curated local unsaved meal draft was read for evidence without reading authentication storage; it is not independent database verification. No new SQL/hash/count readback, ingredient-based nutritional accuracy, billing-provider, real account-deletion, physical-device or release acceptance is established. No backend deployment, billing mutation, credential automation, merge, push or distribution. Original Developer checkout changes remain preserved. Evidence: continuation chat work/day-generation-20261113 and outputs/Execute-day-generation-evidence-20261113.zip. The separate writer maintains the canonical Execute Document.


## 2026-11-13 — Checkpoint daily-use acceptance after diagnosing timestamp acknowledgments
**Type:** architecture · **Status:** partial simulator/database acceptance; user requested wind-down
**Problem:** The first native workout Start created exactly one QA in-progress row but decoding its acknowledgment failed. The SDK encoded nested dates as a fractional UTC timestamp without a zone, while the payload decoder accepted only ISO8601 with a zone. The screen then incorrectly exposed editable exercises without an acknowledged log ID.
**Decision:** Accept existing fractional/zone-less UTC payload timestamps, encode new nested payload dates with explicit UTC zones, and hide exercise editors after a failed Start. Resume only the exact workout/date, serialize progress writes, flush on scene deactivation, prevent concurrent completion and surface DailyLog synchronization errors before showing success. Add native planned-meal logging with source-meal-plan/type links, retry lookup before another create, correction of the same FoodLog via shallow patch and recalculation that does not double-count a linked planned estimate. Planned-food deletion clears its completion type while retaining unrelated food rows. Client reads do not establish atomic cross-device uniqueness.
**Verification:** Independent SELECTs before activity confirmed QA ownership/attribution, three masters with exactly one active refined version2, one active workout, one active meal, two goals and three progress entries, three DailyLogs, zero FoodLogs and zero WorkoutLogs. The saved master targets are2200/160/255/60; saved workout exercises and meal names match supplied content. The generated45minute duration differs from the supplied approximately30minutes; recorded before repairs and remains unresolved. Old uppercase workout UUID links are supported case-insensitively. After the timestamp fix, the signed simulator resumed the existing log, recorded two incline-pushup sets, retained2of6 after background/foreground, and was fully terminated. An independent SELECT after termination returned exactly that same single in-progress row with completed indices[0,1]. Full post-termination relaunch/resume, workout completion/DailyLog synchronization, meal logging/correction/deletion and cross-screen acceptance remain next. Final22 affected fixture tests passed,0fail/0skip: DailyUseWorkflow3, Home6, Nutrition6, WorkoutSession4, timestamp compatibility3. These cover exact-date matching, lost-create acknowledgment retry, failed DailyLog synchronization, legacy timestamps and corrected linked-food arithmetic. Two new fixture declaration errors were corrected before the final run.
**Limits:** Planned-meal controls are implemented and calculation fixtures pass but have not been used live. Nutrition ingredient values remain model estimates. Automatic goal tracking remains unfinished. No new provider/billing or physical-device acceptance. User explicitly deferred the physical phone until simulator work is complete. No backend deployment/schema change, billing mutation, real account deletion, credential automation, merge/push/distribution. The original Developer checkout diff fingerprint is unchanged. Canonical Execute Document rows116–117 are maintained/read back by the separate writer.


## 2026-11-15 — Reconcile activity-backed daily tasks and verify the native daily-use workflow
**Type:** architecture · **Status:** scoped simulator and independent database acceptance passed; physical acceptance pending
**Problem:** A completed synthetic workout synchronized workout_done/duration/calories but left checklist arrays, completion IDs and counters stale. Train history displayed its later completion date instead of its saved activity date. Planned food correction/deletion and relaunch still needed live acceptance.
**Decision:** Reconcile existing workout/nutrition task entries and completion IDs/counters from acknowledged activity, retaining custom tasks, unknown task properties and unrelated DailyLog fields. Read the current DailyLog before nutrition synchronization; use shallow patches and never patch master/child plans. Logging all planned meals completes the planned-meal task independently of hitting macro targets. Deleting one clears that task. Train history prefers the saved activity date, with completion date as a legacy fallback. Add accessible macro-field names.
**Fixtures:** Final38/38 affected tests passed,0fail/0skip: DailyActivityChecklist3, DailyUseWorkflow4, Home6, Nutrition6, PerformanceDestination12, WorkoutSession4 and timestamp3. New coverage exercises lost planned-food creation acknowledgment, same-record correction, deletion with an unrelated snack, preservation of unknown daily/task fields and master data, checklist reversal and history across midnight.
**Live simulator and independent SELECTs:** The Nov13 workout resumed after full termination on Nov14 with2/6sets; SELECT confirmed exactly the same one in-progress record. Completing all6sets produced one completed WorkoutLog48fe6e66-fa10-4bce-999e-990f8f0682e6,2exercises,27bounded estimated minutes/166estimatedkcal, and updated the existing Nov13DailyLog. Three planned meal actions created exactly one linked FoodLog per meal and2200/160/255/60. Added a synthetic100/5/10/2snack, corrected breakfast on its same ID to600/30/80/15, deleted lunch and verified1450/100/173/33 and2/3meals after full termination/relaunch. Re-logging lunch created one replacement; final4food rows total2200/155/253/57 with3/3planned meals. The correction remains below the protein target; task completion is not target attainment. Full final close/relaunch restored that state.
**Cross-screen agreement:** HomeNov15 stays a rest day with no current-day intake/burned activity; saved activity belongs toNov13. Train history now showsNov13; Nutrition retains actual intake; MyWeek shows workout and planned meals checked. Same DailyLog has2/4tasks and50%adherence, readiness/recovery false. RecoveryNov13 remains uncompleted/no new check-in or generated guidance. Insights reports exactly1completed session, priorNov9energy90/100, and missing steps/sleep/water as unlogged. Automatic goal tracking remains unfinished.
**Preservation:** Independent final SELECTs show4FoodLogs,1WorkoutLog and3DailyLogs, all QA ownership/attribution checks true. All master/child-plan, goal/progress, profile/readiness table payload checksums match the baseline; both older DailyLog payload hashes remain unchanged. Only intended current activity data changed. Deleted lunch is absent; replacement lunch, corrected breakfast, dinner and unrelated snack are the four intended food rows. Original Developer checkout fingerprint remains preserved.
**Limits:** The pre-existing generated workout duration45minutes still differs from supplied approximately30minutes; no master/child-plan repair was made during logging acceptance. Ingredient nutrition accuracy, automatic goals, richer Insights, camera/barcode/storage and physical/release acceptance remain open. A fresh physical-device query cannot establish a connection; cached iPhone17 reports tunnel unavailable and DDI services not ready. No backend/schema deployment, billing mutation, real account deletion, credential automation, merge/push/distribution. Separate progress_writer maintains the canonical document; curated evidence/checkpoint is in the continuation chat outputs.
