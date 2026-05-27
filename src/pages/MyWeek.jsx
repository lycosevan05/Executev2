import { useState, useEffect } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Sparkles, Loader2, RefreshCw, Flag, Dumbbell, Activity,
  PersonStanding, Leaf, Zap, UtensilsCrossed, Moon, ChevronRight, ArrowLeft, Target, BatteryCharging, Check, AlertCircle
} from 'lucide-react';
import {
  loadActiveAIPlan, togglePlanItemComplete, getTodayISODate
} from '@/lib/personalizationSync';
import { ensureDailyLogForDate } from '@/lib/plans/ensureDailyLogForDate';
import { getOrCreateWorkoutPlanForDate } from '@/lib/plans/getOrCreateWorkoutPlanForDate';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const WORKOUT_ICON = {
  strength: Dumbbell,
  cardio: Activity,
  mobility: PersonStanding,
  recovery: Leaf,
  rest: RefreshCw,
  mixed: Zap,
};

const INTENSITY_COLOR = {
  low: { bg: 'rgba(141,164,0,0.1)', color: '#8ea400' },
  moderate: { bg: 'rgba(176,90,58,0.1)', color: '#b05a3a' },
  high: { bg: 'rgba(200,100,60,0.15)', color: '#b05a3a' },
  rest: { bg: '#f2efe7', color: '#91968e' },
};

function WorkoutIcon({ type, size = 16 }) {
  const Icon = WORKOUT_ICON[type] || Dumbbell;
  return <Icon size={size} />;
}

// ─── Status phases ─────────────────────────────────────────────────────────

const PHASES = {
  IDLE: 'idle',
  GENERATING: 'generating',
  READY: 'ready',
  ERROR: 'error',
};

// ─── Subcomponents ─────────────────────────────────────────────────────────

function EmptyState() {
  return (
    <div className="px-5 pt-10 pb-32 flex flex-col items-center text-center">
      <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}>
        <div className="w-20 h-20 rounded-3xl flex items-center justify-center mx-auto mb-6"
          style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
          <Flag size={32} style={{ color: ACCENT_DARK }} />
        </div>
        <h2 className="text-xl font-black mb-2 tracking-tight" style={{ color: '#141613' }}>
          Complete your plan first
        </h2>
        <p className="text-sm leading-relaxed max-w-xs mx-auto mb-8" style={{ color: '#5d635d' }}>
          Complete the Plan Questionnaire to generate your first personalized performance week.
        </p>
        <Link to="/plan?generate=true"
          className="inline-flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          <Sparkles size={15} />
          Complete Plan Questionnaire
        </Link>
      </motion.div>
    </div>
  );
}

function PhaseLoader({ phase }) {
  return (
    <div className="px-5 pt-16 pb-32 flex flex-col items-center text-center">
      <motion.div
        className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5"
        style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}
        animate={{ scale: [1, 1.06, 1] }} transition={{ repeat: Infinity, duration: 1.4 }}>
        <Sparkles size={24} style={{ color: ACCENT_DARK }} />
      </motion.div>
      <p className="text-base font-bold mb-1.5" style={{ color: '#141613' }}>Loading your week…</p>
      <p className="text-sm leading-relaxed max-w-xs" style={{ color: '#91968e' }}>Fetching your schedule and progress.</p>
    </div>
  );
}

function ErrorState({ onRetry }) {
  return (
    <div className="px-5 pt-8 pb-32 flex flex-col items-center text-center">
      <div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-5" style={{ background: 'rgba(176,90,58,0.08)' }}>
        <AlertCircle size={22} style={{ color: '#b05a3a' }} />
      </div>
      <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>We couldn't load your week.</p>
      <p className="text-sm mb-6" style={{ color: '#91968e' }}>Something went wrong. Please try again.</p>
      <div className="flex gap-3">
        <button onClick={onRetry}
          className="px-5 py-3 rounded-2xl text-sm font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          Try Again
        </button>
        <Link to="/plan"
          className="px-5 py-3 rounded-2xl text-sm font-semibold border"
          style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}>
          Back to Plan
        </Link>
      </div>
    </div>
  );
}

