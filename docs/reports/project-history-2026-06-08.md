<div align="center">

# 📱 Execute (Executev3) — Project History

**AI fitness & nutrition planner · Capacitor 8 + React/Vite iOS app**
`com.executelabs.execute`

</div>

---

> [!NOTE]
> **Generated** 2026-06-08 · **Source** deep-review engine over all session history
> **Coverage** `2026-W22 → 2026-W24` (≈ May 26 → Jun 8) · **Run** `.analysis/all_20260608_142417`
> **Scope** Project report only — *what was built, why, and what's left.* Claude Code usage analysis omitted by request.

<div align="center">

| Sessions | Turns | Tool calls | Decision weeks |
|:---:|:---:|:---:|:---:|
| **21** | **5,960** | **1,216** | **3** |

</div>

---

## 🎯 At a Glance

In three weeks the app went from a working web build to a **near-submission-ready native iOS app**. Three threads carried the effort:

| Thread | What happened | State |
|---|---|:---:|
| 💳 **Payments / IAP** | Full RevenueCat + StoreKit + Stripe stack built from scratch, then hardened against WKWebView/Capacitor failure modes | 🟡 Built, not verified live |
| 🛡️ **App Store compliance** | Privacy manifests, usage strings, governing law, fake-integration removal, live localized pricing | 🟢 Code-complete |
| 🧩 **App data & UX** | Shared personalization/plan-sync layer, lazy per-date plans, scroll/back-stack nav, nutrition polish | 🟢 Done |

