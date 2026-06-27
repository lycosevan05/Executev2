import { useState, useEffect, useRef, useCallback } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { X, ChevronLeft, ChevronRight, Check, SkipForward, Flag, Minus, Plus, PlusCircle, Play, Pause, RotateCcw } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getUnitSystem } from '@/lib/units';
import PostWorkoutCheckIn from '@/components/workouts/PostWorkoutCheckIn';
import WorkoutSummary from '@/components/workouts/WorkoutSummary';
import { refreshDynamicReadiness } from '@/lib/readinessScore';
import { getTodayISODate } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.completed_at || a?.started_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.completed_at || b?.started_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function hasExercises(plan) {
  return Array.isArray(plan?.exercises) && plan.exercises.length > 0;
}

function chooseBestWorkoutPlan(plans = [], workout = null) {
  const safePlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];
  if (!safePlans.length) return null;

  if (workout?.id) {
    const exact = safePlans.find(plan => sameValue(plan.id, workout.id));
    if (exact) return exact;
  }

  if (workout?.source_plan_id && workout?.generation_batch_id) {
    const linked = safePlans.filter(plan =>
      sameValue(plan.source_plan_id, workout.source_plan_id) &&
      sameValue(plan.generation_batch_id, workout.generation_batch_id)
    );
    if (linked.length) return linked.find(hasExercises) || linked[0];
  }

  if (workout?.source_plan_id) {
    const sourceLinked = safePlans.filter(plan => sameValue(plan.source_plan_id, workout.source_plan_id));
    if (sourceLinked.length) return sourceLinked.find(hasExercises) || sourceLinked[0];
  }

  const canonicalGroups = [
    safePlans.filter(plan => plan.source === 'plan_questionnaire_overview'),
    safePlans.filter(plan => plan.plan_payload?.source === 'plan_questionnaire_overview'),
    safePlans.filter(plan => plan.source === 'plan_questionnaire_initial'),
    safePlans.filter(plan => plan.plan_payload?.source === 'plan_questionnaire_initial'),
  ];
  for (const group of canonicalGroups) {
    if (group.length) return group.find(hasExercises) || group[0];
  }

  return safePlans.find(hasExercises) || safePlans[0] || null;
}

function chooseBestWorkoutLog(logs = [], workout = null) {
  const safeLogs = Array.isArray(logs) ? logs.filter(Boolean).sort(newestFirst) : [];
  if (!safeLogs.length) return null;

  if (workout?.id) {
    const exactPlanLog = safeLogs.find(log => sameValue(log.workout_plan_id, workout.id));
    if (exactPlanLog) return exactPlanLog;
  }

  if (workout?.source_plan_id && workout?.generation_batch_id) {
    const linked = safeLogs.find(log =>
      sameValue(log.source_plan_id, workout.source_plan_id) &&
      sameValue(log.generation_batch_id, workout.generation_batch_id)
    );
    if (linked) return linked;
  }

  if (workout?.source_plan_id) {
    const sourceLinked = safeLogs.find(log => sameValue(log.source_plan_id, workout.source_plan_id));
    if (sourceLinked) return sourceLinked;
  }

  return safeLogs[0] || null;
}

async function loadUserWeightKg() {
  const profiles = await backend.entities.UserProfile.list('-updated_date', 1).catch(() => []);
  const profile = profiles?.[0] || null;
  return profile?.weight_kg || profile?.weight || 75;
}

async function loadLinkedDailyLogForWorkout(date, workout = null) {
  if (!date) return null;

  if (workout?.source_plan_id && workout?.generation_batch_id) {
    const linkedLogs = await backend.entities.DailyLog.filter({
      date,
      source_plan_id: workout.source_plan_id,
      generation_batch_id: workout.generation_batch_id,
    }).catch(() => []);

    if (linkedLogs.length > 0) {
      return linkedLogs[0];
    }
  }

  const dateLogs = await backend.entities.DailyLog.filter({ date }).catch(() => []);

  return (
    dateLogs.find(log =>
      sameValue(log.source_plan_id, workout?.source_plan_id) &&
      sameValue(log.generation_batch_id, workout?.generation_batch_id)
    ) ||
    dateLogs.find(log => sameValue(log.source_plan_id, workout?.source_plan_id)) ||
    dateLogs.find(log => log.source === 'plan_questionnaire_overview') ||
    dateLogs.find(log => log.plan_payload?.source === 'plan_questionnaire_overview') ||
    dateLogs.find(log => log.source === 'plan_questionnaire_initial') ||
    dateLogs.find(log => log.plan_payload?.source === 'plan_questionnaire_initial') ||
    dateLogs[0] ||
    null
  );
}

function formatTime(secs) {
  const m = Math.floor(secs / 60).toString().padStart(2, '0');
  const s = (secs % 60).toString().padStart(2, '0');
  return `${m}:${s}`;
}

// Parse a rest string ("2-3 min", "90 sec") → seconds. Ranges use the upper bound.
function parseRestSeconds(restStr) {
  const s = String(restStr || '').toLowerCase();
  const mins = [...s.matchAll(/(\d+)\s*min/g)].map(m => parseInt(m[1]));
  if (mins.length) return Math.max(...mins) * 60;
  const secs = [...s.matchAll(/(\d+)\s*sec/g)].map(m => parseInt(m[1]));
  if (secs.length) return Math.max(...secs);
  return 90;
}

