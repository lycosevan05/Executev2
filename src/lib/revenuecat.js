/**
 * revenuecat.js
 *
 * iOS-only helpers around the RevenueCat Capacitor SDK.
 *
 * This module dynamically imports `@revenuecat/purchases-capacitor` so the
 * web bundle never pulls the native plugin. Only call into this module
 * when `getPlatform() === 'ios'` (see paymentClient.js).
 *
 * Env var required (set in .env / Vercel for native builds):
 *   VITE_REVENUECAT_IOS_KEY=appl_xxxxxxxxxxxx
 */

const REVENUECAT_IOS_KEY = import.meta.env.VITE_REVENUECAT_IOS_KEY || '';

let _initialized = false;
let _purchasesPromise = null;

async function loadPurchases() {
  if (!_purchasesPromise) {
    _purchasesPromise = import('@revenuecat/purchases-capacitor').then(m => m.Purchases);
  }
  return _purchasesPromise;
}

/**
 * Configure the RevenueCat SDK. Idempotent — safe to call repeatedly.
 * Pass the signed-in user's email as `appUserId` so RevenueCat webhooks
 * arrive at our backend keyed by the same identifier we use in Supabase.
 */
export async function initRevenueCat(appUserId, onStep = () => {}) {
  if (_initialized) return;
  if (!REVENUECAT_IOS_KEY) {
    console.warn('[RevenueCat] VITE_REVENUECAT_IOS_KEY not set; skipping init.');
    return;
  }
  onStep('rc: importing plugin…');
  const Purchases = await loadPurchases();
  onStep('rc: plugin imported, dispatching configure…');
  // The native `configure` method is registered with CAPPluginReturnNone, so
  // it sends no callback to JS — awaiting it never resolves under Capacitor 8
  // (the promise hangs forever). Native configuration is synchronous, so we
  // fire it without awaiting and immediately treat the SDK as configured.
  Purchases.configure({
    apiKey: REVENUECAT_IOS_KEY,
    appUserID: appUserId || undefined,
  });
  onStep('rc: configure dispatched');
  _initialized = true;
}

export async function loginRevenueCat(appUserId) {
  if (!appUserId) return null;
  const Purchases = await loadPurchases();
  if (!_initialized) await initRevenueCat(appUserId);
  return Purchases.logIn({ appUserID: appUserId });
}

export async function logoutRevenueCat() {
  if (!_initialized) return null;
  const Purchases = await loadPurchases();
  return Purchases.logOut();
}

export async function getOfferingsRevenueCat() {
  const Purchases = await loadPurchases();
  return Purchases.getOfferings();
}

export async function purchasePackageRevenueCat(aPackage) {
  const Purchases = await loadPurchases();
  return Purchases.purchasePackage({ aPackage });
}

export async function restorePurchasesRevenueCat() {
  const Purchases = await loadPurchases();
  return Purchases.restorePurchases();
}

/**
 * Subscribe to entitlement updates. Returned listener id can be passed to
 * removeCustomerInfoListener() for cleanup.
 */
export async function addCustomerInfoListener(callback) {
  const Purchases = await loadPurchases();
  return Purchases.addCustomerInfoUpdateListener(callback);
}

export async function getCustomerInfo() {
  const Purchases = await loadPurchases();
  return Purchases.getCustomerInfo();
}
