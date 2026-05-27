import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Dumbbell, Play, RefreshCw, CheckCircle, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getTodayISODate } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const PLAN_LOCAL_KEY = 'execute_today_workout';

export default function WorkoutQuickLink() {
  const navigate = useNavigate();
  const [log, setLog] = useState(null);
  const [loading, setLoading] = useState(true);
  const [workout, setWorkout] = useState(null);

  const today = getTodayISODate();

  useEffect(() => {
    Promise.all([
      backend.entities.WorkoutLog.filter({ date: today }).catch(() => []),
      backend.entities.WorkoutPlan.filter({ date: today }).catch(() => []),
    ]).then(([logs, plans]) => {
      if (logs.length > 0) setLog(logs[0]);
      if (plans.length > 0) setWorkout(plans[0]);
    }).finally(() => setLoading(false));
  }, []);

  const isCompleted = log?.status === 'completed';
  const isInProgress = log?.status === 'in_progress';
  const hasWorkout = !!workout;

  const label = isCompleted
    ? 'View Summary'
    : isInProgress
    ? 'Resume Workout'
    : hasWorkout
    ? "Start Today's Workout"
    : "Generate Workout";

  const Icon = isCompleted ? CheckCircle : isInProgress ? RefreshCw : Play;

  const handleTap = () => {
    if (isCompleted && log) {
      navigate('/workout-session', {
        state: {
          workout: workout || { name: log.workout_name, exercises: [] },
          logId: log.id,
          startedAt: log.started_at,
          viewSummary: true,
          completedLogData: log,
        },
      });
      return;
    }
    if (workout) {
      navigate('/workout-session', {
        state: { workout, logId: log?.id || null, startedAt: log?.started_at || null },
      });
    } else {
      navigate('/plan?generate=true');
    }
  };

  return (
    <button
      onClick={handleTap}
      className="flex items-center justify-between p-4 rounded-xl border col-span-2 w-full"
      style={{ background: isCompleted ? 'rgba(200,224,0,0.06)' : '#1a1f1a', borderColor: isCompleted ? 'rgba(200,224,0,0.3)' : '#2a2f2a' }}
    >
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
          <Dumbbell size={14} style={{ color: ACCENT }} />
        </div>
        <div className="text-left">
          <p className="text-xs font-bold" style={{ color: isCompleted ? ACCENT_DARK : '#ffffff' }}>{label}</p>
          <p className="text-[10px]" style={{ color: '#5d635d' }}>
            {isCompleted ? 'Session complete ✓' : isInProgress ? 'In progress — tap to continue' : workout ? workout.name : 'No workout planned yet'}
          </p>
        </div>
      </div>
      {loading ? <Loader2 size={13} className="animate-spin" style={{ color: '#5d635d' }} /> : <Icon size={14} style={{ color: isCompleted ? ACCENT_DARK : '#91968e' }} />}
    </button>
  );
}