// Inline, adjustable rest timer that lives under the stats row of each exercise.
// Seeds from the exercise's prescribed rest; remounts per exercise (card is keyed).
function RestTimerWidget({ defaultSeconds }) {
  const STEP = 15;
  const [target, setTarget] = useState(defaultSeconds);
  const [remaining, setRemaining] = useState(defaultSeconds);
  const [running, setRunning] = useState(false);

  useEffect(() => {
    if (!running) return;
    if (remaining <= 0) { setRunning(false); return; }
    const id = setTimeout(() => setRemaining(r => r - 1), 1000);
    return () => clearTimeout(id);
  }, [running, remaining]);

  const adjust = (delta) => {
    setRunning(false);
    setTarget(t => {
      const next = Math.max(STEP, t + delta);
      setRemaining(next);
      return next;
    });
  };
  const toggle = () => {
    if (remaining <= 0) { setRemaining(target); setRunning(true); return; }
    setRunning(r => !r);
  };
  const reset = () => { setRunning(false); setRemaining(target); };

  const done = remaining <= 0;
  const pct = target > 0 ? Math.max(0, Math.min(1, remaining / target)) : 0;

  return (
    <div className="mb-5 rounded-2xl p-3" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)' }}>
      <div className="flex items-center justify-between mb-2.5">
        <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#4a4f4a' }}>Rest timer</p>
        <button onClick={reset} className="flex items-center gap-1 text-[10px] font-bold uppercase tracking-widest" style={{ color: '#5d635d' }}>
          <RotateCcw size={11} /> Reset
        </button>
      </div>
      <div className="flex items-center gap-2.5">
        <button onClick={() => adjust(-STEP)} aria-label="Decrease rest"
          className="w-11 h-11 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
          <Minus size={15} style={{ color: '#91968e' }} />
        </button>
        <button onClick={toggle}
          className="flex-1 relative overflow-hidden rounded-xl h-12 flex items-center justify-center"
          style={{ background: running ? 'rgba(200,224,0,0.15)' : 'rgba(200,224,0,0.1)', border: `1px solid ${running ? 'rgba(200,224,0,0.4)' : 'rgba(200,224,0,0.2)'}` }}>
          <div className="absolute inset-y-0 left-0" style={{ width: `${pct * 100}%`, background: 'rgba(200,224,0,0.14)', transition: 'width 1s linear' }} />
          <span className="relative flex items-center gap-2">
            {running
              ? <Pause size={16} style={{ color: ACCENT }} />
              : <Play size={16} style={{ color: done ? '#5d635d' : ACCENT }} />}
            <span className="text-2xl font-black tabular-nums" style={{ color: done ? '#5d635d' : ACCENT }}>{formatTime(remaining)}</span>
          </span>
        </button>
        <button onClick={() => adjust(STEP)} aria-label="Increase rest"
          className="w-11 h-11 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
          <Plus size={15} style={{ color: '#91968e' }} />
        </button>
      </div>
    </div>
  );
}

// Parse rep string → { label, min, max, isTime, isAmrap, midpoint }
function parseRepTarget(reps) {
  if (!reps) return { label: null, midpoint: null, isTime: false, isAmrap: false };
  const str = String(reps).trim().toLowerCase();

  if (str === 'amrap' || str.includes('amrap')) return { label: 'AMRAP', midpoint: null, isTime: false, isAmrap: true };
  if (str.includes('sec') || str.includes('min') || str.includes('hold')) return { label: `${reps}`, midpoint: null, isTime: true, isAmrap: false };

  // Range: "6-8", "6–8", "8 to 10"
  const rangeMatch = str.match(/(\d+)\s*(?:-|–|to)\s*(\d+)/);
  if (rangeMatch) {
    const min = parseInt(rangeMatch[1]);
    const max = parseInt(rangeMatch[2]);
    const midpoint = Math.round((min + max) / 2);
    return { label: `${min}–${max} reps`, midpoint, isTime: false, isAmrap: false };
  }

  // Fixed number
  const fixedMatch = str.match(/^(\d+)/);
  if (fixedMatch) {
    const val = parseInt(fixedMatch[1]);
    return { label: `${val} reps`, midpoint: val, isTime: false, isAmrap: false };
  }

  return { label: String(reps), midpoint: null, isTime: false, isAmrap: false };
}