function PlanReadyBanner({ plan }) {
  return (
    <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl border p-5"
      style={{ background: 'linear-gradient(135deg, rgba(200,224,0,0.12) 0%, rgba(200,224,0,0.04) 100%)', borderColor: 'rgba(200,224,0,0.35)' }}>
      <div className="flex items-start gap-4">
        <div className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0"
          style={{ background: ACCENT }}>
          <Dumbbell size={22} style={{ color: '#141613' }} />
        </div>
        <div className="flex-1">
          <p className="text-base font-black tracking-tight leading-tight mb-1" style={{ color: '#141613' }}>
            Your training schedule is ready
          </p>
          <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>
            Detailed workouts are built one at a time so your plan stays fast, accurate, and adaptable.
          </p>
        </div>
      </div>
      {plan.weeklyFocus && (
        <div className="mt-4 pt-4 border-t flex items-center gap-2 flex-wrap" style={{ borderColor: 'rgba(200,224,0,0.2)' }}>
          <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Focus:</span>
          <span className="text-xs font-semibold" style={{ color: '#141613' }}>{plan.weeklyFocus}</span>
        </div>
      )}
    </motion.div>
  );
}

function WeeklyFocusCard({ plan, onStartToday }) {
  return (
    <motion.div initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl border p-6"
      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="flex items-start justify-between gap-4 mb-4">
        <div className="flex-1">
          <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>
            This Week's Focus
          </p>
          <h2 className="text-xl font-black tracking-tight leading-tight mb-2" style={{ color: '#141613' }}>
            {plan.weeklyFocus}
          </h2>
          <p className="text-sm leading-relaxed" style={{ color: '#5d635d' }}>
            {plan.summary}
          </p>
        </div>
        <div className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0"
          style={{ background: 'rgba(200,224,0,0.12)' }}>
          <Target size={22} style={{ color: ACCENT_DARK }} />
        </div>
      </div>

      <div className="flex flex-wrap gap-2 mb-5">
        {[
          { label: plan.trainingLoad, icon: Dumbbell },
          { label: plan.nutritionFocus, icon: UtensilsCrossed },
          { label: plan.recoveryFocus, icon: BatteryCharging },
        ].filter(p => p.label).map((pill, i) => (
          <div key={i} className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold"
            style={{ background: '#f2efe7', color: '#5d635d', border: '1px solid #e8e1d4' }}>
            <pill.icon size={11} style={{ color: ACCENT_DARK }} />
            {pill.label}
          </div>
        ))}
      </div>

      <button onClick={onStartToday}
        className="w-full py-3.5 rounded-2xl text-sm font-bold"
        style={{ background: ACCENT, color: '#141613' }}>
        Start Today
      </button>
    </motion.div>
  );
}

