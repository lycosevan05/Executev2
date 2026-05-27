import { motion } from 'framer-motion';
import { Dumbbell, Leaf, Zap, Clock } from 'lucide-react';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';
import { getTodayISODate } from '@/lib/personalizationSync';

const ACCENT_DARK = '#8ea400';

const FALLBACK_DAYS = [
  { day: 'MON', name: 'Upper Strength', duration: '45 min', type: 'strength' },
  { day: 'TUE', name: 'Mobility + Zone 2', duration: '30 min', type: 'recovery' },
  { day: 'WED', name: 'Lower Strength', duration: '50 min', type: 'strength' },
  { day: 'THU', name: 'Recovery', duration: '30 min', type: 'rest' },
  { day: 'FRI', name: 'Conditioning', duration: '40 min', type: 'cardio' },
];

function getIcon(type) {
  if (type === 'rest' || type === 'recovery') return <Leaf size={18} style={{ color: '#5d8a5d' }} />;
  if (type === 'cardio') return <Zap size={18} style={{ color: ACCENT_DARK }} />;
  return <Dumbbell size={18} style={{ color: ACCENT_DARK }} />;
}

function getIconBg(type) {
  if (type === 'rest' || type === 'recovery') return 'rgba(93,138,93,0.1)';
  return 'rgba(200,224,0,0.1)';
}

function DayCard({ day, name, duration, type, isToday, index }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.05 + index * 0.05 }}
      className="flex-shrink-0 flex flex-col items-center p-3.5 rounded-2xl"
      style={{
        background: '#ffffff',
        border: isToday ? '1.5px solid rgba(200,224,0,0.5)' : '1px solid #e8e1d4',
        boxShadow: isToday ? '0 4px 16px rgba(200,224,0,0.12)' : '0 2px 8px rgba(20,22,19,0.06)',
        minWidth: 96,
        maxWidth: 96,
      }}
    >
      <span className="text-[10px] font-bold uppercase tracking-widest mb-2.5"
        style={{ color: isToday ? ACCENT_DARK : '#91968e' }}>
        {day}
      </span>
      <div className="w-10 h-10 rounded-full flex items-center justify-center mb-2.5"
        style={{ background: getIconBg(type) }}>
        {getIcon(type)}
      </div>
      <span className="text-xs font-bold text-center leading-tight mb-2"
        style={{ color: '#141613' }}>
        {name}
      </span>
      <div className="flex items-center gap-1">
        <Clock size={9} style={{ color: '#91968e' }} />
        <span className="text-[10px]" style={{ color: '#91968e' }}>{duration}</span>
      </div>
      {isToday && (
        <div className="mt-2 w-5 h-1 rounded-full" style={{ background: ACCENT_DARK }} />
      )}
    </motion.div>
  );
}

export default function WeeklyPlanPreview({ activePlan }) {
  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const weeklyFocus = planSummary?.weekly_focus || planSummary?.primary_goal || '';
  // Build days from plan if available, else fallback
  const weeklyOverview = activePlan?.weekly_overview || activePlan?.plan_payload?.weekly_overview;
  const todayIso = getTodayISODate();
  const dayNames = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

  let days = FALLBACK_DAYS;

  if (weeklyOverview?.days?.length) {
    const NON_TRAINING = ['rest', 'recovery', 'mobility'];
    const trainingSplit = activePlan?.training_split || activePlan?.plan_payload?.training_split || {};
    const planSessionLen = trainingSplit.session_length_minutes;
    days = weeklyOverview.days.slice(0, 7).map(d => {
      const dayOfWeek = dayNames[new Date(d.date + 'T12:00:00').getDay()];
      const isRest = (d.day_type && NON_TRAINING.includes(d.day_type)) ||
        (d.workout_needed === false);
      const type = isRest ? 'rest' : d.day_type || 'strength';
      const trainingType = d.training_type || (isRest ? 'Recovery' : 'Training');
      const sessionTitle = getPlanDaySessionTitle(d, trainingType);
      const dayLen = d.session_duration_min || d.session_length_minutes;
      const duration = isRest
        ? '—'
        : (dayLen ? `${dayLen} min` : (planSessionLen ? `${planSessionLen} min` : ''));
      return { day: dayOfWeek, name: sessionTitle, duration, type, date: d.date };
    });
  }

  return (
    <div className="space-y-3">
      {weeklyFocus && (
        <div className="px-1">
          <div className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full mb-1.5"
            style={{ background: 'rgba(200,224,0,0.12)', border: '1px solid rgba(200,224,0,0.25)' }}>
            <div className="w-1.5 h-1.5 rounded-full" style={{ background: ACCENT_DARK }} />
            <span className="text-[11px] font-bold tracking-wide" style={{ color: ACCENT_DARK }}>This Week's Focus</span>
          </div>
          <p className="text-base font-black leading-snug" style={{ color: '#141613', letterSpacing: '-0.02em' }}>{weeklyFocus}</p>
        </div>
      )}
      <div className="overflow-x-auto pb-1 -mx-1 px-1">
        <div className="flex gap-2.5" style={{ width: 'max-content' }}>
          {days.map((d, i) => (
            <DayCard
              key={i}
              {...d}
              index={i}
              isToday={d.date === todayIso}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