// Single swipeable exercise card
function ExerciseCard({ ex, exIdx, totalExercises, completedSets, weights, repsOverrides, onCompleteSet, onWeightChange, onRepsChange, unitSystem }) {
  const sets = ex.sets || 0;
  const doneSetsCount = Array.from({ length: sets }, (_, si) => completedSets[`${exIdx}-${si}`]).filter(Boolean).length;
  const repTarget = parseRepTarget(ex.reps);
  const defaultReps = repTarget.midpoint || 0;
  const currentReps = repsOverrides[exIdx] !== undefined ? repsOverrides[exIdx] : defaultReps;

  return (
    <div className="flex flex-col h-full">
      {/* Exercise header */}
      <div className="mb-4">
        <div className="flex items-start justify-between mb-1">
          <h2 className="text-2xl font-black leading-tight flex-1 pr-3" style={{ color: '#ffffff', letterSpacing: '-0.03em' }}>{ex.name}</h2>
        </div>
        {ex.muscles && <p className="text-sm mb-1" style={{ color: '#5d635d' }}>{ex.muscles}</p>}

        {ex.notes && <p className="text-xs leading-relaxed mt-2" style={{ color: '#3d423d' }}>{ex.notes}</p>}
      </div>

      {/* Stats row */}
      <div className="flex gap-2 mb-5 w-full overflow-hidden">
        <div className="flex-1 rounded-2xl p-3 text-center" style={{ background: 'rgba(200,224,0,0.08)', border: '1px solid rgba(200,224,0,0.15)' }}>
          <p className="text-xl font-black" style={{ color: ACCENT }}>{ex.sets || '—'}</p>
          <p className="text-[10px] uppercase tracking-widest mt-0.5" style={{ color: '#5d635d' }}>sets</p>
        </div>
        <div className="flex-1 rounded-2xl p-3 text-center" style={{ background: 'rgba(200,224,0,0.08)', border: '1px solid rgba(200,224,0,0.15)' }}>
          <p className="text-xl font-black" style={{ color: ACCENT }}>{repTarget.label || currentReps || '—'}</p>
          <p className="text-[10px] uppercase tracking-widest mt-0.5" style={{ color: '#5d635d' }}>reps</p>
        </div>
        <div className="flex-1 rounded-2xl p-3 text-center" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)' }}>
          <p className="text-xs font-bold" style={{ color: '#ffffff' }}>{ex.rest || '—'}</p>
          <p className="text-[10px] uppercase tracking-widest mt-0.5" style={{ color: '#5d635d' }}>rest</p>
        </div>
        {ex.weight && (
          <div className="flex-1 rounded-2xl p-3 text-center" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)' }}>
            <p className="text-xs font-bold" style={{ color: '#ffffff' }}>{ex.weight}</p>
            <p className="text-[10px] uppercase tracking-widest mt-0.5" style={{ color: '#5d635d' }}>target</p>
          </div>
        )}
      </div>

      {/* Adjustable rest timer */}
      <RestTimerWidget defaultSeconds={parseRestSeconds(ex.rest)} />

      {/* Reps input */}
      <div className="mb-4">
        <div className="flex items-center justify-between mb-2">
          <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#4a4f4a' }}>Reps completed</p>
          {repTarget.label && !repTarget.isTime && !repTarget.isAmrap && (
            <p className="text-[10px]" style={{ color: '#5d635d' }}>Target: {repTarget.label}</p>
          )}
        </div>
        <div className="flex items-center gap-2 w-full">
          <button onClick={() => onRepsChange(exIdx, Math.max(1, currentReps - 1))}
            className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
            <Minus size={14} style={{ color: '#91968e' }} />
          </button>
          <input
            type="number"
            value={currentReps || ''}
            onChange={e => onRepsChange(exIdx, parseInt(e.target.value) || 1)}
            placeholder={String(defaultReps || 10)}
            className="min-w-0 flex-1 text-center py-3 rounded-xl text-base font-bold bg-transparent outline-none border"
            style={{ borderColor: 'rgba(255,255,255,0.1)', color: '#ffffff' }}
          />
          <button onClick={() => onRepsChange(exIdx, (currentReps || defaultReps || 0) + 1)}
            className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
            <Plus size={14} style={{ color: '#91968e' }} />
          </button>
        </div>
        {!repTarget.isTime && !repTarget.isAmrap && (
          <p className="text-[10px] text-center mt-1.5" style={{ color: '#4a4f4a' }}>Adjust to actual reps completed</p>
        )}
      </div>

      {/* Weight input */}
      <div className="mb-5">
        <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#4a4f4a' }}>
          Weight ({unitSystem === 'imperial' ? 'lbs' : 'kg'}) — optional
        </p>
        <div className="flex items-center gap-2 w-full">
          <button onClick={() => {
            const step = unitSystem === 'imperial' ? 5 : 2.5;
            const cur = weights[exIdx] || 0;
            onWeightChange(exIdx, Math.max(0, Math.round((cur - step) * 10) / 10));
          }}
            className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
            <Minus size={14} style={{ color: '#91968e' }} />
          </button>
          <input
            type="number"
            value={weights[exIdx] || ''}
            onChange={e => onWeightChange(exIdx, parseFloat(e.target.value) || 0)}
            placeholder="0"
            className="min-w-0 flex-1 text-center py-3 rounded-xl text-base font-bold bg-transparent outline-none border"
            style={{ borderColor: 'rgba(255,255,255,0.1)', color: '#ffffff' }}
          />
          <button onClick={() => {
            const step = unitSystem === 'imperial' ? 5 : 2.5;
            const cur = weights[exIdx] || 0;
            onWeightChange(exIdx, Math.round((cur + step) * 10) / 10);
          }}
            className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
            <Plus size={14} style={{ color: '#91968e' }} />
          </button>
        </div>
      </div>

      {/* Sets */}
      <div className="mb-2">
        <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#4a4f4a' }}>
          {doneSetsCount}/{sets} sets — tap to complete
        </p>
        <div className="flex gap-3 flex-wrap">
          {Array.from({ length: sets }, (_, si) => {
            const key = `${exIdx}-${si}`;
            const done = completedSets[key];
            return (
              <motion.button key={si} whileTap={{ scale: 0.9 }}
                onClick={() => onCompleteSet(exIdx, si)}
                className="flex-1 min-w-[56px] py-5 rounded-2xl font-black text-sm transition-all"
                style={{
                  background: done ? 'rgba(200,224,0,0.15)' : 'rgba(255,255,255,0.05)',
                  border: `2px solid ${done ? 'rgba(200,224,0,0.5)' : 'rgba(255,255,255,0.08)'}`,
                  color: done ? ACCENT : '#5d635d',
                }}>
                {done ? <Check size={18} className="mx-auto" /> : `S${si + 1}`}
              </motion.button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

export default function WorkoutSession() {
  const navigate = useNavigate();
  const location = useLocation();

  const passedWorkout = location.state?.workout;
  const passedLogId = location.state?.logId || null;
  const passedStartedAt = location.state?.startedAt || null;
  const passedSourcePlanId = location.state?.sourcePlanId || passedWorkout?.source_plan_id || '';
  const passedGenerationBatchId = location.state?.generationBatchId || passedWorkout?.generation_batch_id || '';
  const passedWeeklyPlanId = location.state?.weeklyPlanId || passedWorkout?.weekly_plan_id || '';
  const viewSummary = location.state?.viewSummary || false;
  const completedLogData = location.state?.completedLogData || null;

  const workoutContext = passedWorkout ? {
    ...passedWorkout,
    source_plan_id: passedWorkout.source_plan_id || passedSourcePlanId,
    generation_batch_id: passedWorkout.generation_batch_id || passedGenerationBatchId,
    weekly_plan_id: passedWorkout.weekly_plan_id || passedWeeklyPlanId,
  } : null;



  const [logId, setLogId] = useState(passedLogId);
  const [startedAt, setStartedAt] = useState(passedStartedAt);
  const [exercises, setExercises] = useState(workoutContext?.exercises || []);
  const [currentExIdx, setCurrentExIdx] = useState(0);
  const [completedSets, setCompletedSets] = useState({});
  const [weights, setWeights] = useState({});
  const [repsOverrides, setRepsOverrides] = useState({});
  const [showCheckIn, setShowCheckIn] = useState(false);
  const [showSummary, setShowSummary] = useState(viewSummary);
  const [summaryData, setSummaryData] = useState(completedLogData ? buildSummaryFromLog(completedLogData, passedWorkout) : null);
  const [notes, setNotes] = useState('');
  const [skippedExercises, setSkippedExercises] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAddCustom, setShowAddCustom] = useState(false);
  const [customForm, setCustomForm] = useState({ name: '', sets: '3', reps: '10', muscles: '', notes: '' });
  const [unitSystem] = useState(() => getUnitSystem());

  // Touch/swipe state
  const touchStartX = useRef(null);

  function buildSummaryFromLog(log, workout) {
    return {
      workout: workout || { name: log.workout_name, exercises: [] },
      duration_minutes: log.duration_minutes,
      sets_completed: log.sets_completed,
      exercises_completed: log.exercises_completed,
      estimated_calories_burned: log.estimated_calories_burned,
      session_rpe: log.session_rpe,
      exertion_level: log.exertion_level,
      post_workout_feeling: log.post_workout_feeling,
      performance_rating: log.performance_rating,
      pain_flag: log.pain_flag,
      pain_notes: log.pain_notes,
      user_notes: log.user_notes,
    };
  }

  // Init: if viewSummary, skip straight to summary
  useEffect(() => {
    if (viewSummary && completedLogData) {
      setShowSummary(true);
      setLoading(false);
      return;
    }
    if (!passedWorkout) {
      navigate('/workouts');
      return;
    }
    initSession().catch(() => setLoading(false));
  }, []);

  // Fetch exercises from best available canonical WorkoutPlan if the passed workout has none
  const initSession = async () => {
    const workoutExercises = workoutContext?.exercises || [];
    let resolvedWorkout = workoutContext;

    if (workoutExercises.length === 0) {
      const date = workoutContext?.date || getTodayISODate();
      let planCandidates = [];

      if (workoutContext?.id) {
        const exactPlans = await backend.entities.WorkoutPlan.filter({ id: workoutContext.id }).catch(() => []);
        planCandidates = planCandidates.concat(exactPlans);
      }

      if (workoutContext?.source_plan_id && workoutContext?.generation_batch_id) {
        const linkedPlans = await backend.entities.WorkoutPlan.filter({
          date,
          source_plan_id: workoutContext.source_plan_id,
          generation_batch_id: workoutContext.generation_batch_id,
        }).catch(() => []);
        planCandidates = planCandidates.concat(linkedPlans);
      }

      if (workoutContext?.source_plan_id) {
        const sourceLinkedPlans = await backend.entities.WorkoutPlan.filter({
          date,
          source_plan_id: workoutContext.source_plan_id,
        }).catch(() => []);
        planCandidates = planCandidates.concat(sourceLinkedPlans);
      }

      const datePlans = await backend.entities.WorkoutPlan.filter({ date }).catch(() => []);
      planCandidates = planCandidates.concat(datePlans);

      const richPlan = chooseBestWorkoutPlan(planCandidates, workoutContext);

      if (richPlan?.exercises?.length > 0) {
        setExercises(richPlan.exercises);
        resolvedWorkout = {
          ...workoutContext,
          ...richPlan,
          source_plan_id: richPlan.source_plan_id || workoutContext?.source_plan_id || '',
          generation_batch_id: richPlan.generation_batch_id || workoutContext?.generation_batch_id || '',
          weekly_plan_id: richPlan.weekly_plan_id || workoutContext?.weekly_plan_id || '',
        };
      }
    }

    initLog(resolvedWorkout);
  };

  const initLog = async (sourceWorkout = workoutContext) => {
    const now = new Date().toISOString();
    const today = (sourceWorkout?.date || workoutContext?.date || passedWorkout?.date || now.split('T')[0]);

    const workoutForLog = sourceWorkout || workoutContext || passedWorkout;

    if (passedLogId && passedStartedAt) {
      const exactLogs = await backend.entities.WorkoutLog.filter({ id: passedLogId }).catch(() => []);
      const exactLog = exactLogs[0] || null;

      if (exactLog) {
        if (exactLog.exercise_logs?.length > 0) {
          restoreProgress(exactLog);
        }

        setLogId(exactLog.id);
        setStartedAt(exactLog.started_at || passedStartedAt || now);
        setLoading(false);
        return;
      }
    }

    const existingLogs = await backend.entities.WorkoutLog.filter({
      date: today,
      status: 'in_progress',
    }).catch(() => []);

    const existingLog = chooseBestWorkoutLog(existingLogs, workoutForLog);

    if (existingLog) {
      setLogId(existingLog.id);
      setStartedAt(existingLog.started_at || null);
      restoreProgress(existingLog);
      setLoading(false);
      return;
    }

    const newLog = await backend.entities.WorkoutLog.create({
      date: today,
      workout_name: workoutForLog?.name || 'Workout',
      workout_plan_id: workoutForLog?.id || '',
      source_plan_id: workoutForLog?.source_plan_id || '',
      generation_batch_id: workoutForLog?.generation_batch_id || '',
      weekly_plan_id: workoutForLog?.weekly_plan_id || '',
      status: 'in_progress',
      started_at: now,
      timer_started_at: now,
      exercise_logs: [],
    }).catch(() => null);

    if (newLog) {
      setLogId(newLog.id);
      // Timing is tracked silently from session start (no visible timer).
      setStartedAt(now);
    }

    setLoading(false);
  };
  const restoreProgress = (log) => {
    if (log.exercise_logs && log.exercise_logs.length > 0) {
      // Restore completedSets and weights from saved exercise_logs
      const restoredSets = {};
      const restoredWeights = {};
      log.exercise_logs.forEach(exLog => {
        const { exIdx, completedSetIndices, weight } = exLog;
        if (Array.isArray(completedSetIndices)) {
          completedSetIndices.forEach(si => { restoredSets[`${exIdx}-${si}`] = true; });
        }
        if (weight) restoredWeights[exIdx] = weight;
      });
      setCompletedSets(restoredSets);
      setWeights(restoredWeights);
      // Restore current exercise index
      if (typeof log.exercises_completed === 'number') {
        setCurrentExIdx(Math.min(log.exercises_completed, (passedWorkout?.exercises?.length || 1) - 1));
      }
    }
    if (log.user_notes) setNotes(log.user_notes);
    if (log.skipped_exercises) setSkippedExercises(log.skipped_exercises);
  };

  const buildExerciseLogs = useCallback(() => {
    return exercises.map((ex, exIdx) => {
      const completedSetIndices = Array.from({ length: ex.sets || 0 }, (_, si) => si).filter(si => completedSets[`${exIdx}-${si}`]);
      const repTarget = parseRepTarget(ex.reps);
      const defaultReps = repTarget.midpoint || 0;
      const reps = repsOverrides[exIdx] !== undefined ? repsOverrides[exIdx] : defaultReps;
      return { exIdx, name: ex.name, completedSetIndices, weight: weights[exIdx] || 0, reps };
    });
  }, [exercises, completedSets, weights, repsOverrides]);

  const saveProgress = useCallback(async (overrides = {}) => {
    if (!logId) return;
    const totalSets = exercises.reduce((s, ex) => s + (ex.sets || 0), 0);
    const doneSets = Object.values(completedSets).filter(Boolean).length;
    await backend.entities.WorkoutLog.update(logId, {
      sets_completed: doneSets,
      exercises_completed: currentExIdx,
      user_notes: notes,
      exercise_logs: buildExerciseLogs(),
      skipped_exercises: skippedExercises,
      ...overrides,
    }).catch(() => {});
  }, [logId, completedSets, currentExIdx, notes, exercises, buildExerciseLogs, skippedExercises]);

  const handleCompleteSet = (exIdx, setIdx) => {
    const key = `${exIdx}-${setIdx}`;
    setCompletedSets(prev => ({ ...prev, [key]: !prev[key] }));
  };

  // Save whenever completedSets/weights/notes change (debounced)
  const saveTimer = useRef(null);
  useEffect(() => {
    if (!logId || loading) return;
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => saveProgress(), 800);
    return () => clearTimeout(saveTimer.current);
  }, [completedSets, weights, repsOverrides, notes, currentExIdx]);

  const handleWeightChange = (exIdx, val) => {
    setWeights(w => ({ ...w, [exIdx]: val }));
  };

  const handleRepsChange = (exIdx, val) => {
    setRepsOverrides(r => ({ ...r, [exIdx]: Math.max(1, val) }));
  };

  const goToExercise = (idx) => {
    const clamped = Math.max(0, Math.min(exercises.length - 1, idx));
    setCurrentExIdx(clamped);
    saveProgress({ exercises_completed: clamped });
  };

  const handleAddCustomExercise = () => {
    if (!customForm.name.trim()) return;
    const newEx = {
      name: customForm.name.trim(),
      sets: parseInt(customForm.sets) || 3,
      reps: parseInt(customForm.reps) || 10,
      muscles: customForm.muscles.trim(),
      notes: customForm.notes.trim(),
      rest: '90 sec',
      custom: true,
    };
    setExercises(prev => [...prev, newEx]);
    setCustomForm({ name: '', sets: '3', reps: '10', muscles: '', notes: '' });
    setShowAddCustom(false);
    // Navigate to the newly added exercise
    setTimeout(() => setCurrentExIdx(exercises.length), 50);
  };

  const handleSkip = () => {
    setSkippedExercises(prev => [...prev, exercises[currentExIdx]?.name]);
    if (currentExIdx < exercises.length - 1) goToExercise(currentExIdx + 1);
    else handleFinishIntent();
  };

  const handleFinishIntent = async () => {
    await saveProgress();
    setShowCheckIn(true);
  };

  // Swipe handling
  const handleTouchStart = (e) => { touchStartX.current = e.touches[0].clientX; };
  const handleTouchEnd = (e) => {
    if (touchStartX.current === null) return;
    const diff = touchStartX.current - e.changedTouches[0].clientX;
    if (Math.abs(diff) > 60) {
      if (diff > 0 && currentExIdx < exercises.length - 1) goToExercise(currentExIdx + 1);
      else if (diff < 0 && currentExIdx > 0) goToExercise(currentExIdx - 1);
    }
    touchStartX.current = null;
  };

  const totalSets = exercises.reduce((s, ex) => s + (ex.sets || 0), 0);
  const doneSets = Object.values(completedSets).filter(Boolean).length;
  const progress = totalSets > 0 ? doneSets / totalSets : 0;

  const handleCheckInDone = async (checkInData) => {
    const now = new Date().toISOString();
    const weight = await loadUserWeightKg();

    // Completed work drives both duration and calories. PER_SET_MIN ~= work + avg rest.
    const PER_SET_MIN = 3;
    const SESSION_CEILING_MIN = 120;
    const skipped = new Set(skippedExercises);
    const engagedPlannedSets = exercises
      .filter(ex => !skipped.has(ex.name))
      .reduce((s, ex) => s + (ex.sets || 0), 0);
    const workSets = doneSets > 0 ? doneSets : engagedPlannedSets;
    const workMinutes = workSets * PER_SET_MIN;
    const rawWallMin = startedAt ? (Date.now() - new Date(startedAt).getTime()) / 60000 : 0;
    // Stored/displayed duration = REAL elapsed, capped at 1.5x the work estimate (floor 5)
    // and a hard ceiling, so a session left open can't balloon the minutes or calories.
    const durationCapMin = Math.min(Math.max(workMinutes * 1.5, 5), SESSION_CEILING_MIN);
    const durationMinutes = Math.round(Math.min(rawWallMin, durationCapMin));
    // Calories weight completed work (70%) over the capped time (30%).
    const effortMinutes = 0.7 * workMinutes + 0.3 * durationMinutes;
    const intensityMultiplier = { Easy: 4, Moderate: 6, Hard: 8, 'Very hard': 10, 'Max effort': 12 }[checkInData.exertionLevel] || 6;
    const estimatedCalories = Math.round(weight * (effortMinutes / 60) * intensityMultiplier);

    const logUpdate = {
      status: 'completed',
      completed_at: now,
      duration_minutes: durationMinutes,
      sets_completed: doneSets,
      exercises_completed: exercises.length - skippedExercises.length,
      skipped_exercises: skippedExercises,
      user_notes: notes,
      session_rpe: checkInData.rpe,
      exertion_level: checkInData.exertionLevel,
      post_workout_feeling: checkInData.feeling,
      performance_rating: checkInData.performance,
      pain_flag: checkInData.pain,
      pain_notes: checkInData.painNotes || '',
      estimated_calories_burned: estimatedCalories,
      rating: Math.round(checkInData.rpe / 2),
      exercise_logs: buildExerciseLogs(),
    };

    if (logId) await backend.entities.WorkoutLog.update(logId, logUpdate).catch(() => {});

    // Update the DailyLog linked to this canonical workout plan when available.
    const today = now.split('T')[0];
    const dailyLogData = {
      workout_done: true,
      workout_duration_min: durationMinutes,
      workout_type: workoutContext?.name || passedWorkout?.name || 'Workout',
      calories_burned: estimatedCalories,
    };

    const linkedDailyLog = await loadLinkedDailyLogForWorkout(today, workoutContext);

    if (linkedDailyLog?.id) {
      await backend.entities.DailyLog.update(linkedDailyLog.id, dailyLogData).catch(() => {});
    } else {
      await backend.entities.DailyLog.create({
        date: today,
        source_plan_id: workoutContext?.source_plan_id || '',
        generation_batch_id: workoutContext?.generation_batch_id || '',
        weekly_plan_id: workoutContext?.weekly_plan_id || '',
        ...dailyLogData,
      }).catch(() => {});
    }

    // Refresh dynamic readiness score based on workout completion + feeling
    refreshDynamicReadiness(today).catch(() => {});

    setSummaryData({ ...logUpdate, workout: workoutContext || passedWorkout || { name: logUpdate.workout_name }, estimatedCalories });
    setShowCheckIn(false);
    setShowSummary(true);
  };

  // Loading state
  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ background: '#0f1010' }}>
        <div className="text-center">
          <div className="w-12 h-12 border-2 rounded-full animate-spin mx-auto mb-4" style={{ borderColor: 'rgba(200,224,0,0.2)', borderTopColor: ACCENT }} />
          <p className="text-sm" style={{ color: '#5d635d' }}>Loading workout…</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex flex-col overflow-x-hidden max-w-md mx-auto w-full" style={{ background: '#0f1010', color: '#ffffff' }}>
      {/* ADD CUSTOM EXERCISE MODAL */}
      <AnimatePresence>
        {showAddCustom && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 flex items-end justify-center"
            style={{ background: 'rgba(0,0,0,0.7)' }}
            onClick={() => setShowAddCustom(false)}>
            <motion.div
              initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
              transition={{ type: 'spring', damping: 26, stiffness: 320 }}
              className="w-full max-w-lg rounded-t-3xl p-6 pb-10"
              style={{ background: '#1a1d1a', border: '1px solid rgba(255,255,255,0.08)' }}
              onClick={e => e.stopPropagation()}>
              <div className="w-10 h-1 rounded-full mx-auto mb-5" style={{ background: 'rgba(255,255,255,0.15)' }} />
              <h3 className="text-base font-bold mb-5" style={{ color: '#ffffff' }}>Add Custom Exercise</h3>
              <div className="space-y-3">
                <input
                  value={customForm.name}
                  onChange={e => setCustomForm(f => ({ ...f, name: e.target.value }))}
                  placeholder="Exercise name *"
                  autoFocus
                  className="w-full px-4 py-3 rounded-xl text-sm outline-none"
                  style={{ background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)', color: '#ffffff' }}
                />
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <p className="text-[10px] font-semibold mb-1.5 uppercase tracking-widest" style={{ color: '#4a4f4a' }}>Sets</p>
                    <input type="number" value={customForm.sets}
                      onChange={e => setCustomForm(f => ({ ...f, sets: e.target.value }))}
                      className="w-full px-4 py-3 rounded-xl text-sm outline-none text-center font-bold"
                      style={{ background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)', color: '#ffffff' }} />
                  </div>
                  <div>
                    <p className="text-[10px] font-semibold mb-1.5 uppercase tracking-widest" style={{ color: '#4a4f4a' }}>Reps</p>
                    <input type="number" value={customForm.reps}
                      onChange={e => setCustomForm(f => ({ ...f, reps: e.target.value }))}
                      className="w-full px-4 py-3 rounded-xl text-sm outline-none text-center font-bold"
                      style={{ background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)', color: '#ffffff' }} />
                  </div>
                </div>
                <input
                  value={customForm.muscles}
                  onChange={e => setCustomForm(f => ({ ...f, muscles: e.target.value }))}
                  placeholder="Muscles targeted (optional)"
                  className="w-full px-4 py-3 rounded-xl text-sm outline-none"
                  style={{ background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)', color: '#ffffff' }}
                />
                <input
                  value={customForm.notes}
                  onChange={e => setCustomForm(f => ({ ...f, notes: e.target.value }))}
                  placeholder="Notes / cues (optional)"
                  className="w-full px-4 py-3 rounded-xl text-sm outline-none"
                  style={{ background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)', color: '#ffffff' }}
                />
              </div>
              <div className="flex gap-3 mt-5">
                <button onClick={() => setShowAddCustom(false)}
                  className="flex-1 py-3.5 rounded-2xl text-sm font-semibold"
                  style={{ background: 'rgba(255,255,255,0.07)', color: '#91968e' }}>
                  Cancel
                </button>
                <button onClick={handleAddCustomExercise} disabled={!customForm.name.trim()}
                  className="flex-1 py-3.5 rounded-2xl text-sm font-bold"
                  style={{ background: customForm.name.trim() ? ACCENT : 'rgba(200,224,0,0.3)', color: '#141613' }}>
                  Add Exercise
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* POST-WORKOUT CHECK-IN */}
      <AnimatePresence>
        {showCheckIn && (
          <PostWorkoutCheckIn
            onDone={handleCheckInDone}
            onBack={() => setShowCheckIn(false)}
          />
        )}
      </AnimatePresence>

      {/* SUMMARY */}
      <AnimatePresence>
        {showSummary && summaryData && (
          <WorkoutSummary
            data={summaryData}
            onDone={() => navigate('/workouts')}
          />
        )}
      </AnimatePresence>

      {/* If summary needed but no data, show fallback */}
      {showSummary && !summaryData && (
        <div className="min-h-screen flex flex-col items-center justify-center px-6" style={{ background: '#0f1010' }}>
          <p className="text-lg font-bold mb-2" style={{ color: '#ffffff' }}>Session Summary</p>
          <p className="text-sm mb-8" style={{ color: '#5d635d' }}>No summary data available for this session.</p>
          <button onClick={() => navigate('/workouts')} className="px-8 py-4 rounded-2xl font-bold" style={{ background: ACCENT, color: '#141613' }}>
            Back to Workouts
          </button>
        </div>
      )}

      {!showSummary && (
        <>
          {/* TOP BAR */}
          <div className="flex items-center gap-3 px-4 pt-14 pb-4 flex-shrink-0" style={{ borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
            <button onClick={() => navigate('/workouts')} aria-label="Close workout"
              className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(255,255,255,0.07)' }}>
              <X size={22} style={{ color: '#c4c9c0' }} />
            </button>
            <p className="flex-1 text-base font-bold leading-snug"
              style={{ color: '#ffffff', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
              {passedWorkout?.name || 'Workout'}
            </p>
          </div>

          {/* PROGRESS BAR */}
          <div className="h-1 flex-shrink-0" style={{ background: 'rgba(255,255,255,0.06)' }}>
            <motion.div className="h-full" style={{ background: ACCENT }} animate={{ width: `${progress * 100}%` }} transition={{ duration: 0.4 }} />
          </div>

          {/* EXERCISE NAV BAR */}
          <div className="flex items-center justify-between px-5 py-3 flex-shrink-0">
            <button onClick={() => goToExercise(currentExIdx - 1)} disabled={currentExIdx === 0}
              className="w-10 h-10 rounded-xl flex items-center justify-center disabled:opacity-20 transition-opacity"
              style={{ background: 'rgba(255,255,255,0.07)' }}>
              <ChevronLeft size={16} style={{ color: '#91968e' }} />
            </button>

            <div className="flex flex-col items-center gap-1.5">
              <p className="text-xs font-semibold" style={{ color: '#91968e' }}>
                Exercise {currentExIdx + 1} of {exercises.length}
              </p>
              {/* Dot indicators */}
              <div className="flex gap-1.5">
                {exercises.map((_, i) => (
                  <button key={i} onClick={() => goToExercise(i)}
                    className="rounded-full transition-all"
                    style={{
                      width: i === currentExIdx ? 16 : 6,
                      height: 6,
                      background: i === currentExIdx ? ACCENT : 'rgba(255,255,255,0.15)',
                    }} />
                ))}
              </div>
            </div>

            <button onClick={() => goToExercise(currentExIdx + 1)} disabled={currentExIdx >= exercises.length - 1}
              className="w-10 h-10 rounded-xl flex items-center justify-center disabled:opacity-20 transition-opacity"
              style={{ background: 'rgba(255,255,255,0.07)' }}>
              <ChevronRight size={16} style={{ color: '#91968e' }} />
            </button>
          </div>

          {/* SWIPEABLE EXERCISE AREA */}
          <div
            className="flex-1 overflow-hidden relative w-full"
            onTouchStart={handleTouchStart}
            onTouchEnd={handleTouchEnd}
          >
            <AnimatePresence mode="wait">
              {exercises.length > 0 ? (
                <motion.div
                   key={currentExIdx}
                   initial={{ opacity: 0, x: 40 }}
                   animate={{ opacity: 1, x: 0 }}
                   exit={{ opacity: 0, x: -40 }}
                   transition={{ duration: 0.22 }}
                   className="h-full overflow-y-auto overflow-x-hidden px-3 pt-2 box-border"
                   style={{ paddingBottom: 'calc(env(safe-area-inset-bottom) + 1.5rem)' }}
                 >
                  {/* Main exercise card */}
                  <div className="rounded-3xl p-4 mb-4 overflow-hidden w-full" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.08)' }}>
                    <ExerciseCard
                      ex={exercises[currentExIdx]}
                      exIdx={currentExIdx}
                      totalExercises={exercises.length}
                      completedSets={completedSets}
                      weights={weights}
                      repsOverrides={repsOverrides}
                      onCompleteSet={handleCompleteSet}
                      onWeightChange={handleWeightChange}
                      onRepsChange={handleRepsChange}
                      unitSystem={unitSystem}
                    />
                  </div>

                  {/* Skip + Next row */}
                  <div className="flex gap-3 mb-4">
                    <button onClick={handleSkip}
                      className="flex-1 flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold"
                      style={{ background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.07)', color: '#5d635d' }}>
                      <SkipForward size={14} /> Skip Exercise
                    </button>
                    {currentExIdx < exercises.length - 1 && (
                      <button onClick={() => goToExercise(currentExIdx + 1)}
                        className="flex-1 flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-bold"
                        style={{ background: 'rgba(200,224,0,0.12)', border: '1px solid rgba(200,224,0,0.2)', color: ACCENT_DARK }}>
                        Next <ChevronRight size={14} />
                      </button>
                    )}
                  </div>

                  {/* Add Custom Exercise */}
                  <button onClick={() => setShowAddCustom(true)}
                    className="w-full flex items-center justify-center gap-2 py-3 rounded-2xl text-sm font-semibold mb-4"
                    style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.07)', color: '#5d635d' }}>
                    <PlusCircle size={14} /> Add Custom Exercise
                  </button>

                  {/* Next up preview */}
                  {exercises[currentExIdx + 1] && (
                    <div className="px-4 py-3 rounded-2xl mb-4" style={{ background: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.05)' }}>
                      <p className="text-[10px] uppercase tracking-widest mb-1" style={{ color: '#4a4f4a' }}>Up next</p>
                      <p className="text-sm font-semibold" style={{ color: '#91968e' }}>{exercises[currentExIdx + 1].name}</p>
                      <p className="text-xs" style={{ color: '#3a3f3a' }}>{exercises[currentExIdx + 1].sets} × {exercises[currentExIdx + 1].reps}</p>
                    </div>
                  )}

                  {/* Session Notes */}
                  <div className="rounded-2xl p-4 mb-4" style={{ background: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.05)' }}>
                    <p className="text-[10px] uppercase tracking-widest mb-2" style={{ color: '#4a4f4a' }}>Session Notes</p>
                    <textarea
                      value={notes}
                      onChange={e => setNotes(e.target.value)}
                      placeholder="PRs, feelings, adjustments..."
                      rows={2}
                      className="w-full bg-transparent outline-none resize-none text-sm"
                      style={{ color: '#91968e', caretColor: ACCENT }}
                    />
                  </div>

                  {/* Finish button */}
                  <motion.button whileTap={{ scale: 0.97 }} onClick={handleFinishIntent}
                    className="w-full py-5 rounded-2xl font-black text-base flex items-center justify-center gap-2"
                    style={{ background: ACCENT, color: '#141613' }}>
                    <Flag size={16} /> Finish Workout
                  </motion.button>
                </motion.div>
              ) : (
                /* No exercises — friendly empty state */
                <div className="flex flex-col items-center justify-center h-full px-6 text-center">
                  <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5" style={{ background: 'rgba(200,224,0,0.08)', border: '1px solid rgba(200,224,0,0.15)' }}>
                    <Flag size={24} style={{ color: ACCENT_DARK }} />
                  </div>
                  <p className="text-lg font-bold mb-2" style={{ color: '#ffffff' }}>Workout not ready yet</p>
                  <p className="text-sm mb-8 max-w-xs leading-relaxed" style={{ color: '#5d635d' }}>
                    This workout summary hasn't been converted into exercises yet. Generate your full plan from the Train page to get specific exercises.
                  </p>
                  <button onClick={() => navigate('/workouts')} className="px-8 py-4 rounded-2xl font-bold" style={{ background: ACCENT, color: '#141613' }}>
                    Back to Workouts
                  </button>
                </div>
              )}
            </AnimatePresence>
          </div>
        </>
      )}
    </div>
  );
}