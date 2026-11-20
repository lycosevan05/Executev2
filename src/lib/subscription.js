/**
 * subscription.js
 *
 * Subscription state management for Execute.
 * Central helper for checking premium access across the entire app.
 *
 * DEVELOPER NOTES — Stripe Configuration Required:
 * ─────────────────────────────────────────────────
 * Before subscriptions work end-to-end, set these environment variables
 * in your Supabase dashboard → Settings → Environment Variables:
 *
 *   STRIPE_SECRET_KEY          — Your Stripe secret key (sk_live_... or sk_test_...)
 *   STRIPE_WEBHOOK_SECRET      — Webhook signing secret from Stripe Dashboard
 *   STRIPE_PREMIUM_PRICE_ID    — Price ID for the $14.99/month plan (price_...)
 *
 * In the frontend (see stripeConfig below), set:
 *   VITE_STRIPE_PUBLISHABLE_KEY — Your Stripe publishable key (pk_live_... or pk_test_...)
 *
 * Stripe Product Setup:
 *   1. Create a product called "Execute Premium" in Stripe Dashboard
 *   2. Add a recurring monthly price of $14.99 USD
 *   3. Copy the Price ID (price_...) into STRIPE_PREMIUM_PRICE_ID
 *
 * Webhook events to subscribe (Stripe Dashboard → Webhooks):
 *   - checkout.session.completed
 *   - customer.subscription.created
 *   - customer.subscription.updated
 *   - customer.subscription.deleted
 *   - invoice.payment_succeeded
 *   - invoice.payment_failed
 *
 * Webhook endpoint URL: your Supabase function endpoint for stripeWebhook
 * ─────────────────────────────────────────────────
 */

import { backend, supabase } from '@/api/backendClient';

// ─── Stripe frontend config ───────────────────────────────────────────────────
// TODO: Replace with your actual Stripe publishable key
export const STRIPE_PUBLISHABLE_KEY = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY || '';

// ─── In-memory cache ──────────────────────────────────────────────────────────
let _cachedSubscription = null;
let _cacheTime = 0;
let _cacheOwner = null;
let _cacheGeneration = 0;
const READ_TIMEOUT_MS = 8_000;
const CACHE_TTL_MS = 60_000; // 1 minute

export function bustSubscriptionCache() {
  _cachedSubscription = null;
  _cacheTime = 0;
  _cacheOwner = null;
  _cacheGeneration++;
}

/**
 * Synchronous peek at the last-known subscription row (ignores TTL). Powers the
 * SWR seed in useSubscription and PlanGuard's cached-sub classification. Returns
 * null after logout (bustSubscriptionCache) so it can't leak across a session.
 */
export function peekCachedSubscription() {
  return _cachedSubscription;
}

// ─── Core check ───────────────────────────────────────────────────────────────

/**
 * Returns true if the user has an active or trialing Premium subscription.
 * This is the single source of truth for feature gating.
 */
export function isPremiumUser(subscription) {
  if (!subscription) return false;
  const { plan, status } = subscription;
  return plan === 'premium' && (status === 'active' || status === 'trialing');
}

/**
 * Returns true if the subscription is in a past_due or unpaid state.
 * Used to show billing issue warnings.
 */
export function hasBillingIssue(subscription) {
  if (!subscription) return false;
  return subscription.status === 'past_due' || subscription.status === 'unpaid';
}

// ─── Data fetching ────────────────────────────────────────────────────────────

/**
 * Load the current user's subscription record.
 * Returns null if none found (treat as free).
 */
export async function loadUserSubscription(forceRefresh = false) {
  const generation = _cacheGeneration;
  let timer;
  let timedOut = false;

  const read = async () => {
    const user = await backend.auth.me();
    if (!user || timedOut || generation !== _cacheGeneration) return null;
    if (!forceRefresh && _cacheOwner === user.id && Date.now() - _cacheTime < CACHE_TTL_MS) {
      return _cachedSubscription;
    }

    const { data, error } = await supabase.rpc('read_execute_billing_projection');
    if (timedOut || generation !== _cacheGeneration) return null;
    if (error && error.code !== 'PGRST202') throw error;
    let sub = null;
    if (error?.code === 'PGRST202' || data?.state === 'legacy') {
      // Older projects and owners outside the verified cohort use the existing email reader.
      const records = await backend.entities.UserSubscription.filter(
        { user_id: user.email }, '-updated_date', 1
      );
      sub = records?.[0] ?? null;
    } else if (data?.state === 'verified') {
      sub = data.subscription ?? null;
    } else if (data?.state !== 'unavailable') {
      throw new Error('Billing projection response was not recognized');
    }
    if (timedOut || generation !== _cacheGeneration) return null;
    const currentUser = await backend.auth.me();
    if (timedOut || generation !== _cacheGeneration || currentUser?.id !== user.id) return null;
    _cachedSubscription = sub;
    _cacheOwner = user.id;
    _cacheTime = Date.now();
    return sub;
  };

  // The first Home render waits on billing. Bound the whole read, including
  // auth and the legacy fallback, and discard any response after the deadline.
  const deadline = new Promise(resolve => {
    timer = setTimeout(() => {
      timedOut = true;
      resolve(null);
    }, READ_TIMEOUT_MS);
  });
  try {
    return await Promise.race([read(), deadline]);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
