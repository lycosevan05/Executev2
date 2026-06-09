import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { appCache } from '@/lib/appCache';
import { backend, isSupabaseConfigured, supabase, supabaseConfigError } from '@/api/backendClient';
import { getPlatform } from '@/lib/platform';
import { bustSubscriptionCache } from '@/lib/subscription';

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

  const checkUserAuth = useCallback(async () => {
    try {
      setIsLoadingAuth(true);
      const currentUser = await backend.auth.me();
      setUser(currentUser);
      setIsAuthenticated(true);
      setAuthError(null);
    } catch (error) {
      setUser(null);
      setIsAuthenticated(false);
      setAuthError({
        type: 'auth_required',
        message: error.message || 'Authentication required',
      });
    } finally {
      setIsLoadingAuth(false);
      setAuthChecked(true);
    }
  }, []);

  const checkAppState = useCallback(async () => {
    setIsLoadingPublicSettings(true);
    setAuthError(null);

    if (!isSupabaseConfigured) {
      setUser(null);
      setIsAuthenticated(false);
      setAuthError({
        type: 'missing_config',
        message: supabaseConfigError || 'Supabase is not configured.',
      });
      setIsLoadingAuth(false);
      setIsLoadingPublicSettings(false);
      setAuthChecked(true);
      return;
    }

    try {
      setAppPublicSettings({
        id: 'execute',
        public_settings: { requiresAuth: true },
      });

      const { data, error } = await supabase.auth.getSession();
      if (error) throw error;
      if (data?.session) {
        await checkUserAuth();
      } else {
        setUser(null);
        setIsAuthenticated(false);
        setAuthError({
          type: 'auth_required',
          message: 'Authentication required',
        });
        setIsLoadingAuth(false);
        setAuthChecked(true);
      }
    } catch (error) {
      setUser(null);
      setIsAuthenticated(false);
      setAuthError({
        type: 'unknown',
        message: error.message || 'Failed to load authentication state',
      });
      setIsLoadingAuth(false);
      setAuthChecked(true);
    } finally {
      setIsLoadingPublicSettings(false);
    }
  }, [checkUserAuth]);

  useEffect(() => {
    checkAppState();
  }, [checkAppState]);

  useEffect(() => {
    if (!supabase) return undefined;

    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      if (session?.user) {
        checkUserAuth().catch(() => {});
      } else {
        setUser(null);
        setIsAuthenticated(false);
        setAuthError({
          type: 'auth_required',
          message: 'Authentication required',
        });
        setIsLoadingAuth(false);
        setAuthChecked(true);
      }
    });

    return () => data?.subscription?.unsubscribe();
  }, [checkUserAuth]);

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
                await supabase.auth.setSession({ access_token, refresh_token });
                await checkUserAuth();
                return;
              }
            }
            if (url.includes('code=')) {
              await supabase.auth.exchangeCodeForSession(url);
              await checkUserAuth();
            }
          } catch (err) {
            console.warn('[Auth] OAuth callback processing failed:', err);
          }
        });
        cleanup = () => handle.remove();
      } catch (err) {
        console.warn('[Auth] could not attach appUrlOpen listener:', err);
      }
    })();

    return () => { cancelled = true; cleanup?.(); };
  }, [checkUserAuth]);

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
          // logIn returns LogInResult { customerInfo, created } — seed the live signal.
          const res = await rc.loginRevenueCat(email);
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
    setUser(null);
    setIsAuthenticated(false);
    appCache.clear();
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
