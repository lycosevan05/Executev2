import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { Flame, Sparkles } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getUserAIContext } from '@/lib/aiContext';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function StatTile({ label, value, sub }) {
  return (
    <div className="rounded-2xl p-4 text-center" style={{ background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.07)' }}>
      <p className="text-2xl font-black" style={{ color: '#ffffff' }}>{value}</p>
      {sub && <p className="text-xs" style={{ color: ACCENT }}>{sub}</p>}
      <p className="text-[10px] uppercase tracking-widest mt-1" style={{ color: '#4a4f4a' }}>{label}</p>
    </div>
  );
}

function formatDuration(mins) {
  if (!mins) return '—';
  return `${mins}m`;
}

export default function WorkoutSummary({ data, onDone }) {
  const [aiRec, setAiRec] = useState('');
  const [loadingAi, setLoadingAi] = useState(true);

  const durationMins = data.duration_minutes || 0;
  const workout = data.workout || {};

  useEffect(() => { generateAiRec(); }, []);

  const generateAiRec = async () => {
    try {
      const ctx = await getUserAIContext().catch(() => '');
      const result = await backend.integrations.Core.InvokeLLM({
        prompt: `You are an elite sports scientist and recovery coach. A user just finished a workout. You have their full profile and training history. Give them recovery guidance so specific it could only apply to them.

Session just completed:
- Workout: ${workout.name || 'Unknown'}
- Duration: ${durationMins} minutes
- Exertion level: ${data.exertion_level || 'Moderate'}
- RPE: ${data.session_rpe || 7}/10
- How they feel post-session: ${data.post_workout_feeling || 'Good'}
- Performance vs expectation: ${data.performance_rating || 'As expected'}
- Pain flag: ${data.pain_flag || 'No'}
- Pain notes: ${data.pain_notes || 'None'}
- Session notes: ${data.user_notes || 'None'}

User context:
${ctx}

RULES:
- Keep it under 80 words total.
- Reference the specific workout they just did and their goal.
- Give an exact protein target and timing window for their post-workout nutrition (based on their body weight and goal).
- Tell them whether tomorrow should be full training, deload, or rest — and why, based on today's RPE and their recent session history.
- If pain was flagged as "Yes, concerning", tell them to consult a qualified professional before their next session.
- Never diagnose. Use "guidance", "recommendation", "consider".
- Sound like a coach who knows them, not a generic app message.`,
      });
      setAiRec(typeof result === 'string' ? result : result?.text || '');
    } catch {
      setAiRec('Great effort today. Prioritize protein and sleep to maximize recovery. If you felt any discomfort, rest and consult a qualified professional if it persists.');
    } finally {
      setLoadingAi(false);
    }
  };

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex flex-col overflow-y-auto" style={{ background: '#0f1010' }}>

      {/* Header */}
      <div className="px-6 pt-16 pb-6 text-center">
        <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ type: 'spring', damping: 14 }}
          className="w-20 h-20 rounded-full mx-auto mb-5 flex items-center justify-center"
          style={{ background: 'rgba(200,224,0,0.15)', border: '2px solid rgba(200,224,0,0.35)' }}>
          <span style={{ fontSize: 36 }}>🏆</span>
        </motion.div>
        <h1 className="text-2xl font-black" style={{ color: '#ffffff', letterSpacing: '-0.04em' }}>Session Complete</h1>
        <p className="text-sm mt-1" style={{ color: '#5d635d' }}>{workout.name || 'Workout'}</p>
      </div>

      <div className="px-6 pb-10 space-y-4">
        {/* Stats grid */}
        <div className="grid grid-cols-2 gap-3">
          <StatTile label="Duration" value={formatDuration(durationMins)} />
          <StatTile label="Sets Done" value={data.sets_completed || '—'} />
          <StatTile label="Exercises" value={data.exercises_completed || '—'} />
          <StatTile label="RPE" value={data.session_rpe ? `${data.session_rpe}/10` : '—'} />
        </div>

        {/* Calories */}
        <div className="flex items-center gap-4 rounded-2xl p-4" style={{ background: 'rgba(200,224,0,0.08)', border: '1px solid rgba(200,224,0,0.2)' }}>
          <div className="w-10 h-10 rounded-xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
            <Flame size={18} style={{ color: ACCENT }} />
          </div>
          <div>
            <p className="text-lg font-black" style={{ color: ACCENT }}>~{data.estimated_calories_burned || '—'} kcal</p>
            <p className="text-[10px]" style={{ color: '#5d635d' }}>Estimated based on duration, intensity & profile. Not exact.</p>
          </div>
        </div>

        {/* Feeling & performance */}
        <div className="rounded-2xl p-4" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)' }}>
          <div className="flex justify-between">
            <div>
              <p className="text-[10px] uppercase tracking-widest mb-1" style={{ color: '#4a4f4a' }}>How you felt</p>
              <p className="text-sm font-semibold" style={{ color: '#ffffff' }}>{data.post_workout_feeling || '—'}</p>
            </div>
            <div className="text-right">
              <p className="text-[10px] uppercase tracking-widest mb-1" style={{ color: '#4a4f4a' }}>Performance</p>
              <p className="text-sm font-semibold" style={{ color: '#ffffff' }}>{data.performance_rating || '—'}</p>
            </div>
          </div>
          {data.exertion_level && (
            <div className="mt-3 pt-3 border-t" style={{ borderColor: 'rgba(255,255,255,0.05)' }}>
              <p className="text-[10px] uppercase tracking-widest mb-1" style={{ color: '#4a4f4a' }}>Intensity</p>
              <p className="text-sm font-semibold" style={{ color: ACCENT }}>{data.exertion_level}</p>
            </div>
          )}
        </div>

        {/* Notes */}
        {(data.user_notes || data.checkInData?.notes) && (
          <div className="rounded-2xl p-4" style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)' }}>
            <p className="text-[10px] uppercase tracking-widest mb-2" style={{ color: '#4a4f4a' }}>Session Notes</p>
            <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>{data.user_notes || data.checkInData?.notes}</p>
          </div>
        )}

        {/* AI Recovery Rec */}
        <div className="rounded-2xl p-4" style={{ background: 'rgba(200,224,0,0.06)', border: '1px solid rgba(200,224,0,0.2)' }}>
          <div className="flex items-center gap-2 mb-2">
            <Sparkles size={12} style={{ color: ACCENT_DARK }} />
            <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>Recovery Guidance</p>
          </div>
          {loadingAi ? (
            <div className="flex items-center gap-2">
              <div className="w-3 h-3 rounded-full border-2 animate-spin" style={{ borderColor: ACCENT_DARK, borderTopColor: 'transparent' }} />
              <p className="text-xs" style={{ color: '#5d635d' }}>Generating recovery guidance…</p>
            </div>
          ) : (
            <p className="text-sm leading-relaxed" style={{ color: '#ffffff' }}>{aiRec}</p>
          )}
        </div>

        {/* Pain disclaimer */}
        {data.pain_flag && data.pain_flag !== 'No' && (
          <div className="rounded-2xl p-4" style={{ background: 'rgba(176,90,58,0.08)', border: '1px solid rgba(176,90,58,0.25)' }}>
            <p className="text-xs leading-relaxed" style={{ color: '#b05a3a' }}>
              You reported {data.pain_flag.toLowerCase()} discomfort. This is not medical advice. If pain persists or worsens, please consult a qualified healthcare professional before returning to intense training.
            </p>
          </div>
        )}

        <motion.button whileTap={{ scale: 0.97 }} onClick={onDone}
          className="w-full py-5 rounded-2xl font-black text-base"
          style={{ background: ACCENT, color: '#141613' }}>
          Done
        </motion.button>
      </div>
    </motion.div>
  );
}