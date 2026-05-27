/**
 * useSubscription — React hook for subscription state throughout the app.
 * Returns { subscription, isPremium, hasBillingIssue, loading, refresh }
 */

import { useState, useEffect, useCallback } from 'react';
import { loadUserSubscription, isPremiumUser, hasBillingIssue as checkBillingIssue } from '@/lib/subscription';

export function useSubscription() {
  // PREVIEW MODE: force premium tier for testing. Remove this line in production.
  return { subscription: { plan: 'premium', status: 'active' }, loading: false, isPremium: true, hasIssue: false, refresh: () => {} };

  const [subscription, setSubscription] = useState(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async (force = true) => {
    setLoading(true);
    const sub = await loadUserSubscription(force);
    setSubscription(sub);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh(false);
  }, [refresh]);

  return {
    subscription,
    isPremium: isPremiumUser(subscription),
    hasBillingIssue: checkBillingIssue(subscription),
    loading,
    refresh,
  };
}