// Full 7-day schedule list row
function ScheduleDayRow({ day, isToday, isSelected, onSelect, onBuildWorkout, navigate, workoutPlanStatus, workoutPlan }) {
  const isRest = day.dayType !== 'training';
  const dateLabel = new Date(day.date + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  const WorkoutIcn = WORKOUT_ICON[day.workout?.type] || Dumbbell;
  const isBuilt = !isRest && workoutPlanStatus === 'ready' && workoutPlan;
  const isLoading = !isRest && workoutPlanStatus === 'loading';
  const workoutName = workoutPlan?.name || day.workout?.title || day.dayFocus || 'Training';

  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-2xl border overflow-hidden transition-all"
      style={{
        background: isSelected ? 'rgba(200,224,0,0.04)' : '#ffffff',
        borderColor: isSelected ? 'rgba(200,224,0,0.45)' : isToday ? 'rgba(200,224,0,0.3)' : '#e8e1d4',
      }}>
      <button className="w-full flex items-center gap-3 px-4 py-3.5 text-left" onClick={onSelect}>
        <div className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0"
          style={{ background: isRest ? '#f2efe7' : 'rgba(200,224,0,0.12)' }}>
          <WorkoutIcn size={16} style={{ color: isRest ? '#91968e' : ACCENT_DARK }} />
        </div>

        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-0.5">
            <span className="text-sm font-bold" style={{ color: '#141613' }}>{isToday ? 'Today' : day.dayName}</span>
            <span className="text-[10px]" style={{ color: '#91968e' }}>{dateLabel}</span>
          </div>
          {isRest ? (
            <p className="text-xs font-medium" style={{ color: '#91968e' }}>
              Recovery day{day.recovery?.summary ? ` · ${day.recovery.summary}` : ''}
            </p>
          ) : (
            <p className="text-xs font-medium truncate" style={{ color: '#5d635d' }}>
              {workoutName}
              {workoutPlan?.duration ? ` · ${workoutPlan.duration}` : day.workout?.durationMinutes ? ` · ${day.workout.durationMinutes} min` : ''}
            </p>
          )}
        </div>

        {/* Badge / button */}
        {isLoading && (
          <Loader2 size={14} className="animate-spin flex-shrink-0" style={{ color: ACCENT_DARK }} />
        )}
        {!isRest && !isLoading && isBuilt && (
          <button
            onClick={(e) => { e.stopPropagation(); navigate(`/workouts?date=${day.date}&planId=${workoutPlan.id}`); }}
            className="flex-shrink-0 px-3 py-1.5 rounded-xl text-xs font-bold"
            style={{ background: ACCENT, color: '#141613' }}>
            Start
          </button>
        )}
        {!isRest && !isLoading && !isBuilt && (
          <button
            onClick={(e) => { e.stopPropagation(); onBuildWorkout(day.date); }}
            className="flex-shrink-0 px-3 py-1.5 rounded-xl text-xs font-bold"
            style={{ background: ACCENT, color: '#141613' }}>
            Build
          </button>
        )}
        {isRest && (
          <span className="flex-shrink-0 px-2.5 py-1 rounded-xl text-xs font-semibold"
            style={{ background: '#f2efe7', color: '#91968e' }}>Rest</span>
        )}
      </button>

      <AnimatePresence>
        {isSelected && (
          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.2 }} className="overflow-hidden">
            <div className="px-4 pb-4 pt-1 space-y-2" style={{ borderTop: '1px solid #f2efe7' }}>
              {day.dayFocus && (
                <div>
                  <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Priority · </span>
                  <span className="text-xs font-medium" style={{ color: '#5d635d' }}>{day.dayFocus}</span>
                </div>
              )}
              {day.recovery?.summary && (
                <div>
                  <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Recovery · </span>
                  <span className="text-xs font-medium" style={{ color: '#5d635d' }}>{day.recovery.summary}</span>
                </div>
              )}
              {!isRest && (
                <button
                  onClick={() => navigate(isBuilt ? `/workouts?date=${day.date}&planId=${workoutPlan.id}` : `/workouts?date=${day.date}`)}
                  className="mt-1 w-full py-2.5 rounded-xl text-xs font-bold flex items-center justify-center gap-1.5"
                  style={{ background: ACCENT, color: '#141613' }}>
                  {isBuilt ? <><Check size={12} /> View workout</> : <><Sparkles size={12} /> Build workout</>}
                </button>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

function DayChip({ day, isToday, isSelected, onClick }) {
  const Icon = WORKOUT_ICON[day.workout?.type] || Dumbbell;
  return (
    <button onClick={onClick} className="flex flex-col items-center gap-1.5 flex-shrink-0 w-14">
      <div className="w-12 h-12 rounded-2xl flex flex-col items-center justify-center border transition-all"
        style={{
          background: isSelected ? ACCENT : isToday ? 'rgba(200,224,0,0.12)' : '#ffffff',
          borderColor: isSelected ? ACCENT : isToday ? 'rgba(200,224,0,0.4)' : '#e8e1d4',
        }}>
        <Icon size={16} style={{ color: isSelected ? '#141613' : isToday ? ACCENT_DARK : '#91968e' }} />
      </div>
      <span className="text-[10px] font-semibold" style={{ color: isSelected ? ACCENT_DARK : '#5d635d' }}>
        {day.dayLabel}
      </span>
    </button>
  );
}

function ActionRow({ icon: Icon, iconBg, label, title, description, isCompleted, onToggle, onOpen, actionLabel }) {
  return (
    <div className="py-4 border-b last:border-b-0" style={{ borderColor: '#f2efe7' }}>
      <div className="flex items-start gap-3">
        <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
          style={{ background: iconBg || '#f2efe7' }}>
          <Icon size={15} style={{ color: ACCENT_DARK }} />
        </div>
        <div className="flex-1 min-w-0">
          <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>{label}</p>
          <p className="text-sm font-bold leading-tight" style={{ color: '#141613', textDecoration: isCompleted ? 'line-through' : 'none', opacity: isCompleted ? 0.6 : 1 }}>{title}</p>
          {description && <p className="text-xs mt-0.5 leading-relaxed" style={{ color: '#5d635d' }}>{description}</p>}
          <div className="flex items-center gap-2 mt-2">
            <button onClick={onOpen}
              className="flex items-center gap-1 px-3 py-1.5 rounded-xl text-xs font-semibold border"
              style={{ borderColor: '#e8e1d4', background: '#f9f7f3', color: '#5d635d' }}>
              {actionLabel || 'Open'} <ChevronRight size={11} />
            </button>
            <button onClick={onToggle}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold border transition-all"
              style={{
                borderColor: isCompleted ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                background: isCompleted ? 'rgba(200,224,0,0.12)' : '#f9f7f3',
                color: isCompleted ? ACCENT_DARK : '#91968e',
              }}>
              <Check size={11} />
              {isCompleted ? 'Done' : 'Mark done'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function DayDetailCard({ day, isToday, completedIds, onToggle, navigate, weeklyPlanId, dailyLogIds }) {
  const date = day.date;
  const isRestDay = day.dayType !== 'training';
  const intensityStyle = INTENSITY_COLOR[day.workout?.intensity] || INTENSITY_COLOR.rest;

  const workoutId = `workout:${date}`;
  const nutritionId = `nutrition:${date}`;
  const recoveryId = `recovery:${date}`;

  const workoutDone = completedIds.includes(workoutId);
  const nutritionDone = completedIds.includes(nutritionId);
  const recoveryDone = completedIds.includes(recoveryId);

  const workoutPlanId = dailyLogIds?.workoutPlanId || null;
  const mealPlanId = dailyLogIds?.mealPlanId || null;

  return (
    <motion.div key={date} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl border overflow-hidden"
      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      {/* Card header */}
      <div className="px-5 pt-5 pb-3 flex items-center justify-between"
        style={{ borderBottom: '1px solid #f2efe7' }}>
        <div>
          <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>
            {isToday ? 'TODAY · ' : ''}{day.dayName?.toUpperCase()}
          </p>
          <h3 className="text-base font-black tracking-tight" style={{ color: '#141613' }}>
            {day.dayFocus}
          </h3>
        </div>
        {day.workout?.durationMinutes > 0 && !isRestDay && (
          <div className="px-2.5 py-1 rounded-xl text-[10px] font-bold"
            style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
            {day.workout.durationMinutes} min
          </div>
        )}
      </div>

      {/* Action rows */}
      <div className="px-5">
        {/* Workout */}
        {!isRestDay ? (
          <ActionRow
            icon={WORKOUT_ICON[day.workout?.type] || Dumbbell}
            iconBg="rgba(200,224,0,0.1)"
            label="Workout"
            title={day.workout?.title || day.dayFocus}
            description={day.workout?.summary}
            isCompleted={workoutDone}
            onToggle={() => onToggle(date, workoutId)}
            onOpen={() => navigate(`/workouts?date=${date}${workoutPlanId ? `&planId=${workoutPlanId}` : ''}`)}
            actionLabel="Build workout"
          />
        ) : (
          <div className="py-4 border-b" style={{ borderColor: '#f2efe7' }}>
            <div className="flex items-center gap-3">
              <div className="w-9 h-9 rounded-xl flex items-center justify-center" style={{ background: '#f2efe7' }}>
                <Leaf size={15} style={{ color: '#91968e' }} />
              </div>
              <div>
                <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>Workout</p>
                <p className="text-sm font-semibold" style={{ color: '#91968e' }}>Rest day — focus on recovery</p>
              </div>
            </div>
          </div>
        )}

        {/* Nutrition */}
        <ActionRow
          icon={UtensilsCrossed}
          iconBg="rgba(141,164,0,0.1)"
          label="Nutrition"
          title={day.nutrition?.title || 'Nutrition Plan'}
          description={`${day.nutrition?.calorieTarget ? day.nutrition.calorieTarget + ' cal · ' : ''}${day.nutrition?.summary || ''}`}
          isCompleted={nutritionDone}
          onToggle={() => onToggle(date, nutritionId)}
          onOpen={() => navigate(`/nutrition?date=${date}${mealPlanId ? `&planId=${mealPlanId}` : ''}`)}
            actionLabel="Build meals"
        />

        {/* Recovery */}
        {day.recovery?.summary && (
          <ActionRow
            icon={Moon}
            iconBg="rgba(93,99,93,0.08)"
            label="Recovery"
            title={day.recovery?.title || 'Recovery'}
            description={day.recovery?.summary}
            isCompleted={recoveryDone}
            onToggle={() => onToggle(date, recoveryId)}
            onOpen={() => navigate(`/recovery?date=${date}&source=my_week`)}
            actionLabel="View recovery"
          />
        )}
      </div>

      {/* Intensity + reason footer */}
      {!isRestDay && (day.workout?.intensity || day.workout?.reason) && (
        <div className="px-5 pb-4 pt-2 flex gap-2 flex-wrap"
          style={{ borderTop: '1px solid #f2efe7' }}>
          {day.workout?.intensity && day.workout.intensity !== 'rest' && (
            <span className="text-[10px] px-2 py-0.5 rounded-full font-semibold"
              style={{ background: intensityStyle.bg, color: intensityStyle.color }}>
              {day.workout.intensity} intensity
            </span>
          )}
          {day.workout?.reason && (
            <span className="text-[10px]" style={{ color: '#b8b4ac', fontStyle: 'italic' }}>
              {day.workout.reason}
            </span>
          )}
        </div>
      )}
    </motion.div>
  );
}

function UpcomingCard({ day, onClick }) {
  const Icon = WORKOUT_ICON[day.workout?.type] || Dumbbell;
  const dateLabel = new Date(day.date + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  return (
    <motion.button initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      onClick={onClick}
      className="w-full flex items-center gap-3 p-4 rounded-2xl border text-left"
      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0"
        style={{ background: '#f2efe7' }}>
        <Icon size={16} style={{ color: ACCENT_DARK }} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 mb-0.5">
          <span className="text-sm font-bold" style={{ color: '#141613' }}>{day.dayName}</span>
          <span className="text-[10px]" style={{ color: '#91968e' }}>{dateLabel}</span>
        </div>
        <p className="text-xs font-semibold mb-0.5" style={{ color: '#5d635d' }}>{day.dayFocus}</p>
        <p className="text-[10px] leading-relaxed line-clamp-1" style={{ color: '#91968e' }}>
          {day.workout?.summary || day.recovery?.summary}
        </p>
      </div>
      <ChevronRight size={14} style={{ color: '#d9d1c2', flexShrink: 0 }} />
    </motion.button>
  );
}

// ─── Normalization helper ────────────────────────────────────────────────────

const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function inferWorkoutType(trainingType = '') {
  const t = trainingType.toLowerCase();
  if (/strength|upper|lower|push|pull|legs|hypertrophy/.test(t)) return 'strength';
  if (/cardio|run|conditioning|zone/.test(t)) return 'cardio';
  if (/mobility|stretch/.test(t)) return 'mobility';
  if (/recovery/.test(t)) return 'recovery';
  if (/rest/.test(t)) return 'rest';
  return 'mixed';
}

/**
 * Determine the canonical day_type for a weekly overview day.
 * Uses explicit day_type if present; falls back to backward-compat logic.
 */
function resolveDayType(day) {
  const VALID = ['training', 'recovery', 'rest', 'mobility'];
  if (day.day_type && VALID.includes(day.day_type)) return day.day_type;

  // Backward compat for old AIPlans without day_type
  if (day.workout_needed === true) return 'training';
  if (day.workout_needed === false) {
    const t = (day.training_type || '').toLowerCase();
    if (/\bmobility\b|\bstretch/.test(t)) return 'mobility';
    if (/\brecovery\b/.test(t)) return 'recovery';
    if (/\brest\b|\boff\b/.test(t)) return 'rest';
    // workout_needed false but label unclear → treat as training to not hide workouts
    return 'training';
  }
  return 'training';
}

function normalizeLightweightWeeklyOverview(masterPlan) {
  const overview = masterPlan.weekly_overview || masterPlan.plan_payload?.weekly_overview || null;
  const planSummary = masterPlan.plan_summary || masterPlan.plan_payload?.plan_summary || {};
  const nutritionTargets = masterPlan.nutrition_targets || masterPlan.plan_payload?.nutrition_targets || {};
  const trainingSplit = masterPlan.training_split || masterPlan.plan_payload?.training_split || {};
  const recoveryStrategy = masterPlan.recovery_strategy || masterPlan.plan_payload?.recovery_strategy || {};

  if (!overview?.days?.length) return null;

  const days = overview.days.map((day) => {
    const dateObj = new Date(day.date + 'T12:00:00');
    const dow = dateObj.getDay();
    const dayType = resolveDayType(day);
    const isTraining = dayType === 'training';
    const workoutType = isTraining ? inferWorkoutType(day.training_type || '') : dayType;
    const sessionTitle = getPlanDaySessionTitle(day, isTraining ? 'Training' : 'Recovery day');

    const workout = isTraining
      ? {
          type: workoutType,
          title: sessionTitle,
          summary: 'Workout details will be built when you open this day.',
          durationMinutes: trainingSplit.session_length_minutes || 45,
          intensity: 'moderate',
          reason: 'Generated from your weekly overview.',
        }
      : {
          type: dayType, // 'rest', 'recovery', or 'mobility'
          title: sessionTitle,
          summary: day.recovery_focus || 'Focus on recovery today.',
          durationMinutes: 0,
          intensity: 'rest',
          reason: 'Recovery or rest day.',
        };

    return {
      date: day.date,
      dayLabel: day.day_label || DAY_LABELS[dow],
      dayName: DAY_NAMES[dow],
      dayFocus: day.priority || sessionTitle || '',
      dayType,
      workout,
      nutrition: {
        title: 'Nutrition target',
        calorieTarget: nutritionTargets.calories || null,
        summary: day.nutrition_focus || planSummary.nutrition_focus || 'Stay aligned with your nutrition targets.',
      },
      recovery: {
        title: 'Recovery focus',
        summary: day.recovery_focus || recoveryStrategy.mobility_focus || 'Keep recovery on track.',
      },
    };
  });

  return {
    weeklyFocus: planSummary.primary_goal || masterPlan.summary || 'Your performance week',
    summary: planSummary.positioning_summary || masterPlan.summary || '',
    trainingLoad: trainingSplit.split_type || planSummary.training_focus || '',
    nutritionFocus: planSummary.nutrition_focus || 'Hit your daily nutrition targets',
    recoveryFocus: planSummary.recovery_focus || 'Protect recovery and consistency',
    days,
  };
}

// ─── Tab bar ─────────────────────────────────────────────────────────────────

function TabBar({ activeTab, onChange }) {
  return (
    <div className="flex gap-1 p-1 rounded-2xl" style={{ background: '#ede9df' }}>
      {[{ id: 'today', label: 'Today' }, { id: 'week', label: 'This Week' }].map(tab => (
        <button
          key={tab.id}
          onClick={() => onChange(tab.id)}
          className="flex-1 py-2.5 rounded-xl text-xs font-semibold transition-all"
          style={{
            background: activeTab === tab.id ? '#ffffff' : 'transparent',
            color: activeTab === tab.id ? '#141613' : '#91968e',
            boxShadow: activeTab === tab.id ? '0 1px 4px rgba(20,22,19,0.08)' : 'none',
          }}
        >
          {tab.label}
        </button>
      ))}
    </div>
  );
}

// ─── Main page ──────────────────────────────────────────────────────────────

export default function MyWeek() {
  const navigate = useNavigate();
  const [weeklyPlan, setWeeklyPlan] = useState(null);
  const [longTermPlan, setLongTermPlan] = useState(null);
  const [hasLongTermPlan, setHasLongTermPlan] = useState(null);
  const [phase, setPhase] = useState(PHASES.GENERATING);
  const [completedByDate, setCompletedByDate] = useState({});
  const [dailyLogIds, setDailyLogIds] = useState({});
  const [activeTab, setActiveTab] = useState('today');
  const [scheduleExpandedIdx, setScheduleExpandedIdx] = useState(null);
  const [splitResults, setSplitResults] = useState({}); // { [date]: { status, workoutPlan } }

  const todayStr = getTodayISODate();

  useEffect(() => {
    loadActiveAIPlan('daily').then(async (masterPlan) => {
      if (!masterPlan) { setHasLongTermPlan(false); setPhase(PHASES.IDLE); return; }
      const normalized = normalizeLightweightWeeklyOverview(masterPlan);
      if (!normalized) { setHasLongTermPlan(false); setPhase(PHASES.IDLE); return; }
      setLongTermPlan(masterPlan);
      setHasLongTermPlan(true);
      setWeeklyPlan(normalized);
      await loadCompletionState(normalized.days, masterPlan);
      setPhase(PHASES.READY);
    }).catch(() => { setHasLongTermPlan(false); setPhase(PHASES.IDLE); });
  }, []);

  // Load real WorkoutPlan records for the week tab so we never show "Build" for already-built workouts
  const longTermPlanId = longTermPlan?.id || null;
  useEffect(() => {
    if (activeTab !== 'week' || !weeklyPlan?.days?.length || !longTermPlan) return;
    let cancelled = false;

    const trainingDays = weeklyPlan.days.filter(d => d.dayType === 'training');

    // Mark training days as loading
    const initial = {};
    trainingDays.forEach(d => { initial[d.date] = { status: 'loading', workoutPlan: null }; });
    setSplitResults(initial);

    async function loadSplitResults() {
      for (const day of trainingDays) {
        if (cancelled) break;
        const result = await getOrCreateWorkoutPlanForDate(day.date, {
          generate: false,
          masterPlan: longTermPlan,
        }).catch(() => ({ status: 'needs_generation', workoutPlan: null }));
        if (!cancelled) {
          setSplitResults(prev => ({ ...prev, [day.date]: { status: result.status, workoutPlan: result.workoutPlan } }));
        }
      }
    }

    loadSplitResults();
    return () => { cancelled = true; };
  }, [activeTab, longTermPlanId]);

  const loadCompletionState = async (days, masterPlan) => {
    if (!days?.length || !masterPlan) return;
    const byDate = {};
    const idsByDate = {};
    const results = await Promise.all(
      days.map(async (day) => {
        try {
          const result = await ensureDailyLogForDate(day.date, { masterPlan, createIfMissing: true, linkExistingPlans: true });
          const log = result.dailyLog || null;
          return { date: day.date, completedIds: log?.plan_items_completed || [], ids: { dailyLogId: log?.id || null, workoutPlanId: log?.planned_workout_id || null, mealPlanId: log?.planned_meal_plan_id || null } };
        } catch {
          return { date: day.date, completedIds: [], ids: { dailyLogId: null, workoutPlanId: null, mealPlanId: null } };
        }
      })
    );
    results.forEach(r => { byDate[r.date] = r.completedIds; idsByDate[r.date] = r.ids; });
    setCompletedByDate(byDate);
    setDailyLogIds(idsByDate);
  };

  const handleBuildWorkoutForDate = async (date) => {
    setSplitResults(prev => ({ ...prev, [date]: { status: 'loading', workoutPlan: null } }));
    const result = await getOrCreateWorkoutPlanForDate(date, { generate: true, masterPlan: longTermPlan }).catch(() => ({ status: 'needs_generation', workoutPlan: null }));
    setSplitResults(prev => ({ ...prev, [date]: { status: result.status, workoutPlan: result.workoutPlan } }));
  };

  const handleToggleComplete = async (date, itemId) => {
    setCompletedByDate(prev => {
      const existing = prev[date] || [];
      const isNowDone = !existing.includes(itemId);
      return { ...prev, [date]: isNowDone ? [...existing, itemId] : existing.filter(id => id !== itemId) };
    });
    await togglePlanItemComplete(date, itemId, {
      source_plan_id: longTermPlan?.id,
      generation_batch_id: longTermPlan?.generation_batch_id,
      daily_log_id: dailyLogIds[date]?.dailyLogId,
    }).catch(() => {});
  };

  const todayDay = weeklyPlan?.days?.find(d => d.date === todayStr) || weeklyPlan?.days?.[0];
  const isLoading = phase === PHASES.GENERATING;
  const isError = phase === PHASES.ERROR;

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pt-12 pb-3"
        style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center gap-3 mb-3">
          <button onClick={() => navigate('/plan')}
            className="w-8 h-8 rounded-xl flex items-center justify-center border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ArrowLeft size={14} style={{ color: '#5d635d' }} />
          </button>
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>My Week</h1>
            <p className="text-[10px]" style={{ color: '#91968e' }}>Training, meals & recovery</p>
          </div>
        </div>
        {weeklyPlan && <TabBar activeTab={activeTab} onChange={setActiveTab} />}
      </div>

      {/* Content */}
      <AnimatePresence mode="wait">
        {isLoading ? (
          <PhaseLoader key="loading" phase={phase} />
        ) : hasLongTermPlan === false ? (
          <EmptyState key="empty" />
        ) : isError ? (
          <ErrorState key="error" onRetry={() => window.location.reload()} />
        ) : weeklyPlan ? (
          <motion.div key="content" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
            <AnimatePresence mode="wait">

              {/* ── TODAY TAB ── */}
              {activeTab === 'today' && (
                <motion.div key="today" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                  className="px-5 pb-32 pt-5 space-y-4">
                  {todayDay ? (
                    <>
                      <DayDetailCard
                        day={todayDay}
                        isToday={todayDay.date === todayStr}
                        completedIds={completedByDate[todayDay.date] || []}
                        onToggle={handleToggleComplete}
                        navigate={navigate}
                        weeklyPlanId={null}
                        dailyLogIds={dailyLogIds[todayDay.date] || {}}
                      />
                      <button
                        onClick={() => setActiveTab('week')}
                        className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                        View full week schedule <ChevronRight size={13} />
                      </button>
                    </>
                  ) : (
                    <div className="py-16 text-center">
                      <p className="text-sm" style={{ color: '#91968e' }}>No plan data for today.</p>
                    </div>
                  )}
                </motion.div>
              )}

              {/* ── THIS WEEK TAB ── */}
              {activeTab === 'week' && (
                <motion.div key="week" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                  className="px-5 pb-32 pt-5 space-y-5">

                  {/* Plan banner */}
                  <PlanReadyBanner plan={weeklyPlan} />

                  {/* Weekly focus */}
                  <WeeklyFocusCard plan={weeklyPlan} onStartToday={() => setActiveTab('today')} />

                  {/* 7-day schedule */}
                  <div>
                    <p className="text-xs font-bold uppercase tracking-widest mb-3 px-1" style={{ color: '#91968e' }}>
                      7-Day Schedule
                    </p>
                    <div className="space-y-2.5">
                      {weeklyPlan.days?.map((day, idx) => (
                        <ScheduleDayRow
                          key={day.date}
                          day={day}
                          isToday={day.date === todayStr}
                          isSelected={scheduleExpandedIdx === idx}
                          onSelect={() => setScheduleExpandedIdx(prev => prev === idx ? null : idx)}
                          onBuildWorkout={handleBuildWorkoutForDate}
                          navigate={navigate}
                          workoutPlanStatus={splitResults[day.date]?.status}
                          workoutPlan={splitResults[day.date]?.workoutPlan}
                        />
                      ))}
                    </div>
                  </div>
                </motion.div>
              )}

            </AnimatePresence>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </div>
  );
}
