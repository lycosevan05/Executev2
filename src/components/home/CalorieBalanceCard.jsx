import { motion } from 'framer-motion';
import { Link } from 'react-router-dom';
import { Flame, Plus, Zap } from 'lucide-react';
import { resolveCalorieBudget } from '@/lib/calorieGoal';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

export default function CalorieBalanceCard({
  caloriesConsumed = 0,
  caloriesBurned = 0,
  calorieGoal = null,
  calorieGoalSource = null,
}) {
  const consumed = caloriesConsumed || 0;
  const burned = caloriesBurned || 0;

  // Dynamic budget: base goal + logged exercise calories
  const resolvedTarget = { calories: calorieGoal || 0, source: calorieGoalSource };
  const { budget, exerciseBonus } = resolveCalorieBudget(resolvedTarget, burned);

  const effectiveBudget = budget || 0;
  const remaining = effectiveBudget > 0 ? effectiveBudget - consumed : null;
  const isOver = remaining !== null && remaining < 0;

  // Ring reflects consumed vs adjusted daily total
  const baseGoal = calorieGoal || 0;
  const pct = effectiveBudget > 0 ? Math.min(Math.round((consumed / effectiveBudget) * 100), 100) : 0;

  const R = 30;
  const CIRC = 2 * Math.PI * R;
  const ringOffset = CIRC * (1 - pct / 100);

  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.11 }}
      className="rounded-2xl border px-3 py-3"
      style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 2px 12px rgba(20,22,19,0.08), 0 1px 3px rgba(20,22,19,0.05)' }}
    >
      {/* Title row */}
      <div className="flex items-center gap-1 mb-3">
        <Flame size={13} style={{ color: ACCENT_DARK }} />
        <span className="text-xs font-bold" style={{ color: '#141613' }}>Calories</span>
        {remaining !== null && (
          <span className="text-xs font-semibold ml-1" style={{ color: isOver ? '#b05a3a' : '#91968e' }}>
            · {isOver ? `${Math.abs(remaining).toLocaleString()} over` : `${remaining.toLocaleString()} left`}
          </span>
        )}
        <Link
          to="/log-food"
          className="ml-auto flex items-center gap-1 px-2.5 py-1 rounded-full text-[11px] font-bold"
          style={{ background: ACCENT, color: '#141613' }}
        >
          <Plus size={11} /> Log
        </Link>
      </div>

      {/* Exercise bonus banner — only shown when exercise calories exist */}
      {exerciseBonus > 0 && (
        <div
          className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-xl mb-3 text-[10px] font-semibold"
          style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.25)', color: ACCENT_DARK }}
        >
          <Zap size={10} />
          +{exerciseBonus} kcal exercise bonus · budget {effectiveBudget.toLocaleString()} kcal
        </div>
      )}

      {/* Two rings side by side */}
      <div className="flex items-center justify-around">
        {/* Intake ring */}
        <div className="flex flex-col items-center gap-1.5">
          <div className="relative" style={{ width: 72, height: 72 }}>
            <svg width="72" height="72" viewBox="0 0 72 72" style={{ transform: 'rotate(-90deg)' }}>
              <circle cx="36" cy="36" r={R} fill="none" stroke="#ede8de" strokeWidth="7" />
              {effectiveBudget > 0 && (
                <motion.circle
                  cx="36" cy="36" r={R}
                  fill="none"
                  stroke={isOver ? '#b05a3a' : ACCENT}
                  strokeWidth="7"
                  strokeLinecap="round"
                  strokeDasharray={CIRC}
                  initial={{ strokeDashoffset: CIRC }}
                  animate={{ strokeDashoffset: ringOffset }}
                  transition={{ duration: 1.1, ease: 'easeOut' }}
                />
              )}
            </svg>
            <div className="absolute inset-0 flex flex-col items-center justify-center">
              <span className="text-sm font-black leading-none" style={{ color: isOver ? '#b05a3a' : '#141613' }}>
                {consumed > 0 ? (consumed >= 1000 ? `${(consumed / 1000).toFixed(1)}k` : consumed) : '—'}
              </span>
              <span className="text-[8px] mt-0.5" style={{ color: '#91968e' }}>eaten</span>
            </div>
          </div>
          {effectiveBudget > 0 && (
            <Link to="/profile?section=nutrition&focus=calories" className="text-[10px] font-semibold" style={{ color: '#91968e' }}>
              {pct}% of total
            </Link>
          )}
        </div>

        {/* Divider */}
        <div className="flex flex-col items-center gap-1 px-2">
          <div style={{ width: 1, height: 40, background: '#e8e1d4' }} />
        </div>

        {/* Burned ring */}
        {(() => {
          const BURN_MAX = 1000;
          const burnPct = burned > 0 ? Math.min(burned / BURN_MAX, 1) : 0;
          const burnOffset = CIRC * (1 - burnPct);
          return (
            <div className="flex flex-col items-center gap-1.5">
              <div className="relative" style={{ width: 72, height: 72 }}>
                <svg width="72" height="72" viewBox="0 0 72 72" style={{ transform: 'rotate(-90deg)' }}>
                  <circle cx="36" cy="36" r={R} fill="none" stroke="#ede8de" strokeWidth="7" />
                  {burned > 0 && (
                    <motion.circle
                      cx="36" cy="36" r={R}
                      fill="none"
                      stroke="#b05a3a"
                      strokeWidth="7"
                      strokeLinecap="round"
                      strokeDasharray={CIRC}
                      initial={{ strokeDashoffset: CIRC }}
                      animate={{ strokeDashoffset: burnOffset }}
                      transition={{ duration: 1.1, ease: 'easeOut' }}
                    />
                  )}
                </svg>
                <div className="absolute inset-0 flex flex-col items-center justify-center">
                  <span className="text-sm font-black leading-none" style={{ color: burned > 0 ? '#b05a3a' : '#d9d1c2' }}>
                    {burned > 0 ? (burned >= 1000 ? `${(burned / 1000).toFixed(1)}k` : burned) : '—'}
                  </span>
                  <span className="text-[8px] mt-0.5" style={{ color: '#91968e' }}>burned</span>
                </div>
              </div>
              <span className="text-[10px] font-semibold" style={{ color: '#91968e' }}>
                {burned > 0 ? `${Math.round(burnPct * 100)}% of ${BURN_MAX}` : 'Log activity'}
              </span>
            </div>
          );
        })()}
      </div>
    </motion.div>
  );
}