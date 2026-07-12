/**
 * planGuardDecision — pure, side-effect-free decision logic for PlanGuard.
 *
 * Extracted so the SWR short-circuit is unit-testable without pulling in App.jsx
 * (which registers window listeners at import). PlanGuard.jsx (and, until the
 * keep-alive commit, App.jsx) imports syncDecide from here.
 *
 * Decisions:
 *   'allow'    — render the guarded children now
 *   'checking' — hold the skeleton; not enough settled state to decide
 *   'confirm'  — cache miss under a premium user; caller must do an authoritative
 *                AIPlan read before redirecting (a bare null is not a negative)
 */

/**
 * Classify the cached subscription snapshot for the SWR short-circuit.
 *   'active'  — premium is live (table row premium/active OR live entitlement)
 *   'lapsed'  — a cached row exists and is explicitly NOT premium (expired/free)
 *   'unknown' — no cached snapshot yet
 *
 * @param {boolean} isPremium  resolved premium flag (table OR live entitlement)
 * @param {object|null} cachedSub  the last-known subscription row, or null
 * @param {(sub: object) => boolean} isPremiumRow  isPremiumUser predicate
 */
export function classifySubState(isPremium, cachedSub, isPremiumRow) {
  if (isPremium) return 'active';
  if (cachedSub && !isPremiumRow(cachedSub)) return 'lapsed';
  return 'unknown';
}

/**
 * @param {object} p
 * @param {boolean} p.subLoading    subscription still revalidating
 * @param {boolean} p.cacheReady     appCache durable hydration settled
 * @param {boolean} p.isPremium      resolved premium flag
 * @param {boolean} p.generating     a plan generation is in flight
 * @param {boolean} p.hasCachedPlan  a plan is already in the warm cache
 * @param {'active'|'lapsed'|'unknown'} p.subState  cached subscription class
 * @returns {'allow'|'checking'|'confirm'}
 */
export function syncDecide({ subLoading, cacheReady, isPremium, generating, hasCachedPlan, subState }) {
  // SWR short-circuit: paint instantly from the warm plan cache while the
  // subscription revalidates — but NEVER fast-allow a known-lapsed subscriber
  // (that flashes entitled content before the revalidation redirect). A cached
  // plan with an active-or-unknown sub is safe to render now.
  if (hasCachedPlan && subState !== 'lapsed') return 'allow';

  // Not settled and no safe warm path — hold the skeleton rather than guess.
  if (subLoading || !cacheReady) return 'checking';

  // Fully settled path (unchanged semantics): non-premium isn't plan-gated here,
  // an in-flight generation is never bounced, and a premium cache-miss must be
  // confirmed by the caller before any redirect.
  if (!isPremium) return 'allow';
  if (generating) return 'allow';
  return hasCachedPlan ? 'allow' : 'confirm';
}