> [!WARNING]
> **Two things to act on now:** (1) the latest W24 work is **uncommitted on `main`** (incl. the App Store build-number bump), and (2) the purchase → webhook → unlock loop has **never been confirmed live**. Details in [§5 Open Threads](#5--open-threads).

---

## 🏗️ 1. What Was Built — by Area

<details open>
<summary><b>💳 Payments / IAP</b> — the largest body of work (W22 build · W23 hardening)</summary>

<br>

| File | What it does |
|---|---|
| `src/lib/revenuecat.js` | JS facade: `ensureConfigured()` guard, `loadModule()` proxy-deadlock workaround; `login/logout/getOfferings/purchase/restore` + customer-info listeners. Dynamically imported so web never pulls the native plugin. |
| `src/lib/paymentClient.js` | Platform-aware facade: `purchase()`, `restorePurchases()`, `openManageBilling()`, `getOfferings()`. Per-step `withTimeout()`, plugin-availability guard, `packageType`-first matching, cache-bust after purchase. |
| `src/lib/platform.js` | `getPlatform()/isIOS()/isWeb()` with SSR-safe fallback. |
| `supabase/functions/revenuecatWebhook/index.ts` | Receives **all** RC event types, upserts `user_subscriptions`, constant-time bearer check. **Sole writer of the subscription row.** |
| `src/lib/subscription.js` | `isPremiumUser()`, `loadUserSubscription()` (1-min cache), `bustSubscriptionCache()`. No client write path by design. |
| `src/hooks/useSubscription.js` | **OR-gate**: `isPremiumUser() \|\| liveEntitled` (count-based), listens to `execute:subscription-changed`. |
| `src/components/premium/PremiumPaywall.jsx` | Live StoreKit prices via `getOfferings()`, iOS-only Restore, auto-renew disclosure. |
| `src/components/premium/PremiumGate.jsx` | Reads `isPremium`; renders nothing while loading. |
| `src/pages/Billing.jsx` | iOS native upgrade + Restore; web Stripe `<Elements>` + Apple Pay; privacy/terms links. |
| `src/components/billing/ApplePayButton.jsx` | Returns `null` on iOS so the Stripe Wallet button never renders natively. |
| `src/lib/AuthContext.jsx` | RC identity: `loginRevenueCat(email)` on sign-in; listener busts cache on out-of-band renewals. |

</details>

<details>
<summary><b>🔐 Auth</b></summary>

<br>

- `src/lib/AuthContext.jsx` — `appUrlOpen` deep-link bridge handling **both** implicit (`#access_token=`) and PKCE (`?code=`) Supabase callbacks.
- `src/api/backendClient.js` — iOS OAuth redirect → `com.executelabs.execute://login-callback`.
- `src/components/AuthScreen.jsx` — Apple/Google OAuth + email OTP, **SIWA ordered before Google**.
- `/tmp/apple-client-secret.mjs` *(W24, not committed)* — env-parameterized Apple SIWA JWT regenerator. ⚠️ execution unconfirmed.

</details>

<details>
<summary><b>🧠 Plan / AI Generation & Personalization</b></summary>

<br>

| File | Role |
|---|---|
| `src/lib/personalizationSync.js` | Shared layer: `getCurrentUserEmail()` (TTL cache), `loadActiveAIPlan`, `togglePlanItemComplete`, `bustPlanCache`. |
| `src/lib/generateInitialPlanBundle.js` | Lightweight plan-bundle overview (no eager rows). |
| `src/lib/plans/getOrCreateWorkoutPlanForDate.js` | Per-date lazy workout-plan creation. |
| `src/lib/planDayDisplay.js` | Normalizes generic AI titles into sport-specific session titles. |
| `refinePlanFromChat.js`, `goalSync.js`, `readinessScore.js`, `healthContext.js`, `aiContext.js` | Refreshed onto the shared helpers. |

</details>

<details>
<summary><b>🎨 Pages & UX</b></summary>

<br>

- **Navigation** — `src/components/layout/AppShell.jsx`: per-tab scroll save/restore (rAF), per-tab back-stack, 450 ms tab debounce, nav hidden for `/workout-session` / overlays / customize mode. `customize/CustomizeWrapper.jsx` resets `body` state on exit.
- **Screens refreshed** — `Workouts`, `Nutrition`, `MyWeek`, `LogFood`, `Track`, `Progress`, `Goals`, `TrackingHistoryPage`, `Plan`, `WorkoutSession`, `Onboarding`, `PersonalizeQuestionnaire`, `Home`, `Insights`.
- **Nutrition polish (W24)** — `src/pages/Nutrition.jsx`: all calorie/macro/goal values via `Math.round()` + `|| 0` null-safety, **at the display layer only**.
- **Components** — `PlanFocusCard`, `WeeklyPlanPreview`, `WorkoutHeroCard`, `CustomSplitSheet`, `ChecklistCustomizeModal`, `BarcodeLogModal`, `PhotoLogModal`, …

</details>

<details>
<summary><b>🛡️ App Store Compliance</b></summary>

<br>

| Change | File | Guideline |
|---|---|---|
| `NSCameraUsageDescription` added (barcode + meal photo) | `ios/App/App/Info.plist` | Privacy strings |
| Six data-type entries + UserDefaults reason API | `ios/App/App/PrivacyInfo.xcprivacy` | Privacy manifest |
| Governing law → **British Columbia, Canada** (was placeholder) | `src/pages/Terms.jsx` | 2.1 incomplete content |
| Fake Apple Health / HealthKit UI removed | `src/pages/Profile.jsx` | No undeclared capabilities |

</details>

<details>
<summary><b>⚙️ Build / iOS / Tooling</b></summary>

<br>

- `vite.config.js` — `cssCodeSplit: false` (WKWebView `<link>` hang fix), `holdUntilCrawlEnd: false`, `ios/**` excluded from watch, `lucide-react`/`recharts` proxy-aliased.
- `index.html` — cache-bust query after a blank-page regression.
- `ios/App/App/AppDelegate.swift` — native RC `configure()` **removed** (see [D1](#-2-decision-log)).
- `ios/App/App.xcodeproj/project.pbxproj` *(W24)* — `CURRENT_PROJECT_VERSION` **1 → 2**.
- `.gitignore` — excludes `.claude/` and `.analysis/`.
- `CLAUDE.md` *(W24)* — agent guardrails + iOS pipeline + IAP contract.
- `docs/reviews/2026-06-07.md` — deep-review of the window.

</details>

---

## 💡 2. Decision Log

> *Each decision below records the rejected alternative and why.*

| # | Decision | Why |
|:---:|---|---|
| **D1** | Configure RevenueCat **from JS, never AppDelegate** | The plugin's `PurchasesHybridCommon` checks its own singleton; native configure → fatalError on first call. *(⚠️ CLAUDE.md still says the opposite — see [O7](#5--open-threads).)* |
| **D2** | **OR-gate** unlock (DB row **OR** live RC entitlement) | DB row is durable truth but webhook-written; live entitlement grants access instantly post-purchase. Device never writes the row. |
| **D3** | **Count-based** entitlement check | `active.length > 0` is immune to dashboard ID renames vs. keying on a literal string. |
| **D4** | Dynamic import + `loadModule()` | `registerPlugin()` proxy intercepts `then` → phantom bridge call deadlocks `await`. Await the ES namespace instead. |
| **D5** | `cssCodeSplit: false` | WKWebView (`capacitor://`) sometimes never fires `load` on injected `<link>`, freezing CSS-bearing `import()`. |
| **D6** | RC identity = **Supabase email** | Both Stripe + RC webhooks share one identity key — no mapping table. |
| **D7** | **Per-step** `withTimeout()` | A frozen button always reports *which* native step stalled. |
| **D8** | Match by **`packageType`** before identifier | Robust to RC identifier drift (`$rc_month` vs `$rc_monthly`). |
| **D9** | Keep **Health + Fitness** in PrivacyInfo | App collects manual nutrition/workout data; ASC Nutrition Label **must mirror** these. |
| **D10** | Round at **display layer**, not storage | Preserves DB precision, avoids compound macro rounding. |
| **D11** | **CLAUDE.md** as the architecture contract | IAP design was re-derived across sessions at cost; encode it once. |
| **D12** | `.analysis/` **gitignored** | Run artifacts may embed transcripts/credentials. |

---

## 🗓️ 3. Timeline

```
W22  ≈ May 26–30   ██████████  CORE BUILD-OUT
                   RC facade · payment client · webhook · OR-gate layer · paywall/billing
                   OAuth deep-link · personalization/plan-sync · AppShell nav · page refreshes
                   Build fixes: cssCodeSplit, AppDelegate configure removal, blank-page cache-bust

W23  ≈ Jun 1–4     ███████     HARDENING + COMPLIANCE
                   Purchase diagnostics · live StoreKit pricing · RC identity listener
                   Camera string · PrivacyInfo manifest · Terms law · fake-integration removal

W24  ≈ Jun 8       ████        POLISH + HYGIENE
                   Nutrition rounding (unstaged) · build # → 2 · CLAUDE.md · deep-review · SIWA script
```

---

## 🚧 5. Open Threads

### 🔴 Act now

| ID | Issue | Impact |
|:---:|---|---|
| **O1** | W24 work **uncommitted on `main`** — Nutrition rounding, `pbxproj` build-# bump (v2), `.gitignore` change | An archive without the build-# bump can be **rejected as a duplicate**. |
| **O6** | Purchase → webhook → unlock **never confirmed live** (webhook curl timed out; `REVENUECAT_WEBHOOK_SECRET` + dashboard URL needed) | Premium unlock unproven end-to-end. |
| **O7** | **CLAUDE.md contradicts the code** on RC init — doc says "native AppDelegate", code/[D1] say JS-side | A future session may trust the doc and reintroduce the fatalError. |

### 🟡 Code-side risks

| ID | Issue |
|:---:|---|
| **O2** | `monthly → '$rc_month'` in `paymentClient.js` vs spec's `$rc_monthly` — `packageType` fallback should catch it; verify against live dashboard. |
| **O3** | `upsertUserSubscription()` still exists in `subscription.js` despite "device never writes" rule — remove/deprecate. |
| **O4** | RC `customerInfo` listener has **no remove API** — could accumulate on remount/hot-reload. |
| **O5** | `getOfferings()` on paywall mount swallows errors if SDK not yet configured → static fallback prices, no retry. |

### 🟠 Verification gaps

| ID | Issue |
|:---:|---|
| **O8** | No verified Xcode archive this window; AppDelegate-configure change needs a device run. |
| **O9** | Apple SIWA secret regeneration unconfirmed — if expired, Sign in with Apple is silently broken. |

### 🔵 Human-side (App Store Connect / dashboards)

- [ ] **O10** — Build with Xcode 26 / iOS 26 SDK
- [ ] **O11** — StoreKit products approved + RC offering marked **Current**
- [ ] **O12** — ASC Nutrition Label filed & **matching** `PrivacyInfo.xcprivacy` (must list Health + Fitness, see [D9](#-2-decision-log))
- [ ] **O13** — Demo review credentials, age-rating answers, screenshots
- [ ] **O14** — EU trader / DSA + export-compliance declarations

---

<div align="center">
<sub>Merged from three per-week <code>cc-project-progress-analyst</code> passes over <code>slices/decisions/{2026-W22,W23,W24}.json</code>.</sub>
</div>
