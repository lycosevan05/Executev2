# Execute → Native SwiftUI Migration Assessment

> Scope: replace the entire web frontend + Capacitor shell with a native SwiftUI app while
> **keeping the Supabase backend, edge functions, and RevenueCat project unchanged**.
> Every claim below is grounded in a file actually present in this repo.

## TL;DR
- **What survives untouched:** the whole server side — `supabase/functions/*` (~856 LOC, 6 functions + 2 shared helpers) and the Postgres schema. A native client re-points at the same endpoints.
- **What dominates the cost:** (1) ~8,700 LOC of client-side business logic in `src/lib/` — mostly LLM prompt-building + response normalization — must be **re-implemented in Swift**, and (2) ~28,000 LOC of UI across `src/pages/` (20 screens, ~12,393 LOC) and `src/components/` (~113 files, ~15,910 LOC) must be **rewritten** in SwiftUI.
- **What is cheap:** the three external SDKs port cleanly (`supabase-js`→`supabase-swift`, `@capacitor/preferences`→UserDefaults/Keychain, `@revenuecat/purchases-capacitor`→RevenueCat's native iOS SDK).
- **What gets deleted:** the entire Capacitor layer, `platform.js`, the web tier of the cache, Stripe (web-only), and ~9 unused/web-only npm packages.
- **Bottom line:** This is a **large** migration (calibration in §5). The backend reuse is a real discount, but it does **not** shrink the two dominant costs (business-logic rewrite + UI rewrite). A **partial/incremental path (native modules behind Capacitor)** is materially cheaper if the goal is performance on a few screens; it is *not* cheaper if the goal is a fully native UI shell.

---

## 1. Migration surface inventory

### 1a. React components — count & grouping
`src/components/` = **~113 files, ~15,910 LOC** (glob-verified). Grouped:

| Group | Files | Role | Native disposition |
|---|---|---|---|
| `ui/` | **54** | Radix+Tailwind primitives (button, dialog, select, card, chart wrapper, input-otp, carousel, resizable, sidebar…) | Mostly **vanish** — replaced by built-in SwiftUI controls |
| `home/` | 14 | Dashboard widgets (VitalsRowWidget, MacroTrackerCard, AICoachCard, DailyChecklist, TripleRingRow…) | Mechanical UI rewrite |
| `plan/` | 12 | Plan create/view (`PlanQuestionnaire.jsx` ~1,913 LOC — BYO+PDF; RefinePlanModal, WeeklyPlanPreview…) | Mechanical→rearchitecture |
| `customize/` | 6 | Drag-to-reorder layout system (CustomizeWrapper, pageLayouts, usePageLayout) | **Rearchitecture** (DOM drag) |
| `nutrition/` | 5 | Meal/recipe modals | Mechanical |
| `workouts/` | 5 | Session/summary UI | Mechanical |
| `profile/` | 3 | Profile modals (`StarterProfileModal.jsx` ~750 LOC) | Mechanical |
| `premium/` | 3 | Paywall/gate/badge | Mechanical (+IAP wiring) |
| `track/`,`vitals/` | 4 | Vitals logging sheets (`LogModal.jsx` portaled) | Mechanical |
| `food/` | 2 | **`BarcodeLogModal.jsx` (getUserMedia)**, **`PhotoLogModal.jsx` (`<input capture>`)** | **Logic rewrite** (web media APIs) |
| `billing/` | 1 | ApplePayButton | Mechanical |
| `layout/` | 1 | **`AppShell.jsx`** — scroll restore, custom-event nav hiding, scroll-lock | **Rearchitecture** |
| root | 2 | ProtectedRoute, UserNotRegisteredError | Mechanical |

Pages: `src/pages/` = **20 files, ~12,393 LOC**. Biggest: `Workouts.jsx` 1,497, `Nutrition.jsx` 1,326 (flagged in CLAUDE.md as over single-read limit), `WorkoutSession.jsx` 1,023, `Home.jsx` 938, `Profile.jsx` 886. Routes declared in `src/App.jsx` (~20 routes incl. public `/privacy`,`/terms`).

### 1b. Client-side business logic & state (~8,700 LOC, `src/lib/`)
- **Plan generation (the crown jewels):** `generateInitialPlanBundle.js` (738), `personalizationSync.js` (**1,477** — central write+cache-invalidation layer), `refinePlanFromChat.js` (345), `plans/getOrCreateWorkoutPlanForDate.js` (410), `plans/getOrCreateMealPlanForDate.js` (415), `plans/buildWorkoutPlansForDates.js` (101, pooled concurrency cap=4), `plans/buildMealPlansForDates.js` (102), `withBackoff.js` (78, full-jitter retry), `goalSync.js` (373), `generateInitialPlans.js`/TDEE (287).
- **BYO ("input your own plan"):** `plans/structurePastedPlan.js` (239), `plans/byoCadence.js` (127), `plans/extractPdfText.js` (118, pdfjs), `plans/byoDraft.js` (45).
- **Vitals/logging:** `vitalsLog.js` (218), `plans/ensureDailyLogForDate.js` (257).
- **State/cache:** `appCache.js` (**373** — two-tier in-memory+durable, op-chain, SWR TTLs, multi-user purge), `durableStore.js` (86), `hooks/useCacheHydrated.js` (36), `query-client.js`.
- **Subscription:** `subscription.js` (101), `hooks/useSubscription.js` (54).
- State management is **React Context + hooks + TanStack Query** (TanStack used in only 3 files: Billing/Plan/Profile; the rest call the backend client directly).

### 1c. Capacitor plugins in use (6)
From `ios/App/CapApp-SPM/Package.swift` + JS imports: `@capacitor/core` (platform detect), `@capacitor/app` (`appUrlOpen` deep-link listener — `AuthContext.jsx:149`), `@capacitor/browser` (OAuth popover — `backendClient.js:369`, `AuthContext.jsx:154`), `@capacitor/preferences` (durable storage — `durableStore.js:16`, **static import on purpose**), `@capacitor/ios`, `@revenuecat/purchases-capacitor`. **No** Camera/HealthKit plugin — camera goes through WebView `getUserMedia`/`<input capture>`.

### 1d. Third-party JS dependencies (~87 total: 72 deps + 15 dev)
- **UI/render (vanish or rewrite):** react, react-dom, framer-motion, ~28 `@radix-ui/*`, tailwind(+animate,merge,clsx,cva), lucide-react, next-themes, canvas-confetti, vaul, sonner, embla-carousel-react, react-resizable-panels, cmdk, input-otp.
- **Data/state (rewrite):** @tanstack/react-query, react-hook-form, @hookform/resolvers, zod, react-router-dom.
- **Backend/payments:** @supabase/supabase-js, @revenuecat/purchases-capacitor, @stripe/* (web-only → drop on iOS).
- **Utility (port logic):** date-fns, moment, lodash, react-day-picker, pdfjs-dist, recharts, react-markdown.
- **Likely dead weight (0 grep hits):** three, react-leaflet, html2canvas, jspdf, react-quill, react-hot-toast (duplicate of sonner). Confirm-and-delete.

### 1e. Every Supabase / RevenueCat / auth touchpoint
- **Supabase client:** `src/api/backendClient.js` (435 LOC) — single `createClient` (PKCE, autoRefresh, persistSession, realtime 10 evt/s); generic `EntityClient` (list/filter/create/update/delete/**subscribe**) over **19 tables** (AIPlan, DailyLog, FoodLog, MealPlan, WorkoutPlan/Log, UserProfile, NutritionProfile, WorkoutProfile, UserSubscription, Goal, UserAIContext, UserPageLayout, SavedRecipe, ReadinessCheckIn, …); `invokeFunction()` → edge functions; `Core.InvokeLLM`, `Core.UploadFile`.
- **Auth:** `src/lib/AuthContext.jsx` (327) — session recovery, **email OTP** (code on iOS / link on web), **Sign in with Apple** (offered first per App Store), **Google OAuth via Capacitor Browser + `appUrlOpen` deep-link + PKCE `exchangeCodeForSession`** (gotcha: pass *only* the `code` param), RevenueCat `logIn` on email change, `customerInfo` listener → `execute:subscription-changed` event.
- **RevenueCat:** `src/lib/revenuecat.js` (106, `ensureConfigured`/`Purchases.configure` from JS — **never native**, per `AppDelegate.swift` comment), `paymentClient.js` (164, iOS↔Stripe facade + timeouts), `subscription.js`, `useSubscription.js` (**OR-gate**: backend row premium/active OR live RC entitlements non-empty). Sole writer of the row = `supabase/functions/revenuecatWebhook`.

---

## 2. Per-subsystem effort classification

Legend: **(a)** SDK port · **(b)** mechanical UI rewrite · **(c)** logic rewrite · **(d)** rearchitecture · **(e)** throwaway.

| Subsystem | Class | Justification (from code) |
|---|---|---|
| Supabase data access (`backendClient.js`) | **(a)+(c)** | `createClient`/CRUD port to `supabase-swift`; the `EntityClient` generic + `flattenRecord` data-shaping + realtime echo handling is custom logic to re-derive. |
| Edge functions (`supabase/functions/*`) | **(e→reuse)** | Server-side; **0 migration**. Native client calls the same `functions.invoke`. ~856 LOC stays. |
| Auth flows (`AuthContext.jsx`) | **(c)+(d)** | supabase-swift auth exists, but OTP/SIWA/OAuth flows are reimplemented; OAuth deep-link bridge is *simpler* native (ASWebAuthenticationSession) → counts as rearchitecture, not just port. |
| RevenueCat (`revenuecat.js`,`paymentClient.js`,`subscription.js`,`useSubscription.js`) | **(a)+(c)** | Native RC SDK replaces the Capacitor plugin (port); the OR-gate + webhook reconcile logic re-implements. The "configure from JS not native" hazard disappears entirely. |
| Plan generation (`src/lib/` ~8,700 LOC) | **(c)** | Pure JS computation (TDEE, prompt assembly, JSON normalization, cadence resolution, backoff). No React/web dependency, **but no Swift equivalent exists** → must be hand-translated. **Dominant cost.** |
| App cache / hydration (`appCache.js`,`durableStore.js`,`useCacheHydrated.js`) | **(c)+(d)** | Durable tier ports to UserDefaults/Keychain (a), but the op-chain serialization, 8s anti-hang timeout, SWR TTL map, multi-user purge, and Realtime-echo optimistic reconcile are subtle invariants to re-derive in Swift's concurrency model. |
| `ui/` primitives (54 files) | **(e)+(b)** | Most are Radix wrappers → replaced by native SwiftUI controls (throwaway); a few custom (rings, metric cards) are mechanical. |
| Pages + feature components (20 + ~59) | **(b)** mostly, **(d)** for AppShell/customize | Structure preserved screen-by-screen; `AppShell.jsx` scroll/overlay/nav and `customize/` drag system need native rearchitecture. |
| Camera/barcode (`food/*`) | **(c)** | `getUserMedia`+`<input capture>` rewritten on AVFoundation + Vision `VNDetectBarcodesRequest` (native is cleaner/more reliable). |
| Charts (`recharts`, Insights/Progress) | **(b)** | DOM SVG → Swift Charts; mechanical but per-chart. |
| PDF (`pdfjs-dist`, `extractPdfText.js`) | **(c)** | Browser pdfjs → PDFKit text extraction; quality-gate logic re-implements. |
| Routing (`react-router-dom`, `App.jsx`) | **(d)** | → SwiftUI `NavigationStack`/`TabView`; routing + auto-resume-workout + scroll restore is rearchitecture. |
| Capacitor shell, `platform.js`, Stripe-web, dead npm libs | **(e)** | Deleted outright. |

---

## 3. Native equivalence map

| JS dep / plugin | Native Swift equivalent | Flag |
|---|---|---|
| `@supabase/supabase-js` | **`supabase-swift`** (official: auth, Postgrest, Realtime, Storage, Functions) | Good coverage; Realtime + PKCE OAuth supported. |
| `@capacitor/preferences` | **UserDefaults** (+ **Keychain** for tokens) or **SwiftData** | Clean. Note: supabase-swift manages its own token store. |
| `@revenuecat/purchases-capacitor` | **RevenueCat `purchases-ios` (StoreKit 2)** | Clean; the JS-vs-native configure hazard disappears. |
| `@capacitor/browser` (OAuth) | **ASWebAuthenticationSession** | *Better* native — handles callback without manual deep-link plumbing. |
| `@capacitor/app` (`appUrlOpen`) | **`.onOpenURL`** / SceneDelegate | Clean. |
| `@capacitor/core` (platform detect) | n/a — always iOS | **Throwaway.** |
| `react-router-dom` | **NavigationStack / TabView** | No 1:1; rearchitecture. |
| `@tanstack/react-query` | No direct equiv — `@Observable` + a custom cache, or a community lib | **Reduced capability**; caching/SWR rebuilt by hand. |
| `react-hook-form`+`zod` | SwiftUI `@State` bindings + manual/`Codable` validation | Rewrite; no clean equiv. |
| `framer-motion` | SwiftUI animations/transitions | Mostly cleaner; complex gesture choreography is manual. |
| Radix UI (28 pkgs) | Native SwiftUI controls (Picker, Sheet, Menu, Toggle…) | Net code reduction. |
| Tailwind | SwiftUI modifiers / design tokens | Rewrite. |
| `lucide-react` | **SF Symbols** (+ asset catalog for misses) | Mechanical; some icons may lack an SF match. |
| `recharts` | **Swift Charts** (iOS 16+) | Good; note app target is iOS 15 → bump or use a lib. **Flag.** |
| `pdfjs-dist` | **PDFKit** | Clean. |
| `react-markdown` | **AttributedString** (markdown) / `Down` | Clean-ish. |
| `canvas-confetti` | CAEmitterLayer / Lottie | Cosmetic. |
| `input-otp` | native segmented `TextField` | Clean. |
| barcode `getUserMedia` | **Vision `VNDetectBarcodesRequest`** | *Better* native. |
| photo `<input capture>` | **PHPickerViewController / camera** | Clean. |
| `@stripe/*` | — (iOS uses IAP only) | **Throwaway** on iOS. |
| date/util (`date-fns`,`moment`,`lodash`) | Foundation `Date`/`Calendar`, Swift stdlib | Watch local-vs-UTC date logic (`getTodayISODate`). |

No equivalent / reduced capability to flag explicitly: **TanStack Query** (rebuild caching), **react-hook-form/zod** (rebuild form+validation), **the appCache hydration semantics** (no library gives the exact op-chain/anti-hang/SWR/multi-user behavior — it's bespoke).

---

## 4. High-risk areas & unknowns

1. **LLM JSON contract (highest risk).** The ~8,700 LOC business layer's hardest part isn't the math — it's parsing/normalizing free-form model output: markdown-fence stripping, wrapper-key unwrapping, shape validation, per-day slicing, BYO clarification loops (`generateInitialPlanBundle.js`, `structurePastedPlan.js`, `refinePlan*`). The `invoke-llm` edge fn returns text/JSON that JS massages heavily. Re-implementing that tolerance in Swift `Codable` is brittle and **cannot be fully validated by static analysis** — needs live model output across many inputs.
2. **Cache hydration invariants.** `appCache.js` guarantees (Invariant 4) that a hung durable op never wedges the chain (8s race), serializes ops, purges on user switch, and exposes `whenHydrated()` that load effects await to avoid cold-launch flash. Reproducing this on Swift concurrency (actors/async) is subtle; getting it wrong reintroduces the exact cold-launch flashes the team already fixed (see DECISIONS/MEMORY history).
3. **Realtime echo / optimistic writes.** `EntityClient.subscribe` echoes a client's *own* writes back after a DB round-trip (hundreds of ms). Every write-and-read UI does **read-free optimistic updates pre-await** and reconciles on echo (`vitalsLog.js`). supabase-swift Realtime has the same echo behavior — the optimistic+reconcile pattern must be rebuilt screen-by-screen or stale flashes return.
4. **Auth edge cases.** OTP differs by platform (code on iOS / link on web), SIWA must be offered first (App Store), and the OAuth PKCE exchange has a known gotcha (pass only `code`). supabase-swift changes these flows; each needs device testing.
5. **iOS 15 vs Swift Charts (iOS 16+).** Current deployment target is 15.0; native charting and some APIs want 16+. Decision needed.
6. **Not determinable statically:** real LLM response variance; RevenueCat dashboard offering/entitlement config; exact ASC privacy-label mapping vs `PrivacyInfo.xcprivacy`; device-timing of hydration/realtime; whether `three`/`react-leaflet`/`jspdf`/`html2canvas`/`react-quill` are truly unused (0 grep hits, but confirm before deleting).

---

## 5. Bottom line

**Calibrated difficulty: large.** Not because any one piece is exotic, but because two big, independent rewrites stack:
- **UI rewrite** — ~28,000 LOC across 20 pages + ~113 components. Native controls shrink the 54 `ui/` primitives, but every feature screen is rebuilt; `AppShell`, `customize/` drag, and routing are rearchitecture.
- **Business-logic rewrite** — ~8,700 LOC of `src/lib/` translated to Swift, with LLM-output normalization as the landmine.

**What the "keep Supabase" framing actually buys you:** the server side (~856 LOC edge functions + schema) is reused at **near-zero cost**, and the three SDKs port cleanly. That removes the *backend* from the budget — but it does **not** reduce the two dominant client costs above. So the discount is real but bounded.

**Cost ranking (most→least):** UI rewrite ≈ business-logic rewrite ≫ auth/realtime/cache reimplementation ≫ SDK ports ≈ throwaway deletions.

**Incremental alternative (native modules behind Capacitor) — materially cheaper for the same benefit?**
- **Yes, if the goal is performance/UX on specific pain points.** You can keep the React app and drop in native plugins where the WebView hurts: a native **barcode/camera** plugin (Vision), native **charts**, or native list scrolling for the heaviest screens (`Nutrition.jsx`, `Workouts.jsx`). This captures most of the felt benefit while preserving the ~8,700 LOC business layer and most UI — a fraction of the full-rewrite cost.
- **No, if the goal is a fully native UI shell / App Store "real native" feel.** Native-feeling navigation, transitions, and scrolling require replacing `AppShell`, routing, and every screen — at which point you're paying for the full UI rewrite anyway, and the business-logic rewrite is unavoidable regardless of path.

**Recommendation:** Decide what "benefit" means first. If it's smoother specific interactions → go **incremental** (native plugins behind Capacitor). If it's a wholesale native product → the full rewrite is justified, but budget it as **two rewrites (UI + logic)** with the LLM-normalization layer and cache/realtime invariants as the schedule risks, and treat the backend as free.
