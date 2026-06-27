# REPO_MAP — Execute (Executev3)

A directory-by-directory map of the Execute codebase for an engineer who can't
see the filesystem. Execute is a **Capacitor-wrapped React/Vite iOS app**
(bundle id `com.executelabs.execute`, appName "Execute"). It's a
fitness/nutrition coaching app: AI-generated training + meal plans, daily
tracking, and a premium subscription gate (RevenueCat IAP on iOS, Stripe on web).

> Conventions: paths are relative to the repo root. Where a signature/value is
> quoted, it's verbatim from the file named. "Entity" = a logical record type
> exposed by `src/api/backendClient.js`; "table" = the Postgres table it maps to.

---

## Top-level layout

```
Executev3/
├── src/                  # React/Vite app source (all app logic)
├── supabase/             # Backend: edge functions + SQL migrations + config
├── ios/                  # Native Capacitor iOS project (Xcode, SPM, Info.plist)
├── dist/                 # Vite production build output (gitignored build artifact)
├── docs/                 # Decision log, reports, reviews, this doc
├── legal/                # Static legal/marketing site (git submodule → executelabs.ca)
├── legal-site/           # Single static index.html (legal landing)
├── marketing/            # Single static index.html (marketing landing)
├── Public/               # PWA-ish assets: icon.png, manifest.json
├── node_modules/         # Dependencies (gitignored)
├── App.jsx entrypoint via index.html → src/main.jsx
├── capacitor.config.ts   # Capacitor config (TypeScript; NO .js variant)
├── vite.config.js, tailwind.config.js, postcss.config.js, eslint.config.js
├── jsconfig.json         # TS config used by `npm run typecheck` (tsc -p ./jsconfig.json)
├── components.json       # shadcn/ui generator config
├── package.json / package-lock.json
├── CLAUDE.md             # Agent/project instructions (the current rules)
├── README.md, REVENUECAT_SETUP.md
└── index.html            # Vite HTML entry; mounts #root
```

### Build / dev commands (from `package.json` `scripts`)
| Script | Command | Purpose |
|---|---|---|
| `dev` | `vite` | Browser preview only — NOT part of any iOS build |
| `build` | `vite build` | Production bundle → `dist/` |
| `ios:sync` | `vite build && cap sync ios` | Canonical build-for-iOS step |
| `ios:open` | `cap open ios` | Open Xcode project |
| `ios:run` | `vite build && cap sync ios && cap run ios` | Build + run on device/sim |
| `lint` / `lint:fix` | `eslint . --quiet` / `--fix` | ESLint |
| `typecheck` | `tsc -p ./jsconfig.json` | Type check (JS via jsconfig) |
| `preview` | `vite preview` | Preview a built bundle |

---

## `src/` — application source

Entry chain: `index.html` → `src/main.jsx` (mounts `<App/>` on `#root`) →
`src/App.jsx` (providers + router).

### `src/main.jsx`
Minimal: `ReactDOM.createRoot(...).render(<App/>)`, imports `@/index.css`.

### `src/App.jsx` — providers + routing (the route table)
Provider tree (outer→inner): `AuthProvider` → `QueryClientProvider`
(`queryClientInstance` from `src/lib/query-client`) → `BrowserRouter` →
`AuthenticatedApp` → `AppShell` → `<Routes>`. `<Toaster/>` is a sibling of Router.

`AuthenticatedApp` gates render on auth state (`useAuth()`), shows a loading
splash while `isLoadingPublicSettings || isLoadingAuth`, and special-cases
`authError.type` → `UserNotRegisteredError` / `AuthScreen`. Public legal routes
(`/privacy`, `/terms`) are rendered **before** the auth gate so unauthenticated
links resolve. Also runs boot prewarm (`prewarmUserEmail`, `loadActivePlan`,
`runMigrationIfNeeded`) and `useAutoResumeWorkout` (redirects to
`/workout-session` if an `in_progress` `WorkoutLog` exists for today).

**Route table** (all inside `<AppShell>`):

