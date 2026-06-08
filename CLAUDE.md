# Execute (Executev3) — Project Instructions

Capacitor-wrapped React/Vite iOS app. Bundle id `com.executelabs.execute`, appName "Execute".

## Stack
- React 18 + Vite 6, ESM (`"type": "module"`). Tailwind + Radix UI + framer-motion; lucide-react icons.
- Data/state: TanStack Query (`@tanstack/react-query`), react-hook-form, react-router-dom v6.
- Backend: Supabase (`@supabase/supabase-js`) — auth + edge functions. Client in `src/api/`.
- Native shell: Capacitor 8 (SPM-based, no Podfile; native plugins in `ios/App/CapApp-SPM`). Plugins: App, Browser, RevenueCat Purchases.
- Payments: iOS → RevenueCat/StoreKit IAP; web → Stripe. Platform gate: `src/lib/platform.js` `getPlatform()`; facade: `src/lib/paymentClient.js`.

## Commands (use these, don't improvise)
- `npm run dev` — Vite dev server (browser preview only; NOT part of any iOS build).
- `npm run build` — Vite production build → `dist/`.
- `npm run ios:sync` — `vite build && cap sync ios` (the canonical build-for-iOS step).
- `npm run ios:open` — open the iOS project in Xcode.
- `npm run ios:run` — build, sync, and run on a device/simulator.
- `npm run lint` / `npm run lint:fix` — ESLint. `npm run typecheck` — `tsc -p ./jsconfig.json`.

## Repo map (where things live — read here before Glob-sweeping)
- `src/pages/` — route-level screens (Nutrition, Workouts, Billing, Profile, PrivacyPolicy, Terms…).
- `src/components/` — UI; payments under `components/premium/` (PremiumPaywall, PremiumGate) and `components/billing/`.
- `src/lib/` — app logic: auth (`AuthContext.jsx`), payments (`paymentClient.js`, `revenuecat.js`, `subscription.js`, `platform.js`), plan generation (`generateInitialPlanBundle.js`, `refinePlanFromChat.js`, `goalSync.js`, `personalizationSync.js`).
- `src/hooks/` — React hooks (`useSubscription.js`). `src/api/` — Supabase client. `src/utils/` — helpers.
- `supabase/functions/revenuecatWebhook/` — server-side IAP event receiver. `ios/App/` — native iOS project + Info.plist + AppDelegate.swift + PrivacyInfo.xcprivacy.
- Routing is declared in `src/App.jsx`.

> Note: secrets (Supabase keys, RevenueCat/Apple credentials) are NOT in this file by design — it is committed to git. Find them in env/local config, not here.

## Agent guardrails
- Read a file in-session before you Edit it. Bare Edit on an unread file is rejected. Read → Edit is mandatory.
- Scope every Grep to a subdir (src/lib/, src/pages/) or a filename. Never grep the repo root loosely. Prefer Read+offset/limit when the target file is known.
- Capacitor config is `capacitor.config.ts` (TypeScript). There is no `.js` variant.
- macOS zsh has no GNU `timeout`. Use the Bash tool's built-in timeout param, not `timeout <n> <cmd>`.
- `Nutrition.jsx` exceeds the single-read token limit — always read it with offset/limit until it's split.

## iOS build pipeline
- To build for iOS: `npm run ios:sync` (= `vite build && cap sync ios`), then `npm run ios:open` for Xcode. Never run `npm run dev` or curl-probe a dev server as part of a build/sync.
- If `cap sync ios` fails more than once, stop and run `npx cap doctor`; check `ios/App/CapApp-SPM/Package.swift` before retrying.
- Vite dev-server hang fix: set optimizeDeps.holdUntilCrawlEnd: false in vite.config.js.

## RevenueCat / IAP (iOS)
- Package IDs: $rc_monthly → execute_premium_month, $rc_annual → execute_premium_annual
- Entitlement gate: "premium"; Offering: "default" (Current in RC dashboard)
- Unlock = OR-gate: Supabase user_subscription row premium/active OR live customerInfo.entitlements.active non-empty.
  Device never writes user_subscription; the revenuecatWebhook edge function is the sole writer.
- SDK configured from JS via ensureConfigured() in src/lib/revenuecat.js (Purchases.configure), NOT natively in AppDelegate. Native configure would initialize the app-target instance, leaving the Capacitor plugin's PurchasesHybridCommon instance unconfigured → logIn/getOfferings fatalError.
- Subscription truth lives across: revenuecat.js (SDK/entitlement), subscription.js (backend row), useSubscription.js (React hook). Read order: hook → lib.
