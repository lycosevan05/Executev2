# KEY_FLOWS.md — Execute (Executev3) Runtime Behavior

End-to-end sequences for the load-bearing flows in Execute — the "how it
actually works" that the structure docs don't capture. Read
[`REPO_MAP.md`](./REPO_MAP.md) for orientation and
[`DATA_MODEL.md`](./DATA_MODEL.md) for the schema; this doc does **not**
re-document tables.

> **Two facts carried forward from DATA_MODEL.md (do not re-derive):**
>
> 1. The 19 entity tables are a generic JSONB-bag schema. Entity-specific fields
>    (`plan.weekly_overview`, `dailyLog.steps`, `subscription.status`, …) live in
>    `data` and are **app-convention, not DB-enforced**. Every flow below that
>    reads/writes an entity field is operating on that bag.
> 2. The de-facto read/write boundary is `flattenRecord` / `recordPayload` in
>    `src/api/backendClient.js`. On read, `data` is spread to the top level and
>    `owner_id`/`owner_email` are dropped; on write, `created_by`/`user_email`
>    are duplicated into both the wrapper columns and inside `data`. Treat that
>    pair as the contract — there are no types.

Each flow uses the same shape: **Trigger → Steps (file + function) → Failure
modes & mitigations → Gotchas.**

---

## 1. Auth — Sign in with Apple → Supabase PKCE → session

**Trigger:** User taps "Continue with Apple" on `AuthScreen`
(`src/components/AuthScreen.jsx`, button at line 136 → `handleOAuth('apple')`).
Google is identical; the only divergence is email OTP (covered at the end).

### Steps

1. **`AuthScreen.handleOAuth(provider)`** (`AuthScreen.jsx:34`) sets a spinner and
   calls `loginWithOAuth('apple')` from `useAuth()`.
2. **`AuthContext.loginWithOAuth`** (`src/lib/AuthContext.jsx:271`) →
   **`backend.auth.loginWithOAuth(provider)`** (`backendClient.js:350`).
3. Inside `loginWithOAuth`, the path **forks on platform** via `getPlatform()`:
   - **iOS** (`backendClient.js:354-372`): calls
     `supabase.auth.signInWithOAuth({ provider, options: { redirectTo: IOS_OAUTH_REDIRECT, skipBrowserRedirect: true } })`.
     `IOS_OAUTH_REDIRECT = 'com.executelabs.execute://login-callback'`
     (`backendClient.js:7`). `skipBrowserRedirect` makes Supabase **return** the
     provider URL instead of navigating `window.location` (which on iOS would
     dump the user into Safari with no way back). It then dynamically imports
     `@capacitor/browser` and calls `Browser.open({ url, presentationStyle: 'popover' })`.
     Returns `{ ok: true }` immediately — the session does **not** exist yet.
   - **Web** (`backendClient.js:374-379`): `signInWithOAuth({ provider, options: { redirectTo } })`
     with no `skipBrowserRedirect`, so Supabase navigates the page; the session
     lands via `detectSessionInUrl` on return. The rest of this flow is iOS-only.
4. **Apple auth completes in the in-app browser.** Supabase redirects to
   `com.executelabs.execute://login-callback?code=…` (PKCE) — or, for some
   providers, `#access_token=…&refresh_token=…` (implicit). The Supabase client
   was created with `flowType: 'pkce'` (`backendClient.js:40`), so Apple/Google
   normally come back as `?code=`.
5. **iOS hands the custom-scheme URL to the app** via Capacitor's `appUrlOpen`
   event. The listener is attached in **`AuthContext`'s iOS deep-link effect**
   (`AuthContext.jsx:141-200`), guarded by `getPlatform() === 'ios'`. It imports
   `@capacitor/app` and registers `App.addListener('appUrlOpen', …)`.
6. **The handler** (`AuthContext.jsx:151`):
   - Ignores any URL not starting with `com.executelabs.execute://login-callback`.
   - Closes the in-app browser (`Browser.close()`).
   - **Implicit branch** (`:162-172`): if the URL has a `#` fragment containing
     `access_token=`, parses `access_token`/`refresh_token` and calls
     `supabase.auth.setSession({ access_token, refresh_token })`.
   - **PKCE branch** (`:173-182`): if the URL contains `code=`, extracts **only
     the code value** via `new URL(url).searchParams.get('code')` and calls
     `supabase.auth.exchangeCodeForSession(code)`. The inline comment
     (`:174-176`) is load-bearing: passing the **full URL** instead of the bare
     code makes the exchange fail and strands the user on the login screen.
   - Either branch then awaits `checkUserAuth()`.
7. **`AuthContext.checkUserAuth`** (`AuthContext.jsx:26`): calls
   `backend.auth.me()` (`backendClient.js:318` → `currentSupabaseUser()` →
   `supabase.auth.getUser()`), sets `user`/`isAuthenticated`, and calls
   `appCache.activateUser(currentUser.id)` to reconcile the cache to this uid.
8. **Independently, `supabase.auth.onAuthStateChange`** (`AuthContext.jsx:111`)
   fires on the new session. It calls `appCache.activateUser(session.user.id)`
   (idempotent on same uid) and `checkUserAuth()` again. So the authenticated
   state is reached whether or not the deep-link handler's own `checkUserAuth`
   wins — they converge.
9. **RevenueCat identity attaches** (iOS): a separate effect keyed on
   `user?.email` (`AuthContext.jsx:206-231`) calls `loginRevenueCat(email)` once
   a user exists (see Flow 3, step "identity").

**App-state bootstrapping (cold launch, before any tap):**
`AuthContext.checkAppState` (`AuthContext.jsx:49`) runs on mount. It calls
`supabase.auth.getSession()` — a **local, no-network** read — and, if a session
exists, calls `appCache.activateUser(session.user.id)` off the local uid
(`:78`) *before* the networked `me()`. The comment at `:75-77` notes this lets
an **offline cold launch** activate the right user even if `me()` later fails.

