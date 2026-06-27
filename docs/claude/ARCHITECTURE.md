# ARCHITECTURE — Execute (Executev3)

How the Execute app is wired together, for an engineer who can't see the
filesystem or run the code. Execute is a **Capacitor-wrapped React/Vite SPA**
shipped as an iOS app (bundle id `com.executelabs.execute`) and also runnable on
the web. It's an AI fitness/nutrition coach: a questionnaire produces a master
plan, per-day workouts and meals are generated on demand, the user tracks
vitals/food/workouts daily, and premium features sit behind a subscription gate
(RevenueCat/StoreKit on iOS, Stripe on web).

> This doc describes *systems and flows*. For a file/directory inventory see
> `REPO_MAP.md`. Where a signature or value is quoted it is verbatim from the
> cited file; where I did not read an implementation end-to-end I say so.

---

## 1. The big picture: four layers

```
┌──────────────────────────────────────────────────────────────────────┐
│ React SPA (src/)                                                       │
│   AuthProvider → QueryClientProvider → Router → AppShell → Routes      │
│   pages/ + components/ ── read/write through ──┐                       │
│                                                │                       │
│   cross-cutting singletons (src/lib/):         │                       │
│     appCache (2-tier) · durableStore · AuthContext · paymentClient     │
└────────────────────────────────────────────────┼──────────────────────┘
                                                  │ @supabase/supabase-js
┌─────────────────────────────────────────────────▼──────────────────────┐
│ Supabase (backend)                                                      │
│   Postgres (JSONB-envelope tables + RLS) · Auth (PKCE) · Realtime ·     │
│   Storage · Edge Functions (Deno)                                       │
│     invoke-llm → OpenAI   revenuecatWebhook / stripeWebhook → writes    │
│     deleteUserData   stripeCreateCheckout/Portal                        │
└─────────────────────────────────────────────────┬──────────────────────┘
            ┌─────────────────────────────────────┴───────────┐
┌───────────▼───────────┐                       ┌──────────────▼─────────┐
│ OpenAI /v1/responses  │                       │ RevenueCat / StoreKit  │
│ (gpt-4.1-mini)        │                       │ + Stripe (web)         │
└───────────────────────┘                       └────────────────────────┘
```

Three deliberate properties shape everything below:
1. **The device is a thin client over Supabase.** There is no app server of our
   own besides Supabase Edge Functions. The browser bundle holds the OpenAI
   prompt-building logic; only the raw OpenAI call is proxied server-side.
2. **The subscription table is server-written only.** The device may *read* live
   entitlements for instant unlock, but only webhooks write the truth row.
3. **Cold-launch correctness is a first-class concern.** A two-tier cache with a
   strict hydration "loading floor" exists specifically so an iOS cold launch
   never paints an empty/wrong state.

---

## 2. Boot sequence & app shell

Entry: `index.html` → `src/main.jsx` (`ReactDOM.createRoot(...).render(<App/>)`)
→ `src/App.jsx`.

`App` (`src/App.jsx:256`) mounts providers outer→inner:
`AuthProvider` → `QueryClientProvider` (`queryClientInstance`) → `BrowserRouter`
→ `AuthenticatedApp`, with `<Toaster/>` a sibling.

What happens on launch, in order:
1. **Module init** — importing `@/lib/appCache` runs `appCache.bootHydrate()` as
   a side-effect (`src/lib/appCache.js:372`). This is the FIRST op on the cache
   op-chain, before any React effect. It replays the last-active user's durable
   cache into memory (see §5).
2. **`AuthProvider` mounts** → `checkAppState()` (`AuthContext.jsx:49`) reads the
   *local* Supabase session (`supabase.auth.getSession()` — no network), and if a
   session exists calls `appCache.activateUser(session.user.id)` then the
   networked `checkUserAuth()` (`backend.auth.me()`).