| Path | Component (`src/pages/`) |
|---|---|
| `/`, `/home` | `Home` |
| `/track` | `Track` |
| `/plan` | `Plan` |
| `/insights` | `Insights` |
| `/goals` | `Goals` |
| `/profile` | `Profile` |
| `/meals` | `Meals` |
| `/workouts` | `Workouts` |
| `/recovery` | `Recovery` |
| `/nutrition` | `Nutrition` |
| `/onboarding` | `Onboarding` |
| `/log-food` | `LogFood` |
| `/my-week` | `MyWeek` |
| `/workout-session` | `WorkoutSession` |
| `/tracking-history` | `TrackingHistoryPage` |
| `/personalize` | `PersonalizeQuestionnaire` |
| `/billing` | `Billing` |
| `/progress` | `Progress` |
| `/privacy` | `PrivacyPolicy` |
| `/terms` | `Terms` |
| `*` | `PageNotFound` (`src/lib/PageNotFound.jsx`) |

### `src/pages/` — route-level screens (20 files)
`Home.jsx`, `Track.jsx`, `Plan.jsx`, `Insights.jsx`, `Goals.jsx`,
`Profile.jsx`, `Meals.jsx`, `Workouts.jsx`, `Recovery.jsx`, `Nutrition.jsx`
(exceeds single-read token limit — read with offset/limit),
`Onboarding.jsx`, `LogFood.jsx`, `MyWeek.jsx`, `WorkoutSession.jsx`,
`TrackingHistoryPage.jsx`, `PersonalizeQuestionnaire.jsx`, `Billing.jsx`,
`Progress.jsx`, `PrivacyPolicy.jsx`, `Terms.jsx`.

### `src/api/` — backend client (single file)
**`backendClient.js`** — the entire Supabase data layer. Exports `backend`,
`supabase`, `supabaseConfigError`, `isSupabaseConfigured`.
- Creates the Supabase client (PKCE auth, realtime `eventsPerSecond: 10`) from
  `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`.
- `EntityClient` class wraps each table with `list/filter/create/update/delete/subscribe`.
  Records are stored as `{ id, owner_id, owner_email, created_by, user_email,
  data: {...}, created_date, updated_date }`; `flattenRecord` spreads `data` up
  to the top level on read. Server-side filtering uses `data->>key`; array/object
  criteria are filtered client-side.
- `subscribe(cb)` = Supabase Realtime `postgres_changes` (`event:'*'`, table-scoped);
  cb receives `{ type:'create'|'update'|'delete', data: flattenRecord(...), raw }`.
  **Realtime echoes a client's own writes back to itself** (round-trip, hundreds of ms)
  — UIs that both read and write must update optimistically.
- `backend.auth`: `me`, `loginWithOtp`, `verifyOtp`, `loginWithOAuth`, `logout`,
  `redirectToLogin`, `updateMe`. iOS OAuth opens an in-app `@capacitor/browser`
  and relies on the `IOS_OAUTH_REDIRECT = 'com.executelabs.execute://login-callback'`
  deep link (handled in `AuthContext`). iOS email OTP uses 6-digit codes (no magic link).
- `backend.functions.invoke(name, body)` → `supabase.functions.invoke`.
- `backend.integrations.Core.InvokeLLM(payload)` → invokes the `invoke-llm` edge
  fn. `Core.UploadFile` → Supabase Storage (`VITE_SUPABASE_UPLOAD_BUCKET`, default `uploads`).

**Entity → table map** (the `TABLES` const, 19 entities):

| Entity | Table |
|---|---|
| `AIPlan` | `ai_plans` |
| `CustomChecklistItem` | `custom_checklist_items` |
| `DailyLog` | `daily_logs` |
| `FoodLog` | `food_logs` |
| `Goal` | `goals` |
| `GoalProgressEntry` | `goal_progress_entries` |
| `InjuryProfile` | `injury_profiles` |
| `MealPlan` | `meal_plans` |
| `NutritionProfile` | `nutrition_profiles` |
| `ReadinessCheckIn` | `readiness_check_ins` |
| `SavedRecipe` | `saved_recipes` |
| `User` | `app_users` |
| `UserAIContext` | `user_ai_contexts` |
| `UserPageLayout` | `user_page_layouts` |
| `UserProfile` | `user_profiles` |
| `UserSubscription` | `user_subscriptions` |
| `WorkoutLog` | `workout_logs` |
| `WorkoutPlan` | `workout_plans` |
| `WorkoutProfile` | `workout_profiles` |

### `src/lib/` — app logic (29 files + 2 subdirs)
The brain of the app. Grouped by concern:

**Auth & subscription**
- `AuthContext.jsx` — `AuthProvider`/`useAuth`; auth state, iOS OAuth deep-link
  bridge, RevenueCat login. Logout = `clear()` + `deactivate()` + cache reset.