### Failure modes & mitigations
- **User dismisses the browser without finishing:** `handleOAuth` clears its
  spinner in the success path (`AuthScreen.jsx:43`) precisely so the button
  doesn't spin forever when the deep link never arrives.
- **Token exchange throws:** caught in the handler (`AuthContext.jsx:183-191`),
  logged, and surfaced as `authError` — the comment (`:184-185`) notes a
  swallowed error here looks like an endless login loop.
- **`appUrlOpen` listener fails to attach:** caught at `:194-195`, warns; OAuth
  on iOS then silently can't complete (no fallback).
- **Supabase returns no URL:** thrown at `backendClient.js:368`.

### Gotchas
- There are **two** independent `checkUserAuth` triggers (deep-link handler +
  `onAuthStateChange`). This is intentional redundancy, not a bug — but it means
  `checkUserAuth` and `me()` can run twice per sign-in.
- **iOS email OTP is a different flow:** `backend.auth.loginWithOtp`
  (`backendClient.js:323`) omits `emailRedirectTo` on iOS (`:329`), so Supabase
  sends a **6-digit code** instead of a magic link (a link can't hand a session
  back to the native app). The user types it; `AuthScreen.handleVerify`
  (`AuthScreen.jsx:64`) → `verifyOtp` → `supabase.auth.verifyOtp({ type: 'email' })`
  (`backendClient.js:340`). Web keeps the magic-link flow. `useCode = isIOS()`
  (`AuthScreen.jsx:30`) switches the UI.
- **`activateUser` is the cache's switch primitive** and is called from *three*
  places during auth (checkAppState, checkUserAuth, onAuthStateChange) — all
  idempotent on the same uid (see Flow 4).

---

## 2. Plan generation — `generateInitialPlanBundle` + `invoke-llm`

> **`generateInitialPlans.js` is legacy and NOT the live path.** The old eager
> "generate all 7 days up front" flow is disabled. That module exports **three**
> symbols: `buildAnswerContext` (`:137`) and `calcTDEE` (`:222`) — both live,
> imported by the bundle (`generateInitialPlanBundle.js:21`) — plus
> `generateInitialPlans()` itself (`:284`), a **disabled stub that `throw`s**
> ("use `generateInitialPlanBundle`…"). The other throwing guard,
> `operationalizeWeeklyPlan()`, does **not** live in this module — it is in
> **`personalizationSync.js:1344-1348`** (it blocks legacy child-projection
> creation). Do not document a dead eager-generation flow — there is exactly
> **one** LLM call at plan creation.

**Trigger:** User finishes `PlanQuestionnaire` →
`Plan.handleQuestionnaireSubmit(answers)` (`src/pages/Plan.jsx:325`). Gated
behind `useSubscription` (the questionnaire only mounts for premium users).

### Steps (overview generation — ONE LLM call)

1. **`Plan.handleQuestionnaireSubmit`** (`Plan.jsx:325`) calls
   **`startGeneration(answers)`** then immediately
   **`subscribeToGeneration(applyGenerationResult)`** (`Plan.jsx:345-346`). The
   comment (`:343-344`) notes the subscribe happens right after start so the page
   is guaranteed attached before completion; completion is delivered **only**
   through the subscriber.
2. **`startGeneration`** (`src/lib/planGenerationState.js:63`) is a singleton: if
   a generation is already in-flight it returns the existing `_promise`
   (re-attach). It persists `answers` to `sessionStorage` via
   `savePendingAnswers(answers)` (`:66` → `sessionStorage.setItem`, `:20`) for
   crash/nav recovery, races `generateInitialPlanBundle(answers)` against a
   **3-minute timeout** (`:69-71`), and on settle notifies all `_listeners` and
   buffers `_lastResult`
   for late subscribers (`:78-97`). This is what lets the user navigate away
   mid-generation and still receive the result on return
   (`subscribeToGeneration` replays a buffered, unclaimed result at `:111-118`).
3. **`generateInitialPlanBundle(answers)`** (`src/lib/generateInitialPlanBundle.js:471`):
   - **Step 1** (`:477`): `savePlanQuestionnairePersonalization(answers)` — writes
     the profile entities.
   - **Step 2** (`:480`): `invalidateUserAIContext()`.
   - **Step 2b** (`:486-530`, BYO only — see Flow 6).
   - **Step 3** (`:533`): `calcTDEE(answers)` (imported from the legacy module)
     computes macros **synchronously**, before any LLM call.
   - **Step 4** (`:557-630`): builds one large prompt via `buildOverviewPrompt`
     (`:159`) and calls **`backend.integrations.Core.InvokeLLM({ prompt, response_json_schema })`**.
     The schema (`:563-629`) requires `plan_summary`, `nutrition_targets`,
     `training_split`, `recovery_strategy`, `weekly_overview` with **exactly 7
     days**. The prompt explicitly forbids generating detailed workouts/meals —
     this is the "lightweight overview", not the full plan.
   - **Step 5** (`:633-637`): `unwrapOverviewResponse` (handles markdown fences +
     wrapper keys) then `normalizeAndValidateOverview` (forces `day_type` ⇄
     `workout_needed` consistency, fills generic titles, throws on a bad shape).
   - **Step 6** (`:660-665`): `bustPlanCache('daily')`, then **archive every
     existing active AIPlan** (`status: 'active'` → `'archived'`).
   - **Step 7** (`:671-721`): `AIPlan.create(...)` with the overview, a
     `generation_batch_id` (`:28`, `batch_<ts>_<rand>`), `source:
     'plan_questionnaire_overview'`, and the full overview duplicated into
     `plan_payload`. Then `bustPlanCache('daily')` + `invalidateUserAIContext()`
     again.
   - Returns `{ success, aiPlan, plan, masterPlan, overview, generation_batch_id }`.
4. **`Plan.applyGenerationResult(err, result)`** (`Plan.jsx:210`) is the single
   completion handler (only ever called via the subscriber). On rate-limit error
   it shows a 429-specific message (`:212-213`); on success it adopts the new
   plan.

### Steps (per-day workouts — lazy, on demand)

