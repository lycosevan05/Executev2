/**
 * Billing — Execute Premium subscription management page.
 *
 * Shows:
 * - Current plan and status
 * - Upgrade CTA for free users
 * - Manage billing button for Premium users
 * - Renewal date and billing issue warnings
 */

import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Sparkles, CheckCircle2, AlertTriangle, ChevronLeft, Loader2,
  Crown, CreditCard, Calendar, RotateCcw,
  Dumbbell, UtensilsCrossed, Camera, Activity, Brain, Target,
} from 'lucide-react';
import { useSubscription } from '@/hooks/useSubscription';
import { bustSubscriptionCache } from '@/lib/subscription';
import { purchase as startPurchase, openManageBilling, restorePurchases } from '@/lib/paymentClient';
import { getPlatform } from '@/lib/platform';
import PremiumPaywall from '@/components/premium/PremiumPaywall';
import { loadStripe } from '@stripe/stripe-js';
import { Elements } from '@stripe/react-stripe-js';
import ApplePayButton from '@/components/billing/ApplePayButton';

const stripePromise = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY
  ? loadStripe(import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY)
  : null;

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const BENEFITS = [
  { icon: Dumbbell, text: 'AI workout plans that adapt to your goals and recovery' },
  { icon: UtensilsCrossed, text: 'AI meal plans and personalized nutrition guidance' },
  { icon: Camera, text: 'Food photo macro estimates powered by AI' },
  { icon: Activity, text: 'Readiness-based daily guidance' },
  { icon: Brain, text: 'Adaptive wellness and performance plans' },
  { icon: Target, text: 'Personalized health and performance insights' },
  { icon: Sparkles, text: 'Full access to all advanced AI features' },
];

function StatusBadge({ status }) {
  const map = {
    active:   { label: 'Active',     bg: 'rgba(200,224,0,0.12)', color: '#8ea400', border: 'rgba(200,224,0,0.3)' },
    trialing: { label: 'Trial',      bg: 'rgba(93,138,93,0.1)',  color: '#5d8a5d', border: 'rgba(93,138,93,0.3)' },
    past_due: { label: 'Past Due',   bg: 'rgba(176,90,58,0.1)',  color: '#b05a3a', border: 'rgba(176,90,58,0.3)' },
    canceled: { label: 'Canceled',   bg: 'rgba(145,150,142,0.1)',color: '#91968e', border: '#e8e1d4' },
    unpaid:   { label: 'Unpaid',     bg: 'rgba(176,90,58,0.1)',  color: '#b05a3a', border: 'rgba(176,90,58,0.3)' },
    inactive: { label: 'Free Plan',  bg: '#f2efe7',              color: '#91968e', border: '#e8e1d4' },
  };
  const s = map[status] || map.inactive;
  return (
    <span className="px-3 py-1 rounded-full text-xs font-bold border"
      style={{ background: s.bg, color: s.color, borderColor: s.border }}>
      {s.label}
    </span>
  );
}

