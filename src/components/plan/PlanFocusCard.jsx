import { motion } from 'framer-motion';
import { Dumbbell, Leaf, Activity, Play } from 'lucide-react';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';
import { getTodayISODate } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';
const NON_TRAINING = ['rest', 'recovery', 'mobility'];

export default function PlanFocusCard({ activePlan, readiness, onStartToday, hasPlan }) {
  const todayStr = getTodayISODate();

  // Find today's day from the weekly overview
  const weeklyOverview = activePlan?.weekly_overview || activePlan?.plan_payload?.weekly_overview;
  const todayDay = weeklyOverview?.days?.find(d => d.date === todayStr) || null;

  const isRestDay = todayDay
    ? (NON_TRAINING.includes(todayDay.day_type) || todayDay.workout_needed === false)
    : false;

  const todayTraining = todayDay?.training_type || (isRestDay ? 'Recovery' : 'Training');
  const todayFocus = todayDay?.priority || todayDay?.day_focus || todayDay?.dayFocus || '';
  const todayNutrition = todayDay?.nutrition_focus || '';

  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const todayHeadline = getPlanDaySessionTitle(
    todayDay,
    todayTraining || planSummary?.primary_goal || "Today's performance plan"
  );
  const todaySupportText = todayNutrition || (todayFocus && todayFocus !== todayHeadline ? todayFocus : '');
  const todayLoadLabel = isRestDay
    ? 'Recovery day'
    : todayDay?.session_kind === 'sport'
      ? 'Sport performance day'
      : 'Training day';

  const readinessScore = readiness?.readiness_score ?? null;
  const readinessLabel = readinessScore == null ? 'Not checked in'
    : readinessScore >= 75 ? 'High — push today'
    : readinessScore >= 50 ? 'Moderate — train smart'
    : 'Low — protect recovery';

  const readinessColor = readinessScore == null ? '#91968e'
    : readinessScore >= 75 ? ACCENT_DARK
    : readinessScore >= 50 ? '#a07030'
    : '#b05a3a';

  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.05 }}
      className="rounded-3xl overflow-hidden"
      style={{ background: '#ffffff', border: '1px solid #ddd6c8', boxShadow: '0 6px 28px rgba(20,22,19,0.11), 0 2px 6px rgba(20,22,19,0.06)' }}
    >
      <div className="relative px-5 pt-5 pb-4" style={{ overflow: 'hidden' }}>
        {/* Subtle bg decoration */}
        <div className="absolute top-0 right-0 opacity-[0.13] pointer-events-none select-none"
          style={{ transform: 'translate(10%, -5%)' }}>
          <svg width="160" height="120" viewBox="0 0 160 120" fill="none">
            <path d="M0 120L60 20L110 70L160 0L160 120Z" fill={ACCENT} />
          </svg>
        </div>

        {/* Badge */}
        <div className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full mb-3"
          style={{ background: 'rgba(200,224,0,0.15)', border: '1px solid rgba(200,224,0,0.35)' }}>
          <div className="w-1.5 h-1.5 rounded-full" style={{ background: ACCENT_DARK }} />
          <span className="text-[11px] font-bold tracking-wide" style={{ color: ACCENT_DARK }}>Today's Plan</span>
        </div>

        {/* Today headline */}
        <h2 className="text-xl font-black leading-tight mb-2 pr-8"
          style={{ color: '#141613', letterSpacing: '-0.03em' }}>
          {todayHeadline}
        </h2>
        {todaySupportText && (
          <p className="text-xs mb-4 leading-relaxed" style={{ color: '#5d635d' }}>{todaySupportText}</p>
        )}

        {/* Today's quick stats */}
        <div className="flex items-center gap-4 mb-5 pt-4" style={{ borderTop: '1px solid #f2efe7' }}>
          <div className="flex items-center gap-1.5">
            {isRestDay
              ? <Leaf size={13} style={{ color: '#5d8a5d' }} />
              : <Dumbbell size={13} style={{ color: ACCENT_DARK }} />}
            <span className="text-xs font-semibold" style={{ color: '#141613' }}>{todayLoadLabel}</span>
          </div>
          <div className="flex items-center gap-1.5">
            <Activity size={13} style={{ color: readinessColor }} />
            <span className="text-xs font-semibold" style={{ color: readinessColor }}>{readinessLabel}</span>
          </div>
        </div>

        {/* CTA */}
        <motion.button
          whileTap={{ scale: 0.98 }}
          onClick={onStartToday}
          className="w-full flex items-center justify-center gap-2.5 py-4 rounded-2xl text-sm font-black"
          style={{ background: ACCENT, color: '#141613', boxShadow: '0 5px 22px rgba(200,224,0,0.42), 0 2px 6px rgba(200,224,0,0.2)', letterSpacing: '-0.01em' }}
        >
          <Play size={16} fill="#141613" />
          Start Today's Plan
        </motion.button>
      </div>
    </motion.div>
  );
}
