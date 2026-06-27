# STATE.md — Execute (Executev3) Status Snapshot

> **Point-in-time snapshot · 2026-06-27.** This is the most perishable doc in
> `docs/claude/`. It captures *current status / roadmap*, which rots fast —
> **regenerate it often** and trust the dated structure docs
> ([REPO_MAP](./REPO_MAP.md), [KEY_FLOWS](./KEY_FLOWS.md),
> [DATA_MODEL](./DATA_MODEL.md), [ARCHITECTURE](./ARCHITECTURE.md)) and
> [`docs/DECISIONS.md`](../DECISIONS.md) over this file if they disagree.
>
> Every status claim below is tagged **[Done] / [In progress] / [Known issue] /
> [Unverified]** and cited to a file. Where the evidence only proves "the code
> exists," not "it ships in production," the claim says so.

---

## What this app is (one line)
Capacitor 8 + React/Vite iOS app (bundle `com.executelabs.execute`): AI-generated
training + nutrition plans, daily tracking, premium subscription gate (RevenueCat
IAP on iOS, Stripe on web), Supabase backend. See REPO_MAP.md.

---

## [Done] — shipped / working in the codebase

These are implemented and (per the cited docs/decisions) considered complete.
"Done" here means *in the codebase and verified by the structure docs* — final
App Store *approval* is a human/ASC step (see open items).