The bundle deliberately creates **no** `WorkoutPlan`/`MealPlan`/`DailyLog` rows
(comment `generateInitialPlanBundle.js:727`). Those are generated when a day is
opened, via:

5. **`getOrCreateWorkoutPlanForDate(date, { generate })`**
   (`src/lib/plans/getOrCreateWorkoutPlanForDate.js:132`): loads the active
   master `AIPlan`, finds the matching `weekly_overview.days[date]`, and:
   - returns an existing `WorkoutPlan` with exercises if present (`:172-174`),
   - returns `{ status: 'rest_day' }` for non-training days (`:188`),
   - returns `{ status: 'needs_generation' }` if `generate !== true` (`:193`),
   - otherwise builds one workout with a **second** `InvokeLLM` call
     (`:339-362`, `max_output_tokens: 2000`), validates 4–8 exercises
     (`validateWorkout`, `:102`), and `WorkoutPlan.create`s it linked by
     `source_plan_id` + `generation_batch_id`.
6. **Multi-day "Build all"** goes through **`buildWorkoutPlansForDates(dates)`**
   (`src/lib/plans/buildWorkoutPlansForDates.js:47`), called from
   `Workouts.jsx` / `MyWeek.jsx` / `Home.jsx`. It hoists the invariant context
   (`UserProfile`, `WorkoutProfile`, `InjuryProfile`, `ReadinessCheckIn`)
   **once** (`:62-74`), then runs per-day generation with a **concurrency cap of
   4** (`pooledMap`, `:27`; `DAY_BUILD_CONCURRENCY = 4`, `:20`), passing that
   `context` into `getOrCreateWorkoutPlanForDate` so each day does **zero**
   invariant re-reads (`getOrCreateWorkoutPlanForDate.js:209-213`).

### Rate-limit / backoff handling (the load-bearing part)

This exists because the multi-day build used to 429 from two sources: DB
fan-out (PostgREST 429s) and OpenAI TPM (429s). Both are now absorbed:

- **DB side — `withBackoff(fn)`** (`src/lib/withBackoff.js:53`): full-jitter
  exponential backoff (`retries: 5`, `baseMs: 300`, `capMs: 8000`,
  `deadlineMs: 30000`). `defaultRetryable` (`:22`) matches `status` 429/503/5xx
  **and** text-matches `/429|rate.?limit|too many|service unavailable|503/`
  because PostgREST 429s don't always surface a clean numeric status through the
  backend error wrapper (`:18-21`). Honors `retry-after[-ms]` as a minimum wait.
  Wraps every per-day DB op in `getOrCreateWorkoutPlanForDate` (`:167`, `:390`,
  `:397`, `:401`) and the hoisted context read (`buildWorkoutPlansForDates.js:67`).
- **OpenAI side — edge function** `supabase/functions/invoke-llm/index.ts`:
  `fetchOpenAIWithBackoff` (`:27`) retries 429 + ≥500 with full-jitter backoff
  (`LLM_MAX_ATTEMPTS: 5`, `LLM_BASE_MS: 500`, `LLM_PER_WAIT_CAP_MS: 20_000`,
  `LLM_DEADLINE_MS: 45_000`), honoring `retry-after-ms`/`retry-after` headers
  (`parseRetryAfterMs`, `:13`) as a minimum, capping the wait at the remaining
  deadline (`:55`), and draining the response body so the connection is reused
  (`:58`). `FORCE_LLM_429` env var injects synthetic 429s for testing (`:36-40`,
  `:142`).
- **Fan-out removal:** the per-day path used to fire 3 parallel `WorkoutPlan`
  queries; it's now a single widest-net query (`getOrCreateWorkoutPlanForDate.js:161-169`),
  and the invariant reads are hoisted once (proof-of-once log at
  `buildWorkoutPlansForDates.js:84`).

**How a 429 surfaces to the UI:** `invoke-llm` returns the OpenAI error status
verbatim (`index.ts:153-158`). `invokeFunction` (`backendClient.js:308`) maps it
to `error.context?.status` (`:311`). `Plan.applyGenerationResult` detects 429 by
message substring (`Plan.jsx:212`) and shows a rate-limit message.

### Failure modes & mitigations
- **Generation hangs:** the 3-minute race in `startGeneration` rejects it
  (`planGenerationState.js:69-71`).
- **Non-parseable LLM JSON:** `invoke-llm` returns 502
  (`index.ts:164-165`); `unwrapOverviewResponse` throws (`generateInitialPlanBundle.js:74`).
- **Overview fails validation** (wrong day count, missing fields):
  `normalizeAndValidateOverview` throws (`generateInitialPlanBundle.js:454-456`).
- **A single day's build fails** in the multi-day path: isolated by
  `pooledMap`'s per-item try/catch (`buildWorkoutPlansForDates.js:95-99`) — other
  days still succeed; the failed day returns `needs_generation`.

### Gotchas
- **`invoke-llm` requires auth**: it calls `getUser(req)`
  (`invoke-llm/index.ts:84` → `_shared/records.ts:54`), 401 if the JWT is
  missing/invalid. The browser client always sends the session JWT through
  `supabase.functions.invoke`.
- **Nutrition now mirrors the workout fix (verified by direct read
  2026-06-27 — supersedes the earlier "deliberately un-fixed" note):** the
  multi-day meal build wraps its hoisted invariant context in `withBackoff`
  (`buildMealPlansForDates.js:67`, concurrency cap 4), and
  `getOrCreateMealPlanForDate.js` wraps the existing-plan filter reads
  (`:168`/`:170`), the FoodLog read (`:201`), and `MealPlan.create` (`:404`) in
  `withBackoff` — with the swallowing `.catch` placed **outside** the wrapper so
  a first 429 retries instead of collapsing to "no plan." The LLM call sets
  `max_output_tokens: 2500` (`:365`). Residual: the single-day **no-`context`
  fallback** branch (`:204–218`) still does bare `Promise.allSettled` invariant
  reads with no backoff, but the multi-day build always passes `context`, so the
  burst path that used to 429 is covered.
