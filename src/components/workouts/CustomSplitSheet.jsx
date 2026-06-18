import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Plus, Trash2, ChevronDown, ChevronUp, Check, Dumbbell } from 'lucide-react';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const DAY_FULL = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

const QUICK_TYPES = ['Push', 'Pull', 'Legs', 'Upper', 'Lower', 'Full Body', 'Cardio', 'Core', 'Rest'];

function makeDay(i) {
  return { day: DAY_FULL[i], type: i >= 5 ? 'Rest' : '', exercises: [] };
}

function makeExercise() {
  return { name: '', sets: '3', reps: '10' };
}

export default function CustomSplitSheet({ onClose, onSave, existingSplit = null }) {
  const [days, setDays] = useState(() => {
    // Accept either { days, name } object or a plain array
    const d = existingSplit?.days || (Array.isArray(existingSplit) ? existingSplit : null);
    if (d?.length === 7) return d;
    return DAY_FULL.map((_, i) => makeDay(i));
  });
  const [splitName, setSplitName] = useState(existingSplit?.name || '');
  const [openDay, setOpenDay] = useState(null);
  const [saving, setSaving] = useState(false);

  const updateDay = (di, patch) =>
    setDays(prev => prev.map((d, i) => i === di ? { ...d, ...patch } : d));

  const addExercise = (di) =>
    setDays(prev => prev.map((d, i) => i === di ? { ...d, exercises: [...(d.exercises || []), makeExercise()] } : d));

  const updateExercise = (di, ei, patch) =>
    setDays(prev => prev.map((d, i) => {
      if (i !== di) return d;
      const exs = d.exercises.map((e, j) => j === ei ? { ...e, ...patch } : e);
      return { ...d, exercises: exs };
    }));

  const removeExercise = (di, ei) =>
    setDays(prev => prev.map((d, i) => i !== di ? d : { ...d, exercises: d.exercises.filter((_, j) => j !== ei) }));

  const handleSave = async () => {
    setSaving(true);
    try {
      const splitData = { days, name: splitName || 'My Split' };
      await backend.auth.updateMe({ custom_split: JSON.stringify(splitData) });
      onSave(splitData);
    } finally {
      setSaving(false);
    }
  };

  const trainingDays = days.filter(d => d.type && d.type !== 'Rest').length;

  // Hide the AppShell bottom nav while this sheet is open and restore on unmount.
  useEffect(() => {
    window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: true } }));
    return () => window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: false } }));
  }, []);

  return (
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex flex-col justify-end"
      style={{ background: 'rgba(20,22,19,0.55)', backdropFilter: 'blur(4px)' }}
      onClick={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 300 }}
        className="rounded-t-3xl flex flex-col overflow-hidden"
        style={{ background: '#f6f2e8', height: '100dvh' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Handle */}
        <div className="flex justify-center pt-safe-header pb-1 flex-shrink-0">
          <div className="w-10 h-1 rounded-full" style={{ background: '#ddd6c8' }} />
        </div>

        {/* Header */}
        <div className="flex items-center justify-between px-5 py-3 flex-shrink-0" style={{ borderBottom: '1px solid #e8e1d4' }}>
          <div>
            <h2 className="text-base font-black tracking-tight" style={{ color: '#141613' }}>Build My Split</h2>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{trainingDays} training days</p>
          </div>
          <button onClick={onClose} className="w-8 h-8 rounded-full flex items-center justify-center" style={{ background: '#e8e1d4' }}>
            <X size={14} style={{ color: '#5d635d' }} />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 min-h-0 overflow-y-auto px-5 py-4 space-y-3">

          {/* Split name */}
          <input
            value={splitName}
            onChange={e => setSplitName(e.target.value)}
            placeholder="Split name (e.g. Push Pull Legs)"
            className="w-full px-4 py-3 rounded-xl border text-sm font-semibold outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />

          {days.map((day, di) => {
            const isOpen = openDay === di;
            const isRest = day.type === 'Rest';
            const exCount = (day.exercises || []).length;
            const hasType = !!day.type;

            return (
              <div key={di} className="rounded-2xl border overflow-hidden"
                style={{ background: '#ffffff', borderColor: hasType && !isRest ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}>

                {/* Day header row */}
                <button
                  className="w-full flex items-center gap-3 px-4 py-3.5 text-left"
                  onClick={() => setOpenDay(isOpen ? null : di)}
                >
                  {/* Day badge */}
                  <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 text-xs font-black"
                    style={{
                      background: isRest ? '#f2efe7' : hasType ? 'rgba(200,224,0,0.15)' : '#f2efe7',
                      color: hasType && !isRest ? ACCENT_DARK : '#91968e',
                    }}>
                    {DAYS[di]}
                  </div>

                  {/* Day info */}
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-bold" style={{ color: '#141613' }}>{day.day}</p>
                    <p className="text-xs" style={{ color: hasType ? '#5d635d' : '#b8b4ac' }}>
                      {day.type || 'Tap to set'}
                      {!isRest && exCount > 0 ? ` · ${exCount} exercise${exCount !== 1 ? 's' : ''}` : ''}
                    </p>
                  </div>

                  {hasType && !isRest && <Check size={13} style={{ color: ACCENT_DARK, flexShrink: 0 }} />}
                  {isOpen
                    ? <ChevronUp size={14} style={{ color: '#91968e', flexShrink: 0 }} />
                    : <ChevronDown size={14} style={{ color: '#91968e', flexShrink: 0 }} />}
                </button>

                <AnimatePresence>
                  {isOpen && (
                    <motion.div
                      initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
                      exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.2 }}
                      className="overflow-hidden"
                    >
                      <div className="px-4 pb-4 space-y-4" style={{ borderTop: '1px solid #f2efe7' }}>

                        {/* Quick type chips */}
                        <div className="pt-3">
                          <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Workout type</p>
                          <div className="flex flex-wrap gap-2">
                            {QUICK_TYPES.map(t => {
                              const sel = day.type === t;
                              return (
                                <button key={t} onClick={() => updateDay(di, { type: t })}
                                  className="px-3 py-1.5 rounded-xl border text-xs font-semibold transition-all"
                                  style={{
                                    background: sel ? (t === 'Rest' ? '#f2efe7' : 'rgba(200,224,0,0.14)') : '#f9f7f3',
                                    borderColor: sel ? (t === 'Rest' ? '#d9d1c2' : 'rgba(200,224,0,0.5)') : '#e8e1d4',
                                    color: sel ? (t === 'Rest' ? '#5d635d' : ACCENT_DARK) : '#5d635d',
                                  }}>
                                  {t}
                                </button>
                              );
                            })}
                          </div>
                          {/* Custom name */}
                          <input
                            value={!QUICK_TYPES.includes(day.type) ? (day.type || '') : ''}
                            onChange={e => updateDay(di, { type: e.target.value })}
                            placeholder="Or type custom name…"
                            className="w-full mt-2 px-3 py-2.5 rounded-xl border text-sm outline-none"
                            style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
                          />
                        </div>

                        {/* Exercises — only show if not Rest */}
                        {day.type && day.type !== 'Rest' && (
                          <div>
                            <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Exercises</p>

                            {(day.exercises || []).length === 0 && (
                              <p className="text-xs mb-2" style={{ color: '#b8b4ac' }}>No exercises yet — add your first one below.</p>
                            )}

                            <div className="space-y-2">
                              {(day.exercises || []).map((ex, ei) => (
                                <div key={ei} className="flex items-center gap-2 p-3 rounded-xl"
                                  style={{ background: '#f9f7f3', border: '1px solid #e8e1d4' }}>
                                  {/* Exercise name */}
                                  <input
                                    value={ex.name}
                                    onChange={e => updateExercise(di, ei, { name: e.target.value })}
                                    placeholder="Exercise name"
                                    className="flex-1 bg-transparent text-sm outline-none font-medium min-w-0"
                                    style={{ color: '#141613' }}
                                  />
                                  {/* Sets */}
                                  <div className="flex items-center gap-1 flex-shrink-0">
                                    <input
                                      value={ex.sets}
                                      onChange={e => updateExercise(di, ei, { sets: e.target.value })}
                                      className="w-8 text-center bg-white rounded-lg border text-xs font-bold outline-none py-1"
                                      style={{ borderColor: '#e8e1d4', color: '#141613' }}
                                    />
                                    <span className="text-[10px] font-semibold" style={{ color: '#91968e' }}>sets</span>
                                  </div>
                                  {/* Reps */}
                                  <div className="flex items-center gap-1 flex-shrink-0">
                                    <input
                                      value={ex.reps}
                                      onChange={e => updateExercise(di, ei, { reps: e.target.value })}
                                      className="w-10 text-center bg-white rounded-lg border text-xs font-bold outline-none py-1"
                                      style={{ borderColor: '#e8e1d4', color: '#141613' }}
                                    />
                                    <span className="text-[10px] font-semibold" style={{ color: '#91968e' }}>reps</span>
                                  </div>
                                  {/* Remove */}
                                  <button onClick={() => removeExercise(di, ei)} className="flex-shrink-0 ml-1">
                                    <Trash2 size={13} style={{ color: '#d9d1c2' }} />
                                  </button>
                                </div>
                              ))}
                            </div>

                            <button
                              onClick={() => addExercise(di)}
                              className="mt-2 w-full flex items-center justify-center gap-2 py-2.5 rounded-xl border text-xs font-semibold transition-all"
                              style={{ background: 'transparent', borderColor: 'rgba(200,224,0,0.4)', color: ACCENT_DARK, borderStyle: 'dashed' }}
                            >
                              <Plus size={12} /> Add exercise
                            </button>
                          </div>
                        )}

                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            );
          })}
          {/* Save button inside scroll area so it's always reachable */}
          <div className="pt-2 pb-8">
            <motion.button
              whileTap={{ scale: 0.97 }}
              onClick={handleSave}
              disabled={saving || trainingDays === 0}
              className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
              style={{
                background: trainingDays > 0 ? ACCENT : '#e8e1d4',
                color: trainingDays > 0 ? '#141613' : '#91968e',
                boxShadow: trainingDays > 0 ? '0 4px 18px rgba(200,224,0,0.35)' : 'none',
              }}
            >
              <Dumbbell size={14} />
              {saving ? 'Saving…' : `Save Split · ${trainingDays} day${trainingDays !== 1 ? 's' : ''}`}
            </motion.button>
          </div>
        </div>
      </motion.div>
    </motion.div>
  );
}