- **App Store compliance hardening** — a dedicated pass resolved the first-audit
  rejection risks: removed test-access bypass, removed fake HealthKit
  integration, added Privacy Policy + Terms pages (routed + paywall-linked),
  `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption=false`,
  `NSCameraUsageDescription`, live StoreKit pricing, Terms governing law = British
  Columbia, Canada. Evidence: `docs/DECISIONS.md` (2026-06-03 "App Store
  compliance hardening pass"); MEMORY "App Store audit notes (updated
  2026-06-03)".
- **Local-bundled web assets, no `server.url`** — `capacitor.config.ts`
  (`webDir: 'dist'`) → Guideline 4.2 ok. Evidence: DECISIONS 2026-06-03 "Bundle
  web assets locally"; REPO_MAP `ios/` section.
- **IAP / RevenueCat (iOS rail)** — purchase → entitlement → webhook → client
  OR-gate is fully wired. `revenuecatWebhook` is the **sole writer** of
  `user_subscriptions` on iOS; client only reads, OR-gated against live
  `customerInfo`. Restore + auto-renew disclosure present. RC configured from JS
  (`ensureConfigured()`), not natively. Evidence: KEY_FLOWS §3; DECISIONS
  2026-06-08 (sole writer) + 2026-06-03 (configure-from-JS); REPO_MAP.
- **Stripe (web rail)** — `stripeWebhook` writes the same `user_subscriptions`
  table; `stripeCreateCheckout`/`stripeCreatePortal` read it. *Not traced
  step-by-step* — see Known issues / Unverified. Evidence: REPO_MAP
  `supabase/functions`; KEY_FLOWS "Unverified" §.
- **Auth** — Sign in with Apple (offered first) + Google OAuth (Capacitor Browser
  + `appUrlOpen` deep-link + PKCE `exchangeCodeForSession`) + email OTP (6-digit
  code on iOS, magic link on web). Evidence: KEY_FLOWS §1; REPO_MAP.
- **Plan generation (lazy/on-demand)** — one master `AIPlan` per generation (one
  overview LLM call), per-day workouts/meals built on demand. Multi-day "Build
  all" hardened with `withBackoff` + pooled concurrency cap=4 + edge-fn OpenAI
  backoff. Evidence: KEY_FLOWS §2; REPO_MAP.
- **Nutrition multi-day build hardened** — verified by direct read 2026-06-27.
  `buildMealPlansForDates.js:67` wraps the once-hoisted invariant context in
  `withBackoff` (concurrency cap=4, `:24`); `getOrCreateMealPlanForDate.js`
  wraps the existing-plan filter reads (`:168`, `:170`), the FoodLog read
  (`:201`), and `MealPlan.create` (`:404`) in `withBackoff`, with the swallowing
  `.catch` placed *outside* the wrapper so a first 429 retries rather than
  collapsing to "no plan." The LLM call sets `max_output_tokens: 2500` (`:365`).
  Mirrors the workout fix. **The KEY_FLOWS §2 "deliberately un-fixed" gotcha is
  now stale — see resolved conflict below.** Residual: the single-day
  **no-`context` fallback branch** (`getOrCreateMealPlanForDate.js:204–218`)
  still does bare `Promise.allSettled` invariant reads with no backoff, but the
  multi-day build always passes `context`, so the burst path that used to 429 is
  covered. Evidence: direct read of both files; MEMORY "NUTRITION NOW HARDENED".
- **Cold-launch flash fix / durable cache** — `appCache.js` two-tier
  (in-memory + durable via Capacitor `Preferences` on iOS), op-chain hydration
  with 8s anti-hang + 3s boot floor, SWR TTLs, multi-user purge. Home/Plan gate
  on `cacheReady`. Evidence: KEY_FLOWS §4; MEMORY "appCache durable hydration".
- **Realtime self-echo / optimistic writes** — vitals logging (Track + Home
  overlay) does read-free optimistic update pre-await, reconciles on echo.
  Evidence: KEY_FLOWS §5; MEMORY "Vitals logging".
- **BYO "input your own plan" (`planType: 'custom'`)** — paste/PDF a plan,
  structure it via an LLM pre-call, build the missing side. No DB schema change
  (all in `plan_payload`). Evidence: KEY_FLOWS §6; MEMORY "BYO". **Implemented +
  lint/build/typecheck clean but NOT device-verified** (PDF `input_file`
  end-to-end + cadence beyond the 7-day overview) per MEMORY.

---

## [In progress] / evaluations open

- **Native SwiftUI migration — evaluation only, NOT started.** A full assessment
  exists (`docs/swift-migration-assessment.md`) sizing a rewrite (keep Supabase
  backend, rewrite ~28k LOC UI + ~8.7k LOC business logic in Swift). Its
  recommendation is to **decide what "benefit" means first** and prefer an
  *incremental* native-modules-behind-Capacitor path for specific pain points.
  **Verified not in-flight (2026-06-27):** no decision in `docs/DECISIONS.md`, and
  a grep of `src/` for `swift|migration` returns only the unrelated
  localStorage→Supabase *data* migration (`personalizationSync.js:1354
  runMigrationIfNeeded`) — **no Swift code or config anywhere in the repo**. Treat
  as **deliberation, not committed roadmap**. Evidence:
  `docs/swift-migration-assessment.md` §5; absence of a DECISIONS entry; grep
  `src/` `swift|migration` (data-migration hits only).
- **House board feature — status ambiguous (shipped vs. uncommitted).** The
  *only* in-progress signal is that
  `supabase/migrations/20260622000000_house_board.sql` is **git-untracked** at
  this snapshot — which is ambiguous (pending-commit, local-only, or
  already-deployed-but-uncommitted). It conflicts with MEMORY, which describes
  house board as an **existing/live** feature (executelabs.ca/house, Supabase-
  backed, open anon RLS, in the `legal/` submodule). So this is **not confirmed
  in-progress**: it's either shipped-per-MEMORY or an uncommitted local migration.
  Resolve by checking whether the feature is live at executelabs.ca/house and
  whether the migration has been applied to the remote DB. Evidence: REPO_MAP
  `supabase/migrations`; MEMORY "[House board]" (describes it as live); gitStatus
  `?? supabase/migrations/20260622000000_house_board.sql`. **[Unverified]**

---

## [Known issue] / [Unverified] — open items in code & docs

### Disabled stubs (intentional legacy fences — leave them)
- **`generateInitialPlans.js` is legacy/disabled.** `generateInitialPlans()`
  (`:284`) is a `throw`ing stub ("use `generateInitialPlanBundle`"). Only
  `buildAnswerContext` (`:137`) + `calcTDEE` (`:222`) survive and are imported by
  the bundle. Evidence: KEY_FLOWS §2 note; REPO_MAP `src/lib/`.
- **`personalizationSync.js` legacy fences** — `upsertWeeklyPlan` disabled
  (`:626`, "weekly overview now lives on the active master AIPlan"),
  `operationalizeWeeklyPlan` disabled (`:1342–1348`, "child projections must be
  created by generateInitialPlanBundle"), legacy localStorage plan migration
  intentionally disabled (`:1442`). These are guard rails, not bugs. Evidence:
  Grep of `src/lib/personalizationSync.js`.

### TODO / incomplete config
- **`src/lib/subscription.js:39`** — `// TODO: Replace with your actual Stripe
  publishable key`. **The comment is stale:** the very next line (`:40`) already
  reads `STRIPE_PUBLISHABLE_KEY = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY ||
  ''` — the env-var mechanism is in place, there is no hardcoded placeholder to
  replace. The *real* open item is operational, not code: the web Stripe key must
  be set in the environment (empty-string fallback if unset). Only TODO in
  `src/`; **zero** TODO/FIXME in `supabase/`. Evidence: re-grep `src/`+`supabase/`
  2026-06-27; direct read of `subscription.js:39–40`.

### Architectural caveats flagged in code (load-bearing, not yet acted on)
- **`isPremium` is a count-based OR-gate, not entitlement-id-specific**
  (`useSubscription.js:34–43`). Safe *only* while `premium` is the lone RC
  entitlement; a second entitlement would silently unlock full premium. Make it
  id-specific before adding entitlements. Evidence: KEY_FLOWS §3 gotchas;
  DECISIONS 2026-06-08 "Any active entitlement = premium".
- **`saveVitalLog`'s two loaders are not appCache-backed** → 2 cold reads per
  save (off the UI path; deferred). Evidence: KEY_FLOWS §5 gotchas; MEMORY.

### Doc-level conflict — RESOLVED 2026-06-27 (direct read)
- **Nutrition rate-limit hardening.** Conflict settled by reading both files.
  **MEMORY is correct; KEY_FLOWS §2 is stale.** Nutrition multi-day build IS
  hardened: `withBackoff` wraps the hoisted invariant context
  (`buildMealPlansForDates.js:67`), the existing-plan filter reads
  (`getOrCreateMealPlanForDate.js:168/170`), the FoodLog read (`:201`), and
  `MealPlan.create` (`:404`); `max_output_tokens: 2500` is set (`:365`). The only
  un-wrapped invariant reads are in the **single-day no-`context` fallback**
  (`:204–218`), which the multi-day build never hits (it always passes
  `context`). KEY_FLOWS §2's "deliberately un-fixed / no `withBackoff` / no
  `max_output_tokens`" gotcha and its matching "Unverified" entry should be
  removed/updated. **[Done]**

### Not traced / not verified on device
- **Web Stripe purchase path** (`purchaseWeb` / `stripeWebhook` /
  `stripeCreateCheckout`) named but not traced step-by-step; event mapping
  unread. Evidence: KEY_FLOWS "Unverified".
- **BYO end-to-end on device** (PDF `input_file`, cadence past day 7) — not
  device-verified. Evidence: MEMORY "BYO ... STATUS".
- **Home vitals overlay** (portal/AnimatePresence in-out, nav cover during
  pull-to-refresh transform, scroll-lock, safe-area footer, Realtime echo
  reconcile) — implemented + build green but **not device-verified**. Evidence:
  MEMORY "Vitals logging ... STATUS".

### Human-side / ASC items remaining for actual App Store submission
Build with Xcode 26 / iOS 26 SDK; demo creds in review notes (login-gated);
age-rating answers; StoreKit products approved + RevenueCat offering set Current;
ASC Nutrition Label matches `PrivacyInfo.xcprivacy` (must list Health + Fitness);
screenshots; EU trader/DSA; export compliance. Evidence: MEMORY "App Store audit
notes ... Remaining (human-side)".

---

## Build / lint status (as last noted)
Lint + typecheck pass with **pre-existing TS errors only**; production build is
green. Note: `lucide-react` and `recharts` are aliased to hand-maintained shims —
importing an un-re-exported member passes lint+tsc but **fails the vite build**.
Evidence: REPO_MAP shim warnings; MEMORY "Gotchas"; BYO/Vitals "STATUS" lines.

---

## Last verified against
- `docs/claude/REPO_MAP.md`
- `docs/claude/KEY_FLOWS.md`
- `src/lib/plans/buildMealPlansForDates.js` (full — nutrition rate-limit conflict)
- `src/lib/plans/getOrCreateMealPlanForDate.js` (full — nutrition rate-limit conflict)
- `docs/swift-migration-assessment.md`
- `docs/DECISIONS.md`
- `CLAUDE.md` (project instructions, in context)
- `MEMORY.md` (auto-memory, in context)
- Grep of `src/` for `TODO|FIXME|disabled|stub|deprecated` (hits:
  `src/lib/subscription.js:39`, `src/lib/personalizationSync.js:626/1342/1442`,
  plus the legacy-stub references confirmed in KEY_FLOWS)
- Glob `docs/**/*.md`; git status (untracked `house_board.sql` migration)

_Snapshot date: 2026-06-27. Regenerate when status changes._