- **Two LLM calls per opened training day total**: one overview (at plan
  creation) + one per day (lazy). Never a 7× burst.

---

## 3. IAP / subscription — RevenueCat purchase → entitlement → webhook → client

**Trigger:** User taps a plan on `PremiumPaywall`
(`src/components/premium/PremiumPaywall.jsx`) → `purchase(plan)` from
`src/lib/paymentClient.js`.

### Steps (the purchase, iOS)

1. **`paymentClient.purchase(plan, onStep)`** (`paymentClient.js:123`) forks on
   `getPlatform()`. iOS → `purchaseIOS`; everything else → `purchaseWeb`
   (Stripe checkout redirect, `:99`).
2. **`purchaseIOS`** (`paymentClient.js:41`):
   - Hard-checks `Capacitor.isPluginAvailable('Purchases')` (`:45`) — if the
     native plugin didn't load, every native call would hang, so it throws a
     descriptive rebuild error instead.
   - Dynamically imports `@/lib/revenuecat`, calls `initRevenueCat()` (idempotent
     configure), `getOfferingsRevenueCat()`, picks the package by `packageType`
     (`MONTHLY`/`ANNUAL`) then identifier (`$rc_monthly`/`$rc_annual`,
     `PLAN_TO_RC_IDENTIFIER`, `:22`), and calls `purchasePackageRevenueCat(pkg)`.
   - Every native call is wrapped in `withTimeout` (`:30`) with a step-specific
     hint so a frozen StoreKit sheet surfaces as a visible error.
   - On success: `bustSubscriptionCache()` (`:81`) and returns
     `{ ok: true, transaction }`.
3. **`revenuecat.js` configures the SDK from JS, not natively**
   (`src/lib/revenuecat.js`). `ensureConfigured` (`:38`) calls
   `Purchases.configure({ apiKey: VITE_REVENUECAT_IOS_KEY })` exactly once,
   guarded by a shared promise. The module imports the plugin via a **dynamic
   import that resolves to the ES module namespace, never the Capacitor proxy**
   (`loadModule`, `:29`) — the comment (`:20-28`) is load-bearing: the
   `registerPlugin()` proxy returns a native-method wrapper for *any* property
   including `then`, so resolving a promise *to* the proxy would dispatch a
   phantom `proxy.then(...)` bridge call and deadlock the await. CLAUDE.md
   explains *why* JS-side: a native `Purchases.configure` in AppDelegate would
   configure the app-target instance, leaving the plugin's
   `PurchasesHybridCommon` instance unconfigured → `fatalError` on first
   `logIn`/`getOfferings`.

### Steps (identity — keying RC to Supabase)

4. **`AuthContext` RevenueCat effect** (`AuthContext.jsx:206-231`, iOS only,
   keyed on `user?.email`): on sign-in calls
   `loginRevenueCat(email)` (`revenuecat.js:59` → `Purchases.logIn({ appUserID: email })`),
   seeding `rcCustomerInfo` from the returned `LogInResult.customerInfo`. On
   sign-out calls `logoutRevenueCat()`. **The Supabase email is the RevenueCat
   `appUserID`** — this is what makes the webhook's `event.app_user_id` equal the
   `user_id` column server-side.

### Steps (entitlement → server → client)

5. **RevenueCat fires `revenuecatWebhook`** (server-to-server) on every
   entitlement change. On the **iOS rail** it is the **only** writer of
   `user_subscriptions` rows, and **the device never writes that table** (`src/`
   only ever `.filter`s it — `subscription.js:89`). This is *iOS-scoped*, not
   "nothing writes this table anywhere": `stripeWebhook` writes the same table
   on the web rail (and `stripeCreateCheckout`/`stripeCreatePortal` only read
   it). So globally there are two server-side writers; on iOS, just this one:
   - Requires `Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>`, compared in
     **constant time** (`constantTimeEqual`, `:49`); 401 otherwise.
   - `buildUpdate(event)` (`:84`) maps the RC event type to
     `{ plan, status, cancel_at_period_end, … }`: `INITIAL_PURCHASE`/`RENEWAL`/
     `PRODUCT_CHANGE`/`UNCANCELLATION`/`SUBSCRIPTION_EXTENDED`/
     `TEMPORARY_ENTITLEMENT_GRANT` → `plan:'premium'`, `status` `trialing` if
     `period_type==='TRIAL'` else `active`; `CANCELLATION`/`NON_RENEWING_PURCHASE`
     → premium+active but `cancel_at_period_end:true`; `EXPIRATION` →
     `free`/`canceled`; `BILLING_ISSUE` → premium/`past_due`;
     `SUBSCRIPTION_PAUSED` → `free`/`paused`; `TEST`/`TRANSFER`/`SUBSCRIBER_ALIAS`
     → `null` (acknowledged + skipped, `:156-160`).
   - `upsertSubscription` (`:63`) writes via `createServiceClient()` +
     `upsertRecordBy(service, 'user_subscriptions', { user_id }, payload, userId)`
     (`_shared/records.ts:160`). `service_role` **bypasses RLS** (see
     DATA_MODEL §5). `user_id` stores the **email** (matching `stripeWebhook`).
6. **Client learns entitlement state two ways (OR-gate)** —
   **`src/hooks/useSubscription.js`**:
   - **Webhook-written table:** `loadUserSubscription(force)`
     (`src/lib/subscription.js:79`) reads the latest `UserSubscription` row
     filtered by `{ user_id: user.email }` (`:89-93`), cached 60s in-memory
     (`CACHE_TTL_MS`, `:45`). `isPremiumUser(sub)` (`:58`) = `plan==='premium' &&
     (status==='active' || 'trialing')`.
   - **Live RC entitlements:** `rcCustomerInfo` from `AuthContext`.
     `liveEntitled = Object.keys(rcCustomerInfo?.entitlements?.active ?? {}).length > 0`
     (`useSubscription.js:43`).
   - **`isPremium = isPremiumUser(subscription) || liveEntitled`**
     (`useSubscription.js:49`). The live signal gives **instant unlock** before
     the webhook round-trips; the table is the durable truth.
