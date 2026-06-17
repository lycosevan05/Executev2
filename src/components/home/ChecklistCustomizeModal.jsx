import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Plus, Trash2, Check, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getTodayISODate } from '@/lib/personalizationSync';
import { DEFAULT_CHECKLIST_ITEMS, getHiddenDefaults, saveHiddenDefaults } from '@/lib/checklistPrefs';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const RECUR_OPTIONS = [
  { value: 'forever', label: 'Forever' },
  { value: '7days', label: '7 days' },
  { value: '14days', label: '14 days' },
  { value: '30days', label: '30 days' },
  { value: 'custom', label: 'Custom end date' },
];

function addDays(dateStr, n) {
  const d = new Date(dateStr + 'T12:00:00');
  d.setDate(d.getDate() + n);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function todayStr() {
  return getTodayISODate();
}

function resolveEndsOn(recur, customDate) {
  if (recur === 'forever') return null;
  if (recur === '7days') return addDays(todayStr(), 7);
  if (recur === '14days') return addDays(todayStr(), 14);
  if (recur === '30days') return addDays(todayStr(), 30);
  if (recur === 'custom') return customDate || null;
  return null;
}

function ItemForm({ onAdd, onCancel, saving }) {
  const [label, setLabel] = useState('');
  const [days, setDays] = useState([0, 1, 2, 3, 4, 5, 6]);
  const [recur, setRecur] = useState('forever');
  const [customDate, setCustomDate] = useState('');

  const toggleDay = (d) => {
    setDays(prev => prev.includes(d) ? prev.filter(x => x !== d) : [...prev, d].sort());
  };

  const handleAdd = () => {
    if (!label.trim()) return;
    const endsOn = resolveEndsOn(recur, customDate);
    onAdd({ label: label.trim(), days, endsOn });
  };

  return (
    <motion.div
      initial={{ opacity: 0, y: -8 }}
      animate={{ opacity: 1, y: 0 }}
      className="rounded-2xl border p-4 space-y-4"
      style={{ background: '#f9f7f3', borderColor: 'rgba(200,224,0,0.35)' }}
    >
      <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>New Item</p>

      <input
        value={label}
        onChange={e => setLabel(e.target.value)}
        placeholder="e.g. Take a 20-min walk"
        className="w-full px-3 py-2.5 rounded-xl border text-sm outline-none"
        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        autoFocus
      />

      <div>
        <p className="text-[10px] font-semibold mb-2" style={{ color: '#91968e' }}>Active on</p>
        <div className="flex gap-1.5 flex-wrap">
          {DAY_LABELS.map((d, i) => {
            const active = days.includes(i);
            return (
              <button key={i} onClick={() => toggleDay(i)}
                className="w-9 h-9 rounded-xl text-[11px] font-bold border transition-all"
                style={{
                  background: active ? ACCENT : '#ffffff',
                  borderColor: active ? ACCENT : '#e8e1d4',
                  color: active ? '#141613' : '#91968e',
                }}>
                {d}
              </button>
            );
          })}
        </div>
      </div>

      <div>
        <p className="text-[10px] font-semibold mb-2" style={{ color: '#91968e' }}>Recur for</p>
        <div className="flex flex-wrap gap-2">
          {RECUR_OPTIONS.map(opt => (
            <button key={opt.value} onClick={() => setRecur(opt.value)}
              className="px-3 py-1.5 rounded-xl text-xs font-semibold border transition-all"
              style={{
                background: recur === opt.value ? ACCENT : '#ffffff',
                borderColor: recur === opt.value ? ACCENT : '#e8e1d4',
                color: recur === opt.value ? '#141613' : '#5d635d',
              }}>
              {opt.label}
            </button>
          ))}
        </div>
        {recur === 'custom' && (
          <input type="date" value={customDate} min={todayStr()} onChange={e => setCustomDate(e.target.value)}
            className="mt-2 w-full px-3 py-2.5 rounded-xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
        )}
      </div>

      <div className="flex gap-2">
        <button onClick={onCancel}
          className="flex-1 py-2.5 rounded-xl border text-sm font-semibold"
          style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}>
          Cancel
        </button>
        <button onClick={handleAdd} disabled={!label.trim() || saving}
          className="flex-1 py-2.5 rounded-xl text-sm font-bold disabled:opacity-40 flex items-center justify-center gap-2"
          style={{ background: ACCENT, color: '#141613' }}>
          {saving ? <Loader2 size={13} className="animate-spin" /> : null}
          Add Item
        </button>
      </div>
    </motion.div>
  );
}