3. **`AuthenticatedApp`** (`App.jsx:180`) shows a splash while
   `isLoadingPublicSettings || isLoadingAuth`, then routes to `AuthScreen` /
   `UserNotRegisteredError` on `authError`, else renders `<AppShell>` with the
   route table. It also fires boot prewarm (`prewarmUserEmail`, `loadActivePlan`,
   `runMigrationIfNeeded` — all fire-and-forget) and `useAutoResumeWorkout`,
   which redirects to `/workout-session` if today has an `in_progress`
   `WorkoutLog`.
4. **Public legal routes** (`/privacy`, `/terms`) are special-cased *before* the
   auth gate (`App.jsx:200-201`) so they resolve unauthenticated.

`AppShell` (`src/components/layout/AppShell.jsx`) — the persistent chrome:
- Root is a **non-scrolling** `<div className="min-h-screen … flex flex-col …
  relative">` (`AppShell.jsx:143`). The **scroller is the child**
  `<main ref={mainRef} className="ios-scroll flex-1">` (`:144`) — NOT the root
  div and NOT `document.body`. Per-tab scroll position is tracked via `mainRef`.
- The bottom `<nav className="fixed bottom-0 … z-50">` (`:150`) is a **sibling of
  `<main>`**. It's hidden when `execute:blocking-overlay`/`execute:customize-mode`
  CustomEvents are active (`:56`, `:71`).
- Routing/stacking consequence (from project notes, not fully re-read here): a
  fixed high-z sheet inside `<main>` beats the z-50 nav only when the route root
  is a plain div; a route root that establishes a stacking context (e.g. a
  pull-to-refresh `transform`) traps child overlays *below* the nav, so such
  overlays must be portaled to `document.body`.

---

## 3. Authentication

Owner: `src/lib/AuthContext.jsx` (`AuthProvider` / `useAuth`). Backend calls go
through `backend.auth.*` in `src/api/backendClient.js`. Supabase client uses
`flowType: 'pkce'`, `detectSessionInUrl: true`, `persistSession: true`
(`backendClient.js:36-41`).