7. **Out-of-band changes propagate:** `AuthContext`'s customerInfo listener
   (`AuthContext.jsx:237-259`, `addCustomerInfoUpdateListener`) fires on
   renewal/cancel/refund (even from iOS Settings while the app is open). It
   updates `rcCustomerInfo`, calls `bustSubscriptionCache()`, and dispatches
   `execute:subscription-changed`. `useSubscription`'s listener
   (`useSubscription.js:28-32`) re-reads the table on that event.

### Failure modes & mitigations
- **Native plugin missing from build:** explicit throw with rebuild steps
  (`paymentClient.js:47-49`).
- **StoreKit/offerings hang:** per-step `withTimeout` (`paymentClient.js:52-80`).
- **No "current" offering:** descriptive throw listing found offerings (`:62-64`).
- **Webhook unauthorized:** constant-time 401 (`revenuecatWebhook/index.ts:175`).
- **Webhook before RC identity attached** (no `app_user_id`): skipped, not
  errored (`:192-195`).
- **Webhook DB write fails:** 500, RC will retry (`:204-208`).

### Gotchas
- **`isPremium` is a count-based OR-gate, not entitlement-id-specific**
  (`useSubscription.js:34-43`). The inline ASSUMPTION (`:38-42`) is load-bearing:
  *any* active entitlement unlocks premium. This is safe **only** while premium
  is the only entitlement the RC project can grant. Add a second entitlement and
  this silently unlocks full premium — make the gate id-specific first.
- **`rcCustomerInfo` is never persisted by the client** (`AuthContext.jsx:13-16`)
  — it's a live mirror of the SDK only; on iOS the webhook remains the sole table
  writer (web is `stripeWebhook` — see step 5).
- **`user_id` column holds an email**, not a uuid — both webhooks key on it, and
  `loadUserSubscription` filters by `user.email`.
- **`openManageBilling` on iOS** deep-links to
  `itms-apps://apps.apple.com/account/subscriptions` (`paymentClient.js:145`);
  web opens the Stripe portal.

---

## 4. Caching — stale-while-revalidate over Capacitor Preferences

**Trigger:** App module init (`appCache.bootHydrate()` runs as a side-effect at
`src/lib/appCache.js:372`) + every screen mount that reads cache.

### What's cached, and where
Two tiers (`appCache.js:1-20`):
- **Tier 1 — in-memory `Map` (`STORE`)**: the **only** thing the synchronous
  `get`/`isFresh` read (`:222`, `:228`). Zero latency.
- **Tier 2 — durable** via `durableStore` (`src/lib/durableStore.js`): routed by
  `isNative()` → **Capacitor `Preferences`** on iOS, `localStorage` on web.
  Survives a true iOS app kill (the old `sessionStorage` tier did not — that was
  the cold-launch flash root cause). Entries are namespaced + tagged:
  `{ v, uid, value, timestamp }` under key `appCache:u:<uid>:<logicalKey>`
  (`:29`, `:188-202`). `lastActiveUid` at `appCache:__meta__:lastActiveUid`.

Logical keys with TTLs (`TTL_MAP`, `appCache.js:42-50`): `home-dashboard` (10m),
`plan-page` (15m), `ai-plan:daily`/`weekly` (30m), `user-email` (60m),
`user-profile` (15m), `meal-plan:<date>` (default 10m, capped to 14 days).

> **`Preferences` is imported STATICALLY** (`durableStore.js:16`). A **dynamic**
> `import('@capacitor/preferences')` hangs forever on iOS `capacitor://localhost`
> (the bridge call never resolves), wedging every durable read/write. Confirmed
> on-device. Do not convert it to a dynamic import.

### Steps (cold launch / hydration)
1. **`bootHydrate()`** (`appCache.js:300-312`) is enqueued as the **first** op on
   a single serialized op-chain (`enqueue`, `:89`) at module init, before any
   React effect runs.
2. **`bootHydrateInner`** (`:204`): reads `lastActiveUid`, sets `activeUid`,
   `pruneDurable()` (age cap 7d + meal-plan cap 14, `:152`), then
   `hydrateActive()` (`:126`) replays that uid's durable entries into `STORE`,
   **dropping foreign-uid or stale-schema entries** (`:141-143`).
3. **The loading floor:** `bootHydrate` **always** settles `hydrated = true` and
   emits `appcache:hydration:done` — even on empty/absent/failed reads and on a
   `BOOT_TIMEOUT_MS = 3000` timeout (`:300-311`). `useCacheHydrated`
   (`src/hooks/useCacheHydrated.js`) turns those events into a `ready` boolean.
4. **Screens gate on it:** Home/Plan hold a skeleton until `cacheReady`, then
   `await appCache.whenHydrated()` (returns the op-chain tail, `:290`) and re-read
   cache to seed state — because `useState` initializers run *pre-hydrate* and
   would see an empty `STORE`.
5. **SWR read pattern:** a screen reads `appCache.get(key)` for instant paint,
   checks `isFresh(key)`, and kicks a background network refresh that writes back
   via `set`/`setForUser`. `set` → `writeForUser` (`:188`) updates `STORE`
   synchronously and fire-and-forget persists to durable (`:195`).

### Invalidation
- `invalidate(keyOrPrefix)` (`:250`): prefix-deletes from `STORE` and (async,
  scoped to `activeUid`) from durable.
- `activateUser(uid)` (`:319`): **idempotent on same uid** (no clear, no floor
  flicker; just persists `lastActiveUid`). A genuine **non-null A → different
  non-null B** switch emits `hydration:start`, purges B-behind-the-floor
  (`clearDurableData`), swaps `activeUid`, re-hydrates, and re-emits
  `hydration:done` in a `finally` so the floor can never wedge (`:334-352`).
  **null → user is NOT a switch** (`isSwitch = activeUid !== null`, `:334`) — the
  comment (`:326-333`) is load-bearing: re-arming the floor on initial activation
  could wedge `hydration:done`.
- `deactivate()` (logout, `:357`): purge + drop uid.
- `clear()` (`:270`): empties durable for all users.

