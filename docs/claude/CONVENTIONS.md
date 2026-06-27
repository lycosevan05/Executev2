# CONVENTIONS.md — How code is written in Execute

This is the "match the house style" reference. It documents patterns that hold
**across** the codebase, each backed by 2–3 real files. Where the repo is
genuinely inconsistent, that is called out rather than smoothed over. For the
*mechanics* of specific flows (plan generation, auth, IAP, caching internals)
see `KEY_FLOWS.md`; for the data schema see `DATA_MODEL.md`; for where files live
see `REPO_MAP.md`. This file is about *style and patterns*.

A convention here means: confirmed in ≥2–3 files. Single-file observations are
labelled as such. Treat the inconsistencies section of each topic as load-bearing
— picking the "wrong" half of an inconsistency still looks native, so the goal is
to know both halves exist.

---

## 1. Component structure

### 1.1 Two distinct component idioms — know which you're in

The repo has **two separate component styles** that do not mix. This is the single
most important thing to internalize.

**(a) shadcn/ui primitives** — `src/components/ui/*.jsx`
- Built with `class-variance-authority` (`cva`) for variants, `React.forwardRef`,
  an explicit `displayName`, and **named** exports.
- Double-quoted strings. Styling is entirely Tailwind classes composed via `cn()`.
- Example: `src/components/ui/button.jsx` — `const buttonVariants = cva(...)`,
  `const Button = React.forwardRef(...)`, `Button.displayName = "Button"`,
  `export { Button, buttonVariants }`.
- These are vendored library primitives. Treat them like a UI kit; don't rewrite
  them in app style.

**(b) Hand-written app components** — everything under `src/components/<feature>/`
and `src/pages/`
- `export default function ComponentName({ props })` — **default** export, named
  function.
- Single-quoted strings.
- Heavy **inline `style={{}}` with hardcoded hex** for color/brand, mixed with
  Tailwind classes for layout (flex, spacing, rounded, sizing).
- Examples: `src/components/home/AICoachCard.jsx`
  (`export default function AICoachCard({ insights })`, inline
  `style={{ background: ... }}` + `#7DF9FF`/`#ADFF2F`),
  `src/components/track/LogModal.jsx`
  (`export default function LogModal({ category, onClose, onSave, currentValue })`),
  `src/components/premium/PremiumPaywall.jsx`
  (`export default function PremiumPaywall({ onClose, context = '' })`).

When writing new feature/page UI, follow (b). When pulling in a base control,
use (a) from `components/ui/`.

### 1.2 In-file sub-components before the default export

Page and larger feature files define helper sub-components as named functions
*in the same file*, above the default export. They are not extracted to their own
files unless reused elsewhere.
- `src/pages/Profile.jsx` — `function DeleteAccountModal({ onConfirm, onCancel, logout })`
  defined before `export default function Profile(...)`.
- `src/pages/Track.jsx` — `FoodLogger`, `ManageWidgetsSheet` defined in-file
  before the default export.
- `src/components/premium/PremiumPaywall.jsx` — module-level `BENEFITS` data array
  before the component.

### 1.3 Early-return guards

Components guard with early returns at the top of the function body rather than
nesting JSX in conditionals.
- `src/components/home/AICoachCard.jsx` — returns `null` when there are no insights.
- `src/components/premium/PremiumGate.jsx` —
  `if (loading) return null; if (isPremium) return <>{children}</>;` then the paywall.

### 1.4 framer-motion is the animation layer

Overlays, sheets, and entrance animations use `framer-motion` (`motion.div`,
`AnimatePresence`), not CSS transitions or other libraries. Sheets are spring
transitions; backdrops fade.
- `src/components/track/LogModal.jsx`, `src/pages/Profile.jsx`
  (`transition={{ type: 'spring', damping: 28, stiffness: 320 }}`),
  `src/components/premium/PremiumGate.jsx` (`AnimatePresence` around the paywall).
- Bottom sheets animate `y: '100%' → 0`; backdrops animate `opacity`.

### 1.5 Inconsistency — when to portal a bottom-sheet overlay

