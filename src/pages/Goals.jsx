import { useState, useEffect } from 'react';
import { usePageLayout } from '@/components/customize/usePageLayout';
import { useNavigate } from 'react-router-dom';

const PAGE_KEY = 'goals';
import { motion, AnimatePresence } from 'framer-motion';
import { Plus, Trophy, X, Pencil, Loader2, BarChart2, ChevronLeft } from 'lucide-react';
import confetti from 'canvas-confetti';
import { createGoal, updateGoal, loadActiveGoals, getTodayISODate } from '@/lib/personalizationSync';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const goalTemplates = [
  { title: 'Walk 10k steps daily', category: 'fitness', target_value: 10000, unit: 'steps', emoji: '🚶' },
  { title: 'Sleep 8 hours per night', category: 'sleep', target_value: 8, unit: 'hours', emoji: '🌙' },
  { title: 'Lose 5kg body weight', category: 'body', target_value: 5, unit: 'kg', emoji: '⚖️' },
  { title: 'Train 3x per week', category: 'fitness', target_value: 12, unit: 'sessions', emoji: '🏋️' },
  { title: 'Drink 2.5L water daily', category: 'habit', target_value: 2.5, unit: 'liters', emoji: '💧' },
  { title: 'Improve recovery score to 85', category: 'performance', target_value: 85, unit: 'score', emoji: '⚡' },
];

