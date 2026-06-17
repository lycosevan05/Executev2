import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { motion } from 'framer-motion';
import { X, Check, Pencil } from 'lucide-react';
import { ACCENT, ACCENT_DARK, habits } from './categories';

export default function LogModal({ category, onClose, onSave, currentValue }) {
  const isSleep = category.id === 'sleep';
  const isCals = category.id === 'cals_burned';
  const defaultVal = isSleep ? '7.5' : isCals ? (currentValue || '0') : '';
  const [value, setValue] = useState(defaultVal);
  const [checkedHabits, setCheckedHabits] = useState([]);
  const [saving, setSaving] = useState(false);

  // Lock body scroll while modal is open
  useEffect(() => {
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = ''; };
  }, []);

  const handleSave = async () => {
    setSaving(true);
    const saveVal = category.id === 'habits' ? checkedHabits : value;
    await new Promise(r => setTimeout(r, 120)); // small delay for feel
    onSave(saveVal);
    setSaving(false);
  };

  const canSave = category.id === 'habits' ? checkedHabits.length > 0 : (value !== '' && value !== null);

  const dateStr = new Date().toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });

  return createPortal(
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 flex items-end"
      style={{ background: 'rgba(20,22,19,0.5)', zIndex: 9999 }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 320 }}
        className="w-full max-w-md mx-auto rounded-t-3xl flex flex-col"
        style={{
          background: '#fbf8f1',
          maxHeight: '88vh',
          boxShadow: '0 -8px 40px rgba(20,22,19,0.18)',
        }}
        onClick={e => e.stopPropagation()}
      >
        {/* Drag handle */}
        <div className="w-10 h-1 rounded-full mx-auto mt-4 mb-0 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        {/* Header */}
        <div className="flex items-center justify-between px-5 pt-4 pb-4 flex-shrink-0">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-full flex items-center justify-center flex-shrink-0"
              style={{ background: 'rgba(200,224,0,0.13)' }}>
              {category.icon
                ? <category.icon size={18} style={{ color: ACCENT_DARK }} />
                : <Pencil size={18} style={{ color: ACCENT_DARK }} />}
            </div>
            <div>
              <h3 className="text-base font-bold leading-tight" style={{ color: '#141613' }}>Log {category.label}</h3>
              <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Today · {dateStr}</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0"
            style={{ background: '#ede9df', border: '1px solid #e0d9cc' }}
          >
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>

        {/* Divider */}
        <div style={{ height: 1, background: '#ede9df', flexShrink: 0 }} />

        {/* Scrollable content */}
        <div className="overflow-y-auto flex-1 px-5 py-5">
          {category.id === 'habits' ? (
            <div className="space-y-2.5">
              {habits.map(h => (
                <button key={h}
                  onClick={() => setCheckedHabits(prev => prev.includes(h) ? prev.filter(x => x !== h) : [...prev, h])}
                  className="w-full flex items-center gap-3 p-3.5 rounded-2xl transition-all border"
                  style={{
                    background: checkedHabits.includes(h) ? 'rgba(200,224,0,0.1)' : '#ffffff',
                    borderColor: checkedHabits.includes(h) ? 'rgba(200,224,0,0.4)' : '#e8e1d4',
                  }}>
                  <div className="w-5 h-5 rounded-full border-2 flex items-center justify-center flex-shrink-0"
                    style={{ borderColor: checkedHabits.includes(h) ? ACCENT_DARK : '#d9d1c2' }}>
                    {checkedHabits.includes(h) && <div className="w-2.5 h-2.5 rounded-full" style={{ background: ACCENT_DARK }} />}
                  </div>
                  <span className="text-sm font-medium" style={{ color: checkedHabits.includes(h) ? '#141613' : '#5d635d' }}>{h}</span>
                </button>
              ))}
            </div>
          ) : category.id === 'mood' ? (
            <div>
              <p className="text-sm mb-6 text-center" style={{ color: '#5d635d' }}>How are you feeling?</p>
              <div className="flex justify-between px-2 mb-4">
                {[
                  { emoji: '😞', label: 'Rough', val: '1' },
                  { emoji: '😕', label: 'Meh', val: '2' },
                  { emoji: '😐', label: 'Okay', val: '3' },
                  { emoji: '😊', label: 'Good', val: '4' },
                  { emoji: '😄', label: 'Great', val: '5' },
                ].map(({ emoji, label, val }) => (
                  <button key={val} onClick={() => setValue(val)}
                    className="flex flex-col items-center gap-1.5 transition-all"
                    style={{ transform: value === val ? 'scale(1.25)' : 'scale(1)', opacity: value === val ? 1 : 0.4 }}>
                    <span className="text-4xl">{emoji}</span>
                    <span className="text-[10px] font-semibold" style={{ color: value === val ? ACCENT_DARK : '#91968e' }}>{label}</span>
                  </button>
                ))}
              </div>
            </div>
          ) : isSleep ? (
            /* ── SLEEP-SPECIFIC UI ── */
            <div>
              {/* Value display */}
              <div className="flex items-end justify-center gap-2 mb-6 mt-2">
                <style>{`
                  input[type=number].no-spinner::-webkit-inner-spin-button,
                  input[type=number].no-spinner::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
                  input[type=number].no-spinner { -moz-appearance: textfield; }
                `}</style>
                <input
                  type="number"
                  className="no-spinner text-center bg-transparent outline-none font-black"
                  style={{ color: '#141613', fontSize: 56, lineHeight: 1, width: 110 }}
                  value={value}
                  min={0} max={14} step={0.5}
                  onChange={e => {
                    const v = Math.min(14, Math.max(0, parseFloat(e.target.value) || 0));
                    setValue(String(v));
                  }}
                />
                <span className="font-medium pb-3" style={{ color: '#91968e', fontSize: 18 }}>hrs</span>
              </div>

              {/* Quick-pick chips */}
              <div className="flex justify-center gap-2 mb-6 flex-wrap">
                {['6', '6.5', '7', '7.5', '8', '8.5', '9'].map(v => (
                  <button key={v} onClick={() => setValue(v)}
                    className="px-3.5 py-1.5 rounded-full text-xs font-semibold border transition-all"
                    style={{
                      background: value === v ? ACCENT : '#ffffff',
                      borderColor: value === v ? ACCENT : '#e8e1d4',
                      color: value === v ? '#141613' : '#5d635d',
                    }}>
                    {v}h
                  </button>
                ))}
              </div>

              {/* Slider */}
              <div className="px-1 mb-4">
                <style>{`
                  input[type=range].sleep-slider { -webkit-appearance: none; appearance: none; width: 100%; height: 6px; border-radius: 99px; background: #e8e1d4; outline: none; }
                  input[type=range].sleep-slider::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 26px; height: 26px; border-radius: 50%; background: ${ACCENT}; cursor: pointer; box-shadow: 0 2px 8px rgba(200,224,0,0.35); border: 3px solid #fff; }
                  input[type=range].sleep-slider::-moz-range-thumb { width: 26px; height: 26px; border-radius: 50%; background: ${ACCENT}; cursor: pointer; box-shadow: 0 2px 8px rgba(200,224,0,0.35); border: 3px solid #fff; }
                `}</style>
                <input
                  type="range"
                  className="sleep-slider"
                  min={0} max={14} step={0.5}
                  value={value || 0}
                  onChange={e => setValue(e.target.value)}
                />
                <div className="flex justify-between mt-1.5">
                  <span className="text-[10px]" style={{ color: '#b8b4ac' }}>0h</span>
                  <span className="text-[10px]" style={{ color: '#b8b4ac' }}>14h</span>
                </div>
              </div>

              {/* Helper text */}
              <p className="text-xs text-center leading-relaxed" style={{ color: '#91968e' }}>
                Most adults feel best with 7–9 hours of sleep.
              </p>
            </div>
          ) : isCals ? (
            /* ── CALORIES BURNED — slider only, max 3000 ── */
            <div>
              <div className="flex items-end justify-center gap-2 mb-6 mt-2">
                <style>{`
                  input[type=number].no-spinner::-webkit-inner-spin-button,
                  input[type=number].no-spinner::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
                  input[type=number].no-spinner { -moz-appearance: textfield; }
                  input[type=range].cals-slider { -webkit-appearance: none; appearance: none; width: 100%; height: 6px; border-radius: 99px; background: #e8e1d4; outline: none; }
                  input[type=range].cals-slider::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 26px; height: 26px; border-radius: 50%; background: #b05a3a; cursor: pointer; box-shadow: 0 2px 8px rgba(176,90,58,0.35); border: 3px solid #fff; }
                  input[type=range].cals-slider::-moz-range-thumb { width: 26px; height: 26px; border-radius: 50%; background: #b05a3a; cursor: pointer; box-shadow: 0 2px 8px rgba(176,90,58,0.35); border: 3px solid #fff; }
                `}</style>
                <input
                  type="number"
                  className="no-spinner text-center bg-transparent outline-none font-black"
                  style={{ color: '#141613', fontSize: 56, lineHeight: 1, width: 140 }}
                  value={value}
                  placeholder="0"
                  min={0} max={3000}
                  onChange={e => setValue(String(Math.min(3000, Math.max(0, parseInt(e.target.value) || 0))))}
                />
                <span className="font-medium pb-3" style={{ color: '#91968e', fontSize: 18 }}>kcal</span>
              </div>

              {/* Quick-pick chips */}
              <div className="flex justify-center gap-2 mb-6 flex-wrap">
                {['100', '200', '300', '400', '500', '600'].map(v => (
                  <button key={v} onClick={() => setValue(v)}
                    className="px-3.5 py-1.5 rounded-full text-xs font-semibold border transition-all"
                    style={{
                      background: value === v ? '#b05a3a' : '#ffffff',
                      borderColor: value === v ? '#b05a3a' : '#e8e1d4',
                      color: value === v ? '#ffffff' : '#5d635d',
                    }}>
                    {v}
                  </button>
                ))}
              </div>

              {/* Slider */}
              <div className="px-1 mb-4">
                <input
                  type="range"
                  className="cals-slider"
                  min={0} max={3000} step={10}
                  value={value || 0}
                  onChange={e => setValue(e.target.value)}
                />
                <div className="flex justify-between mt-1.5">
                  <span className="text-[10px]" style={{ color: '#b8b4ac' }}>0</span>
                  <span className="text-[10px]" style={{ color: '#b8b4ac' }}>3,000 kcal</span>
                </div>
              </div>

              <p className="text-xs text-center leading-relaxed" style={{ color: '#91968e' }}>
                This replaces your current burned calories for today.
              </p>
            </div>
          ) : (
            /* ── GENERIC NUMERIC UI ── */
            <div>
              <div className="flex items-end justify-center gap-2 mb-4 mt-2">
                <style>{`
                  input[type=number].no-spinner::-webkit-inner-spin-button,
                  input[type=number].no-spinner::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
                  input[type=number].no-spinner { -moz-appearance: textfield; }
                `}</style>
                <input
                  type="number"
                  className="no-spinner text-center bg-transparent outline-none font-black"
                  style={{ color: '#141613', fontSize: 52, lineHeight: 1, width: 130 }}
                  value={value}
                  placeholder="0"
                  onChange={e => setValue(e.target.value)}
                />
                <span className="font-medium pb-2.5" style={{ color: '#91968e', fontSize: 16 }}>{category.unit}</span>
              </div>
              <div className="px-1">
                <input type="range" min="0"
                  max={category.id === 'water' ? 5 : category.id === 'weight' ? 200 : category.id === 'energy' ? 10 : category.id === 'steps' ? 30000 : 300}
                  step={category.id === 'weight' ? 0.1 : category.id === 'steps' ? 100 : 0.5}
                  value={value || 0} onChange={e => setValue(e.target.value)}
                  className="w-full" style={{ accentColor: ACCENT }} />
              </div>
            </div>
          )}
        </div>

        {/* Footer — sticky Save button */}
        <div className="flex-shrink-0 px-5 pt-3 pb-6" style={{ paddingBottom: 'max(1.5rem, calc(env(safe-area-inset-bottom) + 1rem))', borderTop: '1px solid #ede9df' }}>
          <button
            onClick={handleSave}
            disabled={saving || !canSave}
            className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 transition-all"
            style={{
              background: saving || !canSave ? '#e8e1d4' : ACCENT,
              color: saving || !canSave ? '#91968e' : '#141613',
            }}
          >
            {saving ? (
              <><span className="w-4 h-4 border-2 border-current border-t-transparent rounded-full animate-spin inline-block" /> Saving…</>
            ) : (
              <>
                <Check size={15} />
                Save {category.label}
              </>
            )}
          </button>
        </div>
      </motion.div>
    </motion.div>,
    document.body
  );
}
