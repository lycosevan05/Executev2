import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { motion } from 'framer-motion';
import { X, Plus, Trash2, Dumbbell, RotateCcw } from 'lucide-react';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const QUICK_TYPES = ['Push', 'Pull', 'Legs', 'Upper', 'Lower', 'Full Body', 'Cardio', 'Core', 'Rest'];

function makeExercise() {
  return { name: '', sets: '3', reps: '10' };
}

/**
 * Per-day editor for the unified weekly split. Edits apply as a WEEKLY
 * TEMPLATE: saving "Monday" affects every future Monday.
 *
 * Backend-agnostic — calls onSave({ day_type, label, exercises }) / onReset();
 * the page owns persistence and optimistic state.
 *
 * @param {{
 *   weekday: string,
 *   initial: { label: string, day_type: string, exercises: Array<{name: string, sets: any, reps: any}> },
 *   hasOverride: boolean,
 *   onClose: () => void,
 *   onSave: (edit: { day_type: string, label: string, exercises: Array<{name: string, sets: string, reps: string}> }) => void,
 *   onReset?: (() => void) | null,
 * }} props
 */
export default function SplitDayEditorSheet({ weekday, initial, hasOverride, onClose, onSave, onReset = null }) {
  const [type, setType] = useState(() =>
    initial?.day_type === 'rest' ? 'Rest' : (initial?.label || ''),
  );
  const [exercises, setExercises] = useState(() =>
    (initial?.exercises || []).map(ex => ({
      name: String(ex.name || ''),
      sets: String(ex.sets ?? '3'),
      reps: String(ex.reps ?? '10'),
    })),
  );

  const isRest = type === 'Rest';
  const cleanedExercises = exercises.filter(ex => ex.name.trim());
  const canSave = !!type.trim();

  const updateExercise = (ei, patch) =>
    setExercises(prev => prev.map((e, i) => (i === ei ? { ...e, ...patch } : e)));
  const removeExercise = (ei) =>
    setExercises(prev => prev.filter((_, i) => i !== ei));

  // Hide the AppShell bottom nav while this sheet is open and restore on unmount.
  useEffect(() => {
    window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: true } }));
    return () => {
      window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: false } }));
    };
  }, []);

  const handleSave = () => {
    if (!canSave) return;
    onSave({
      day_type: isRest ? 'rest' : 'training',
      label: type.trim(),
      exercises: isRest
        ? []
        : cleanedExercises.map(ex => ({ name: ex.name.trim(), sets: ex.sets, reps: ex.reps })),
    });
  };

  return createPortal(
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-[9999] flex flex-col justify-end"
      style={{ background: 'rgba(20,22,19,0.55)', backdropFilter: 'blur(4px)' }}
      onClick={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 300 }}
        className="rounded-t-3xl flex flex-col overflow-hidden"
        style={{ background: '#f6f2e8', maxHeight: '88dvh' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Handle */}
        <div className="flex justify-center pt-3 pb-1 flex-shrink-0">
          <div className="w-10 h-1 rounded-full" style={{ background: '#ddd6c8' }} />
        </div>

        {/* Header */}
        <div className="flex items-center justify-between px-5 py-3 flex-shrink-0" style={{ borderBottom: '1px solid #e8e1d4' }}>
          <div>
            <h2 className="text-base font-black tracking-tight" style={{ color: '#141613' }}>Edit {weekday}</h2>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Changes apply to every {weekday}</p>
          </div>
          <button onClick={onClose} className="w-8 h-8 rounded-full flex items-center justify-center" style={{ background: '#e8e1d4' }}>
            <X size={14} style={{ color: '#5d635d' }} />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 min-h-0 overflow-y-auto px-5 py-4 space-y-4">

          {/* Quick type chips */}
          <div>
            <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Workout type</p>
            <div className="flex flex-wrap gap-2">
              {QUICK_TYPES.map(t => {
                const sel = type === t;
                return (
                  <button key={t} onClick={() => setType(t)}
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
              value={!QUICK_TYPES.includes(type) ? type : ''}
              onChange={e => setType(e.target.value)}
              placeholder="Or type custom name…"
              className="w-full mt-2 px-3 py-2.5 rounded-xl border text-sm outline-none"
              style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
            />
          </div>

          {/* Exercises — only when not Rest */}
          {!isRest && (
            <div>
              <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Exercises</p>

              {exercises.length === 0 && (
                <p className="text-xs mb-2" style={{ color: '#b8b4ac' }}>
                  No exercises yet — leave empty to let AI build the session, or add your own below.
                </p>
              )}

              <div className="space-y-2">
                {exercises.map((ex, ei) => (
                  <div key={ei} className="flex items-center gap-2 p-3 rounded-xl"
                    style={{ background: '#f9f7f3', border: '1px solid #e8e1d4' }}>
                    <input
                      value={ex.name}
                      onChange={e => updateExercise(ei, { name: e.target.value })}
                      placeholder="Exercise name"
                      className="flex-1 bg-transparent text-sm outline-none font-medium min-w-0"
                      style={{ color: '#141613' }}
                    />
                    <div className="flex items-center gap-1 flex-shrink-0">
                      <input
                        value={ex.sets}
                        onChange={e => updateExercise(ei, { sets: e.target.value })}
                        className="w-8 text-center bg-white rounded-lg border text-xs font-bold outline-none py-1"
                        style={{ borderColor: '#e8e1d4', color: '#141613' }}
                      />
                      <span className="text-[10px] font-semibold" style={{ color: '#91968e' }}>sets</span>
                    </div>
                    <div className="flex items-center gap-1 flex-shrink-0">
                      <input
                        value={ex.reps}
                        onChange={e => updateExercise(ei, { reps: e.target.value })}
                        className="w-10 text-center bg-white rounded-lg border text-xs font-bold outline-none py-1"
                        style={{ borderColor: '#e8e1d4', color: '#141613' }}
                      />
                      <span className="text-[10px] font-semibold" style={{ color: '#91968e' }}>reps</span>
                    </div>
                    <button onClick={() => removeExercise(ei)} className="flex-shrink-0 ml-1">
                      <Trash2 size={13} style={{ color: '#d9d1c2' }} />
                    </button>
                  </div>
                ))}
              </div>

              <button
                onClick={() => setExercises(prev => [...prev, makeExercise()])}
                className="mt-2 w-full flex items-center justify-center gap-2 py-2.5 rounded-xl border text-xs font-semibold transition-all"
                style={{ background: 'transparent', borderColor: 'rgba(200,224,0,0.4)', color: ACCENT_DARK, borderStyle: 'dashed' }}
              >
                <Plus size={12} /> Add exercise
              </button>
            </div>
          )}

          {/* Actions */}
          <div className="pt-1 pb-8 space-y-2">
            <motion.button
              whileTap={{ scale: 0.97 }}
              onClick={handleSave}
              disabled={!canSave}
              className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
              style={{
                background: canSave ? ACCENT : '#e8e1d4',
                color: canSave ? '#141613' : '#91968e',
                boxShadow: canSave ? '0 4px 18px rgba(200,224,0,0.35)' : 'none',
              }}
            >
              <Dumbbell size={14} />
              Save — applies to every {weekday}
            </motion.button>

            {hasOverride && onReset && (
              <button
                onClick={onReset}
                className="w-full flex items-center justify-center gap-2 py-3 rounded-2xl border text-xs font-semibold"
                style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
              >
                <RotateCcw size={12} /> Reset to AI plan
              </button>
            )}
          </div>
        </div>
      </motion.div>
    </motion.div>,
    document.body,
  );
}