export default function ChecklistCustomizeModal({ onClose, onSave }) {
  const [items, setItems] = useState([]);
  const [loadingItems, setLoadingItems] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [saving, setSaving] = useState(false);
  const [hiddenDefaults, setHiddenDefaults] = useState([]);

  // Hide the bottom navigation bar while this sheet is open — it overlaps the popup.
  useEffect(() => {
    window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: true } }));
    return () => window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: false } }));
  }, []);

  useEffect(() => {
    backend.entities.CustomChecklistItem.filter({ is_active: true }, '-created_date', 50)
      .then(records => setItems(records))
      .catch(() => setItems([]))
      .finally(() => setLoadingItems(false));
  }, []);

  useEffect(() => {
    getHiddenDefaults().then(setHiddenDefaults).catch(() => setHiddenDefaults([]));
  }, []);

  const toggleDefault = (type) => {
    const next = hiddenDefaults.includes(type)
      ? hiddenDefaults.filter(t => t !== type)
      : [...hiddenDefaults, type];
    setHiddenDefaults(next);
    saveHiddenDefaults(next);
  };

  const handleAdd = async (itemData) => {
    setSaving(true);
    try {
      const created = await backend.entities.CustomChecklistItem.create({
        label: itemData.label,
        days: itemData.days,
        endsOn: itemData.endsOn || null,
        is_active: true,
      });
      setItems(prev => [...prev, created]);
      setShowForm(false);
    } catch {
      // silently fail — user can retry
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id) => {
    setItems(prev => prev.filter(i => i.id !== id));
    await backend.entities.CustomChecklistItem.update(id, { is_active: false }).catch(() => {});
  };

  const formatDays = (days) => {
    if (!days || days.length === 7) return 'Every day';
    if (days.length === 0) return 'No days selected';
    return days.map(d => DAY_LABELS[d]).join(', ');
  };

  const formatEndsOn = (endsOn) => {
    if (!endsOn) return 'Forever';
    return `Until ${new Date(endsOn + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`;
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end"
      style={{ background: 'rgba(20,22,19,0.5)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }}
        animate={{ y: 0 }}
        exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 320 }}
        className="w-full max-w-md mx-auto rounded-t-3xl flex flex-col"
        style={{ background: '#fbf8f1', maxHeight: '88vh', boxShadow: '0 -8px 40px rgba(20,22,19,0.18)' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-10 h-1 rounded-full mx-auto mt-4 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        <div className="flex items-center justify-between px-5 pt-4 pb-4 flex-shrink-0" style={{ borderBottom: '1px solid #ede9df' }}>
          <div>
            <h3 className="text-base font-bold" style={{ color: '#141613' }}>Customize Checklist</h3>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Add recurring items to your daily checklist</p>
          </div>
          <button onClick={onClose}
            className="w-9 h-9 rounded-full flex items-center justify-center"
            style={{ background: '#ede9df', border: '1px solid #e0d9cc' }}>
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>

        <div className="overflow-y-auto flex-1 px-5 py-4 space-y-3">
          {/* Default items (toggleable — tap to show/hide) */}
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>Default Items</p>
            {DEFAULT_CHECKLIST_ITEMS.map(({ type, label }) => {
              const enabled = !hiddenDefaults.includes(type);
              return (
                <button key={type} onClick={() => toggleDefault(type)}
                  className="w-full flex items-center gap-3 px-4 py-3 rounded-xl border mb-1.5 text-left transition-all"
                  style={{ background: enabled ? '#ffffff' : '#f2efe7', borderColor: enabled ? 'rgba(200,224,0,0.3)' : '#e8e1d4' }}>
                  <div className="w-5 h-5 rounded-full border-2 flex items-center justify-center flex-shrink-0"
                    style={{ borderColor: enabled ? ACCENT_DARK : '#d9d1c2', background: enabled ? 'rgba(200,224,0,0.15)' : 'transparent' }}>
                    {enabled && <Check size={11} style={{ color: ACCENT_DARK }} />}
                  </div>
                  <p className="text-sm flex-1" style={{ color: enabled ? '#141613' : '#91968e' }}>{label}</p>
                  <span className="text-[10px]" style={{ color: '#b8b4ac' }}>{enabled ? 'Active' : 'Hidden'}</span>
                </button>
              );
            })}
          </div>

          {/* Custom items from Supabase */}
          {loadingItems ? (
            <div className="flex justify-center py-4">
              <Loader2 size={16} className="animate-spin" style={{ color: ACCENT_DARK }} />
            </div>
          ) : items.length > 0 && (
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>Your Custom Items</p>
              <div className="space-y-2">
                {items.map(item => (
                  <motion.div key={item.id} layout initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }}
                    className="flex items-start gap-3 px-4 py-3 rounded-xl border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-semibold" style={{ color: '#141613' }}>{item.label}</p>
                      <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>
                        {formatDays(item.days)} · {formatEndsOn(item.endsOn)}
                      </p>
                    </div>
                    <button onClick={() => handleDelete(item.id)}
                      className="w-7 h-7 flex items-center justify-center rounded-lg flex-shrink-0"
                      style={{ background: '#f2efe7' }}>
                      <Trash2 size={13} style={{ color: '#b05a3a' }} />
                    </button>
                  </motion.div>
                ))}
              </div>
            </div>
          )}

          <AnimatePresence>
            {showForm ? (
              <ItemForm onAdd={handleAdd} onCancel={() => setShowForm(false)} saving={saving} />
            ) : (
              <motion.button initial={{ opacity: 0 }} animate={{ opacity: 1 }} whileTap={{ scale: 0.97 }}
                onClick={() => setShowForm(true)}
                className="w-full flex items-center justify-center gap-2 py-3 rounded-2xl border-2 border-dashed text-sm font-medium"
                style={{ borderColor: '#d9d1c2', color: '#91968e' }}>
                <Plus size={14} /> Add custom item
              </motion.button>
            )}
          </AnimatePresence>
        </div>

        <div className="flex-shrink-0 px-5 pt-3 pb-6"
          style={{ paddingBottom: 'max(1.5rem, calc(env(safe-area-inset-bottom) + 1rem))', borderTop: '1px solid #ede9df' }}>
          <button onClick={onSave}
            className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
            style={{ background: ACCENT, color: '#141613' }}>
            <Check size={15} />
            Done
          </button>
        </div>
      </motion.div>
    </motion.div>
  );
}