### The cold-launch flash this prevents
Without a durable tier, a killed-and-relaunched iOS app starts with an empty
cache, so a plan-less *or* plan-having user briefly paints the wrong state
(e.g. the "Build my plan" CTA for a user who *has* a plan, or vice-versa) until
the network resolves. By replaying the last-active user's durable snapshot into
`STORE` before the floor lifts, the first paint is the **last known correct**
state, with the network refreshing as SWR. (MEMORY documents a Home-specific
nuance: `loadedOnce` flips true right after re-seeding from a cached
`home-dashboard` snapshot — even `activePlan:null` is a definitive answer — so a
plan-less user's CTA isn't held behind the skeleton.)

### Failure modes & mitigations
- **Durable op hangs** (Preferences bridge stall): every op is raced against
  `OP_TIMEOUT_MS = 8000` (`:87-99`); on hang the chain advances (hydrate-empty)
  rather than wedging `whenHydrated()` forever (Invariant 4).
- **A write resolves after an account switch:** `writeForUser` drops it if
  `uid !== activeUid` (`:189`); background fetches use `setForUser(capturedUid,…)`.
- **Kill before a durable flush:** loses one key, recovered by the next cold
  network load — never wrong content (`:193-194`).

### Gotchas
- `get`/`isFresh` are **STORE-only and synchronous** — they see nothing until
  `whenHydrated()` resolves. A mount that reads without awaiting observes an
  empty cache.
- Durable entries carry `v` (`SCHEMA_VERSION = 1`); bump it to invalidate every
  older-shaped entry on next hydrate.

---

## 5. Data layer — optimistic writes + the Realtime self-echo gotcha

**Trigger:** Any UI that both **reads from `EntityClient.subscribe`** and
**writes** the same entity. The canonical case: logging a vital on Track/Home.

### How a write round-trips
1. **Write:** `EntityClient.update(id, updates)` (`backendClient.js:250`) does a
   read-modify-write: `filter({id})` → merge → `mergeUpdate` → PostgREST
   `update`. `create` (`:237`) inserts a `recordPayload`. Both return the
   `flattenRecord`'d row.
2. **DB commit → logical replication → Realtime websocket:** Supabase pushes a
   `postgres_changes` event (`event:'*'`, table-scoped) to **every** subscriber
   of that table.
3. **`EntityClient.subscribe(cb)`** (`backendClient.js:275`) maps the payload to
   `{ type:'create'|'update'|'delete', data: flattenRecord(payload.new||payload.old), raw }`.

### The self-echo gotcha
**Realtime echoes a client's own writes back to itself** — there is **no
self-exclusion** in `subscribe`. The echo is **not instant**: it's a full
round-trip (DB commit → replication → websocket), hundreds of ms later. So a UI
that re-renders only from its subscription would show a **flash of stale data**
between the user's action and the echo.

**Mitigation — optimistic-by-default (read-free, pre-await):** the writing UI
updates its own in-memory state *before* awaiting the write, then treats the
subscription as the **authoritative reconcile** when the echo arrives.

### Worked example — vitals logging (Track)
- **Save path:** `Track.handleLog` (`src/pages/Track.jsx:~284`) calls
  `saveVitalLog({ categoryId, value, planContext, dailyLogId, onOptimistic })`
  (`src/lib/vitalsLog.js:163`).
- **`saveVitalLog`** owns read → compute → optimistic → write → invalidate:
  - resolves the canonical master plan + the linked `DailyLog`
    (`:166-177`),
  - computes additive updates with `getDailyLogUpdatesForCategory`
    (`:126`; `steps`/`sleep`/`water` accumulate, `ADDITIVE_FIELDS`, `:124`),
  - fires **`onOptimistic({ uiValue, updates, targetDailyLog })`**
    **post-read / pre-write** (`:188`),
  - then `DailyLog.update`/`create` (`:192-206`),
  - then `appCache.invalidate('home-dashboard')` + `'nutrition-today-'` +
    `invalidateUserAIContext()` (`:208-210`).
- **Track's optimism:** `onOptimistic: ({ uiValue }) => setLogged(prev => ({ ...prev, [categoryId]: uiValue }))`
  (`Track.jsx:287`) — instant UI update, before the DB write.
- **Track's reconcile:** a `DailyLog.subscribe` effect (`Track.jsx:255`) merges
  any `update`/`create` for `todayStr` back into `logged` (`:259-262`). This
  catches the user's own echo **and** cross-device writes (e.g. a completed
  workout writing `calories_burned`).

