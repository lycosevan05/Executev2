/**
 * PremiumPaywall — Full-screen or inline paywall shown to free users
 * when they attempt to access a Premium AI feature.
 */

import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Sparkles, X, Zap, Dumbbell, UtensilsCrossed, Camera, Activity, Check, RotateCcw } from 'lucide-react';
import { purchase as startPurchase, restorePurchases, getOfferings } from '@/lib/paymentClient';
import { getPlatform } from '@/lib/platform';
import { useSubscription } from '@/hooks/useSubscription';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const BENEFITS = [
  {
    icon: Dumbbell,
    title: 'Personalized training',
    desc: 'Training plans that adjust to your goals, progress, and recovery.',
  },
  {
    icon: UtensilsCrossed,
    title: 'Nutrition guidance',
    desc: 'Meal and macro guidance tailored to your body, goals, and schedule.',
  },
  {
    icon: Activity,
    title: 'Readiness insights',
    desc: 'Know when to push, recover, or adjust each day.',
  },
  {
    icon: Camera,
    title: 'Food photo tracking',
    desc: 'Estimate macros from a meal photo in seconds.',
  },
];

export default function PremiumPaywall({ onClose, context = '' }) {
  const [loading, setLoading] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [error, setError] = useState('');
  const [step, setStep] = useState('');
  const [plan, setPlan] = useState('annual');
  // Live StoreKit prices on iOS so the displayed price matches App Store Connect
  // and is localized to the user's storefront. Falls back to defaults on web or
  // if offerings can't be loaded.
  const [prices, setPrices] = useState({ annual: '$99.99', monthly: '$14.99' });
  const { refresh } = useSubscription();
  const navigate = useNavigate();
  const isIOS = getPlatform() === 'ios';

  useEffect(() => {
    if (!isIOS) return;
    let cancelled = false;
    getOfferings()
      .then((offerings) => {
        const pkgs = offerings?.current?.availablePackages || [];
        const annual = pkgs.find(p => p.packageType === 'ANNUAL')?.product?.priceString;
        const monthly = pkgs.find(p => p.packageType === 'MONTHLY')?.product?.priceString;
        if (cancelled) return;
        setPrices(prev => ({
          annual: annual || prev.annual,
          monthly: monthly || prev.monthly,
        }));
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [isIOS]);

  const goTo = (path) => { onClose?.(); navigate(path); };

  const handleUpgrade = async () => {
    setLoading(true);
    setError('');
    setStep('');
    try {
      const result = await startPurchase(plan, setStep);
      // Web path redirects to Stripe Checkout and never resolves here.
      // iOS path resolves inline after StoreKit completes — refresh entitlement and close.
      if (result?.ok) {
        await refresh?.(true);
        onClose?.();
      }
    } catch (err) {
      setError(err?.message || 'Could not start checkout. Please try again.');
    } finally {
      setLoading(false);
      setStep('');
    }
  };

  const handleRestore = async () => {
    setRestoring(true);
    setError('');
    try {
      await restorePurchases();
      await refresh?.(true);
      onClose?.();
    } catch (err) {
      setError(err?.message || 'Could not restore purchases.');
    } finally {
      setRestoring(false);
    }
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end justify-center"
      style={{ background: 'rgba(20,22,19,0.65)', backdropFilter: 'blur(8px)' }}
      onClick={e => { if (e.target === e.currentTarget) onClose?.(); }}
    >
      <motion.div
        initial={{ y: 80, opacity: 0 }}
        animate={{ y: 0, opacity: 1 }}
        exit={{ y: 80, opacity: 0 }}
        transition={{ type: 'spring', damping: 28, stiffness: 320 }}
        className="w-full max-w-lg rounded-t-3xl overflow-hidden overflow-y-auto"
        style={{ background: '#f6f2e8', maxHeight: '92vh' }}
      >
        {/* Header */}
        <div className="relative px-6 pt-8 pb-7"
          style={{ background: 'linear-gradient(145deg, #141613 0%, #1c2110 100%)' }}>
          {onClose && (
            <button onClick={onClose}
              className="absolute top-5 right-5 w-9 h-9 rounded-full flex items-center justify-center"
              style={{ background: 'rgba(255,255,255,0.1)' }}>
              <X size={15} style={{ color: '#91968e' }} />
            </button>
          )}

          {/* Price */}
          <div className="flex items-baseline gap-2 mb-1">
            <span className="text-4xl font-black" style={{ color: '#ffffff' }}>
              {plan === 'annual' ? prices.annual : prices.monthly}
            </span>
            <span className="text-base font-medium" style={{ color: '#91968e' }}>
              {plan === 'annual' ? '/ year' : '/ month'}
            </span>
          </div>
          <h2 className="text-xl font-black tracking-tight" style={{ color: '#ffffff', letterSpacing: '-0.02em' }}>
            Your adaptive performance plan
          </h2>
        </div>

        <div className="px-5 py-5 space-y-4">
          {/* Plan selector */}
          <div className="space-y-2.5">
            {/* Annual */}
            <button
              onClick={() => setPlan('annual')}
              className="w-full flex items-center justify-between px-4 py-4 rounded-2xl border-2 transition-all"
              style={{
                background: plan === 'annual' ? 'rgba(200,224,0,0.08)' : '#ffffff',
                borderColor: plan === 'annual' ? ACCENT_DARK : '#e8e1d4',
              }}
            >
              <div className="flex items-center gap-3">
                <div className="w-7 h-7 rounded-full flex items-center justify-center flex-shrink-0"
                  style={{ background: plan === 'annual' ? ACCENT : '#f2efe7', border: plan === 'annual' ? 'none' : '2px solid #d9d1c2' }}>
                  {plan === 'annual' && <Check size={14} style={{ color: '#141613' }} />}
                </div>
                <div className="text-left">
                  <p className="text-sm font-bold" style={{ color: '#141613' }}>Annual</p>
                  <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full"
                    style={{ background: ACCENT, color: '#141613' }}>Best value</span>
                </div>
              </div>
              <div className="text-right">
                <p className="text-sm font-bold" style={{ color: '#141613' }}>{prices.annual} <span className="font-normal text-xs" style={{ color: '#91968e' }}>/ year</span></p>
              </div>
            </button>

            {/* Monthly */}
            <button
              onClick={() => setPlan('monthly')}
              className="w-full flex items-center justify-between px-4 py-4 rounded-2xl border-2 transition-all"
              style={{
                background: plan === 'monthly' ? 'rgba(200,224,0,0.08)' : '#ffffff',
                borderColor: plan === 'monthly' ? ACCENT_DARK : '#e8e1d4',
              }}
            >
              <div className="flex items-center gap-3">
                <div className="w-7 h-7 rounded-full flex-shrink-0"
                  style={{
                    background: plan === 'monthly' ? ACCENT : 'transparent',
                    border: plan === 'monthly' ? 'none' : '2px solid #d9d1c2',
                    display: 'flex', alignItems: 'center', justifyContent: 'center'
                  }}>
                  {plan === 'monthly' && <Check size={14} style={{ color: '#141613' }} />}
                </div>
                <p className="text-sm font-bold" style={{ color: '#141613' }}>Monthly</p>
              </div>
              <div className="text-right">
                <p className="text-sm font-bold" style={{ color: '#141613' }}>{prices.monthly} <span className="font-normal text-xs" style={{ color: '#91968e' }}>/ month</span></p>
                <p className="text-xs" style={{ color: '#91968e' }}>Flexible access</p>
              </div>
            </button>
          </div>

          {/* Benefits */}
          <div className="space-y-3 pt-1">
            {BENEFITS.map((benefit, i) => (
              <motion.div
                key={i}
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: 0.04 + i * 0.05 }}
                className="flex items-start gap-3"
              >
                <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 mt-0.5"
                  style={{ background: 'rgba(200,224,0,0.12)' }}>
                  <benefit.icon size={15} style={{ color: ACCENT_DARK }} />
                </div>
                <div>
                  <p className="text-sm font-semibold" style={{ color: '#141613' }}>{benefit.title}</p>
                  <p className="text-xs leading-relaxed mt-0.5" style={{ color: '#5d635d' }}>{benefit.desc}</p>
                </div>
              </motion.div>
            ))}
          </div>

          {/* Error */}
          {error && (
            <div className="px-4 py-3 rounded-2xl text-xs border"
              style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
              {error}
            </div>
          )}

          {/* CTA */}
          <motion.button
            whileTap={{ scale: 0.97 }}
            onClick={handleUpgrade}
            disabled={loading}
            className="w-full py-4 rounded-2xl text-base font-black flex items-center justify-center gap-2"
            style={{
              background: loading ? 'rgba(200,224,0,0.5)' : ACCENT,
              color: '#141613',
              boxShadow: '0 4px 20px rgba(200,224,0,0.25)',
            }}
          >
            {loading ? (
              <><Zap size={16} className="animate-pulse" /> Starting checkout…</>
            ) : (
              <><Sparkles size={16} /> Start My Plan</>
            )}
          </motion.button>

          {loading && step && (
            <p className="text-[11px] text-center font-mono" style={{ color: '#91968e' }}>{step}</p>
          )}

          {isIOS && (
            <button onClick={handleRestore}
              disabled={restoring || loading}
              className="w-full py-2.5 text-xs font-semibold flex items-center justify-center gap-1.5"
              style={{ color: ACCENT_DARK }}>
              {restoring ? <Zap size={12} className="animate-pulse" /> : <RotateCcw size={12} />}
              {restoring ? 'Restoring…' : 'Restore Purchases'}
            </button>
          )}

          {onClose && (
            <button onClick={onClose}
              className="w-full py-2.5 text-sm font-medium text-center"
              style={{ color: '#91968e' }}>
              Not now
            </button>
          )}

          <p className="text-[11px] leading-relaxed text-center" style={{ color: '#b8b4ac' }}>
            Subscriptions auto-renew until canceled. Cancel anytime in your account settings. Payment is charged to your App Store account.
          </p>
          <div className="flex items-center justify-center gap-3 pb-2">
            <button onClick={() => goTo('/privacy')} className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Privacy Policy</button>
            <span className="text-[11px]" style={{ color: '#d9d1c2' }}>·</span>
            <button onClick={() => goTo('/terms')} className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Terms</button>
          </div>
        </div>
      </motion.div>
    </motion.div>
  );
}