The **default** bottom-sheet/modal idiom is a non-portaled `fixed inset-0`
framer-motion sheet rendered inline in the component tree. Portaling to
`document.body` is the **minority** pattern — only used in the few places the
Home-transform gotcha forces it.
- **Non-portaled (the majority)**: a plain
  `className="fixed inset-0 z-50 flex items-end ..."` motion sheet, e.g.
  `src/components/food/BarcodeLogModal.jsx` (`fixed inset-0 ... items-end`),
  `src/components/workouts/CustomSplitSheet.jsx` (`fixed inset-0 ... justify-end`),
  plus PhotoLogModal, MealEditModal, RecipeEditorModal, ChecklistCustomizeModal,
  VitalsSheet, PostWorkoutCheckIn, PlanGeneratingOverlay, CustomizePanel,
  StarterProfileModal.
- **Portaled (only 3 files)**: `createPortal(node, document.body)` —
  `src/components/track/LogModal.jsx`
  (`import { createPortal } from 'react-dom'`, returns
  `createPortal(<motion.div ...>, document.body)`, plus a body scroll-lock
  `useEffect`), `src/components/plan/RefinePlanModal.jsx`,
  `src/components/plan/AskQuestionsModal.jsx`.
- **When to portal**: a parent's CSS transform creates a stacking context that
  traps a non-portaled overlay *below* the fixed bottom nav. Documented in
  MEMORY: Home's route root is a transformed div (pull-to-refresh), so overlays
  mounted under it must portal to escape. Outside that case, the inline
  `fixed inset-0` sheet is fine — don't reflexively portal.
