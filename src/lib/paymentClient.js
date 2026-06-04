/**
 * paymentClient.js
 *
 * Platform-aware purchase facade. Components that need to start a purchase,
 * restore one, or open billing management call into this module and never
 * need to know whether the active rail is Apple StoreKit (via RevenueCat)
 * or Stripe (web).
 *
 *   - getPlatform() === 'ios'   → RevenueCat / StoreKit IAP
 *   - everything else           → existing Stripe checkout / portal
 *
 * Plans:
 *   'annual'  → maps to RevenueCat package $rc_annual / Stripe annual price
 *   'monthly' → maps to RevenueCat package $rc_monthly / Stripe monthly price
 */

import { Capacitor } from '@capacitor/core';
import { backend } from '@/api/backendClient';
import { getPlatform } from '@/lib/platform';
import { bustSubscriptionCache } from '@/lib/subscription';

const PLAN_TO_RC_IDENTIFIER = {
  annual: '$rc_annual',
  monthly: '$rc_month',
};

// Reject if a native RevenueCat call doesn't settle. A visible timeout beats a
// frozen button. The hint is step-specific so failures point at the real cause
// instead of always blaming StoreKit/the Paid Apps agreement.
function withTimeout(promise, ms, label, hint = '') {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`${label} timed out after ${ms / 1000}s.${hint ? ` ${hint}` : ''}`)), ms)
    ),
  ]);
}

// ─── iOS (RevenueCat) ─────────────────────────────────────────────────────────

async function purchaseIOS(plan, onStep = () => {}) {
  // Hard check: is the native 'Purchases' plugin actually registered in this
  // binary? If false, the SDK never made it into the build and every native
  // call (configure/getOfferings) would hang waiting for a handler.
  const pluginAvailable = Capacitor.isPluginAvailable('Purchases');
  onStep(`Purchases plugin available: ${pluginAvailable}`);
  if (!pluginAvailable) {
    throw new Error('Native RevenueCat plugin "Purchases" is NOT registered in this build. The pod/SPM package compiled but the plugin did not load. Rebuild: in Xcode do File → Packages → Reset Package Caches, then Clean Build Folder, then Run.');
  }

  onStep('loading billing module…');
  const rc = await withTimeout(import('@/lib/revenuecat'), 15000, 'Loading billing module', 'The RevenueCat JS bundle failed to load in the WebView.');

  onStep('configuring RevenueCat (build v3)…');
  // Ensure the SDK is configured even if the startup login effect never ran
  // (e.g. session restored before the iOS effects mounted). Idempotent.
  await withTimeout(rc.initRevenueCat(undefined, onStep), 15000, 'Configuring RevenueCat', 'The native SDK did not initialize — verify the API key and that Purchases is configured at launch.');

  onStep('fetching offerings…');
  const offerings = await withTimeout(rc.getOfferingsRevenueCat(), 20000, 'Fetching offerings', 'StoreKit could not load products — check the Paid Apps agreement is active, the products are approved, and an offering is marked Current.');
  const current = offerings?.current;
  if (!current) {
    const ids = Object.keys(offerings?.all || {}).join(', ') || 'none';
    throw new Error(`No "current" offering in RevenueCat. Offerings found: ${ids}. Mark an offering as Current in the dashboard.`);
  }
  const identifier = PLAN_TO_RC_IDENTIFIER[plan] || PLAN_TO_RC_IDENTIFIER.annual;
  const wantType = plan === 'monthly' ? 'MONTHLY' : 'ANNUAL';
  const available = current.availablePackages || [];
  onStep(`offering "${current.identifier}": ${available.length} pkg(s)`);
  // Match by packageType first (robust to $rc_month vs $rc_monthly naming),
  // then fall back to the literal package identifier.
  const pkg =
    available.find(p => p.packageType === wantType) ||
    available.find(p => p.identifier === identifier);
  if (!pkg) {
    const have = available.map(p => p.identifier).join(', ') || 'none';
    throw new Error(`No ${wantType} package in offering "${current.identifier}". Available: ${have}.`);
  }
  onStep('presenting StoreKit sheet…');
  const result = await withTimeout(rc.purchasePackageRevenueCat(pkg), 60000, 'StoreKit purchase', 'The App Store purchase sheet did not complete.');
  bustSubscriptionCache();
  return { ok: true, transaction: result };
}

async function restoreIOS() {
  const rc = await import('@/lib/revenuecat');
  const info = await rc.restorePurchasesRevenueCat();
  bustSubscriptionCache();
  return { ok: true, info };
}

async function getOfferingsIOS() {
  const rc = await import('@/lib/revenuecat');
  return rc.getOfferingsRevenueCat();
}

// ─── Web (Stripe — existing behavior preserved) ──────────────────────────────

async function purchaseWeb(plan) {
  const response = await backend.functions.invoke('stripeCreateCheckout', { plan });
  if (response?.data?.url) {
    window.location.href = response.data.url;
    return { ok: true, redirected: true };
  }
  throw new Error(response?.data?.error || 'Could not start checkout.');
}

async function openPortalWeb() {
  const response = await backend.functions.invoke('stripeCreatePortal');
  if (response?.data?.url) {
    window.location.href = response.data.url;
    return { ok: true, redirected: true };
  }
  throw new Error(response?.data?.error || 'Could not open billing portal.');
}

// ─── Public API ──────────────────────────────────────────────────────────────

/**
 * Start a purchase for the given plan. Resolves on success or throws on error.
 * On web this redirects to Stripe Checkout; on iOS it presents the native sheet.
 */
export async function purchase(plan, onStep = () => {}) {
  const platform = getPlatform();
  onStep(`platform: ${platform}`);
  if (platform === 'ios') return purchaseIOS(plan, onStep);
  return purchaseWeb(plan);
}

/**
 * Restore previously-completed purchases. Web returns a no-op result; on iOS
 * this re-syncs the user's entitlements from Apple.
 */
export async function restorePurchases() {
  if (getPlatform() === 'ios') return restoreIOS();
  return { ok: false, reason: 'not-applicable' };
}

/**
 * Open the user's subscription management UI. On iOS this deep-links into the
 * App Store subscriptions page; on web it opens the Stripe Customer Portal.
 */
export async function openManageBilling() {
  if (getPlatform() === 'ios') {
    window.location.href = 'itms-apps://apps.apple.com/account/subscriptions';
    return { ok: true };
  }
  return openPortalWeb();
}

/**
 * Returns RevenueCat offerings on iOS, or null on web (web uses hardcoded
 * plan cards in the existing PremiumPaywall UI).
 */
export async function getOfferings() {
  if (getPlatform() === 'ios') return getOfferingsIOS();
  return null;
}

/** True when this device should use native StoreKit/RevenueCat. */
export function isNativeBillingPlatform() {
  return getPlatform() === 'ios';
}