- `paymentClient.js` — platform-agnostic payment facade.
- `platform.js` — `getPlatform()` (`'ios'` | `'android'` | `'web'`) platform gate; also exports `isNative`, `isIOS`, `isAndroid`, `isWeb`.
- `revenuecat.js` — RevenueCat SDK / entitlement. `ensureConfigured()` calls
  `Purchases.configure` **from JS** (not natively in AppDelegate).
- `subscription.js` — backend `user_subscriptions` row truth.

**Plan generation** (see also `src/lib/plans/`)
- `generateInitialPlanBundle.js` — makes ONE master `AIPlan` (1 LLM call, 7-day
  overview); per-day workouts/meals generated on demand. Handles BYO custom plans.
- `generateInitialPlans.js` — legacy module; the old generation flow is
  **disabled**. Now only preserves `buildAnswerContext` + `calcTDEE`, still
  imported by `generateInitialPlanBundle.js`. Does no generation itself.
- `refinePlanFromChat.js` — plan refinement via chat.
- `goalSync.js`, `personalizationSync.js`, `profilePlanSync.js` — sync layers
  between profile answers, goals, and generated plans. `personalizationSync.js`
  also exports route helpers used by `App.jsx` (`runMigrationIfNeeded`,
  `userScopedFilter`, `prewarmUserEmail`, `loadActivePlan`, `getTodayISODate`).
- `aiContext.js`, `healthContext.js` — assemble LLM context blobs.
- `planDayDisplay.js`, `planGenerationState.js`, `readinessScore.js`,
  `calorieGoal.js`, `units.js`.

**Caching / storage** (cold-launch flash fix — see MEMORY.md for invariants)
- `appCache.js` — two-tier cache; Tier-2 is durable. `whenHydrated()`,
  `activateUser(uid)`, `setForUser`. Sole event source `appcache:hydration:start/done`.
- `durableStore.js` — async `getItem/setItem/removeItem/keys`, routed by
  `isNative()`: Capacitor `Preferences` (imported **statically**) on iOS,
  `localStorage` on web.
- `query-client.js` — TanStack Query `queryClientInstance`.

**Tracking / misc**
- `vitalsLog.js` — `saveVitalLog` + daily-log helpers (shared by Track + Home overlay).
- `customTrackers.js`, `checklistPrefs.js`, `withBackoff.js` (full-jitter DB retry),
  `utils.js`, `lucide-react.js` (**icon shim** — see warning below),
  `recharts.js` (**alias shim** — `vite.config.js` aliases `recharts` → this file,
  same mechanism as the lucide shim; importing an unre-exported recharts member
  fails the build the same way), `PageNotFound.jsx`.

**`src/lib/plans/`** — per-day plan helpers
- `getOrCreateWorkoutPlanForDate.js`, `getOrCreateMealPlanForDate.js` — only
  generate when `options.generate === true`.
- `buildWorkoutPlansForDates.js`, `buildMealPlansForDates.js` — multi-day batch
  build (hoist invariant context once + pooled concurrency cap=4).
- `ensureDailyLogForDate.js`.
- BYO ("input your own plan"): `byoDraft.js` (crash-draft in durableStore),
  `structurePastedPlan.js` (LLM structuring), `extractPdfText.js` (pdfjs +
  opt-in OpenAI `input_file`), `byoCadence.js` (activity/session resolution).

**`src/lib/nutrition/`** — `computeNutritionPlan.js` (macro/TDEE math).

### `src/hooks/`
- `useSubscription.js` — `isPremium` truth (OR-gate: backend row OR live
  RevenueCat entitlement). Read order: hook → lib.
- `useCacheHydrated.js` — event-driven `ready` boolean (drives loading floor).
- `usePullToRefresh.js`, `use-mobile.jsx`.

### `src/utils/`
- `index.ts` — generic helpers.

### `src/components/` — UI

