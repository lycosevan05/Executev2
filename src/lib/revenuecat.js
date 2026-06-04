/**
 * revenuecat.js
 *
 * iOS-only helpers around the RevenueCat Capacitor SDK.
 *
 * This module dynamically imports `@revenuecat/purchases-capacitor` so the
 * web bundle never pulls the native plugin. Only call into this module
 * when `getPlatform() === 'ios'` (see paymentClient.js).
 *
 * The SDK is configured THROUGH the Capacitor plugin here (ensureConfigured),
 * not natively in AppDelegate. A native `Purchases.configure` in AppDelegate
 * configures the app target's own RevenueCat instance, which is NOT the same
 * instance the plugin's PurchasesHybridCommon checks — so the plugin would
 * fatalError with "Purchases has not been configured" on the first logIn.
 */

let _modulePromise = null;
let _configurePromise = null;

// Resolve to the ES module *namespace*, never to the Capacitor `Purchases`
// proxy. The proxy from registerPlugin() returns a native-method wrapper for
// ANY property access — including `then` — so if a Promise (or an async
// function's return) ever resolves *to* the proxy, the Promise machinery's
// thenable check calls `proxy.then(resolve, reject)`, which dispatches a
// phantom native bridge call that never calls back and deadlocks the await.
// The module namespace has no `then`, so awaiting it is safe; callers then read
// `.Purchases` synchronously and only await its methods (which return plain
// objects).
function loadModule() {
  if (!_modulePromise) _modulePromise = import('@revenuecat/purchases-capacitor');
  return _modulePromise;
}

// Configure the plugin's RevenueCat instance exactly once. EVERY native call
// (logIn, getOfferings, purchasePackage, listeners) requires this first, or the
// plugin fatalErrors with "Purchases has not been configured". Guarded by a
// shared promise so concurrent callers configure only once.
function ensureConfigured() {
  if (!_configurePromise) {
    _configurePromise = (async () => {
      const { Purchases } = await loadModule();
      const apiKey = import.meta.env.VITE_REVENUECAT_IOS_KEY;
      if (!apiKey) throw new Error('VITE_REVENUECAT_IOS_KEY is empty — cannot configure RevenueCat.');
      await Purchases.configure({ apiKey });
    })();
  }
  return _configurePromise;
}

/**
 * Configure the RevenueCat SDK. Idempotent — safe to call repeatedly.
 */
export async function initRevenueCat(appUserId, onStep = () => {}) {
  onStep('rc: configuring plugin…');
  await ensureConfigured();
  onStep('rc: ready (configured)');
}

export async function loginRevenueCat(appUserId) {
  if (!appUserId) return null;
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.logIn({ appUserID: appUserId });
}

export async function logoutRevenueCat() {
  // Nothing to log out of if we never configured (e.g. startup while signed out).
  if (!_configurePromise) return null;
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.logOut();
}

export async function getOfferingsRevenueCat() {
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.getOfferings();
}

export async function purchasePackageRevenueCat(aPackage) {
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.purchasePackage({ aPackage });
}

export async function restorePurchasesRevenueCat() {
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.restorePurchases();
}

/**
 * Subscribe to entitlement updates. Returned listener id can be passed to
 * removeCustomerInfoListener() for cleanup.
 */
export async function addCustomerInfoListener(callback) {
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.addCustomerInfoUpdateListener(callback);
}

export async function getCustomerInfo() {
  await ensureConfigured();
  const { Purchases } = await loadModule();
  return Purchases.getCustomerInfo();
}
