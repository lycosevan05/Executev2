import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { appCache } from '@/lib/appCache';
import { backend, isSupabaseConfigured, supabase, supabaseConfigError } from '@/api/backendClient';

const AuthContext = createContext();

export const AuthProvider = ({ children }) => {
  const [user, setUser] = useState(null);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
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

  const loginWithOtp = useCallback(async (email) => {
    await backend.auth.loginWithOtp(email);
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
      isLoadingAuth,
      isLoadingPublicSettings,
      authChecked,
      authError,
      appPublicSettings,
      loginWithOtp,
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