| Subdir | What lives there |
|---|---|
| (root) | `AuthScreen.jsx` (login: Apple→Google OAuth→email OTP), `ProtectedRoute.jsx`, `UserNotRegisteredError.jsx` |
| `layout/` | `AppShell.jsx` — non-scrolling root `<div … flex flex-col … relative>`; the scroller is the child `<main ref={mainRef} className="ios-scroll flex-1">` (NOT the root div, NOT `document.body`); fixed bottom `<nav>` (z-50) is a sibling of `<main>`. Hides nav on `execute:blocking-overlay`/`execute:customize-mode` events; per-tab scroll restore via `mainRef` |
| `ui/` | 54 shadcn/ui + Radix primitives (button, dialog, sheet, drawer, card, chart…) plus a few app-specific cards (`AIInsightCard`, `MetricCard`, `VitalityRing`, `HeroStepsCard`, `SectionHeader`) |
| `premium/` | `PremiumPaywall.jsx` (IAP UI; live StoreKit prices, Restore, auto-renew disclosure), `PremiumGate.jsx`, `PremiumBadge.jsx` |
| `billing/` | `ApplePayButton.jsx` |
| `home/` | Home dashboard widgets: `AICoachCard`, `CalorieBalanceCard`, `MacroTrackerCard`, `TripleRingRow`, `DailyChecklist`, `DailyMissions`, `VitalsRowWidget`, `VitalsPicker`, `WorkoutQuickLink`, `ProgressSnapshotCard`, `HomeWidgetManager`, `ChecklistCustomizeModal`, `GoalsCompleteAnimation`, `useVitalsLayout` |
| `plan/` | `PlanQuestionnaire.jsx` (incl. BYO flow), `PlanFocusCard`, `WeeklyPlanPreview`, `PlanGeneratingOverlay`, `RefinePlanModal`, `AskQuestionsModal`, `EmptyPlanState`, `PlanSegmentedTabs`, `PlanInsightCard`, `SportWeekSchedule`, `SupplementsPicker`, `ResetAppDataButton` |
| `workouts/` | `CustomSplitSheet`, `WorkoutHeroCard`, `WorkoutSummary`, `WorkoutCompleteAnimation`, `PostWorkoutCheckIn` |
| `nutrition/` | `MealEditModal`, `MealIngredients`, `RecipeCard`, `RecipeEditorModal`, `RecipesTab` |
| `food/` | `BarcodeLogModal.jsx` (camera `getUserMedia` barcode scan), `PhotoLogModal.jsx` (meal photo `<input capture>`) |
| `track/` | `LogModal.jsx` (portaled framer-motion log sheet, shared Track+Home), `TrackingHistory.jsx`, `categories.js` (`ALL_CATEGORIES`, accents, habits) |
| `vitals/` | `VitalWidget.jsx`, `VitalsSheet.jsx` |
| `customize/` | Page-layout customization: `CustomizableWidget`, `CustomizeButton`, `CustomizePanel`, `CustomizeWrapper`, `pageLayouts.jsx`, `usePageLayout.jsx` |
| `profile/` | `EditableNutritionTargets`, `StarterProfileModal`, `StarterResultScreen` |

> **⚠ `lucide-react` is aliased** to a hand-maintained shim
> `src/lib/lucide-react.js` that re-exports only listed icons. Importing an icon
> NOT in the shim passes lint+tsc but **fails the vite/rollup build**
> (`"<Icon>" is not exported by "src/lib/lucide-react.js"`). Fix: add the
> `export { default as <Icon> } from '../../node_modules/lucide-react/dist/esm/icons/<kebab>.js'`
> line (alphabetical).

---

## `supabase/` — backend

```
supabase/
├── config.toml
├── functions/
│   ├── _shared/
│   │   ├── cors.ts        # handleCors, json helpers
│   │   └── records.ts     # getUser, createServiceClient, upsertRecordBy
│   ├── invoke-llm/        # index.ts — OpenAI proxy (raw fetch to /v1/responses)
│   ├── revenuecatWebhook/ # index.ts — IAP entitlement events → user_subscriptions
│   ├── deleteUserData/    # index.ts — account deletion (called from Profile)
│   ├── stripeCreateCheckout/  # web Stripe checkout session
│   ├── stripeCreatePortal/    # web Stripe billing portal
│   └── stripeWebhook/         # web Stripe events → user_subscriptions
└── migrations/
    ├── 20260526000000_supabase_backend.sql   # base schema (all entity tables)
    └── 20260622000000_house_board.sql        # house board feature (untracked at snapshot)
```

**`invoke-llm`** — proxies to OpenAI `/v1/responses` (model gpt-4.1-mini per
CLAUDE.md). Full-jitter backoff on 429/5xx (`LLM_MAX_ATTEMPTS=5`,
`LLM_DEADLINE_MS=45_000`), honors `Retry-After`, has a `forceFailures` test hook.
Supports an `input_file` content branch for opt-in PDF (BYO plans). 429 status
surfaces to the frontend via `error.context.status`.