- Footers respect the safe area: `paddingBottom: 'calc(... + env(safe-area-inset-bottom))'`
  (LogModal, Profile's DeleteAccountModal).

### 1.6 Icons and charts come from alias shims, never the npm package directly

`lucide-react` and `recharts` are **vite-aliased** to hand-maintained shim files
(`vite.config.js`). Code still writes `import { X } from 'lucide-react'` /
`'recharts'`, but it resolves to the shim.
- `src/lib/lucide-react.js` — re-exports only a curated icon list, alphabetical,
  some renamed (`AlertCircle` → `circle-alert.js`, `BarChart2` →
  `chart-no-axes-column.js`).
- `src/lib/recharts.js` — **named** re-exports of a curated chart subset.
- **Hard gotcha (confirmed):** importing an icon *not* in the shim passes lint and
  `tsc` but **fails the vite/rollup build** with
  `"<Icon>" is not exported by "src/lib/lucide-react.js"`. To add one, append the
  `export { default as <Icon> } from '.../icons/<kebab>.js'` line (alphabetical).
- Import usage is identical to the real packages, e.g.
  `import { Brain, Zap } from 'lucide-react'` (AICoachCard.jsx),
  `import { Sparkles, X, Zap, Dumbbell, ... } from 'lucide-react'` (PremiumPaywall.jsx).

### 1.7 Inconsistency — brand accent colors have no single source

The brand accent (`#c8e000`) and its dark shade (`#8ea400`) are **duplicated
across ~63 files** with no design-token module. Three patterns coexist:
- **Imported** from `src/components/track/categories.js` (which
  `export const ACCENT = '#c8e000'; export const ACCENT_DARK = '#8ea400';`).
- **Redefined locally** as module constants:
  `src/components/premium/PremiumGate.jsx`, `PremiumPaywall.jsx`,
  `src/pages/Profile.jsx` all have their own
  `const ACCENT = '#c8e000'; const ACCENT_DARK = '#8ea400';`.
- **Inlined as raw hex** in `style={{}}` and local color maps
  (`AICoachCard.jsx` uses `#7DF9FF`, `#ADFF2F` directly).

There is no "right" choice that matches the whole repo. When in doubt, redefining
`ACCENT`/`ACCENT_DARK` as a local module const (the Profile/Premium pattern) is the
most common and won't look out of place. Don't assume a shared token exists.

---

## 2. State management

### 2.1 Local `useState`/`useEffect` is the default; Context is reserved

Most state is component-local `useState` + `useEffect`. Cross-cutting state lives
in a small number of React Contexts, primarily **`AuthContext`**.
- `src/lib/AuthContext.jsx` —
  `const AuthContext = createContext()`, `export const AuthProvider = ({ children }) => {...}`,
  many `useState`, `useCallback` for `checkUserAuth`; consumed via a `useAuth()`
  hook.
- Consumers: `src/pages/Profile.jsx` (`useAuth()`),
  `src/hooks/useSubscription.js` (pulls `rcCustomerInfo` from `useAuth()`).

There is no Redux/Zustand/Jotai. Server/state caching is handled by the layers
below, not a global store.

### 2.2 Hooks wrap a lib + a context + a cache; components consume the hook

Domain state is exposed to components through a custom hook in `src/hooks/`, which
internally composes a `src/lib/` module (the source of truth) and any context it
needs. Components read the hook, never the lib directly.
- `src/hooks/useSubscription.js` (named export `export function useSubscription()`)
  composes `src/lib/subscription.js` (backend row + module cache) and
  `useAuth()` (live RC entitlement), exposing `{ isPremium, loading, refresh }`.
- The documented read order is **hook → lib** (CLAUDE.md). Mirror this for new
  domains.

### 2.3 Module-level TTL cache (lightweight SWR) in lib modules

`src/lib/` modules that hit the backend cache the result in **module-scoped
variables** with a TTL and an explicit bust function. This is the project's
SWR-lite: serve cached, refresh, expose a manual invalidator.
- `src/lib/subscription.js` —
  `let _cachedSubscription = null; let _cacheTime = 0; const CACHE_TTL_MS = 60_000;`
  + `export function bustSubscriptionCache()`.
- `src/lib/personalizationSync.js` — `resetPersonalizationCaches()` clears
  `_aiPlanCache` + `_cachedUserEmail` (referenced from AuthContext logout).
- A separate, heavier two-tier durable cache (`src/lib/appCache.js`) backs
  cold-launch hydration; that is its own subsystem — see KEY_FLOWS / MEMORY, not
  a pattern to hand-roll per module.

### 2.4 Optimistic-write + Realtime-reconcile (one shared write path)

This is a single shared mechanism rather than a pattern replicated across domains:
the only UIs that both read a `.subscribe()` Realtime stream **and** write are
`src/pages/Track.jsx` and `src/pages/Home.jsx`, and both route their writes
through `saveVitalLog` in `src/lib/vitalsLog.js`. Where it applies, the rule is:
update optimistically from in-memory state (read-free, *before* the await), then
let the Realtime echo reconcile to authority. Supabase Realtime echoes a client's
own writes back after a DB round-trip (hundreds of ms) — never instant — so
without optimism you get a flash of stale.
- `src/lib/vitalsLog.js` — `saveVitalLog({ ..., onOptimistic = null })` fires
  `onOptimistic?.({ uiValue, updates, targetDailyLog })` *after* the read and
  *before* the `DailyLog.update/create` write, then `appCache.invalidate(...)`.
- Confirmed against the EntityClient subscribe contract in
  `src/api/backendClient.js` and the AppShell/Track/Home integration notes.
- **Note** `onOptimistic` must default to `null` in the signature — otherwise
  `tsc` infers it required and call sites that don't pass it error.
- If you add a *new* subscription-backed writer (a new domain), apply the same
  optimistic-before-await discipline; today there is just this one path.

### 2.5 OR-gate for premium (never trust a single source)

Premium is unlocked if **either** the backend `user_subscription` row says
premium/active **or** live RevenueCat `customerInfo.entitlements.active` is
non-empty. Don't gate on one alone.
- `src/hooks/useSubscription.js` —
  `isPremium: isPremiumUser(subscription) || liveEntitled`.
- `src/lib/subscription.js` — `isPremiumUser` =
  `plan === 'premium' && (status === 'active' || status === 'trialing')`.

---

## 3. Data access

### 3.1 All entity reads/writes go through `backend.entities.*` (EntityClient)

Application code **never** touches the Supabase client for data. It goes through
the `EntityClient` abstraction in `src/api/backendClient.js`, exposed as
`backend.entities.<Entity>`.
- `src/lib/subscription.js` —
  `backend.entities.UserSubscription.filter({ user_id: user.email }, '-updated_date', 1)`.
- `src/lib/vitalsLog.js` — `DailyLog.update/create` via the same client.
- `src/pages/Profile.jsx` — `import { backend } from '@/api/backendClient'`.
- The raw `supabase` client (also exported from backendClient.js) is reserved for
  **auth and edge functions** (`backend.functions.invoke(...)`), not table CRUD.
  E.g. `backend.functions.invoke('deleteUserData', {})` in Profile.jsx.

### 3.2 The JSONB `data` bag convention

Entity fields live in a single JSONB `data` column by convention, not as real
columns. The EntityClient flattens this for you:
- `flattenRecord(row)` spreads `row.data` to the top level and adds
  `id / created_by / user_email / *_date` wrapper fields — so callers see a flat
  object.
- `recordPayload(data, user)` does the inverse on write: duplicates identity
  (email) into both wrapper columns and the `data` bag.
- `mergeUpdate` merges into the existing `data` bag on update.
- Consequence: when adding a field to an entity, you usually **don't** add a DB
  column — just write the key and it lands in `data`. (See DATA_MODEL.md for which
  fields are real columns vs bag.)

### 3.3 Query/filter conventions

- `filter(criteria, order, limit)` is the standard read. Order strings use a `-`
  prefix for descending — `parseOrder` in backendClient.js,
  e.g. `'-updated_date'` (subscription.js).
- Scalar criteria are pushed to the server as `data->>key` JSON-path filters;
  array/object criteria are filtered **client-side** after fetch (`_select` in
  backendClient.js).
- Reads are capped: `MAX_ROWS_PER_QUERY = 2000`. Don't assume unbounded result
  sets.

### 3.4 Entity → table mapping is centralized

The `TABLES` map in `src/api/backendClient.js` is the single Entity→table-name
source (19 entities; see REPO_MAP.md for the list). Add new entities there; don't
hardcode table names elsewhere.

### 3.5 Realtime subscription shape

`EntityClient.subscribe(cb)` wraps Supabase `postgres_changes` (`event: '*'`,
table-scoped). The callback receives
`{ type: 'create'|'update'|'delete', data: flattenRecord(payload.new || payload.old) }`.
It echoes the client's own writes (no self-exclusion) — see §2.4.

### 3.6 Supabase client config (single place)

The `supabase` client is created once in `backendClient.js` with
`flowType: 'pkce'`, `persistSession`, `autoRefreshToken`, `detectSessionInUrl`,
and `realtime.eventsPerSecond: 10`. Env comes from `import.meta.env.VITE_*` with a
`getSupabaseConfigError()` guard that validates the URL shape. Don't spin up a
second client.

---

## 4. Error handling, backoff, and retry

### 4.1 try/catch → log + return null/sentinel in lib reads

Lib data-loaders wrap the backend call in try/catch and return a benign sentinel
(`null`, `[]`, or `{ ok: false, reason }`) rather than throwing to the UI.
- `src/lib/subscription.js` — `loadUserSubscription` try/catch returns `null`.
- `src/lib/vitalsLog.js` — `saveVitalLog` returns `{ ok: false, reason }` on a
  guard miss and `{ ok: true, ... }` on success (result-object style, not throw).
- `src/pages/Profile.jsx` — `DeleteAccountModal` try/catch
  `console.error('Delete account failed:', err)` then resets local state.

So callers branch on a return value; they generally don't wrap lib calls in their
own try/catch.

### 4.2 `withBackoff` for DB-side retries (full jitter)

Transient backend failures are retried with `src/lib/withBackoff.js` —
`export async function withBackoff(fn, options = {})`, a `while (true)` loop that
`return await fn()` on success and on failure waits
`Math.max(retryAfterMs(err), jittered)` (full-jitter) capped by a deadline.
- Used to tame the workout multi-day "Build all" 429 storm (per CLAUDE.md /
  MEMORY): `withBackoff` + pooled concurrency cap in
  `src/lib/plans/buildWorkoutPlansForDates.js`.
- Honor `Retry-After` when present; that's what `retryAfterMs(err)` is for.

### 4.3 LLM 429s surface with `.status`; edge fn does its own backoff

The `invoke-llm` edge function retries OpenAI with its own backoff that honors
`Retry-After`. A 429 propagates to the frontend with `.status` via
`error.context.status` (CLAUDE.md / KEY_FLOWS). Frontend code branches on that
status rather than blind-retrying.

### 4.4 `withBackoff` covers both workout and nutrition multi-day builds

Both the workout and nutrition plan-build paths wrap their backend calls in
`withBackoff`. The nutrition path mirrors the workout fix (hoisted invariant
fetch + per-call backoff):
- `src/lib/plans/buildMealPlansForDates.js` — fetches invariant context exactly
  once through `withBackoff` (`:67`: `await withBackoff(() => Promise.all([...
  UserProfile.filter ..., NutritionProfile.filter ...]))`).
- `src/lib/plans/getOrCreateMealPlanForDate.js` — wraps the existing-plan filter
  reads (`:168`, `:170`), the FoodLog read (`:201`), and the final
  `MealPlan.create` (`:404`) in `withBackoff`, with the swallowing `.catch`
  sitting *outside* the wrapper so a first 429 retries rather than converting to
  "no plan".
- `src/lib/plans/buildWorkoutPlansForDates.js` / `getOrCreateWorkoutPlanForDate.js`
  — the original hardened path (backoff + pooled concurrency cap).

So `withBackoff` is the repo-wide standard for multi-day plan builds. Match it
when adding new build paths.

---

## 5. Naming, file organization, routing

### 5.1 Imports use the `@/` alias for `src`

Cross-module imports use the `@` alias (`vite.config.js`: `@ → ./src`), not deep
relative paths.
- `src/pages/Profile.jsx` — `import { backend } from '@/api/backendClient'`,
  `import { useAuth } from '@/lib/AuthContext'`,
  `import { useSubscription } from '@/hooks/useSubscription'`.
- `src/components/premium/PremiumPaywall.jsx` — `@/lib/paymentClient`,
  `@/lib/platform`, `@/hooks/useSubscription`.
- The two shim files use **relative** paths into `node_modules` on purpose
  (lucide-react.js, recharts.js) — that's the exception, not the rule.

### 5.2 Where things live (and the naming that follows)

- `src/pages/*.jsx` — route-level screens, PascalCase (`Profile.jsx`,
  `Track.jsx`, `Nutrition.jsx`). One default-exported page component each.
- `src/components/<feature>/*.jsx` — feature UI grouped by domain folder
  (`home/`, `track/`, `premium/`, `billing/`, `plan/`, `customize/`, `ui/`).
- `src/lib/*.js` — app logic / source-of-truth modules (auth, payments, plan
  generation, sync). camelCase filenames (`subscription.js`, `vitalsLog.js`,
  `withBackoff.js`); domain-grouped subfolders like `src/lib/plans/`.
- `src/hooks/*.js` — `useX` named-export hooks.
- `src/api/` — the backend client. `src/utils/` — small helpers.
- Page-scoped constants: a `const PAGE_KEY = 'profile'` style id at the top of a
  page (Profile.jsx).

### 5.3 Routing is centralized in `App.jsx`

All routes are declared in `src/App.jsx` (react-router-dom v6) — see REPO_MAP.md
for the route→page table. Pages are the routed unit; components are not routed.
Navigation inside components uses `useNavigate()` /
`<Link to="...">` (e.g. AICoachCard's `<Link to="/plan">`,
PremiumPaywall's `useNavigate()`), not manual history manipulation.

### 5.4 Helper naming idioms

- `cn(...inputs)` = `twMerge(clsx(inputs))` in `src/lib/utils.js` is the canonical
  className combiner (used by all `ui/` primitives).
- Cache busters are named `bust<Thing>Cache()` / `reset<Thing>Caches()`
  (subscription.js, personalizationSync.js).
- Backend/sync loaders are `load<Thing>` / `save<Thing>` / `getOrCreate<Thing>`;
  premium check is `isPremiumUser`.
- Module-private state uses a leading underscore (`_cachedSubscription`,
  `_aiPlanCache`).

### 5.5 JSDoc/header + section dividers in lib modules

Larger lib and component files open with a JSDoc/comment header describing the
module, and use `// ─── Title ───` (box-drawing) dividers between sections.
- `src/lib/subscription.js` (JSDoc + dividers),
  `src/components/premium/PremiumGate.jsx` (JSDoc header),
  `src/components/premium/PremiumPaywall.jsx` (JSDoc header).
- `// @ts-nocheck` appears at the top of files that opt out of typechecking
  (`src/api/backendClient.js`). The project is `.js/.jsx` checked via
  `tsc -p ./jsconfig.json`, not TypeScript source.

---

## 6. Async & data-fetching idioms

- **async/await throughout**, not raw `.then()` chains. Handlers are
  `const handleX = async () => { ... }` (Profile.jsx `handleConfirm`).
- **Capture-then-bail on identity** for races: long-running loaders capture the
  current `uid`/email and bail if it changed mid-flight before writing cache
  (personalizationSync `loadActivePlan`, per MEMORY). Apply this to any
  multi-step load that writes a shared cache.
- **Optimistic-before-await** for anything backed by a subscription/cache (§2.4)
  — fire the in-memory UI update before the network write, reconcile after.
- **Result objects over throws** for expected failure (`{ ok, reason }` from
  saveVitalLog); throws are reserved for genuinely exceptional paths.
- **Platform gating** for native-vs-web behavior via
  `getPlatform()` (`src/lib/platform.js`): e.g. PremiumPaywall's
  `const isIOS = getPlatform() === 'ios'` to pull live StoreKit prices on iOS
  only. Payment calls go through the `src/lib/paymentClient.js` facade, never
  RevenueCat/Stripe directly from a component.
- **TanStack Query** is available and used for server-state in parts of the app,
  but is **not** universal — many lib modules use the module-level TTL cache
  (§2.3) instead. Don't assume one or the other repo-wide; match the file you're
  editing.

---

## Inconsistencies to remember (summary)

1. **Brand accent has no single token** — imported from categories.js in some
   files, redefined locally in others, inlined as hex in others (~63 files). §1.7
2. **Two component idioms** — shadcn `ui/` (cva/forwardRef/named/double-quote) vs
   app components (default-export/inline-hex/single-quote). Don't mix. §1.1
3. **Portaling overlays is the minority pattern** — the default bottom-sheet is a
   non-portaled `fixed inset-0` motion sheet; only 3 files `createPortal`, and
   only where the Home-transform stacking gotcha forces it. §1.5
4. **Caching is mixed** — module-level TTL caches and TanStack Query coexist;
   plus the separate appCache durable subsystem. §2.3, §6

---

## Last verified against

- `docs/claude/REPO_MAP.md` (orientation: routes, Entity→table list, dir map)
- `src/components/home/AICoachCard.jsx`
- `src/components/track/LogModal.jsx`
- `src/components/track/categories.js` (head)
- `src/components/premium/PremiumGate.jsx`
- `src/components/premium/PremiumPaywall.jsx` (1–55)
- `src/components/ui/button.jsx`
- `src/hooks/useSubscription.js`
- `src/lib/subscription.js`
- `src/lib/vitalsLog.js` (saveVitalLog, ~150–214)
- `src/lib/withBackoff.js` (loop, ~53–78)
- `src/lib/plans/getOrCreateMealPlanForDate.js` (withBackoff sites ~150–410)
- `src/lib/plans/buildMealPlansForDates.js` (~55–79)
- `src/components/food/BarcodeLogModal.jsx` (render ~309–401)
- `src/components/workouts/CustomSplitSheet.jsx` (render ~69–272)
- `src/components/nutrition/MealEditModal.jsx` (head)
- `src/components/plan/RefinePlanModal.jsx` (1–20)
- Grep: `createPortal` / `.subscribe(` / `withBackoff` / `supabase.` across `src/`
- `src/lib/utils.js`
- `src/lib/AuthContext.jsx` (1–30)
- `src/lib/lucide-react.js` (head)
- `src/lib/recharts.js` (head)
- `src/api/backendClient.js` (1–220)
- `src/pages/Profile.jsx` (1–60)
- `src/pages/Track.jsx` (1–75)
- `vite.config.js`
- Grep: `const ACCENT = ` / `'#c8e000'` across `src/` (~63 files matched —
  basis for the accent-color inconsistency)
- Cross-referenced: `CLAUDE.md`, MEMORY notes (backoff/fan-out, optimistic
  pattern, lucide shim gotcha) — flagged where a claim rests on those rather than
  a fresh read.