function LogProgressModal({ goal, onClose, onSave }) {
  const [mode, setMode] = useState('set');
  const [inputVal, setInputVal] = useState('');

  const handleSave = () => {
    const num = parseFloat(inputVal);
    if (isNaN(num)) return;
    const newVal = mode === 'set'
      ? Math.min(num, goal.target_value)
      : Math.min((goal.current_value || 0) + num, goal.target_value);
    onSave(newVal);
    onClose();
  };

  const willComplete = () => {
    const num = parseFloat(inputVal);
    if (isNaN(num)) return false;
    const newVal = mode === 'set' ? num : (goal.current_value || 0) + num;
    return newVal >= goal.target_value;
  };

  return (
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end"
      style={{ background: 'rgba(20,22,19,0.4)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 25, stiffness: 300 }}
        className="w-full max-w-md mx-auto rounded-t-3xl p-6 border-t border-l border-r"
        style={{ background: '#fbf8f1', borderColor: '#e8e1d4' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-12 h-1 rounded-full mx-auto mb-5" style={{ background: '#d9d1c2' }} />

        <div className="flex items-center gap-3 mb-5">
          <div className="w-11 h-11 rounded-2xl flex items-center justify-center text-xl flex-shrink-0" style={{ background: 'rgba(200,224,0,0.12)' }}>
            {goal.emoji || '🎯'}
          </div>
          <div>
            <p className="text-sm font-semibold leading-tight" style={{ color: '#141613' }}>{goal.title}</p>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
              Current: <span style={{ color: ACCENT_DARK }}>{goal.current_value || 0} / {goal.target_value} {goal.unit}</span>
            </p>
          </div>
        </div>

        <div className="flex gap-2 p-1 rounded-2xl mb-4 border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
          {[{ key: 'set', label: 'Set exact value' }, { key: 'add', label: 'Add to current' }].map(m => (
            <button key={m.key} onClick={() => { setMode(m.key); setInputVal(''); }}
              className="flex-1 py-2 rounded-xl text-xs font-medium transition-all"
              style={{ background: mode === m.key ? '#ffffff' : 'transparent', color: mode === m.key ? '#141613' : '#91968e', border: mode === m.key ? '1px solid #e8e1d4' : '1px solid transparent' }}>
              {m.label}
            </button>
          ))}
        </div>

        <div className="relative mb-2">
          <input
            type="number"
            value={inputVal}
            onChange={e => setInputVal(e.target.value)}
            placeholder={mode === 'set' ? `Enter value (max ${goal.target_value})` : `Amount to add`}
            className="w-full px-4 py-4 rounded-2xl text-2xl font-bold outline-none border text-center"
            style={{ background: '#ffffff', borderColor: inputVal ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: '#141613' }}
            autoFocus
          />
          <span className="absolute right-4 top-1/2 -translate-y-1/2 text-sm" style={{ color: '#91968e' }}>{goal.unit}</span>
        </div>

        {inputVal && !isNaN(parseFloat(inputVal)) && (
          <motion.div initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }}
            className="flex items-center justify-center gap-2 mb-4 py-2 rounded-xl"
            style={{ background: 'rgba(200,224,0,0.08)' }}>
            <span className="text-xs" style={{ color: '#91968e' }}>New value:</span>
            <span className="text-sm font-bold" style={{ color: ACCENT_DARK }}>
              {mode === 'set' ? Math.min(parseFloat(inputVal), goal.target_value) : Math.min((goal.current_value || 0) + parseFloat(inputVal), goal.target_value)} {goal.unit}
            </span>
            {willComplete() && <span className="text-xs font-semibold ml-1" style={{ color: '#4a7c59' }}>🏆 Goal complete!</span>}
          </motion.div>
        )}

        <button onClick={handleSave} disabled={!inputVal || isNaN(parseFloat(inputVal))}
          className="w-full py-4 rounded-2xl text-sm font-bold disabled:opacity-40 transition-all"
          style={{ background: ACCENT, color: '#141613' }}>
          Save Progress
        </button>
      </motion.div>
    </motion.div>
  );
}

function GoalCard({ goal, onLogProgress }) {
  const pct = goal.current_value && goal.target_value ? (goal.current_value / goal.target_value) : 0;
  const isComplete = pct >= 1;

  return (
    <motion.div
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      className="p-5 rounded-3xl border"
      style={{ background: '#ffffff', borderColor: isComplete ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}
    >
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-start gap-3">
          <div className="w-11 h-11 rounded-2xl flex items-center justify-center text-xl" style={{ background: 'rgba(200,224,0,0.1)' }}>
            {goal.emoji || '🎯'}
          </div>
          <div>
            <h3 className="text-sm font-semibold leading-tight" style={{ color: '#141613' }}>{goal.title}</h3>
            <span className="text-[10px] px-2 py-0.5 rounded-full mt-1 inline-block font-semibold" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
              {goal.category}
            </span>
          </div>
        </div>
        {isComplete && (
          <div className="w-7 h-7 rounded-full flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
            <Trophy size={14} style={{ color: ACCENT_DARK }} />
          </div>
        )}
      </div>

      <div className="mb-3">
        <div className="flex justify-between mb-1.5">
          <span className="text-xs" style={{ color: '#91968e' }}>Progress</span>
          <span className="text-xs font-semibold" style={{ color: ACCENT_DARK }}>
            {goal.current_value || 0} / {goal.target_value} {goal.unit}
          </span>
        </div>
        <div className="h-2 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div
            className="h-full rounded-full"
            style={{ background: ACCENT }}
            initial={{ width: 0 }}
            animate={{ width: `${Math.min(pct * 100, 100)}%` }}
            transition={{ duration: 1, ease: [0.4, 0, 0.2, 1] }}
          />
        </div>
        <div className="flex justify-between mt-1">
          <span className="text-[10px]" style={{ color: '#91968e' }}>{Math.round(pct * 100)}% complete</span>
          {goal.target_date && (
            <span className="text-[10px]" style={{ color: '#91968e' }}>
              Due {new Date(goal.target_date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
            </span>
          )}
        </div>
      </div>

      <div className="flex gap-2">
        <button
          onClick={() => onLogProgress(goal)}
          className="flex-1 py-2.5 rounded-xl text-xs font-semibold flex items-center justify-center gap-1.5 transition-all active:scale-[0.98] border"
          style={{ background: 'rgba(200,224,0,0.08)', color: ACCENT_DARK, borderColor: 'rgba(200,224,0,0.25)' }}
        >
          {isComplete ? '🏆 Complete!' : (<><Pencil size={11} /> Log Progress</>)}
        </button>
        <a href={`/progress?goalId=${goal.id}`}
          className="px-3 py-2.5 rounded-xl text-xs font-semibold flex items-center gap-1 border"
          style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#5d635d' }}>
          <BarChart2 size={11} /> Trend
        </a>
      </div>
    </motion.div>
  );
}

function AddGoalModal({ onClose, onAdd }) {
  const [selected, setSelected] = useState(null);
  const [custom, setCustom] = useState({ title: '', category: 'fitness', target_value: '', unit: '', target_date: '' });
  const [step, setStep] = useState('template');

  const handleAdd = () => {
    const goal = selected || { ...custom, target_value: Number(custom.target_value), current_value: 0, emoji: '🎯' };
    onAdd(goal);
    onClose();
  };

  const inputStyle = { background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' };

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end"
      style={{ background: 'rgba(20,22,19,0.4)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 25, stiffness: 300 }}
        className="w-full max-w-md mx-auto rounded-t-3xl p-6 border-t border-l border-r max-h-[85vh] overflow-y-auto"
        style={{ background: '#fbf8f1', borderColor: '#e8e1d4' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-12 h-1 rounded-full mx-auto mb-6" style={{ background: '#d9d1c2' }} />
        <div className="flex items-center justify-between mb-6">
          <h3 className="text-lg font-bold" style={{ color: '#141613' }}>New Goal</h3>
          <button onClick={onClose} className="w-8 h-8 rounded-full flex items-center justify-center border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
            <X size={16} style={{ color: '#5d635d' }} />
          </button>
        </div>

        <div className="flex gap-2 p-1 rounded-2xl mb-5 border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
          {['template', 'custom'].map(s => (
            <button key={s} onClick={() => setStep(s)}
              className="flex-1 py-2 rounded-xl text-xs font-medium transition-all capitalize"
              style={{ background: step === s ? '#ffffff' : 'transparent', color: step === s ? '#141613' : '#91968e', border: step === s ? '1px solid #e8e1d4' : '1px solid transparent' }}>
              {s === 'template' ? 'Quick Templates' : 'Custom Goal'}
            </button>
          ))}
        </div>

        {step === 'template' ? (
          <div className="grid grid-cols-2 gap-3 mb-6">
            {goalTemplates.map((t, i) => (
              <button key={i} onClick={() => setSelected(t)}
                className="p-4 rounded-2xl text-left transition-all border"
                style={{
                  background: selected === t ? 'rgba(200,224,0,0.08)' : '#ffffff',
                  borderColor: selected === t ? 'rgba(200,224,0,0.35)' : '#e8e1d4',
                }}>
                <span className="text-xl block mb-2">{t.emoji}</span>
                <p className="text-xs font-medium leading-tight" style={{ color: '#141613' }}>{t.title}</p>
                <p className="text-[10px] mt-1" style={{ color: '#91968e' }}>{t.target_value} {t.unit}</p>
              </button>
            ))}
          </div>
        ) : (
          <div className="space-y-4 mb-6">
            <input value={custom.title} onChange={e => setCustom(p => ({ ...p, title: e.target.value }))}
              placeholder="Goal title..." className="w-full px-4 py-3 rounded-xl text-sm outline-none border" style={inputStyle} />
            <div className="grid grid-cols-2 gap-3">
              <input type="number" value={custom.target_value} onChange={e => setCustom(p => ({ ...p, target_value: e.target.value }))}
                placeholder="Target value" className="px-4 py-3 rounded-xl text-sm outline-none border" style={inputStyle} />
              <input value={custom.unit} onChange={e => setCustom(p => ({ ...p, unit: e.target.value }))}
                placeholder="Unit (kg, hrs...)" className="px-4 py-3 rounded-xl text-sm outline-none border" style={inputStyle} />
            </div>
            <input type="date" value={custom.target_date} onChange={e => setCustom(p => ({ ...p, target_date: e.target.value }))}
              className="w-full px-4 py-3 rounded-xl text-sm outline-none border" style={{ ...inputStyle, colorScheme: 'light' }} />
          </div>
        )}

        <button onClick={handleAdd} disabled={step === 'template' ? !selected : !custom.title}
          className="w-full py-4 rounded-2xl text-sm font-bold disabled:opacity-40 transition-all"
          style={{ background: ACCENT, color: '#141613' }}>
          Add Goal
        </button>
      </motion.div>
    </motion.div>
  );
}

export default function Goals() {
  const navigate = useNavigate();
  const [goals, setGoals] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAdd, setShowAdd] = useState(false);
  const [loggingGoal, setLoggingGoal] = useState(null);
  const layout = usePageLayout(PAGE_KEY); // reserved for future widget customization

  useEffect(() => {
    loadActiveGoals().then(entityGoals => {
      if (entityGoals.length > 0) {
        setGoals(entityGoals);
      }
      setLoading(false);
    }).catch(() => setLoading(false));
  }, []);

  const handleAdd = async (newGoal) => {
    const saved = await createGoal({ ...newGoal, current_value: 0 });
    if (saved) {
      setGoals(prev => [...prev, saved]);
    }
  };

  const handleSaveProgress = async (goalId, newVal) => {
    const goal = goals.find(g => g.id === goalId);
    const wasComplete = goal && goal.current_value >= goal.target_value;
    const nowComplete = newVal >= goal.target_value;
    if (!wasComplete && nowComplete) {
      confetti({ particleCount: 100, spread: 70, origin: { y: 0.6 }, colors: ['#c8e000', '#8ea400', '#d4ef1f'] });
    }
    setGoals(prev => prev.map(g => g.id === goalId ? { ...g, current_value: newVal, status: nowComplete ? 'completed' : 'active' } : g));
    await updateGoal(goalId, { current_value: newVal, status: nowComplete ? 'completed' : 'active' });
    // Write progress entry for trend tracking
    backend.entities.GoalProgressEntry.create({
      goal_id: goalId,
      date: getTodayISODate(),
      value: newVal,
      target_value_snapshot: goal?.target_value,
      source: 'manual',
    }).catch(() => {});
  };

  const overallPct = goals.length > 0
    ? Math.round(goals.reduce((a, g) => a + Math.min((g.current_value || 0) / g.target_value, 1), 0) / goals.length * 100)
    : 0;

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ background: '#f6f2e8' }}>
        <div className="flex flex-col items-center gap-3">
          <Loader2 size={20} className="animate-spin" style={{ color: '#8ea400' }} />
          <p className="text-xs" style={{ color: '#91968e' }}>Loading goals…</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pb-3 pt-safe-header" style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center gap-3 mb-3">
          <button onClick={() => navigate(-1)}
            className="w-8 h-8 rounded-xl flex items-center justify-center border flex-shrink-0"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ChevronLeft size={16} style={{ color: '#5d635d' }} />
          </button>
        </div>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Goals</h1>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{goals.length > 0 ? `${goals.length} active target${goals.length !== 1 ? 's' : ''}` : 'No goals yet'}</p>
          </div>
          <div className="flex items-center gap-2">
            <button onClick={() => navigate('/progress')}
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              <BarChart2 size={12} /> View Progress
            </button>
            <motion.button whileTap={{ scale: 0.9 }} onClick={() => setShowAdd(true)}
              className="w-9 h-9 rounded-xl flex items-center justify-center border"
              style={{ background: 'rgba(200,224,0,0.12)', borderColor: 'rgba(200,224,0,0.3)' }}>
              <Plus size={18} style={{ color: ACCENT_DARK }} />
            </motion.button>
          </div>
        </div>
      </div>

      <div className="px-5 pb-8 space-y-4 pt-5">
        {/* Summary bar */}
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
          className="p-4 rounded-2xl border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <div className="flex items-center gap-4">
            <div className="text-center">
              <div className="text-2xl font-black" style={{ color: ACCENT_DARK }}>{goals.length}</div>
              <div className="text-[10px]" style={{ color: '#91968e' }}>Active</div>
            </div>
            <div className="h-8 w-px" style={{ background: '#e8e1d4' }} />
            <div className="text-center">
              <div className="text-2xl font-black" style={{ color: '#4a7c59' }}>
                {goals.filter(g => (g.current_value || 0) >= g.target_value).length}
              </div>
              <div className="text-[10px]" style={{ color: '#91968e' }}>Complete</div>
            </div>
            <div className="h-8 w-px" style={{ background: '#e8e1d4' }} />
            <div className="flex-1">
              <div className="flex justify-between mb-1">
                <div className="text-xs" style={{ color: '#91968e' }}>Overall</div>
                <div className="text-xs font-semibold" style={{ color: ACCENT_DARK }}>{overallPct}%</div>
              </div>
              <div className="h-1.5 rounded-full" style={{ background: '#e8e1d4' }}>
                <motion.div className="h-full rounded-full" style={{ background: ACCENT }}
                  initial={{ width: 0 }} animate={{ width: `${overallPct}%` }} transition={{ duration: 1 }} />
              </div>
            </div>
          </div>
        </motion.div>

        {goals.length === 0 && (
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
            className="flex flex-col items-center py-16 text-center px-4">
            <div className="w-20 h-20 rounded-3xl flex items-center justify-center mb-6"
              style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
              <Trophy size={32} style={{ color: ACCENT_DARK }} />
            </div>
            <h2 className="text-xl font-black tracking-tight mb-2" style={{ color: '#141613' }}>No goals yet</h2>
            <p className="text-sm leading-relaxed max-w-xs mb-6" style={{ color: '#91968e' }}>
              Set a goal to track your progress toward it. Use a template to get started in seconds.
            </p>
            <button onClick={() => setShowAdd(true)}
              className="flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold"
              style={{ background: ACCENT, color: '#141613' }}>
              <Plus size={14} /> Add your first goal
            </button>
          </motion.div>
        )}

        {goals.map((goal) => (
          <GoalCard key={goal.id} goal={goal} onLogProgress={(g) => setLoggingGoal(g)} />
        ))}
      </div>

      <AnimatePresence>
        {showAdd && <AddGoalModal onClose={() => setShowAdd(false)} onAdd={handleAdd} />}
        {loggingGoal && (
          <LogProgressModal
            goal={loggingGoal}
            onClose={() => setLoggingGoal(null)}
            onSave={(newVal) => { handleSaveProgress(loggingGoal.id, newVal); setLoggingGoal(null); }}
          />
        )}

      </AnimatePresence>
    </div>
  );
}