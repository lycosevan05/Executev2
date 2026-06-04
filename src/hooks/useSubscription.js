/**
 * useSubscription — React hook for subscription state throughout the app.
 * Returns { subscription, isPremium, hasBillingIssue, loading, refresh }
 */

import { useState, useEffect, useCallback } from 'react';
import { loadUserSubscription, isPremiumUser, hasBillingIssue as checkBillingIssue } from '@/lib/subscription';
import { useAuth } from '@/lib/AuthContext';

export function useSubscription() {
  const { rcCustomerInfo } = useAuth();
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

  // AuthContext dispatches this on every RevenueCat customerInfo update
  // (renewal, cancel, refund, or the webhook landing). Re-read the table.
  useEffect(() => {
    const onChange = () => refresh(true);
    window.addEventListener('execute:subscription-changed', onChange);
    return () => window.removeEventListener('execute:subscription-changed', onChange);
  }, [refresh]);

  // Live, read-only unlock signal: any non-empty active entitlement set.
  // Count-based on purpose — we don't key on an entitlement identifier so the
  // gate is immune to the actual id string ("Execute Performance Premium").
  const liveEntitled = Object.keys(rcCustomerInfo?.entitlements?.active ?? {}).length > 0;

  return {
    subscription,
    // Unlock if the webhook-written table says premium OR the live RC
    // entitlements show active. The device never writes the table.
    isPremium: isPremiumUser(subscription) || liveEntitled,
    hasBillingIssue: checkBillingIssue(subscription),
    loading,
    refresh,
  };
}