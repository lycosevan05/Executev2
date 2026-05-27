/**
 * PremiumBadge — Small inline "Premium" badge or lock icon.
 * Used on buttons/cards to hint that a feature requires upgrade.
 */

import { Lock, Sparkles } from 'lucide-react';

export function PremiumLockIcon({ size = 14 }) {
  return <Lock size={size} style={{ color: '#91968e' }} />;
}

export function PremiumBadge({ className = '' }) {
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-bold ${className}`}
      style={{ background: 'rgba(200,224,0,0.15)', color: '#8ea400', border: '1px solid rgba(200,224,0,0.3)' }}
    >
      <Sparkles size={9} />
      Premium
    </span>
  );
}