export default function Billing() {
  const navigate = useNavigate();
  const { subscription, isPremium, hasBillingIssue, loading, refresh } = useSubscription();
  const [checkoutLoading, setCheckoutLoading] = useState(false);
  const [portalLoading, setPortalLoading] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [checkoutError, setCheckoutError] = useState('');
  const [showPaywall, setShowPaywall] = useState(false);
  const isIOS = getPlatform() === 'ios';

  // Handle return from Stripe Checkout
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get('success') === 'true') {
      bustSubscriptionCache();
      // Refresh after a short delay to allow webhook to process
      setTimeout(() => refresh(true), 2000);
    }
  }, []);

  const handleUpgrade = async () => {
    setCheckoutLoading(true);
    setCheckoutError('');
    try {
      // Web redirects to Stripe Checkout (never returns); iOS resolves inline.
      const result = await startPurchase('monthly');
      if (result?.ok && !result.redirected) {
        await refresh(true);
      }
    } catch (err) {
      setCheckoutError(err?.message || 'Could not start checkout. Please try again.');
    } finally {
      setCheckoutLoading(false);
    }
  };

  const handleManageBilling = async () => {
    setPortalLoading(true);
    try {
      await openManageBilling();
    } catch {
      // silently fail
    } finally {
      setPortalLoading(false);
    }
  };

  const handleRestore = async () => {
    setRestoring(true);
    setCheckoutError('');
    try {
      await restorePurchases();
      await refresh(true);
    } catch (err) {
      setCheckoutError(err?.message || 'Could not restore purchases.');
    } finally {
      setRestoring(false);
    }
  };

  const renewalDate = subscription?.current_period_end
    ? new Date(subscription.current_period_end).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })
    : null;

  const params = new URLSearchParams(window.location.search);
  const justUpgraded = params.get('success') === 'true';

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pb-4"
        style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center gap-3">
          <button onClick={() => navigate('/profile')}
            className="w-8 h-8 rounded-xl flex items-center justify-center border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ChevronLeft size={14} style={{ color: '#5d635d' }} />
          </button>
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Premium & Billing</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>Execute Premium · $14.99/month</p>
          </div>
        </div>
      </div>

      <div className="px-5 pb-32 pt-5 space-y-4">

        {loading ? (
          <div className="flex flex-col items-center py-20 gap-3">
            <Loader2 size={22} className="animate-spin" style={{ color: ACCENT_DARK }} />
            <p className="text-sm" style={{ color: '#91968e' }}>Loading subscription…</p>
          </div>
        ) : (
          <>
            {/* Success banner */}
            {justUpgraded && (
              <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}
                className="flex items-center gap-3 px-4 py-3.5 rounded-2xl border"
                style={{ background: 'rgba(200,224,0,0.1)', borderColor: 'rgba(200,224,0,0.35)' }}>
                <CheckCircle2 size={18} style={{ color: ACCENT_DARK }} />
                <div>
                  <p className="text-sm font-bold" style={{ color: '#141613' }}>Welcome to Premium!</p>
                  <p className="text-xs" style={{ color: '#5d635d' }}>Your subscription is being activated. All AI features are now unlocked.</p>
                </div>
              </motion.div>
            )}

            {/* Billing issue warning */}
            {hasBillingIssue && (
              <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
                className="flex items-start gap-3 px-4 py-3.5 rounded-2xl border"
                style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.3)' }}>
                <AlertTriangle size={16} style={{ color: '#b05a3a', flexShrink: 0, marginTop: 2 }} />
                <div>
                  <p className="text-sm font-bold" style={{ color: '#b05a3a' }}>Billing issue</p>
                  <p className="text-xs leading-relaxed" style={{ color: '#b05a3a' }}>
                    Your payment failed. Update your payment method to keep Premium access.
                  </p>
                  <button onClick={handleManageBilling}
                    className="mt-2 text-xs font-bold underline" style={{ color: '#b05a3a' }}>
                    Update payment method
                  </button>
                </div>
              </motion.div>
            )}

            {/* Current plan card */}
            <div className="rounded-3xl overflow-hidden border" style={{ borderColor: '#e8e1d4' }}>
              <div className="px-5 py-5"
                style={{ background: isPremium ? 'linear-gradient(145deg, #141613 0%, #1c2110 100%)' : '#ffffff' }}>
                <div className="flex items-start justify-between mb-4">
                  <div>
                    <p className="text-[10px] font-bold uppercase tracking-widest mb-1"
                      style={{ color: isPremium ? '#4a4f4a' : '#91968e' }}>
                      Current Plan
                    </p>
                    <h2 className="text-xl font-black tracking-tight"
                      style={{ color: isPremium ? '#ffffff' : '#141613', letterSpacing: '-0.03em' }}>
                      {isPremium ? 'Execute Premium' : 'Free Plan'}
                    </h2>
                  </div>
                  {isPremium ? (
                    <div className="w-10 h-10 rounded-2xl flex items-center justify-center"
                      style={{ background: ACCENT }}>
                      <Crown size={18} style={{ color: '#141613' }} />
                    </div>
                  ) : (
                    <StatusBadge status={subscription?.status || 'inactive'} />
                  )}
                </div>

                {isPremium && (
                  <div className="space-y-2">
                    <div className="flex items-center justify-between">
                      <StatusBadge status={subscription?.status || 'active'} />
                      {subscription?.cancel_at_period_end && (
                        <span className="text-xs px-2 py-0.5 rounded-full"
                          style={{ background: 'rgba(176,90,58,0.15)', color: '#b05a3a' }}>
                          Cancels at period end
                        </span>
                      )}
                    </div>
                    {renewalDate && (
                      <div className="flex items-center gap-2">
                        <Calendar size={13} style={{ color: '#4a4f4a' }} />
                        <p className="text-xs" style={{ color: '#4a4f4a' }}>
                          {subscription?.cancel_at_period_end ? 'Access until' : 'Renews'} {renewalDate}
                        </p>
                      </div>
                    )}
                    <div className="flex items-center gap-2">
                      <CreditCard size={13} style={{ color: '#4a4f4a' }} />
                      <p className="text-xs" style={{ color: '#4a4f4a' }}>$14.99/month</p>
                    </div>
                  </div>
                )}

                {!isPremium && (
                  <p className="text-xs leading-relaxed" style={{ color: '#91968e' }}>
                    Manual tracking features are free forever. Upgrade for AI-powered plans, guidance, and insights.
                  </p>
                )}
              </div>

              <div className="px-5 py-4" style={{ background: isPremium ? 'rgba(20,22,19,0.97)' : '#f9f7f3', borderTop: '1px solid rgba(255,255,255,0.05)' }}>
                {isPremium ? (
                  <button
                    onClick={handleManageBilling}
                    disabled={portalLoading}
                    className="w-full py-3.5 rounded-2xl text-sm font-semibold flex items-center justify-center gap-2 border"
                    style={{ background: 'rgba(255,255,255,0.06)', borderColor: 'rgba(255,255,255,0.1)', color: '#c8cac8' }}>
                    {portalLoading ? <Loader2 size={14} className="animate-spin" /> : <CreditCard size={14} />}
                    Manage Billing
                  </button>
                ) : (
                  <>
                    {checkoutError && (
                      <p className="text-xs mb-3 px-3 py-2 rounded-xl border"
                        style={{ color: '#b05a3a', background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.2)' }}>
                        {checkoutError}
                      </p>
                    )}
                    {isIOS ? (
                      <>
                        <button
                          onClick={handleUpgrade}
                          disabled={checkoutLoading}
                          className="w-full py-3.5 rounded-2xl text-sm font-black flex items-center justify-center gap-2"
                          style={{ background: checkoutLoading ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613' }}>
                          {checkoutLoading ? <Loader2 size={14} className="animate-spin" /> : <Sparkles size={14} />}
                          {checkoutLoading ? 'Starting…' : 'Upgrade to Premium — $14.99/month'}
                        </button>
                        <button
                          onClick={handleRestore}
                          disabled={restoring || checkoutLoading}
                          className="w-full py-2.5 mt-1 text-xs font-semibold flex items-center justify-center gap-1.5"
                          style={{ color: ACCENT_DARK }}>
                          {restoring ? <Loader2 size={12} className="animate-spin" /> : <RotateCcw size={12} />}
                          {restoring ? 'Restoring…' : 'Restore Purchases'}
                        </button>
                      </>
                    ) : (
                      <Elements stripe={stripePromise}>
                        <ApplePayButton
                          priceAmountCents={1499}
                          onFallback={handleUpgrade}
                          disabled={checkoutLoading}
                        />
                      </Elements>
                    )}
                    <p className="text-[10px] leading-relaxed text-center mt-2" style={{ color: '#b8b4ac' }}>
                      Subscriptions auto-renew until canceled. Cancel anytime in your account settings. Payment is charged to your App Store account.
                    </p>
                    <div className="flex items-center justify-center gap-3 mt-2">
                      <button onClick={() => navigate('/privacy')} className="text-[10px] font-medium underline" style={{ color: '#91968e' }}>Privacy Policy</button>
                      <span className="text-[10px]" style={{ color: '#d9d1c2' }}>·</span>
                      <button onClick={() => navigate('/terms')} className="text-[10px] font-medium underline" style={{ color: '#91968e' }}>Terms</button>
                    </div>
                  </>
                )}
              </div>
            </div>

            {/* What's included */}
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-3 px-1" style={{ color: '#91968e' }}>
                What's included in Premium
              </p>
              <div className="rounded-3xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                {BENEFITS.map((benefit, i) => (
                  <div key={i}>
                    <div className="flex items-center gap-3 px-5 py-4">
                      <div className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
                        style={{ background: 'rgba(200,224,0,0.1)' }}>
                        <benefit.icon size={14} style={{ color: ACCENT_DARK }} />
                      </div>
                      <p className="text-sm leading-snug" style={{ color: '#2d2f2c' }}>{benefit.text}</p>
                      {isPremium && <CheckCircle2 size={14} style={{ color: ACCENT_DARK, flexShrink: 0, marginLeft: 'auto' }} />}
                    </div>
                    {i < BENEFITS.length - 1 && <div className="mx-5 h-px" style={{ background: '#f2efe7' }} />}
                  </div>
                ))}
              </div>
            </div>

            {/* Free plan features */}
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-3 px-1" style={{ color: '#91968e' }}>
                Always free
              </p>
              <div className="rounded-3xl border p-5" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                <div className="flex flex-wrap gap-2">
                  {[
                    'Manual workout logging', 'Manual food logging', 'Goal creation',
                    'Profile & preferences', 'Workout history', 'Nutrition history',
                    'Recovery check-ins', 'Home dashboard',
                  ].map(f => (
                    <span key={f} className="px-3 py-1.5 rounded-xl text-xs border"
                      style={{ background: '#f2efe7', color: '#5d635d', borderColor: '#e8e1d4' }}>
                      {f}
                    </span>
                  ))}
                </div>
              </div>
            </div>

            {/* Developer note — web only (Stripe config) */}
            {!isIOS && (
              <div className="rounded-2xl border p-4"
                style={{ background: 'rgba(176,90,58,0.04)', borderColor: 'rgba(176,90,58,0.15)' }}>
                <p className="text-[10px] font-bold uppercase tracking-widest mb-1.5" style={{ color: '#b05a3a' }}>
                  Developer Note
                </p>
                <p className="text-xs leading-relaxed" style={{ color: '#91968e' }}>
                  To activate Stripe payments, add these to Supabase Dashboard → Settings → Environment Variables:
                  <br /><code className="font-mono">STRIPE_SECRET_KEY</code> · <code className="font-mono">STRIPE_PREMIUM_PRICE_ID</code> · <code className="font-mono">STRIPE_WEBHOOK_SECRET</code> · <code className="font-mono">APP_BASE_URL</code>
                  <br />Also set <code className="font-mono">VITE_STRIPE_PUBLISHABLE_KEY</code> for the frontend.
                  <br />Register the <code className="font-mono">stripeWebhook</code> function URL as a webhook in Stripe Dashboard.
                </p>
              </div>
            )}

          </>
        )}
      </div>

      <AnimatePresence>
        {showPaywall && <PremiumPaywall onClose={() => setShowPaywall(false)} />}
      </AnimatePresence>
    </div>
  );
}