### Home's variant (read-free optimism)
Home renders the **same** `LogModal` as an overlay (no route change) but holds
**no cached `DailyLog`**, so `saveVitalLog`'s internal reads run **cold**. Home
therefore applies its own **read-free** optimism *before* calling `saveVitalLog`
— merging `getDailyLogUpdatesForCategory(id, val, dailyLog)` into its in-memory
`dailyLog` pre-await (MEMORY notes: do **not** inject a date key, because Home's
local `getTodayStr` ≠ the write's `getTodayISODate`). `saveVitalLog`'s
`onOptimistic` defaults to `null` in the signature (`vitalsLog.js:163`) so a
caller passing none doesn't error.

### Failure modes & mitigations
- **Echo arrives with stale/older value:** the reconcile is a merge that only
  overwrites present fields (`Track.jsx:259-262`), and the optimistic value is
  computed from the same additive logic, so they converge.
- **Write fails after optimistic paint:** `saveVitalLog` returns
  `{ ok:false }` for unmapped categories (`:181`); a thrown DB error rejects and
  the caller's `loadTodayTracking` catch resets state (`Track.jsx:239-245`).

### Gotchas
- **Every entity table is in the realtime publication** (DATA_MODEL §2), so any
  subscriber receives its own writes. Treat `.subscribe()` as authoritative
  reconcile, **never** as the only source of post-write UI state.
- **`subscribe` channel names are random per call**
  (`backendClient.js:277`), so multiple components can independently subscribe to
  the same table.
- **`saveVitalLog`'s two loaders are not appCache-backed** → 2 cold reads per
  save (off the UI path; deferred — MEMORY).

---

## 6. BYO — "bring your own plan" (`planType: 'custom'`)

**Trigger:** User picks "Input your own plan" as the 4th questionnaire option in
`PlanQuestionnaire`, pastes/uploads a training and/or nutrition plan, and submits
→ same `Plan.handleQuestionnaireSubmit` → `generateInitialPlanBundle` path as
Flow 2. **No DB schema change** — everything persists inside existing JSON
columns (`plan_payload.byo_*` + `weekly_overview.days[i].byo_session/byo_meal_focus`).

### How an external plan enters the system (vs. a generated one)
A generated plan: questionnaire answers → `calcTDEE` → one overview LLM call →
`AIPlan`. A BYO plan inserts a **structuring pre-call** and a **per-day mapping**
so the user's own plan is reproduced faithfully and the missing side is built
around it:

1. **Structuring pre-call — `structurePastedPlan({ byoWorkoutText, byoMealText,
   byoTargets })`** (`src/lib/plans/structurePastedPlan.js:223`): one dedicated
   `InvokeLLM` call (schema `RESPONSE_SCHEMA`, `:41`) that returns **either**
   `{ needs_clarification: true, clarification: { questions } }` **or**
   `{ needs_clarification: false, structured: { workout?, nutrition? } }`. It
   derives `workout.derived_activity_level` (`never|1_2_days|3_4_days|5_plus`)
   and a `cadence` (`weekly|rotating|ab` with `advance` +
   `rest_weekdays`). Why a **separate** pre-call (comment `:4-13`): the derived
   cadence feeds `calcTDEE` which runs **before** the overview call, and sparse
   input needs an interactive clarification loop only the questionnaire UI can
   drive.
2. **In the questionnaire** (`PlanQuestionnaire.jsx`, per MEMORY): `byoScope`
   step right after `planType`; paste sheets for workout/meal; a final
   `byoStructuring` step runs the clarification loop and **auto-falls-back after
   2 rounds**. The submit payload carries
   `byoScope`/`byoTargets`/`byoWorkoutText`/`byoMealText`/`byoStructured`, all
   guarded by `planType==='custom'` (stale-text guard).
3. **PDF path (opt-in):** `extractPdfText.js` extracts text client-side with
   `pdfjs-dist`; if quality is too low it opts into sending the PDF as a base64
   data URL. `invoke-llm` has an **`input_file` content branch**
   (`invoke-llm/index.ts:101-113`) — `{ type:'input_file', filename, file_data }`
   — so OpenAI reads the PDF directly. Page/size capping is the caller's
   responsibility so cost stays bounded.
4. **Crash-draft:** `byoDraft.js` persists the in-progress paste to
   `durableStore` (`byo:draft:u:<uid>`, local-only) so an app kill mid-flow
   doesn't lose the text.

### Steps inside `generateInitialPlanBundle` (BYO-specific, Flow 2 step 2b/3/5b)
5. **Step 2b** (`generateInitialPlanBundle.js:486-530`): determines fallback
   sides (`byoFallbackSides`); if `structured` is absent but text survived (app
   killed between steps), **re-runs `structurePastedPlan` ONCE** (`:499-519`) —
   a `needs_clarification` result here can't be answered (no UI past submit), so
   it **degrades to graceful fallback** for the affected side; this path never
   throws/hangs/blocks. Then derives `currentTraining` from the structured
   workout via `normalizeActivityLevel` (`:523-529`) **before** `calcTDEE`.
6. **Macro override** (`:537-546`): a stated-calorie nutrition paste **wins** over
   the computed default (unless that side fell back to AI).
7. **`wantsWorkoutPlan`/`wantsNutritionPlan` both return true for `custom`**
   (`:35-40`) — the overview covers **both** sides; one authoritative-from-paste,
   the other AI-built.
8. **Prompt seeding** (`buildOverviewPrompt`, `:216-239`): for supplied,
   non-fallback sides, the **structured** plan (not raw paste) is injected as
   authoritative ("REPRODUCE FAITHFULLY").
9. **Step 5b — per-day mapping** (`:639-658`): for each of the 7 overview days,
   `resolveByoSession` / `resolveByoMealFocus` (`byoCadence.js`) attach
   `day.byo_session` / `day.byo_meal_focus` for supplied sides — so downstream
   per-day reads are cheap and never re-inject raw text.
10. **Persisted** (`:712-719`) under `plan_payload`: `byo_targets`,
    `byo_workout_text`/`byo_meal_text` (kept **only** as last-resort per-day
    fallback), `byo_structured`, `byo_cadence`, `byo_fallback_sides`.
11. **Per-day workout** (`getOrCreateWorkoutPlanForDate.js:254-270`): injects
    **only this date's** `byo_session` slice (pre-mapped for the first 7 days,
    else resolved via cadence from `byoAnchor`); raw paste text is a last-resort
    fallback, never an unconditional full inject.

### Where the result is consumed
- **`Plan.jsx`** clears the crash-draft (`clearByoDraft()`) **only** on
  `applyGenerationResult` success (left intact on error) and renders a
  non-blocking `byo_fallback_sides` notice above `PlanFocusCard` (MEMORY).

### Failure modes & mitigations
- **Structuring crash mid-flow:** the ONCE-retry in step 2b
  (`generateInitialPlanBundle.js:499-519`); failure → graceful fallback to AI for
  that side.
- **Clarification needed post-submit:** can't be answered → graceful fallback
  (same block).
- **PDF text too sparse client-side:** opt-in `input_file` path to OpenAI.

### Gotchas
- **Inherits the premium gate** — the questionnaire only mounts behind
  `useSubscription` in `Plan.jsx`, so `structurePastedPlan` is never reachable
  unauthenticated/unsubscribed.
- **`pdfjs-dist`** is bundled as a separate chunk + worker asset
  (`?url` import); the `pdf.mjs` is lazily dynamic-imported.
