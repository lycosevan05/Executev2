import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { appCache } from '@/lib/appCache';
import { backend, isSupabaseConfigured, normalizeUser, supabase, supabaseConfigError } from '@/api/backendClient';
import { getPlatform } from '@/lib/platform';
import { bustSubscriptionCache } from '@/lib/subscription';
import { resetPersonalizationCaches } from '@/lib/personalizationSync';

const AuthContext = createContext();

export const AuthProvider = ({ children }) => {
  const [user, setUser] = useState(null);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  // Live, read-only RevenueCat customerInfo for instant-unlock gating.
  // NEVER persisted by the client; the webhook remains the sole writer of the
  // user_subscription table. This only mirrors the SDK's current entitlements.
  const [rcCustomerInfo, setRcCustomerInfo] = useState(null);
  const [isLoadingAuth, setIsLoadingAuth] = useState(true);
  const [isLoadingPublicSettings, setIsLoadingPublicSettings] = useState(true);
  const [authChecked, setAuthChecked] = useState(false);
  const [authError, setAuthError] = useState(null);
  const [appPublicSettings, setAppPublicSettings] = useState({
    id: 'execute',
    public_settings: { requiresAuth: true },
  });

  const authRevision = useRef(0);

  const applySessionUser = useCallback((currentUser, error = null) => {
    setUser(currentUser);
    setIsAuthenticated(Boolean(currentUser));
    setAuthError(currentUser ? null : error || {
      type: 'auth_required',
      message: 'Authentication required',
    });
    if (currentUser?.id) appCache.activateUser(currentUser.id);
    setIsLoadingAuth(false);
    setAuthChecked(true);
  }, []);

  const checkUserAuth = useCallback(async () => {
    const revision = ++authRevision.current;
    setIsLoadingAuth(true);
    try {
      const currentUser = await backend.auth.me();
      if (revision === authRevision.current) applySessionUser(currentUser);
    } catch (error) {
      if (revision === authRevision.current) {
        applySessionUser(null, {
          type: 'auth_required',
          message: error.message || 'Authentication required',
        });
      }
    }
  }, [applySessionUser]);

  const checkAppState = useCallback(async () => {
    const revision = ++authRevision.current;
    setIsLoadingPublicSettings(true);
    setAuthError(null);

    if (!isSupabaseConfigured) {
      applySessionUser(null, {
        type: 'missing_config',
        message: supabaseConfigError || 'Supabase is not configured.',
      });
      setIsLoadingPublicSettings(false);
      return;
    }

    try {
      setAppPublicSettings({
        id: 'execute',
        public_settings: { requiresAuth: true },
      });

      const { data, error } = await supabase.auth.getSession();
      if (revision !== authRevision.current) return;
      if (error) throw error;
      applySessionUser(normalizeUser(data?.session?.user));
    } catch (error) {
      if (revision === authRevision.current) {
        applySessionUser(null, {
          type: 'unknown',
          message: error.message || 'Failed to load authentication state',
        });
      }
    } finally {
      setIsLoadingPublicSettings(false);
    }
  }, [applySessionUser]);

  useEffect(() => {
    checkAppState();
  }, [checkAppState]);

  useEffect(() => {
    if (!supabase) return undefined;

    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      ++authRevision.current;
      if (!session?.user) {
        appCache.deactivate();
        resetPersonalizationCaches();
        bustSubscriptionCache();
      }
      // Supabase delivers the session while holding its auth lock. Use that
      // snapshot directly so the listener never queues another Supabase call.
      applySessionUser(normalizeUser(session?.user));
      setIsLoadingPublicSettings(false);
    });

    return () => {
      ++authRevision.current;
      data?.subscription?.unsubscribe();
    };
  }, [applySessionUser]);

  // ─── iOS OAuth deep-link bridge ────────────────────────────────────────────
  // When the user finishes Google/Apple sign-in inside the in-app Capacitor
  // Browser, Supabase redirects to com.executelabs.execute://login-callback?...
  // iOS hands that URL to the app via the `appUrlOpen` event. We close the
  // browser and ask Supabase to exchange the auth code for a session.
  useEffect(() => {
    if (getPlatform() !== 'ios') return undefined;

    let cleanup = null;
    let cancelled = false;

    (async () => {
      try {
        const { App } = await import('@capacitor/app');
        if (cancelled) return;
        const handle = await App.addListener('appUrlOpen', async ({ url }) => {
          if (!url || !url.startsWith('com.executelabs.execute://login-callback')) return;
          try {
            const { Browser } = await import('@capacitor/browser');
            await Browser.close();
          } catch { /* browser may already be closed */ }
          try {
            if (!supabase) return;
            // Supabase returns auth payload either as a URL fragment
            // (#access_token=...&refresh_token=... — "implicit" flow) or as a
            // query (?code=... — PKCE). Handle both.
            const hashIdx = url.indexOf('#');
            if (hashIdx !== -1 && url.includes('access_token=')) {
              const params = new URLSearchParams(url.slice(hashIdx + 1));
              const access_token = params.get('access_token');
              const refresh_token = params.get('refresh_token');
              if (access_token && refresh_token) {
                const { error } = await supabase.auth.setSession({ access_token, refresh_token });
                if (error) throw error;
                return;
              }
            }
            if (url.includes('code=')) {
              // exchangeCodeForSession expects the auth-code value, NOT the
              // full deep-link URL. Passing the URL makes the token exchange
              // fail, leaving the app stuck on the login screen.
              const code = new URL(url).searchParams.get('code');
              if (code) {
                const { error } = await supabase.auth.exchangeCodeForSession(code);
                if (error) throw error;
              }
            }
          } catch (err) {
            // Surface the failure: a swallowed error here looks like an
            // endless authenticate→login loop with no clue why.
            console.error('[Auth] OAuth callback processing failed:', err);
            setAuthError({
              type: 'auth_required',
              message: err?.message || 'Sign-in could not be completed.',
            });
          }
        });
        cleanup = () => handle.remove();
      } catch (err) {
        console.warn('[Auth] could not attach appUrlOpen listener:', err);
      }
    })();

    return () => { cancelled = true; cleanup?.(); };
  }, []);

  // ─── RevenueCat (iOS native IAP) ───────────────────────────────────────────
  // Identify the signed-in user with RevenueCat so entitlements (and webhooks)
  // are keyed by the same email we use in Supabase. Web/Android builds skip
  // this entirely — the dynamic import is never resolved off-iOS.
  useEffect(() => {
    if (getPlatform() !== 'ios') return undefined;

    let cancelled = false;
    const email = user?.email;

    (async () => {
      try {
        const rc = await import('@/lib/revenuecat');
        if (cancelled) return;
        if (email) {
          // logIn returns LogInResult { customerInfo, created } — seed the live
          // signal. Retry once on failure: a transient network blip here would
          // otherwise leave rcCustomerInfo null and gate a paying user out.
          let res;
          try {
            res = await rc.loginRevenueCat(email);
          } catch {
            res = await rc.loginRevenueCat(email);
          }
          if (!cancelled) setRcCustomerInfo(res?.customerInfo ?? null);
        } else {
          // Signed out — drop the RC identity so the next sign-in re-attaches.
          await rc.logoutRevenueCat();
          if (!cancelled) setRcCustomerInfo(null);
        }
      } catch (err) {
        console.warn('[RevenueCat] login/logout failed:', err);
      }
    })();

    return () => { cancelled = true; };
  }, [user?.email]);

  // Listen for out-of-band entitlement updates (renewal, cancellation, refund
  // happening in iOS Settings while app is open). Busting the cache means the
  // next useSubscription render fetches fresh data. The dispatched window
  // event will be picked up by useSubscription once preview mode is removed.
  useEffect(() => {
    if (getPlatform() !== 'ios') return undefined;

    let listenerHandle = null;
    let cancelled = false;

    (async () => {
      try {
        const rc = await import('@/lib/revenuecat');
        if (cancelled) return;
        listenerHandle = await rc.addCustomerInfoListener((info) => {
          // Retain the pushed customerInfo as the freshest live unlock signal.
          setRcCustomerInfo(info?.customerInfo ?? info ?? null);
          bustSubscriptionCache();
          window.dispatchEvent(new CustomEvent('execute:subscription-changed'));
        });
      } catch (err) {
        console.warn('[RevenueCat] could not attach customerInfo listener:', err);
      }
    })();

    return () => { cancelled = true; /* RC listener is process-lifetime; no remove API on the Capacitor plugin */ };
  }, []);

  // Self-heal the live entitlement signal from the SDK's own persisted state:
  // getCustomerInfo() reflects renewals/refunds that happened while the app was
  // backgrounded or across launches (the in-process listener only fires for
  // changes while the app is running). Runs once at launch and on every resume.
  // getCustomerInfo internally awaits ensureConfigured, so it's safe to call
  // before Purchases.configure has resolved. Passive — never toasts.
  useEffect(() => {
    if (getPlatform() !== 'ios') return undefined;

    let cancelled = false;
    let resumeHandle = null;

    const refreshCustomerInfo = async () => {
      try {
        const rc = await import('@/lib/revenuecat');
        const info = await rc.getCustomerInfo();
        if (!cancelled) setRcCustomerInfo(info?.customerInfo ?? info ?? null);
      } catch {
        // Offline / not-yet-configured — leave the existing signal untouched.
      }
    };

    (async () => {
      await refreshCustomerInfo();
      try {
        const { App } = await import('@capacitor/app');
        if (cancelled) return;
        resumeHandle = await App.addListener('resume', () => { refreshCustomerInfo(); });
      } catch (err) {
        console.warn('[RevenueCat] could not attach resume listener:', err);
      }
    })();

    return () => { cancelled = true; resumeHandle?.remove?.(); };
  }, []);

  const loginWithOtp = useCallback(async (email) => {
    await backend.auth.loginWithOtp(email);
  }, []);

  const verifyOtp = useCallback(async (email, token) => {
    await backend.auth.verifyOtp(email, token);
    // The onAuthStateChange listener picks up the new session and refreshes
    // user state; nothing else to do here.
  }, []);

  const loginWithOAuth = useCallback(async (provider) => {
    await backend.auth.loginWithOAuth(provider);
  }, []);

  const logout = useCallback(async () => {
    ++authRevision.current;
    setUser(null);
    setIsAuthenticated(false);
    appCache.clear();
    // clear() empties the durable store but not the module-level caches; tear
    // those down too and drop the active uid so the next sign-in re-activates.
    appCache.deactivate();
    resetPersonalizationCaches();
    // Drop the 60s-TTL subscription cache so a same-device account switch
    // can't inherit the previous user's premium status.
    bustSubscriptionCache();
    await backend.auth.logout();
    setAuthError({
      type: 'auth_required',
      message: 'Authentication required',
    });
  }, []);

  const navigateToLogin = useCallback(() => {
    setAuthError({
      type: 'auth_required',
      message: 'Authentication required',
    });
  }, []);

  return (
    <AuthContext.Provider value={{
      user,
      isAuthenticated,
      rcCustomerInfo,
      isLoadingAuth,
      isLoadingPublicSettings,
      authChecked,
      authError,
      appPublicSettings,
      loginWithOtp,
      verifyOtp,
      loginWithOAuth,
      logout,
      navigateToLogin,
      checkAppState,
      checkUserAuth,
    }}>
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};