**`revenuecatWebhook`** — the **sole writer** of `user_subscriptions` rows on
iOS (the device never writes that table). Requires
`Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>`. Uses the user's Supabase
email as the RevenueCat `appUserID`, so `event.app_user_id` == the `user_id`
column. `stripeWebhook` writes the same table for web — single source of truth
for `useSubscription().isPremium`.

---

## `ios/` — native Capacitor project

```
ios/App/
├── App.xcodeproj/                 # Xcode project (project.pbxproj, xcworkspace)
├── App/
│   ├── AppDelegate.swift          # app lifecycle (does NOT configure RevenueCat — JS does)
│   ├── Info.plist                 # URL scheme, NSCameraUsageDescription, ITSAppUsesNonExemptEncryption=false
│   ├── PrivacyInfo.xcprivacy      # privacy manifest (collected data types + required-reason APIs)
│   ├── capacitor.config.json      # generated from capacitor.config.ts by `cap sync`
│   ├── config.xml
│   ├── Assets.xcassets/           # AppIcon (single 1024, no alpha), splash
│   ├── Base.lproj/
│   └── public/                    # synced web build (from dist/) — DO NOT hand-edit
└── CapApp-SPM/                    # Swift Package Manager plugin host (NO Podfile)
    ├── Package.swift              # native plugins: App, Browser, Preferences, RevenueCat Purchases
    └── Sources/
```

- Capacitor 8 is **SPM-based, no CocoaPods/Podfile**. Native plugins live in
  `CapApp-SPM/Package.swift`.
- `capacitor.config.ts` sets `webDir: 'dist'` and **no `server.url`** — web
  assets are bundled locally (good for App Store Guideline 4.2). The `.json`
  variant in `ios/App/App/` is generated; edit the `.ts`.
- Deployment target 15.0.

---

## `docs/`, `legal/`, and other root dirs
- `docs/DECISIONS.md` — append-only **why** log (architecture/provider/direction/
  compliance decisions). `docs/reports/`, `docs/reviews/` — dated notes.
  `docs/swift-migration-assessment.md`. `docs/claude/` holds generated knowledge
  docs (this file).
- `legal/` — git submodule for the static `executelabs.ca` site (privacy, terms,
  support, house board); deploy replaces the whole site.
- `legal-site/`, `marketing/` — single static `index.html` landings.
- `Public/` — `icon.png`, `manifest.json`.

---

## Quick "where do I look?" index
| I need to… | Go to |
|---|---|
| Add/change a route | `src/App.jsx` |
| Touch the data layer / add an entity | `src/api/backendClient.js` (`TABLES` map) |
| Change auth / login | `src/lib/AuthContext.jsx`, `src/components/AuthScreen.jsx` |
| Change the IAP / premium gate | `src/hooks/useSubscription.js`, `src/lib/revenuecat.js`, `src/lib/subscription.js`, `src/components/premium/` |
| Change plan generation | `src/lib/generateInitialPlanBundle.js`, `src/lib/plans/` |
| Change LLM behavior | `supabase/functions/invoke-llm/index.ts` |
| Change subscription truth on the server | `supabase/functions/revenuecatWebhook/` (iOS) / `stripeWebhook/` (web) |
| Add a lucide icon | `src/lib/lucide-react.js` (the shim — see warning) |
| Native iOS config | `ios/App/App/Info.plist`, `AppDelegate.swift`, `capacitor.config.ts` |
| App shell / nav / scroll | `src/components/layout/AppShell.jsx` |

---

_Last verified against: `package.json`, `src/App.jsx`, `src/main.jsx`,
`src/api/backendClient.js`, `src/lib/platform.js`, `src/lib/generateInitialPlans.js`
(header), `capacitor.config.ts`, `vite.config.js`, `src/components/layout/AppShell.jsx`,
representative files per component subdir (`home/AICoachCard`, `plan/PlanQuestionnaire`,
`workouts/WorkoutHeroCard`, `nutrition/RecipesTab`, `track/categories`, `vitals/VitalsSheet`,
`customize/CustomizePanel`, `profile/StarterProfileModal`, `premium/PremiumGate`,
`ui/VitalityRing`, `food/BarcodeLogModal`, `billing/ApplePayButton`), directory listings
of `src/` (pages, lib, lib/plans, lib/nutrition, hooks, utils, components/*),
`supabase/functions/*` (heads of `invoke-llm` and `revenuecatWebhook`),
`supabase/migrations/20260526000000_supabase_backend.sql` (entity-table array confirmed
matches the `TABLES` map — all 19), `ios/App/` tree, `docs/`, and root dir listing —
all read/re-verified 2026-06-27._
