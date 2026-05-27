/**
 * PremiumGate — Wraps any AI/premium feature.
 *
 * If the user is Premium → renders children normally.
 * If free → shows a locked card with an upgrade prompt.
 *
 * Usage:
 *   <PremiumGate feature="AI workout generation">
 *     <BuildWorkoutCard ... />
 *   </PremiumGate>
 */

import { useState } from 'react';
import { AnimatePresence } from 'framer-motion';
import { Lock, Sparkles } from 'lucide-react';
import { useSubscription } from '@/hooks/useSubscription';
import PremiumPaywall from './PremiumPaywall';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

export default function PremiumGate({ children, feature = 'this AI feature', showPreview = false }) {
  const { isPremium, loading } = useSubscription();
  const [showPaywall, setShowPaywall] = useState(false);

  // While loading, render nothing (avoids flash)
  if (loading) return null;

  // Premium user — render normally
  if (isPremium) return <>{children}</>;

  return (
    <>
      <div className="relative">
        {/* Preview of the feature behind a blur */}
        {showPreview && (
          <div className="pointer-events-none select-none" style={{ filter: 'blur(4px)', opacity: 0.4 }}>
            {children}
          </div>
        )}

        {/* Locked overlay card */}
        <div
          className={`${showPreview ? 'absolute inset-0' : ''} flex flex-col items-center justify-center rounded-3xl border p-6 text-center`}
          style={{ background: showPreview ? 'rgba(246,242,232,0.88)' : '#ffffff', borderColor: 'rgba(200,224,0,0.25)' }}
        >
          <div className="w-12 h-12 rounded-2xl flex items-center justify-center mb-3"
            style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.25)' }}>
            <Lock size={20} style={{ color: ACCENT_DARK }} />
          </div>
          <p className="text-sm font-bold mb-1" style={{ color: '#141613' }}>Premium Feature</p>
          <p className="text-xs leading-relaxed mb-4 max-w-xs" style={{ color: '#91968e' }}>
            {feature} is part of Execute Premium. Upgrade to unlock adaptive AI guidance.
          </p>
          <button
            onClick={() => setShowPaywall(true)}
            className="flex items-center gap-2 px-5 py-2.5 rounded-xl text-sm font-bold"
            style={{ background: ACCENT, color: '#141613' }}
          >
            <Sparkles size={13} /> Upgrade to Premium
          </button>
          <p className="text-[10px] mt-2" style={{ color: '#b8b4ac' }}>$14.99/month · Cancel anytime</p>
        </div>
      </div>

      <AnimatePresence>
        {showPaywall && (
          <PremiumPaywall
            onClose={() => setShowPaywall(false)}
            context={`${feature} requires Execute Premium`}
          />
        )}
      </AnimatePresence>
    </>
  );
}