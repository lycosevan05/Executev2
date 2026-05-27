import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Dumbbell, Play, RefreshCw, CheckCircle, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';
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

  const canonical =
    safePlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
    safePlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
    safePlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
    safePlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial');
  if (canonical) return canonical;

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

export default function WorkoutHeroCard({ workout, generating, onGenerate }) {
  const navigate = useNavigate();
  const [workoutLog, setWorkoutLog] = useState(null);
  const [checkingLog, setCheckingLog] = useState(true);
  const [resolvedExercises, setResolvedExercises] = useState(workout?.exercises || []);

  const today = getTodayISODate();

  useEffect(() => {
    let cancelled = false;

    async function loadWorkoutState() {
      setCheckingLog(true);

      const date = workout?.date || today;

      try {
        const logQueries = [];

        if (workout?.id) {
          logQueries.push(
            backend.entities.WorkoutLog.filter({
              date,
              workout_plan_id: workout.id,
            }).catch(() => [])
          );
        }

        if (workout?.source_plan_id && workout?.generation_batch_id) {
          logQueries.push(
            backend.entities.WorkoutLog.filter({
              date,
              source_plan_id: workout.source_plan_id,
              generation_batch_id: workout.generation_batch_id,
            }).catch(() => [])
          );
        }

        logQueries.push(backend.entities.WorkoutLog.filter({ date }).catch(() => []));

        const logResults = await Promise.all(logQueries);
        const logs = logResults.flat();
        const bestLog = chooseBestWorkoutLog(logs, workout);

        if (!cancelled) {
          setWorkoutLog(bestLog || null);
        }

        if (!workout?.exercises?.length && date) {
          let planCandidates = [];

          if (workout?.id) {
            const exactPlans = await backend.entities.WorkoutPlan.filter({ id: workout.id }).catch(() => []);
            planCandidates = planCandidates.concat(exactPlans);
          }

          if (workout?.source_plan_id && workout?.generation_batch_id) {
            const linkedPlans = await backend.entities.WorkoutPlan.filter({
              date,
              source_plan_id: workout.source_plan_id,
              generation_batch_id: workout.generation_batch_id,
            }).catch(() => []);
            planCandidates = planCandidates.concat(linkedPlans);
          }

          const datePlans = await backend.entities.WorkoutPlan.filter({ date }).catch(() => []);
          planCandidates = planCandidates.concat(datePlans);

          const richPlan = chooseBestWorkoutPlan(planCandidates, workout);

          if (!cancelled) {
            setResolvedExercises(richPlan?.exercises?.length > 0 ? richPlan.exercises : []);
          }
        } else if (!cancelled) {
          setResolvedExercises(workout?.exercises || []);
        }
      } catch (err) {
        console.warn('[WorkoutHeroCard] Failed to load workout state', err);
      } finally {
        if (!cancelled) setCheckingLog(false);
      }
    }

    loadWorkoutState();

    return () => {
      cancelled = true;
    };
  }, [
    workout?.id,
    workout?.date,
    workout?.source_plan_id,
    workout?.generation_batch_id,
    workout?.exercises,
    today,
  ]);

  const isInProgress = workoutLog?.status === 'in_progress';
  const isCompleted = workoutLog?.status === 'completed';

  const handleStart = () => {
    const workoutWithExercises = { ...workout, exercises: resolvedExercises };
    if (isCompleted && workoutLog) {
      navigate('/workout-session', {
        state: {
          workout: workoutWithExercises || { name: workoutLog.workout_name, exercises: resolvedExercises },
          logId: workoutLog.id,
          startedAt: workoutLog.started_at,
          viewSummary: true,
          completedLogData: workoutLog,
        },
      });
      return;
    }
    navigate('/workout-session', {
      state: {
        workout: workoutWithExercises,
        logId: workoutLog?.id || null,
        startedAt: workoutLog?.started_at || null,
        sourcePlanId: workout?.source_plan_id || '',
        generationBatchId: workout?.generation_batch_id || '',
        weeklyPlanId: workout?.weekly_plan_id || '',
      },
    });
  };

  const ctaLabel = isCompleted ? 'View Session Summary' : isInProgress ? 'Resume Workout' : 'Start Workout';
  const CtaIcon = isCompleted ? CheckCircle : isInProgress ? RefreshCw : Play;

  const allExercises = resolvedExercises;

  return (
    <div className="rounded-3xl overflow-hidden" style={{ background: 'linear-gradient(145deg, #141613 0%, #1a1f1a 100%)', border: '1px solid rgba(200,224,0,0.18)' }}>
      <div className="p-5">
        {/* Header */}
        <div className="flex items-start justify-between mb-4">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <div className="w-6 h-6 rounded-lg flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
                <Dumbbell size={12} style={{ color: ACCENT }} />
              </div>
              <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>Today's Workout</span>
            </div>
            <h2 className="text-lg font-black" style={{ color: '#ffffff', letterSpacing: '-0.03em' }}>{workout?.name || workoutLog?.workout_name || 'No plan yet'}</h2>
            <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>
              {!workout && !workoutLog
                ? 'Build today\'s workout from your plan'
                : `${workout?.type ? workout.type + ' · ' : ''}${workout?.duration || ''}${workout?.intensity ? ' · ' + workout.intensity : ''}`}
            </p>
          </div>
          <button onClick={onGenerate} disabled={generating}
            className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(255,255,255,0.07)' }}>
            {generating ? <Loader2 size={13} className="animate-spin" style={{ color: '#5d635d' }} /> : <RefreshCw size={13} style={{ color: '#5d635d' }} />}
          </button>
        </div>

        {/* All exercises */}
        {allExercises.length > 0 ? (
          <div className="space-y-1.5 mb-4">
            {allExercises.map((ex, i) => (
              <div key={i} className="flex items-center justify-between px-3 py-2 rounded-xl" style={{ background: 'rgba(255,255,255,0.04)' }}>
                <div className="flex items-center gap-2">
                  <span className="w-4 h-4 rounded-md flex items-center justify-center text-[9px] font-bold" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{i + 1}</span>
                  <p className="text-xs font-medium" style={{ color: '#c8cac8' }}>{ex.name}</p>
                </div>
                <p className="text-[10px]" style={{ color: '#4a4f4a' }}>{ex.sets}×{ex.reps}</p>
              </div>
            ))}
          </div>
        ) : !checkingLog && workout ? (
          <div className="px-3 py-3 rounded-xl mb-4" style={{ background: 'rgba(255,255,255,0.04)' }}>
            <p className="text-xs" style={{ color: '#4a4f4a' }}>This workout is missing exercise details. Return to Workouts and build this session from your weekly overview.</p>
          </div>
        ) : null}

        {/* CTA */}
        {generating ? (
          <div className="w-full py-4 rounded-2xl flex items-center justify-center gap-2" style={{ background: 'rgba(200,224,0,0.08)' }}>
            <Loader2 size={13} className="animate-spin" style={{ color: ACCENT_DARK }} />
            <span className="text-sm font-semibold" style={{ color: ACCENT_DARK }}>Generating workout…</span>
          </div>
        ) : (
          <motion.button whileTap={{ scale: 0.97 }} onClick={handleStart}
            className="w-full py-4 rounded-2xl font-black text-sm flex items-center justify-center gap-2"
            style={{
              background: isCompleted ? 'rgba(200,224,0,0.12)' : ACCENT,
              color: isCompleted ? ACCENT_DARK : '#141613',
            }}>
            {checkingLog ? <Loader2 size={14} className="animate-spin" /> : <CtaIcon size={14} />}
            {ctaLabel}
          </motion.button>
        )}
      </div>
    </div>
  );
}