- **No schema change** means there is nothing to verify in DATA_MODEL — the BYO
  shape lives entirely in `plan_payload` (`data` JSONB) and is app-convention
  only.

---

## Unverified / not fully traced
- **Web Stripe purchase path** (`purchaseWeb`/`stripeWebhook`/`stripeCreateCheckout`)
  is named but **not traced step-by-step here** — this doc focuses on the iOS
  RevenueCat rail. `stripeWebhook` writes the same `user_subscriptions` table
  (per REPO_MAP), but its event mapping was not read.
- ~~**`getOrCreateMealPlanForDate` / `buildMealPlansForDates`** internals were
  not read line-by-line...~~ **RESOLVED 2026-06-27:** both files read directly;
  the nutrition path **does** wrap reads + create in `withBackoff` and **does**
  set `max_output_tokens: 2500` — it mirrors the workout fix (see §2 gotchas).
- **`extractPdfText.js` / `byoCadence.js` / `byoDraft.js` / `PlanQuestionnaire.jsx`**
  were not opened in this pass — the BYO questionnaire UI steps and cadence
  resolution are summarized from MEMORY + their call sites, not from the files
  themselves.
- **`calcTDEE` / `buildAnswerContext`** internals (the surviving legacy exports)
  were not read; only their role in the live path is verified.

---

## Last verified against
- `src/api/backendClient.js` (EntityClient `list/filter/create/update/delete/subscribe`, `flattenRecord`, `recordPayload`, `mergeUpdate`, `invokeFunction`, `backend.auth.*`, `InvokeLLM`)
- `src/lib/AuthContext.jsx` (checkAppState, checkUserAuth, onAuthStateChange, iOS appUrlOpen deep-link bridge, RevenueCat login/listener effects, logout)
- `src/components/AuthScreen.jsx` (handleOAuth, handleEmailSubmit, handleVerify, `useCode = isIOS()`)
- `src/lib/revenuecat.js` (loadModule, ensureConfigured, loginRevenueCat, getOfferings, purchasePackage, addCustomerInfoListener)
- `src/lib/paymentClient.js` (purchase/purchaseIOS/purchaseWeb, restore, getOfferings, withTimeout, PLAN_TO_RC_IDENTIFIER)
- `src/lib/subscription.js` (loadUserSubscription, isPremiumUser, hasBillingIssue, bustSubscriptionCache)
- `src/hooks/useSubscription.js` (OR-gate, `execute:subscription-changed` listener)
- `supabase/functions/revenuecatWebhook/index.ts` (auth, buildUpdate event mapping, upsertSubscription)
- `supabase/functions/invoke-llm/index.ts` (fetchOpenAIWithBackoff, parseRetryAfterMs, input_file branch, response_json_schema handling, getUser auth)
- `supabase/functions/_shared/records.ts` (getUser, createServiceClient, findRecords, upsertRecordBy, ENTITY_TABLES)
- `src/lib/generateInitialPlanBundle.js` (full: buildOverviewPrompt, normalizeAndValidateOverview, BYO steps 2b/5b, AIPlan.create, archive-existing)
- `src/lib/generateInitialPlans.js` (confirmed legacy — exports `buildAnswerContext` `:137` + `calcTDEE` `:222` live, plus `generateInitialPlans()` `:284` throwing stub; `operationalizeWeeklyPlan()` is in `personalizationSync.js:1344`)
- `src/lib/planGenerationState.js` (startGeneration singleton, subscribeToGeneration replay buffer, 3-min timeout)
- `src/pages/Plan.jsx` (handleQuestionnaireSubmit, applyGenerationResult, subscribe-on-mount — via grep)
- `src/lib/plans/buildWorkoutPlansForDates.js` (pooledMap, hoisted invariant context, concurrency cap 4)
- `src/lib/plans/getOrCreateWorkoutPlanForDate.js` (full: chooseBestWorkoutPlan, per-day LLM build, withBackoff usage, BYO session injection)
- `src/lib/withBackoff.js` (defaultRetryable, retryAfterMs, full-jitter loop)
- `src/lib/plans/structurePastedPlan.js` (RESPONSE_SCHEMA, buildPrompt, unwrap)
- `src/lib/appCache.js` (full: STORE/durable tiers, enqueue op-chain, bootHydrate, hydrateActive, activateUser/deactivate, invalidate, writeForUser, TTL_MAP)
- `src/lib/durableStore.js` (Preferences static-import note, isNative routing)
- `src/hooks/useCacheHydrated.js` (event-driven ready boolean)
- `src/lib/vitalsLog.js` (saveVitalLog, getDailyLogUpdatesForCategory, ADDITIVE_FIELDS, optimistic onOptimistic hook)
- `src/pages/Track.jsx` (DailyLog.subscribe reconcile, handleLog onOptimistic — via grep)
- Grep: `.subscribe(` consumers (Track.jsx, Home.jsx, backendClient.js); `generateInitialPlanBundle`/`buildWorkoutPlansForDates` call sites
- Grep: every `user_subscriptions` write across `supabase/`+`src/` — writers `revenuecatWebhook:70` + `stripeWebhook:17`; read-only `stripeCreateCheckout:27`, `stripeCreatePortal:22`, `subscription.js:89`
- `src/lib/plans/getOrCreateWorkoutPlanForDate.js` `validateWorkout` (`:102`) — confirmed exercise-count bound is a fixed 4–8 range (`:111`)
- `src/lib/planGenerationState.js` `savePendingAnswers` (`:16`/`:66`) — confirmed `sessionStorage` persistence of questionnaire answers
- `src/lib/plans/buildMealPlansForDates.js` (full) + `src/lib/plans/getOrCreateMealPlanForDate.js` (full) — confirmed nutrition path wraps invariant context (`buildMealPlansForDates.js:67`), filter reads (`:168`/`:170`), FoodLog (`:201`), `MealPlan.create` (`:404`) in `withBackoff`, sets `max_output_tokens: 2500` (`:365`); only the no-`context` fallback (`:204–218`) is un-wrapped — resolves the earlier "deliberately un-fixed" note

_All read/verified 2026-06-27._