**Auth state machine.** `AuthContext` holds `user`, `isAuthenticated`,
`isLoadingAuth`, `isLoadingPublicSettings`, `authError`, plus the live RevenueCat
signal `rcCustomerInfo`. Three reconcile paths all funnel cache activation
through `appCache.activateUser(uid)`:
- `checkAppState()` (mount) — local session → activate + `checkUserAuth()`.
- `onAuthStateChange` (`AuthContext.jsx:111`) — every token refresh / sign-in:
  `appCache.activateUser(session.user.id)` (idempotent on same uid, so a refresh
  doesn't purge) then `checkUserAuth()`; on sign-out `appCache.deactivate()` +
  `resetPersonalizationCaches()`.
- `logout()` (`:275`) — `appCache.clear()` + `appCache.deactivate()` +
  `resetPersonalizationCaches()` + `backend.auth.logout()`.

**Sign-in methods** (UI in `src/components/AuthScreen.jsx`):
- **Apple + Google OAuth.** On web, `signInWithOAuth` navigates normally. On iOS
  it can't hand the session back from Safari, so `backend.auth.loginWithOAuth`
  (`backendClient.js:350`) requests the URL with `skipBrowserRedirect: true`,
  opens it in `@capacitor/browser`, and relies on a deep-link bridge.
- **iOS OAuth deep-link bridge** (`AuthContext.jsx:141-200`): listens for
  `appUrlOpen` to `com.executelabs.execute://login-callback`, closes the in-app
  browser, and exchanges the callback — handling **both** the implicit
  (`#access_token=…&refresh_token=…` → `setSession`) and PKCE (`?code=…` →
  `exchangeCodeForSession(code)`) shapes. Note the comment at `:174`: pass the
  *code value*, not the full URL.
- **Email OTP.** Web gets a magic link; iOS omits `emailRedirectTo` so Supabase
  sends a 6-digit code verified in-app via `verifyOtp` (`backendClient.js:323-349`).

`IOS_OAUTH_REDIRECT = 'com.executelabs.execute://login-callback'` must be
registered in `Info.plist` AND allow-listed in Supabase Auth URL config
(`backendClient.js:5-7`).

---

## 4. Data layer

All persistent app data flows through **one file**: `src/api/backendClient.js`,
exporting `backend`. There is a near-identical server-side mirror in
`supabase/functions/_shared/records.ts` used by edge functions.

### 4.1 The JSONB-envelope pattern
Every entity table has the **same physical shape** (verbatim from
`supabase/migrations/20260526000000_supabase_backend.sql:40-49`):
```sql
create table if not exists public.<table> (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid default auth.uid(),
  owner_email text default (auth.jwt() ->> 'email'),
  created_by text default (auth.jwt() ->> 'email'),
  user_email text default (auth.jwt() ->> 'email'),
  data jsonb not null default '{}'::jsonb,
  created_date timestamptz not null default now(),
  updated_date timestamptz not null default now()
)
```
All entity-specific fields live inside the `data` JSONB blob — **there is no
per-entity column schema**. On read, `flattenRecord` (`backendClient.js:102`)
spreads `data` up to the top level and overlays `id`/`created_by`/`user_email`/
`created_date`/`updated_date`, so callers see a flat object.

The 19 entity→table mappings are the `TABLES` const (`backendClient.js:50-70`);
the identical list is `ENTITY_TABLES` in `records.ts:4-24` and the migration's
`entity_tables` array — all three agree. See `REPO_MAP.md` for the full table.

### 4.2 EntityClient query semantics
`new EntityClient(name, table)` exposes `list / filter / create / update /
delete / subscribe` (`backendClient.js:196-302`). Important behaviors:
- **Filtering is hybrid.** `_select` (`:202`) pushes scalar criteria to Postgres
  — `id`/`created_by`/`user_email` as real columns, everything else as
  `data->>key` (`jsonPath`, `:181`). Array/object/null criteria are *not*
  server-filtered (`canServerFilter`, `:185`); `filter()` re-applies ALL criteria
  client-side via `matchesCriteria` (`:160`). Comparison is stringified
  (`String(actual) === String(expected)`).
- **Bounded reads.** Every select is `.limit(MAX_ROWS_PER_QUERY)` = 2000 (`:72`),
  then sorted/limited in JS. `list` defaults `orderBy='-created_date'`, limit 100.
- **Resilient select.** If the server query errors (e.g. ordering on a missing
  JSON path), it falls back to an unfiltered select and filters in memory (`:218`).
- **update** does a read-modify-write: fetch existing, merge `updates`, strip
  `id`/dates, write back the whole `data` blob (`:250`).

### 4.3 Row-Level Security
Each table has RLS enabled with four policies (select/insert/update/delete), all
gated on the same predicate (migration `:60-104`): `auth.role() = 'service_role'`
OR `owner_id = auth.uid()` OR any of `owner_email`/`created_by`/`user_email`
equals the JWT email. So: a user sees only their own rows; the **service role
(edge functions) bypasses RLS** — which is how webhooks write other users' rows.

### 4.4 Realtime
`EntityClient.subscribe(cb)` (`backendClient.js:275`) opens a Supabase Realtime
`postgres_changes` channel (`event:'*'`, table-scoped) and normalizes each
payload to `{ type: 'create'|'update'|'delete', data: flattenRecord(new||old),
raw }`. **Critical caveat** (from project notes): Realtime **echoes a client's
own writes back to itself** on a DB→replication→websocket round-trip (hundreds of
ms; not instant). Any UI that both reads from a subscription and writes MUST
update optimistically from in-memory state *before* awaiting the write, and treat
the subscription as an authoritative reconcile — otherwise it flashes stale.

### 4.5 Integrations & functions
- `backend.functions.invoke(name, body)` → `supabase.functions.invoke` (`:308`).
- `backend.integrations.Core.InvokeLLM(payload)` → invokes the `invoke-llm` edge
  function (`:404`). 429 surfaces with `.status` via `error.context.status` (`:311`).
- `backend.integrations.Core.UploadFile` → Supabase Storage bucket
  `VITE_SUPABASE_UPLOAD_BUCKET` (default `uploads`), returns a public URL (`:407`).

---

## 5. Caching & cold-launch hydration

This is the most intricate subsystem. Two cooperating modules plus a hook.

### 5.1 durableStore — platform-routed KV
`src/lib/durableStore.js` exposes async `getItem/setItem/removeItem/keys`,
JSON-(de)serialized, every call try/catch → no-op/null. Routed by `isNative()`:
**Capacitor Preferences** on native (survives app kill), **localStorage** on web
(`durableStore.js:26-85`). `Preferences` is imported **statically** (`:16`); the
comment at `:19-24` warns a *dynamic* `import('@capacitor/preferences')` can hang
forever on the iOS `capacitor://localhost` WebView and wedge every durable op.

### 5.2 appCache — two-tier, user-namespaced, op-serialized
`src/lib/appCache.js`. Tier 1 is an in-memory `Map` (`STORE`); Tier 2 is
`durableStore`. `get`/`isFresh`/`set` are **synchronous and read Tier 1 only**;
the durable tier is async and replayed into `STORE` once at boot.

- **Durable entry shape**: `{ v, uid, value, timestamp }` under key
  `appCache:u:<uid>:<logicalKey>`; last user at
  `appCache:__meta__:lastActiveUid` (`:29-30`, `:188-201`). `SCHEMA_VERSION = 1`
  (`:27`) — bump drops all stale-shaped entries.
- **TTL / freshness**: per-prefix `TTL_MAP` (`:42-50`, e.g. `home-dashboard` 10m,
  `plan-page` 15m, `ai-plan:*` 30m). `isFresh` compares `Date.now() - timestamp`.
- **Op-chain invariant**: every bulk op (`bootHydrate`, `activateUser`, `clear`,
  `deactivate`) runs through `enqueue` (`:89`), a single serialized promise chain
  so they never interleave. **Invariant 4 — `whenHydrated()` must ALWAYS
  resolve**: each op is raced against `OP_TIMEOUT_MS = 8000` (`:87`) and
  `bootHydrate` additionally against `BOOT_TIMEOUT_MS = 3000` (`:34`), so a hung
  Preferences bridge call advances the chain (hydrate-empty) rather than hanging
  the loading floor forever.
- **Multi-user safety**: `writeForUser(uid,…)` drops the write if `uid !==
  activeUid` (`:188`) — a background fetch that resolves after an account switch
  can't poison the new user's cache (`setForUser` is the public form, `:245`).
  `hydrateActive` only loads entries matching `prefixFor(activeUid)` and discards
  foreign-uid/stale-schema rows (`:126-150`).
- **`activateUser(uid)` switch logic** (`:319`): same uid → pure no-op (just
  persist `lastActiveUid`); **first activation** (null→uid) is treated as NOT a
  switch (boot already settled the floor, nothing to purge — re-arming would
  flicker/risk a wedge); only a genuine uid→*different* uid emits
  `hydration:start`, purges behind the floor, re-hydrates, emits `hydration:done`
  in a `finally` so the floor always re-settles (`:334-352`).
- **Events**: `appcache:hydration:start` / `appcache:hydration:done` are the only
  signals (`emit`, `:103`).

### 5.3 useCacheHydrated — the loading floor
`src/hooks/useCacheHydrated.js` returns an event-driven `ready` boolean: seeds
from `appCache.isHydrated()`, listens for the two hydration events so it
**re-arms on an in-session account switch** (`useCacheHydrated.js:16-36`).
Screens (Home, Plan per project notes) render a skeleton while `ready === false`
so an empty, not-yet-hydrated cache can never paint the `activePlan===null` CTA.
Load effects `await appCache.whenHydrated()` then re-read cache to seed state
(because `useState` initializers run pre-hydrate and see null).

---

## 6. Subscriptions & payments (dual-rail)

Two purchase rails behind one facade, one truth table, one OR-gate.

### 6.1 The facade
`src/lib/paymentClient.js` is platform-agnostic. `getPlatform() === 'ios'` →
RevenueCat/StoreKit; everything else → Stripe. Public API: `purchase(plan,
onStep)`, `restorePurchases()`, `openManageBilling()`, `getOfferings()`,
`isNativeBillingPlatform()`. Plans map `annual → $rc_annual`, `monthly →
$rc_monthly` (`paymentClient.js:22-25`). iOS calls are wrapped in `withTimeout`
with step-specific hints (`:30`) and a hard plugin-availability check
(`Capacitor.isPluginAvailable('Purchases')`, `:45`). Web `purchase` invokes the
`stripeCreateCheckout` edge fn and redirects; `openManageBilling` invokes
`stripeCreatePortal` (web) or deep-links `itms-apps://…/subscriptions` (iOS).

### 6.2 RevenueCat SDK wrapper (iOS only)
`src/lib/revenuecat.js` dynamically imports `@revenuecat/purchases-capacitor`
(so the web bundle never pulls the native plugin). Key design notes from the file
header:
- **Configured from JS, not AppDelegate** (`:10-14`): a native
  `Purchases.configure` would configure the app-target instance, not the plugin's
  `PurchasesHybridCommon` instance → `fatalError` on first `logIn`.
  `ensureConfigured()` (`:38`) configures once via a shared promise using
  `VITE_REVENUECAT_IOS_KEY`.
- **Never resolve a promise to the Capacitor proxy** (`:20-28`): the
  `registerPlugin()` proxy returns a wrapper for *any* property access including
  `.then`, so awaiting it would dispatch a phantom native call and deadlock.
  `loadModule()` resolves to the ES module namespace; callers read `.Purchases`
  synchronously.

`AuthContext` ties identity together (`AuthContext.jsx:206-259`): on iOS, when
`user.email` changes it calls `rc.loginRevenueCat(email)` so the RevenueCat
`appUserID` == the Supabase email, and seeds `rcCustomerInfo`. A customerInfo
listener busts the subscription cache and dispatches
`execute:subscription-changed` on out-of-band changes (renew/cancel/refund in iOS
Settings).

### 6.3 The truth table & the OR-gate
The single source of truth is the `user_subscriptions` table, keyed by
`user_id = email`. Read path `src/lib/subscription.js`:
- `isPremiumUser(sub)` = `plan === 'premium' && (status === 'active' ||
  'trialing')` (`subscription.js:58`).
- `loadUserSubscription(force)` reads the newest row for `{ user_id: user.email }`
  with a 60s in-memory TTL (`:79`, `bustSubscriptionCache` at `:47`).

`useSubscription()` (`src/hooks/useSubscription.js`) combines two signals:
```js
isPremium: isPremiumUser(subscription) || liveEntitled
// liveEntitled = Object.keys(rcCustomerInfo?.entitlements?.active ?? {}).length > 0
```
i.e. **webhook-written table row says premium OR live RC entitlements are
non-empty**. The hook re-reads the table on `execute:subscription-changed`
(`useSubscription.js:28-32`). Documented assumption (`:38-42`): "any active
entitlement === premium" holds ONLY while premium is the single entitlement; a
second entitlement would require making the gate identifier-specific.

### 6.4 The device never writes the truth table
Both webhooks write `user_subscriptions` via the **service role** (bypassing
RLS):
- `supabase/functions/revenuecatWebhook/index.ts` (iOS) — requires
  `Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>` (constant-time compared,
  `:175`). `buildUpdate(event)` (`:84`) maps RC event types →
  `{plan, status, cancel_at_period_end, …}`: `INITIAL_PURCHASE`/`RENEWAL`/… →
  premium active/trialing; `CANCELLATION`/`NON_RENEWING_PURCHASE` → premium +
  `cancel_at_period_end`; `EXPIRATION` → free/canceled; `BILLING_ISSUE` →
  premium/past_due; `SUBSCRIPTION_PAUSED` → free/paused; `TEST`/`TRANSFER`/
  `SUBSCRIBER_ALIAS` ignored. Upserts by `{ user_id }` via `upsertRecordBy`.
- `supabase/functions/stripeWebhook/index.ts` (web) writes the same table — I
  did NOT read this file this pass; treat its event mapping as analogous but
  verify before relying on specifics.

---

## 7. Plan generation (lazy / on-demand)

Design goal: avoid an eager 7-day generation loop. One questionnaire → one master
`AIPlan` with a 7-day *overview*; the per-day `WorkoutPlan`/`MealPlan`/`DailyLog`
records are materialized only when a day is opened.

- **Master overview**: `src/lib/generateInitialPlanBundle.js` makes ONE
  `AIPlan` via a single `backend.integrations.Core.InvokeLLM({ …,
  response_json_schema: {…} })` call (`generateInitialPlanBundle.js:561`),
  producing `plan_summary`, `nutrition_targets`, `training_split`,
  `recovery_strategy`, and a `weekly_overview` of 7 days (`KNOWN_FIELDS`, `:57`).
  It does NOT create per-day records (`:10`). `wantsWorkoutPlan` /
  `wantsNutritionPlan` (`:35-40`) are both true for BYO `planType: 'custom'`.
- **Per-day materialization**: `src/lib/plans/getOrCreateWorkoutPlanForDate.js`
  and `getOrCreateMealPlanForDate.js` **only generate when `options.generate ===
  true`** (`getOrCreateWorkoutPlanForDate.js:5`); otherwise they load the best
  existing plan. `chooseBestWorkoutPlan` (`:54`) prefers plans with exercises and
  matches on `source_plan_id` + `generation_batch_id` back to the master.
- **Batch build**: `buildWorkoutPlansForDates.js` / `buildMealPlansForDates.js`
  hoist invariant context once and pool concurrency (cap 4 per project notes) to
  avoid the 429 fan-out that serial per-day builds caused. `src/lib/withBackoff.js`
  adds full-jitter DB retry.
- **BYO ("input your own plan", `planType: 'custom'`)**: `structurePastedPlan.js`
  (LLM structuring of pasted text → `{needs_clarification|structured}`),
  `extractPdfText.js` (client `pdfjs` → quality gate → opt-in OpenAI
  `input_file`), `byoCadence.js` (activity/session/meal-focus resolution),
  `byoDraft.js` (durableStore crash-draft). No DB schema change — persisted inside
  existing JSON columns.
- **`generateInitialPlans.js` is legacy** — its old flow is disabled; it only
  still exports `buildAnswerContext` + `calcTDEE`, imported by the bundle
  (`generateInitialPlanBundle.js:21`).

> I read the head of `generateInitialPlanBundle.js` (helpers/prompt-derivation)
> and the single LLM call site, but NOT the full ~600-line body (validation,
> per-day slicing, persistence). Treat the end-to-end persistence details as
> "verify in source" rather than fully specified here.

---

## 8. Edge functions (Deno) — the backend tier

All under `supabase/functions/`, sharing `_shared/cors.ts` (`handleCors`, `json`)
and `_shared/records.ts` (`getUser`, `createServiceClient`, the
`findRecords`/`createRecord`/`updateRecord`/`upsertRecordBy` JSONB helpers that
mirror the client `EntityClient`).

| Function | Auth | Role | Purpose |
|---|---|---|---|
| `invoke-llm` | `getUser(req)` (must be signed in) | user client | Proxy to OpenAI `/v1/responses`. Builds `input` content from `prompt` + optional `input_file` (PDF base64) + `file_urls` (images). Model `payload.model || OPENAI_MODEL || 'gpt-4.1-mini'`; `max_output_tokens` default 4096. Full-jitter backoff on 429/≥500 (`LLM_MAX_ATTEMPTS=5`, `LLM_DEADLINE_MS=45000`), honors `Retry-After`; `FORCE_LLM_429` env test hook. Optional `response_json_schema` → strict-false json_schema output, parsed server-side. |
| `revenuecatWebhook` | `Bearer REVENUECAT_WEBHOOK_SECRET` | service role | iOS IAP events → `user_subscriptions` (see §6.4). |
| `stripeWebhook` | (Stripe signature — not re-read) | service role | Web Stripe events → `user_subscriptions`. |
| `stripeCreateCheckout` | user | — | Create a Stripe Checkout session; returns `{ url }`. |
| `stripeCreatePortal` | user | — | Open the Stripe billing portal; returns `{ url }`. |
| `deleteUserData` | user | service role (assumed) | Account deletion (called from `Profile.jsx` → `DeleteAccountModal`). Not re-read this pass. |

`invoke-llm` request shape (verbatim core, `invoke-llm/index.ts:121-140`):
```ts
const requestBody = { model, input: [{ role: 'user', content }], max_output_tokens };
if (payload.temperature !== undefined) requestBody.temperature = payload.temperature;
if (payload.response_json_schema) requestBody.text = { format: { type: 'json_schema', name, schema, strict: false } };
```

---

## 9. Build & native packaging

- **Web build**: `vite build` → `dist/`. `vite.config.js` pins the Rollup input
  to root `index.html` (so the scanner never crawls `ios/`), **disables CSS code
  splitting** (`cssCodeSplit: false`) because Capacitor's WKWebView sometimes
  never fires `load` on dynamically injected `<link>` → Vite's preload helper
  hangs and freezes any dynamic `import()` carrying a CSS dep
  (`vite.config.js:22-29`).
- **Aliases** (`vite.config.js:31-37`): `@` → `./src`; **`lucide-react` →
  `./src/lib/lucide-react.js`** and **`recharts` → `./src/lib/recharts.js`** are
  hand-maintained re-export *shims*. Importing a member not re-exported passes
  lint+tsc but **fails the build** — a recurring gotcha (see `REPO_MAP.md`).
- **iOS**: `npm run ios:sync` = `vite build && cap sync ios` copies `dist/` into
  `ios/App/App/public/`. Capacitor 8 is **SPM-based, no Podfile**; native plugins
  live in `ios/App/CapApp-SPM/Package.swift` (App, Browser, Preferences,
  RevenueCat Purchases). `capacitor.config.ts` sets `webDir: 'dist'` and **no
  `server.url`** (assets bundled locally → App Store Guideline 4.2). Deployment
  target 15.0.

---

## 10. Cross-cutting conventions & invariants
- **Single source of truth, restated**: subscription = `user_subscriptions` row
  (server-written) OR-ed with live RC entitlements (read-only on device); plan =
  the canonical master `AIPlan`; cache hydration = `appCache` op-chain.
- **Optimistic-by-default** for any UI reading from Realtime or async caches; the
  round-trip echo is not instant, so reconcile to authoritative on arrival.
- **uid-scoped everything**: cache entries, RLS, RevenueCat identity, and
  background-write guards are all keyed to the active user; an account switch
  purges behind the loading floor.
- **Fail-open to "cold load", never hang**: timeouts on durable ops and the boot
  hydrate guarantee the loading floor lifts even if storage stalls.
- **Where decisions/“why” live**: `docs/DECISIONS.md` (append-only) and
  `CLAUDE.md` (current rules). This doc describes mechanism, not rationale beyond
  what's in the code.

---

_Last verified against (read this session): `src/App.jsx`, `src/main.jsx`,
`src/api/backendClient.js`, `src/lib/AuthContext.jsx`, `src/lib/platform.js`,
`src/lib/revenuecat.js`, `src/lib/subscription.js`, `src/lib/paymentClient.js`,
`src/lib/durableStore.js`, `src/lib/appCache.js`, `src/hooks/useSubscription.js`,
`src/hooks/useCacheHydrated.js`, `src/lib/generateInitialPlanBundle.js` (head +
LLM call site only), `src/lib/plans/getOrCreateWorkoutPlanForDate.js` (head),
`src/components/layout/AppShell.jsx` (`<main>`/nav block), `vite.config.js`,
`supabase/functions/invoke-llm/index.ts`,
`supabase/functions/revenuecatWebhook/index.ts`,
`supabase/functions/_shared/records.ts`,
`supabase/migrations/20260526000000_supabase_backend.sql` (table + RLS block).
NOT read this pass (stated inline where relied upon): full body of
`generateInitialPlanBundle.js`, `personalizationSync.js`, `stripeWebhook`,
`stripeCreateCheckout/Portal`, `deleteUserData`, AppShell scroll-restore logic.
Read/verified 2026-06-27._
