/**
 * useSubscription — React hook for subscription state throughout the app.
 * Returns { subscription, isPremium, hasBillingIssue, loading, refresh }
 */

import { useState, useEffect, useCallback } from 'react';
import { loadUserSubscription, isPremiumUser, hasBillingIssue as checkBillingIssue } from '@/lib/subscription';

export function useSubscription() {
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