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

import { backend } from '@/api/backendClient';

// ─── Stripe frontend config ───────────────────────────────────────────────────
// TODO: Replace with your actual Stripe publishable key
export const STRIPE_PUBLISHABLE_KEY = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY || '';

// ─── In-memory cache ──────────────────────────────────────────────────────────
let _cachedSubscription = null;
let _cacheTime = 0;
const CACHE_TTL_MS = 60_000; // 1 minute

export function bustSubscriptionCache() {
  _cachedSubscription = null;
  _cacheTime = 0;
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
  const now = Date.now();
  if (!forceRefresh && _cachedSubscription && now - _cacheTime < CACHE_TTL_MS) {
    return _cachedSubscription;
  }

  try {
    const user = await backend.auth.me();
    if (!user) return null;

    const records = await backend.entities.UserSubscription.filter(
      { user_id: user.email },
      '-updated_date',
      1
    );

    const sub = records?.[0] || null;
    _cachedSubscription = sub;
    _cacheTime = now;
    return sub;
  } catch {
    return null;
  }
}

/**
 * Create or update a UserSubscription record.
 */
export async function upsertUserSubscription(data) {
  try {
    const user = await backend.auth.me();
    if (!user) return null;

    const existing = await backend.entities.UserSubscription.filter(
      { user_id: user.email },
      '-updated_date',
      1
    );

    const payload = {
      ...data,
      user_id: user.email,
      updated_at: new Date().toISOString(),
    };

    let result;
    if (existing?.[0]) {
      result = await backend.entities.UserSubscription.update(existing[0].id, payload);
    } else {
      result = await backend.entities.UserSubscription.create({
        ...payload,
        created_at: new Date().toISOString(),
      });
    }

    bustSubscriptionCache();
    return result;
  } catch {
    return null;
  }
}