# DECISIONS.md — Execute (Executev3)

ADR-style log of the **non-obvious decisions and gotchas** in Execute — the
"why it's built this way, don't undo it" reference. The goal is to stop a future
contributor (or a Project chat) from re-litigating a solved problem or "cleaning
up" something that is load-bearing.

> **Relationship to the other decision files.** The repo also has a hand-written
> `docs/DECISIONS.md` (append-only, narrative "why we got here" log, newest on
> top) and `CLAUDE.md` (the *current rule*, one-liners). This file is the
> **knowledge-doc** form: each entry is **Decision → Context/why →
> Consequence / what-NOT-to-do**, tied to a specific file/line/comment. When the
> three overlap they should agree; if they drift, the source code wins — verify
> before relying on any one.
>
> **Sourcing rule used here:** every entry cites real code, a code comment, or
> `CLAUDE.md`/MEMORY. Where something looks deliberate but the rationale isn't in
> the code, it's labelled **(rationale unverified)** rather than invented.

Sibling docs for orientation: [`REPO_MAP.md`](./REPO_MAP.md) (where things live),
[`ARCHITECTURE.md`](./ARCHITECTURE.md) (how it's wired),
[`KEY_FLOWS.md`](./KEY_FLOWS.md) (runtime sequences),
[`DATA_MODEL.md`](./DATA_MODEL.md) (schema),
[`CONVENTIONS.md`](./CONVENTIONS.md) (house style).

---

## 1. Data & backend

### 1.1 — One generic JSONB-bag schema for all 19 entity tables

**Decision.** Every "entity" (`AIPlan`, `DailyLog`, `UserSubscription`, … 19
total) is stored in a table with the **same 8 columns**; all entity-specific
fields live untyped inside a single `data jsonb` column. There is **no per-entity
column schema** and **no foreign keys anywhere**.

**Context/why.** The tables are created by one templated `do $$…$$` loop in
`supabase/migrations/20260526000000_supabase_backend.sql:40-49`. The app refers
to entities by name via the `TABLES` map (`src/api/backendClient.js`), and the
identical list is mirrored in `supabase/functions/_shared/records.ts`
(`ENTITY_TABLES`). Adding a "field" to an entity means writing a new key into
`data` — no migration. This is what lets features like BYO plans ship with **zero
schema change** (see §3.4).

**Consequence / what NOT to do.**
- You **cannot** learn an entity's real shape from the DB — read the writer code
  (`generateInitialPlanBundle.js`, `vitalsLog.js`, `subscription.js`, …).
- The de-facto record contract is `flattenRecord` / `recordPayload` in
  `backendClient.js`, **not** a TypeScript type — none exist (the only `.ts` in
  `src/` is `src/utils/index.ts`; `backendClient.js` is `// @ts-nocheck`).
- Don't add a real typed column for an entity field expecting the EntityClient to
  use it — only `id`, `created_by`, `user_email`, and the date columns are
  first-class queryable; everything else filters via `data->>key` (GIN-indexed).

### 1.2 — Ownership is a 4-key OR-chain; writes duplicate the email on purpose

**Decision.** A row is "yours" if **any** of `owner_id` (uuid) /
`owner_email` / `created_by` / `user_email` (JWT email) matches the caller; RLS
enforces this OR-chain on select/insert/update/delete. On write, `recordPayload`
duplicates the email into **both** the wrapper columns *and* inside `data`.

**Context/why.** RLS predicate at migration `:60-117`; `recordPayload` at
`backendClient.js:115-131`. The duplication is what makes the OR-chain reliable
regardless of which key a given query or policy reads.

**Consequence / what NOT to do.** Don't "deduplicate" the email out of `data` or
out of one of the wrapper columns — it will silently break ownership matching for
some read paths. `service_role` (edge functions) **bypasses RLS** entirely — this
is *intended* and is how webhooks write other users' subscription rows (§2.2).

### 1.3 — Realtime echoes your own writes; never render solely from `.subscribe()`

**Decision.** Any UI that both **reads** from `EntityClient.subscribe` and
**writes** the same entity must update **optimistically from in-memory state,
before awaiting the write**, and treat the subscription only as an *authoritative
reconcile*.

**Context/why.** Supabase Realtime (`postgres_changes`, `event:'*'`, table-scoped;
`backendClient.js:275`) has **no self-exclusion** — a client's own write echoes
back to it after a full DB→replication→websocket round-trip (hundreds of ms; not
instant). Rendering only from the subscription therefore flashes stale data
between the action and the echo. Documented in CLAUDE.md/MEMORY and confirmed in
the EntityClient subscribe contract.

**Consequence / what NOT to do.** The only current subscription-backed writers
are `src/pages/Track.jsx` and `src/pages/Home.jsx`, both routing through
`saveVitalLog` (`src/lib/vitalsLog.js`), whose `onOptimistic` fires
**post-read / pre-write**. If you add a *new* subscription-backed writer, apply
the same optimistic-before-await discipline. Note `onOptimistic` **must default
to `null`** in the signature, or `tsc` infers it required and no-arg callers
error (CONVENTIONS §2.4).

### 1.4 — All table access goes through `EntityClient`; the raw `supabase` client is auth/functions only

**Decision.** App code uses `backend.entities.<Entity>.*`; the raw `supabase`
export is reserved for auth and `backend.functions.invoke(...)`.

**Context/why.** Centralizes the JSONB flatten/unflatten contract, the hybrid
server/client filtering, the 2000-row read cap (`MAX_ROWS_PER_QUERY`), and the
resilient-select fallback in one place (`backendClient.js`). The single client is
created once with `flowType: 'pkce'` + `realtime.eventsPerSecond: 10`.

**Consequence / what NOT to do.** Don't spin up a second Supabase client or hit a
table directly from a component — you'd bypass `flattenRecord`/`recordPayload`
and the ownership-key duplication. (Exception: `house_listings`, §3.5, is
deliberately accessed raw — it's not an entity.)

---

## 2. Subscriptions & payments

### 2.1 — Premium is an OR-gate (backend row OR live RC entitlement), never one source

**Decision.** `isPremium = isPremiumUser(subscription) || liveEntitled`, where
`liveEntitled = Object.keys(rcCustomerInfo?.entitlements?.active ?? {}).length > 0`.

**Context/why.** `src/hooks/useSubscription.js:49`. The webhook-written
`user_subscriptions` row is the durable truth but lags the purchase by a webhook
round-trip; the live RevenueCat `customerInfo` gives **instant unlock**. Each
covers the other's gap.

**Consequence / what NOT to do.** Don't gate on one signal alone.
**Load-bearing assumption (also in `docs/DECISIONS.md` 2026-06-08):** the gate is
**count-based**, so *any* active entitlement unlocks full premium. This is safe
**only** while `premium` is the single entitlement the RC project can grant — add
a second entitlement and it silently grants premium. Make the gate
identifier-specific *before* adding one (`useSubscription.js:38-42`).

### 2.2 — The device never writes `user_subscriptions`; webhooks are the sole writers

**Decision.** The `user_subscriptions` table is written **only** server-side:
`revenuecatWebhook` on the iOS rail, `stripeWebhook` on the web rail. The device
only ever `.filter`s it.

**Context/why.** A client write after purchase would race the webhook and is
trivially spoofable (`docs/DECISIONS.md` 2026-06-08; the old client-side
`upsertUserSubscription` was removed). `revenuecatWebhook` requires
`Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>` compared in **constant time**
and writes via `service_role` (bypassing RLS). The **Supabase email is the
RevenueCat `appUserID`** (set in `AuthContext`'s RC login effect), so
`event.app_user_id` == the `user_id` column — and `user_id` therefore **holds an
email, not a uuid** (both webhooks key on it; `loadUserSubscription` filters by
`user.email`).

**Consequence / what NOT to do.** Don't reintroduce a device write to this table.
Don't assume `user_id` is a uuid. "Sole writer" is *per rail* — globally there
are two server writers (RC for iOS, Stripe for web), not zero.

### 2.3 — Configure RevenueCat from JS, never natively in AppDelegate

**Decision.** `Purchases.configure` is called **from JS** via
`ensureConfigured()` in `src/lib/revenuecat.js` (once, behind a shared promise),
**not** in `AppDelegate.swift`.

**Context/why.** A native configure initializes the *app-target* `Purchases`
instance, leaving the Capacitor plugin's `PurchasesHybridCommon` instance
unconfigured → `fatalError` on first `logIn`/`getOfferings` (CLAUDE.md;
`docs/DECISIONS.md` 2026-06-03).

**Consequence / what NOT to do.** Don't add `Purchases.configure` to AppDelegate
"for early init" — it breaks the plugin the app actually calls.

### 2.4 — Never resolve a promise *to* the Capacitor RevenueCat proxy

**Decision.** `src/lib/revenuecat.js`'s `loadModule()` resolves to the ES module
**namespace** and callers read `.Purchases` synchronously; the SDK is never
awaited *as* the `registerPlugin()` proxy.

**Context/why.** The Capacitor `registerPlugin()` proxy returns a native-method
wrapper for **any** property access — including `.then`. Resolving a promise *to*
that proxy makes the await machinery dispatch a phantom `proxy.then(...)` bridge
call that never resolves → deadlock (load-bearing comment in `revenuecat.js`).

**Consequence / what NOT to do.** Don't `await import('@revenuecat/...')` and use
the default/namespace as the plugin object in a thenable position. This pattern
mirrors the durableStore static-import gotcha (§4.2) — Capacitor bridge calls on
`capacitor://localhost` can hang silently.

### 2.5 — One `paymentClient` facade; platform-gate iOS↔web; hard-check the native plugin

**Decision.** All purchases go through `src/lib/paymentClient.js`. `getPlatform()
=== 'ios'` → RevenueCat/StoreKit; everything else → Stripe checkout. iOS calls
are wrapped in `withTimeout` with step-specific hints, and the flow hard-checks
`Capacitor.isPluginAvailable('Purchases')` first, throwing a descriptive rebuild
error if missing.

**Context/why.** Apple Guideline 3.1.1 requires IAP for digital goods on iOS;
Stripe is web-only (`docs/DECISIONS.md` 2026-06-03). If the native plugin didn't
load, every native call would hang — so the availability check converts a freeze
into a visible error, and per-step `withTimeout` does the same for a stuck
StoreKit sheet.

**Consequence / what NOT to do.** Don't call RevenueCat/Stripe directly from a
component. The Apple Pay / Stripe-wallet button returns `null` on iOS so it never
renders natively (`src/components/billing/ApplePayButton.jsx`).

---

## 3. Plan generation

### 3.1 — Lazy/on-demand generation: ONE overview LLM call, per-day materialized later

**Decision.** A finished questionnaire makes **one** master `AIPlan` (a 7-day
*overview*, one `InvokeLLM` call). The per-day `WorkoutPlan`/`MealPlan`/`DailyLog`
rows are created **only when a day is opened**, and only when `options.generate
=== true`.

**Context/why.** `generateInitialPlanBundle.js` deliberately creates no per-day
records (comment `:727`); `getOrCreateWorkoutPlanForDate.js` /
`getOrCreateMealPlanForDate.js` gate generation on `options.generate`. Avoids an
eager 7× LLM burst at plan creation (which both costs and 429s).

**Consequence / what NOT to do.** Don't reinstate a "generate all 7 days up
front" loop. **`generateInitialPlans.js` is legacy/disabled** — it only still
exports the live helpers `buildAnswerContext` + `calcTDEE` (imported by the
bundle); `generateInitialPlans()` itself is a throwing stub, and the other guard
`operationalizeWeeklyPlan()` lives in `personalizationSync.js:1344` and blocks
legacy child-projection creation. Don't document/re-enable that dead path.

### 3.2 — Completion is delivered ONLY via a singleton subscriber + replay buffer

**Decision.** `Plan.handleQuestionnaireSubmit` calls `startGeneration(answers)`
then **immediately** `subscribeToGeneration(applyGenerationResult)`. Generation
is a singleton (`planGenerationState.js`): an in-flight call re-attaches to the
existing promise; the result is buffered for late subscribers; answers are
persisted to `sessionStorage`; the whole thing races a **3-minute timeout**.

**Context/why.** This lets the user navigate away mid-generation and still receive
the result on return (replay), and guarantees the page is attached before
completion fires. Comment at `Plan.jsx:343-344`.

**Consequence / what NOT to do.** Don't make `applyGenerationResult` run from the
direct promise return — completion must flow through the subscriber, or a
navigation-away loses the result. Don't drop the `sessionStorage` answer
persistence (crash/nav recovery).

### 3.3 — Two-layer 429/backoff + concurrency cap for multi-day builds

**Decision.** Multi-day "Build all" hoists invariant context **once** and runs
per-day generation with a **concurrency cap of 4** (`pooledMap`); every per-day DB
op and the hoisted read are wrapped in `withBackoff` (full-jitter, honors
`Retry-After`); the `invoke-llm` edge fn independently retries OpenAI 429/≥500
with its own full-jitter backoff honoring `Retry-After`.

**Context/why.** The multi-day build used to 429 from **two** sources: PostgREST
DB fan-out and OpenAI TPM. Both are now absorbed (`buildWorkoutPlansForDates.js`,
`withBackoff.js`, `invoke-llm/index.ts`; KEY_FLOWS §2). `defaultRetryable`
text-matches `/429|rate.?limit|too many|…/` because PostgREST 429s don't always
surface a clean numeric `.status` through the backend error wrapper.

**Consequence / what NOT to do.** Don't re-add parallel per-day query fan-out and
don't remove the concurrency cap. **Both workout AND nutrition** paths are now
hardened the same way (`buildMealPlansForDates.js`, `getOrCreateMealPlanForDate.js`
— with the swallowing `.catch` kept *outside* the `withBackoff` wrapper so a first
429 retries instead of degrading to "no plan"). `withBackoff` is the repo-wide
standard for new multi-day build paths. *(Note: KEY_FLOWS lists the nutrition
hardening as a still-open item; MEMORY/CONVENTIONS record it as done — verify in
`getOrCreateMealPlanForDate.js` before relying on it.)*

### 3.4 — BYO ("input your own plan") persists entirely inside existing JSON columns

**Decision.** The 4th questionnaire option (`planType: 'custom'`) lets a user
paste/upload their own training and/or nutrition plan; Execute structures it and
builds the missing side. **No DB schema change** — everything lives in
`plan_payload.byo_*` and `weekly_overview.days[i].byo_session/byo_meal_focus`.

**Context/why.** The generic JSONB schema (§1.1) makes this free. A dedicated
`structurePastedPlan` LLM **pre-call** runs *before* `calcTDEE` (it derives the
activity level that TDEE needs and drives an interactive clarification loop);
post-submit it can re-run **once** and otherwise **degrades gracefully** to
AI-building that side (it can't ask clarifying questions with no UI). PDF input
uses client `pdfjs` with an opt-in OpenAI `input_file` branch; a crash-draft is
kept in `durableStore`.

**Consequence / what NOT to do.** Don't add columns for BYO fields. Don't let the
post-submit structuring throw/hang — the no-UI path must fall back, never block.
Raw paste text is a **last-resort** per-day fallback only; per-day reads use the
pre-mapped `byo_session`/`byo_meal_focus` slices.

### 3.5 — `house_listings` is the one real-columns table, with fully-permissive RLS (by design)

**Decision.** The `executelabs.ca/house` board uses a standalone
`house_listings` table with real typed columns and **`using(true)/with check(true)`
RLS on all four ops** — anyone with the `anon` key can read/write. It is **not**
an `EntityClient` entity; it's hit via the raw Supabase client.

**Context/why.** It's a public, unlisted, no-login shared board
(`20260622000000_house_board.sql`; header comment). `replica identity full` is set
so Realtime DELETE/UPDATE carry the full old row.

**Consequence / what NOT to do.** Don't "fix" the open RLS — it's intentional for
an auth-free board. Don't fold it into the entity API. Note it uses `created_at`,
**not** the entity tables' `created_date`. *(Migration was untracked in git at the
last snapshot — confirm it's committed before relying on it in another env.)*

---

## 4. Caching & cold-launch

### 4.1 — Two-tier SWR cache over Capacitor Preferences (fixes cold-launch flash-of-wrong-content)

**Decision.** `appCache` is Tier-1 in-memory `Map` (the only thing the synchronous
`get`/`isFresh`/`set` touch) + Tier-2 durable (`durableStore` → Capacitor
`Preferences` on iOS / `localStorage` on web), replayed into Tier-1 once at boot.
Screens paint from cache instantly and refresh in the background.

**Context/why.** The previous `sessionStorage` Tier-2 was **wiped on an iOS app
kill**, so a cold launch started empty and briefly painted the wrong state (e.g.
the "Build my plan" CTA for a user who *has* a plan, or vice-versa) until the
network resolved. `Preferences` survives a true kill, so the first paint is the
**last-known-correct** state (ARCHITECTURE §5; KEY_FLOWS §4).

**Consequence / what NOT to do.**
- Don't move Tier-2 back to `sessionStorage`.
- `get`/`isFresh` are **STORE-only and synchronous** — a mount that reads without
  first `await appCache.whenHydrated()` sees an empty cache (`useState`
  initializers run pre-hydrate). Gate screens on `useCacheHydrated()`'s `ready`
  and re-read after `whenHydrated()`.
- Bump `SCHEMA_VERSION` to invalidate all older-shaped durable entries.

### 4.2 — Import Capacitor `Preferences` STATICALLY (dynamic import hangs forever on iOS)

**Decision.** `durableStore.js` imports `Preferences` with a **static**
`import { Preferences } from '@capacitor/preferences'`.

**Context/why.** A **dynamic** `import('@capacitor/preferences')` never resolves
on iOS `capacitor://localhost` (the bridge call hangs), wedging **every** durable
read/write → cold-launch loading floor stuck. Confirmed on-device (MEMORY;
load-bearing comment in `durableStore.js`).

**Consequence / what NOT to do.** Don't convert it to a dynamic import "for bundle
size." Same family of bug as §2.4. As a defense-in-depth, every durable op is
also raced against `OP_TIMEOUT_MS` and boot against `BOOT_TIMEOUT_MS` so a stalled
bridge call fails open to "cold load" rather than wedging `whenHydrated()`.

### 4.3 — `whenHydrated()` must ALWAYS resolve; first activation is NOT a switch

**Decision.** Every bulk cache op runs on one serialized op-chain and is
timeout-raced; `bootHydrate` always settles `hydrated=true` + emits
`appcache:hydration:done` (even on empty/failed/timed-out reads).
`activateUser(uid)` is **idempotent on the same uid**, treats **null→uid as NOT a
switch** (no floor re-arm), and only purges+re-hydrates on a genuine
non-null→different-non-null switch (in a `finally` so the floor always
re-settles).

**Context/why.** Invariant 4 (MEMORY): a hung durable op must not wedge the chain;
re-arming the loading floor on initial activation could leave `hydration:done`
unfired and hang the app. Comments at `appCache.js:326-333`.

**Consequence / what NOT to do.** Don't make first-activation re-arm the floor.
Don't add a cache op outside `enqueue`. Background fetches that resolve after an
account switch must use `setForUser(capturedUid,…)` — `writeForUser` drops a write
whose uid ≠ `activeUid`, so a late write can't poison the new user's cache.

### 4.4 — Lightweight module-level TTL caches coexist with appCache and TanStack Query

**Decision.** `src/lib/` modules that hit the backend keep a module-scoped TTL
cache + an explicit `bust<Thing>Cache()` (e.g. `subscription.js` 60s;
`personalizationSync.js`'s `resetPersonalizationCaches()`). This is separate from
the heavier `appCache` durable subsystem and from TanStack Query.

**Context/why.** SWR-lite per module where a full durable entry isn't warranted
(CONVENTIONS §2.3).

**Consequence / what NOT to do.** Caching is intentionally **mixed** — don't
assume one mechanism repo-wide; match the file you're editing. Don't hand-roll an
`appCache`-style durable tier per module.

---

## 5. UI / shell

### 5.1 — Bottom-nav double-fire & rapid-tap-burst fix (`onTap` + `e.detail===0` guard + `currentPathRef`)

**Decision.** Each nav item handles taps via framer-motion **`onTap`**, while its
`<button onClick>` only fires when **`e.detail === 0`** (`handleTabPress` is
called from both). "Am I the active tab" is judged against a **`currentPathRef`**
that's set optimistically inside `handleTabPress` on navigate.

**Context/why.** `AppShell.jsx:158,176-177` + comments `:37-41,:112-116,:133-135`.
`e.detail === 0` is a keyboard-activated click (no pointer), so the `onClick`
**only** handles keyboard activation and doesn't double-fire alongside `onTap` for
a real touch. During a synchronous tap **burst**, React may not re-render between
taps, so the closed-over `location.pathname` is **stale** — reading/setting
`currentPathRef` makes each tap judge `isActive` against the path it's actually
heading to.

**Consequence / what NOT to do.** Don't replace this with a plain `onClick` (you
reintroduce double-fire and/or stale-path mis-routing on fast taps). Don't read
`location.pathname` inside `handleTabPress` — use the ref. *(Note: this is the
mechanism actually in the code; it is **not** a single `onTapStart` handler, in
case older notes describe it that way.)*

### 5.2 — `<main>` is the scroller, not `document.body`; nav is a fixed sibling

**Decision.** `AppShell` root is a **non-scrolling** flex `<div>`; the scroller is
the child `<main ref={mainRef} className="ios-scroll flex-1">`; the bottom `<nav>`
is `fixed bottom-0 z-50`, a **sibling** of `<main>`. Per-tab scroll position is
saved/restored via `mainRef`.

**Context/why.** `AppShell.jsx:143-150` (ARCHITECTURE §2). The nav hides on
`execute:blocking-overlay` / `execute:customize-mode` CustomEvents and on
`/workout-session`.

**Consequence / what NOT to do.** Body-level scroll logic (scroll-lock,
scroll-to-top) must target **`<main>`**, not `document.body`. The customize-mode
listener also resets `document.body.style.overflow/touchAction` as a safety net so
an interrupted drag can't freeze all taps — keep it.

### 5.3 — Portaling overlays is the MINORITY pattern; only where the Home-transform traps them

**Decision.** The default bottom-sheet/modal idiom is a **non-portaled**
`fixed inset-0` framer-motion sheet rendered inline. Only **3 files**
(`track/LogModal.jsx`, `plan/RefinePlanModal.jsx`, `plan/AskQuestionsModal.jsx`)
`createPortal(node, document.body)`.

**Context/why.** Home's route root is a transformed `<div>` (pull-to-refresh). A
CSS `transform` creates a stacking context that traps a non-portaled overlay
*below* the fixed z-50 nav. Overlays mounted under Home must portal to escape;
elsewhere the inline sheet sits above the nav fine (CONVENTIONS §1.5; MEMORY).

**Consequence / what NOT to do.** Don't reflexively portal every sheet (it's the
exception). But an overlay that renders under a transformed route root (Home)
**must** portal, or it hides behind the nav. Portaled sheets must also handle
their own body scroll-lock and safe-area footer.

### 5.4 — `lucide-react` and `recharts` are vite-aliased to hand-maintained shims

**Decision.** `vite.config.js:34-35` aliases `lucide-react` →
`src/lib/lucide-react.js` and `recharts` → `src/lib/recharts.js`, each re-exporting
**only a curated subset**. Code still imports from `'lucide-react'`/`'recharts'`.

**Context/why.** Keeps the bundle to the icons/chart pieces actually used
(REPO_MAP; CONVENTIONS §1.6).

**Consequence / what NOT to do.** **Hard gotcha:** importing a member **not** in
the shim passes lint **and** `tsc` but **fails the vite/rollup build**
(`"<Icon>" is not exported by "src/lib/lucide-react.js"`). To add an icon, append
the alphabetical
`export { default as <Icon> } from '../../node_modules/lucide-react/dist/esm/icons/<kebab>.js'`
line (confirmed adding `Pause` 2026-06-27). Same failure mode for recharts.

---

## 6. Auth

### 6.1 — PKCE + `skipBrowserRedirect` + custom-scheme deep link for iOS OAuth

**Decision.** The Supabase client is `flowType: 'pkce'`. On **iOS**,
`loginWithOAuth` requests the provider URL with `skipBrowserRedirect: true`, opens
it in `@capacitor/browser`, and completes via the `appUrlOpen` deep link
`com.executelabs.execute://login-callback` (`IOS_OAUTH_REDIRECT`). Web keeps the
normal `signInWithOAuth` page navigation.

**Context/why.** On iOS a normal redirect dumps the user into Safari with no way
to hand the session back to the native app, so `skipBrowserRedirect` makes
Supabase **return** the URL instead of navigating `window.location`. The deep-link
handler supports **both** PKCE (`?code=` → `exchangeCodeForSession`) and implicit
(`#access_token=` → `setSession`) shapes (KEY_FLOWS §1).

**Consequence / what NOT to do.** **Load-bearing comment (`AuthContext.jsx:174`):**
pass the **bare code value** (`new URL(url).searchParams.get('code')`) to
`exchangeCodeForSession`, **not the full URL** — the full URL makes the exchange
fail and strands the user on login. Don't swallow the exchange error (it looks
like an endless login loop). The redirect scheme must be in `Info.plist` **and**
allow-listed in Supabase Auth URL config.

### 6.2 — iOS email login is a 6-digit OTP code, not a magic link

**Decision.** `loginWithOtp` **omits** `emailRedirectTo` on iOS, so Supabase sends
a **6-digit code** (verified in-app via `verifyOtp({ type: 'email' })`); web keeps
the magic-link flow. `useCode = isIOS()` switches the UI.

**Context/why.** A magic link can't hand a session back to the native app
(`backendClient.js:323-349`; KEY_FLOWS §1).

**Consequence / what NOT to do.** Don't add `emailRedirectTo` on iOS expecting a
link to work. `activateUser` is called from three auth paths (checkAppState,
checkUserAuth, onAuthStateChange) — all idempotent on the same uid; this redundancy
is intentional, not a bug.

---

## 7. Build & native packaging

### 7.1 — `cssCodeSplit: false` because WKWebView can hang on injected `<link>`

**Decision.** `vite.config.js:29` disables CSS code-splitting — all CSS is one
upfront stylesheet from `index.html`.

**Context/why.** Load-bearing comment (`:22-29`): Capacitor's WKWebView
(`capacitor://` scheme) **sometimes never fires `load`** on a dynamically injected
`<link rel="stylesheet">`, which makes Vite's preload helper hang forever —
freezing any dynamic `import()` whose chunk carries a CSS dep (e.g.
`@revenuecat/purchases-capacitor`'s web paywall CSS).

**Consequence / what NOT to do.** Don't re-enable `cssCodeSplit` — dynamic imports
of CSS-carrying chunks will hang on device.

### 7.2 — Pin Rollup input to root `index.html`; keep iOS out of the scanner

**Decision.** `build.rollupOptions.input` is pinned to root `index.html`, and
`optimizeDeps.entries` / `server.watch.ignored` / `server.fs.deny` all exclude
`ios/` and `dist/`. `optimizeDeps.holdUntilCrawlEnd: false`.

**Context/why.** Without pinning, the build scanner crawls into `ios/`
(DerivedData + the iOS-bundled copy of the app at `ios/App/App/public/`) and walks
thousands of files, taking minutes (comments `:14-18`, `:38`). `holdUntilCrawlEnd:
false` is the documented dev-server hang fix (CLAUDE.md).

**Consequence / what NOT to do.** `server.fs.deny` is **dev-server only** and does
NOT apply to `vite build` — the `rollupOptions.input` pin is what protects the
build. Don't remove it.

### 7.3 — Bundle web assets locally; no `server.url` (App Store Guideline 4.2)

**Decision.** `capacitor.config.ts` sets `webDir: 'dist'` and **no `server.url`**;
`npm run ios:sync` (= `vite build && cap sync ios`) copies `dist/` into
`ios/App/App/public/`. Capacitor 8 is **SPM-based, no Podfile** (plugins in
`ios/App/CapApp-SPM/Package.swift`).

**Context/why.** A remote-loaded shell trips Guideline 4.2 (web wrapper /
minimum functionality); local bundling keeps it a "real" native app
(`docs/DECISIONS.md` 2026-06-03; ARCHITECTURE §9).

**Consequence / what NOT to do.** Don't point `server.url` at a hosted build.
`capacitor.config.ts` is **TypeScript** — there is no `.js` variant; the
`ios/App/App/capacitor.config.json` is **generated** by `cap sync` — don't
hand-edit it. Don't hand-edit `ios/App/App/public/` (synced from `dist/`).

---

## 8. Compliance (App Store) — kept-by-decision items not to "tidy away"

**Decision / what NOT to undo.** The following are deliberate compliance choices
(`docs/DECISIONS.md` 2026-06-03; MEMORY audit notes):
- **Health + Fitness data types are KEPT** in `PrivacyInfo.xcprivacy`
  (nutrition=Health, workouts=Fitness) — the ASC Nutrition Label must match. Don't
  strip them.
- `ITSAppUsesNonExemptEncryption=false` and `NSCameraUsageDescription` (camera is
  **real**: barcode scan `getUserMedia` + meal-photo `<input capture>`) in
  `Info.plist` — both required, don't remove.
- Privacy Policy + Terms pages are routed **before** the auth gate so
  unauthenticated links resolve (`App.jsx`); Terms governing law is **British
  Columbia, Canada** (was a placeholder — don't revert to `[Your State/Country]`).
- SIWA (Sign in with Apple) is offered **before** Google in `AuthScreen`
  (Guideline 4.8 ordering); account deletion is wired (`Profile.jsx` →
  `deleteUserData`); Restore Purchases + auto-renew disclosure are in the paywall;
  iOS prices are pulled **live** from StoreKit. Don't remove any of these — each
  maps to a specific rejection-risk guideline.

**Consequence / what NOT to do.** Treat these as load-bearing for App Review. The
fake Apple Health/HealthKit integration and the test-access bypass were **removed**
on purpose — don't reintroduce a "test login" shortcut.

---

## Last verified against

- `docs/claude/REPO_MAP.md`, `docs/claude/ARCHITECTURE.md`,
  `docs/claude/KEY_FLOWS.md`, `docs/claude/DATA_MODEL.md`,
  `docs/claude/CONVENTIONS.md` (read in full this pass)
- `docs/DECISIONS.md` (the narrative why-log — cross-referenced for dates/commits)
- `CLAUDE.md` and project MEMORY (cross-referenced for the lucide shim, durable
  static-import, optimistic-write, OR-gate, dev-server hang fix, and App Store
  audit notes)
- `src/components/layout/AppShell.jsx` (full — bottom-nav `onTap`/`e.detail===0`/
  `currentPathRef`, `<main>` scroller, nav hide events)
- `vite.config.js` (full — `cssCodeSplit:false`, rollup input pin, lucide/recharts
  aliases, `holdUntilCrawlEnd:false`)
- Cited via the knowledge docs above (not independently re-opened this pass):
  `src/api/backendClient.js`, `src/lib/revenuecat.js`, `src/lib/paymentClient.js`,
  `src/lib/subscription.js`, `src/hooks/useSubscription.js`, `src/lib/durableStore.js`,
  `src/lib/appCache.js`, `src/lib/AuthContext.jsx`, `src/lib/vitalsLog.js`,
  `src/lib/generateInitialPlanBundle.js`, `src/lib/plans/*`, `src/lib/withBackoff.js`,
  `supabase/functions/invoke-llm/index.ts`,
  `supabase/functions/revenuecatWebhook/index.ts`,
  `supabase/migrations/20260526000000_supabase_backend.sql`,
  `supabase/migrations/20260622000000_house_board.sql`, `capacitor.config.ts`

_Verified 2026-06-27._
