import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Moon, Flame, Droplets, Heart, Weight, SmilePlus, CheckSquare, X, Plus, UtensilsCrossed, ChevronRight, SlidersHorizontal, Check, Pencil, Footprints } from 'lucide-react';
import { Link } from 'react-router-dom';
import { backend } from '@/api/backendClient';
import { appCache } from '@/lib/appCache';
import { loadCustomTrackers, saveCustomTrackers } from '@/lib/customTrackers';
import { getTodayISODate, invalidateUserAIContext } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseBestLinkedRecord(records = [], masterPlan = null) {
  const safeRecords = Array.isArray(records) ? records.filter(Boolean).sort(newestFirst) : [];
  if (!safeRecords.length) return null;

  if (masterPlan) {
    const exact = safeRecords.find(record =>
      sameValue(record.source_plan_id, masterPlan.id) &&
      sameValue(record.generation_batch_id, masterPlan.generation_batch_id)
    );
    if (exact) return exact;

    const sourcePlanMatch = safeRecords.find(record => sameValue(record.source_plan_id, masterPlan.id));
    if (sourcePlanMatch) return sourcePlanMatch;
  }

  const canonical =
    safeRecords.find(record => record.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.source === 'plan_questionnaire_initial') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_initial');
  if (canonical) return canonical;

  return safeRecords[0] || null;
}

async function loadActiveCanonicalMasterPlan() {
  const plans = await backend.entities.AIPlan
    .filter({ plan_type: 'daily', status: 'active' }, '-generated_at', 25)
    .catch(() => []);

  const sortedPlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];

  return sortedPlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial') ||
    sortedPlans[0] ||
    null;
}

async function loadLinkedDailyLogForDate(date, masterPlan) {
  if (!date) return null;

  if (masterPlan?.id && masterPlan?.generation_batch_id) {
    const linkedLogs = await backend.entities.DailyLog.filter({
      date,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id,
    }).catch(() => []);

    const linkedLog = chooseBestLinkedRecord(linkedLogs, masterPlan);
    if (linkedLog) return linkedLog;
  }

  const dateLogs = await backend.entities.DailyLog.filter({ date }).catch(() => []);
  return chooseBestLinkedRecord(dateLogs, masterPlan);
}

function buildLoggedFromDailyLog(dailyLog) {
  if (!dailyLog) return {};

  const next = {};

  if (dailyLog.sleep_hours != null && dailyLog.sleep_hours !== 0) {
    next.sleep = String(dailyLog.sleep_hours);
  }

  if (dailyLog.water_liters != null && dailyLog.water_liters !== 0) {
    next.water = String(dailyLog.water_liters);
  }

  if (dailyLog.workout_duration_min != null && dailyLog.workout_duration_min !== 0) {
    next.workout = String(dailyLog.workout_duration_min);
  } else if (dailyLog.workout_done) {
    next.workout = '1';
  }

  if (dailyLog.mood != null && dailyLog.mood !== 0) {
    next.mood = String(dailyLog.mood);
  }

  if (dailyLog.weight_kg != null && dailyLog.weight_kg !== 0) {
    next.weight = String(dailyLog.weight_kg);
  }

  if (dailyLog.energy != null && dailyLog.energy !== 0) {
    next.energy = String(dailyLog.energy);
  }

  if (dailyLog.steps != null && dailyLog.steps !== 0) {
    next.steps = String(dailyLog.steps);
  }

  if (dailyLog.calories_burned != null && dailyLog.calories_burned !== 0) {
    next.cals_burned = String(dailyLog.calories_burned);
  }

  if (dailyLog.calories_consumed != null && dailyLog.calories_consumed !== 0) {
    next.cals_consumed = String(dailyLog.calories_consumed);
  }

  if (Array.isArray(dailyLog.habits_completed) && dailyLog.habits_completed.length > 0) {
    next.habits = dailyLog.habits_completed;
  }

  return next;
}

// Fields that accumulate across multiple logs in the same day
const ADDITIVE_FIELDS = ['steps', 'sleep', 'water'];

function getDailyLogUpdatesForCategory(categoryId, value, existingLog) {
  const numericValue = parseFloat(value) || 0;

  // For additive fields, add on top of what's already stored
  const additive = (field) => {
    const current = parseFloat(existingLog?.[field]) || 0;
    return current + numericValue;
  };

  const fieldMap = {
    sleep:      { sleep_hours: ADDITIVE_FIELDS.includes('sleep') ? additive('sleep_hours') : numericValue },
    water:      { water_liters: ADDITIVE_FIELDS.includes('water') ? additive('water_liters') : numericValue },
    steps:      { steps: ADDITIVE_FIELDS.includes('steps') ? additive('steps') : numericValue },
    workout:    { workout_done: true, workout_duration_min: numericValue },
    cals_burned:{ calories_burned: numericValue },
    mood:       { mood: numericValue },
    weight:     { weight_kg: numericValue },
    energy:     { energy: numericValue },
    habits:     { habits_completed: Array.isArray(value) ? value : [] },
  };

  return fieldMap[categoryId] || null;
}

const ALL_CATEGORIES = [
  { id: 'sleep',          icon: Moon,        label: 'Sleep',         unit: 'hours',  desc: 'Track nightly sleep duration' },
  { id: 'water',          icon: Droplets,    label: 'Water',         unit: 'liters', desc: 'Daily hydration' },
  { id: 'steps',          icon: Footprints,  label: 'Steps',         unit: 'steps',  desc: 'Daily step count' },
  { id: 'cals_burned',    icon: Flame,       label: 'Cals Burned',   unit: 'kcal',   desc: 'Calories burned from exercise' },
  { id: 'mood',           icon: Heart,       label: 'Mood',          unit: '/ 5',    desc: 'Emotional wellbeing check-in' },
  { id: 'weight',         icon: Weight,      label: 'Weight',        unit: 'kg',     desc: 'Body weight logging' },
  { id: 'energy',         icon: SmilePlus,   label: 'Energy',        unit: '/ 10',   desc: 'Subjective energy level' },
  { id: 'habits',         icon: CheckSquare, label: 'Habits',        unit: 'done',   desc: 'Daily habit completion' },
];

const DEFAULT_ACTIVE = ['sleep', 'water', 'steps', 'cals_burned', 'mood', 'weight', 'energy', 'habits'];

const habits = ['Morning hydration', 'No phone in bed', 'Stretch 10min', 'Read 15min', 'Cold shower', 'Meditation'];

function FoodLogger({ caloriesConsumed, caloriesBurned }) {
  const net = (caloriesConsumed || 0) - (caloriesBurned || 0);
  return (
    <Link to="/log-food"
      className="flex items-center gap-4 p-4 rounded-2xl border"
      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.3)' }}>
      <div className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: ACCENT }}>
        <UtensilsCrossed size={18} style={{ color: '#141613' }} />
      </div>
      <div className="flex-1">
        <p className="text-sm font-bold" style={{ color: '#141613' }}>Log Food</p>
        {(caloriesConsumed > 0 || caloriesBurned > 0) ? (
          <div className="flex items-center gap-3 mt-1 flex-wrap">
            {caloriesConsumed > 0 && (
              <span className="flex items-center gap-1 text-xs font-semibold" style={{ color: '#5d635d' }}>
                <UtensilsCrossed size={10} style={{ color: '#8ea400' }} />
                {caloriesConsumed} eaten
              </span>
            )}
            {caloriesBurned > 0 && (
              <span className="flex items-center gap-1 text-xs font-semibold" style={{ color: '#b05a3a' }}>
                <Flame size={10} style={{ color: '#b05a3a' }} />
                {caloriesBurned} burned
              </span>
            )}
            {caloriesConsumed > 0 && caloriesBurned > 0 && (
              <span className="text-xs font-bold" style={{ color: net > 0 ? '#5d635d' : '#8ea400' }}>
                = {Math.abs(net)} net {net > 0 ? 'surplus' : 'deficit'}
              </span>
            )}
          </div>
        ) : (
          <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>AI-powered meal logging with macro estimates</p>
        )}
      </div>
      <ChevronRight size={16} style={{ color: '#91968e' }} />
    </Link>
  );
}

function LogModal({ category, onClose, onSave, currentValue }) {
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

  return (
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
    </motion.div>
  );
}

function ManageWidgetsSheet({ activeIds, onToggle, onClose, customCategories, onAddCustom, onRemoveCustom }) {
  const [showForm, setShowForm] = useState(false);
  const [newLabel, setNewLabel] = useState('');
  const [newUnit, setNewUnit] = useState('');

  const handleAdd = () => {
    if (!newLabel.trim()) return;
    onAddCustom({ label: newLabel.trim(), unit: newUnit.trim() || 'units' });
    setNewLabel('');
    setNewUnit('');
    setShowForm(false);
  };

  return (
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end"
      style={{ background: 'rgba(20,22,19,0.45)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 320 }}
        className="w-full max-w-md mx-auto rounded-t-3xl border-t border-l border-r"
        style={{ background: '#fbf8f1', borderColor: '#e8e1d4' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-10 h-1 rounded-full mx-auto mt-3 mb-4" style={{ background: '#d9d1c2' }} />
        <div className="px-5 pb-8">
          <div className="flex items-center justify-between mb-5">
            <div>
              <h3 className="text-base font-bold" style={{ color: '#141613' }}>Manage Tracking Widgets</h3>
              <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Tap to add or remove tracking cards</p>
            </div>
            <button onClick={onClose} className="w-8 h-8 rounded-xl flex items-center justify-center border"
              style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
              <X size={14} style={{ color: '#5d635d' }} />
            </button>
          </div>

          <div className="space-y-2 max-h-[45vh] overflow-y-auto pr-1">
            {ALL_CATEGORIES.map(cat => {
              const isActive = activeIds.includes(cat.id);
              return (
                <motion.button key={cat.id} whileTap={{ scale: 0.97 }}
                  onClick={() => onToggle(cat.id)}
                  className="w-full flex items-center gap-3 px-4 py-3.5 rounded-2xl border text-left transition-all"
                  style={{ background: isActive ? 'rgba(200,224,0,0.07)' : '#ffffff', borderColor: isActive ? 'rgba(200,224,0,0.35)' : '#e8e1d4' }}>
                  <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
                    style={{ background: isActive ? 'rgba(200,224,0,0.15)' : '#f2efe7' }}>
                    <cat.icon size={16} style={{ color: isActive ? ACCENT_DARK : '#91968e' }} />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-semibold" style={{ color: '#141613' }}>{cat.label}</p>
                    <p className="text-xs" style={{ color: '#91968e' }}>{cat.desc}</p>
                  </div>
                  <div className="w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0"
                    style={{ background: isActive ? ACCENT : '#e8e1d4' }}>
                    {isActive
                      ? <Check size={12} style={{ color: '#141613' }} />
                      : <Plus size={12} style={{ color: '#91968e' }} />}
                  </div>
                </motion.button>
              );
            })}

            {/* Custom categories */}
            {customCategories.map(cat => {
              const isActive = activeIds.includes(cat.id);
              return (
                <div key={cat.id} className="flex items-center gap-2">
                  <motion.button whileTap={{ scale: 0.97 }}
                    onClick={() => onToggle(cat.id)}
                    className="flex-1 flex items-center gap-3 px-4 py-3.5 rounded-2xl border text-left transition-all"
                    style={{ background: isActive ? 'rgba(200,224,0,0.07)' : '#ffffff', borderColor: isActive ? 'rgba(200,224,0,0.35)' : '#e8e1d4' }}>
                    <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
                      style={{ background: isActive ? 'rgba(200,224,0,0.15)' : '#f2efe7' }}>
                      <Pencil size={14} style={{ color: isActive ? ACCENT_DARK : '#91968e' }} />
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-semibold" style={{ color: '#141613' }}>{cat.label}</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>Custom · {cat.unit}</p>
                    </div>
                    <div className="w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0"
                      style={{ background: isActive ? ACCENT : '#e8e1d4' }}>
                      {isActive ? <Check size={12} style={{ color: '#141613' }} /> : <Plus size={12} style={{ color: '#91968e' }} />}
                    </div>
                  </motion.button>
                  <button onClick={() => onRemoveCustom(cat.id)} className="w-8 h-8 flex items-center justify-center rounded-xl border flex-shrink-0"
                    style={{ background: '#fff', borderColor: '#e8e1d4' }}>
                    <X size={13} style={{ color: '#b05a3a' }} />
                  </button>
                </div>
              );
            })}
          </div>

          {/* Add custom tracker */}
          <div className="mt-4">
            {!showForm ? (
              <button onClick={() => setShowForm(true)}
                className="w-full flex items-center justify-center gap-2 py-3 rounded-2xl border-2 border-dashed text-sm font-medium"
                style={{ borderColor: '#d9d1c2', color: '#91968e' }}>
                <Plus size={14} /> Create custom tracker
              </button>
            ) : (
              <motion.div initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }}
                className="p-4 rounded-2xl border space-y-3"
                style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>New Custom Tracker</p>
                <input value={newLabel} onChange={e => setNewLabel(e.target.value)}
                  placeholder="Name (e.g. Cold shower, Sunlight)"
                  className="w-full px-3 py-2.5 rounded-xl border text-sm outline-none"
                  style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
                <input value={newUnit} onChange={e => setNewUnit(e.target.value)}
                  placeholder="Unit (e.g. min, mg, times) — optional"
                  className="w-full px-3 py-2.5 rounded-xl border text-sm outline-none"
                  style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
                <div className="flex gap-2">
                  <button onClick={() => setShowForm(false)}
                    className="flex-1 py-2.5 rounded-xl border text-sm font-medium"
                    style={{ borderColor: '#e8e1d4', color: '#5d635d' }}>Cancel</button>
                  <button onClick={handleAdd} disabled={!newLabel.trim()}
                    className="flex-1 py-2.5 rounded-xl text-sm font-bold disabled:opacity-40"
                    style={{ background: ACCENT, color: '#141613' }}>Add</button>
                </div>
              </motion.div>
            )}
          </div>

          <button onClick={onClose}
            className="w-full mt-5 py-3.5 rounded-2xl text-sm font-bold"
            style={{ background: ACCENT, color: '#141613' }}>
            Done
          </button>
        </div>
      </motion.div>
    </motion.div>
  );
}

export default function Track() {
  const [activeModal, setActiveModal] = useState(null);
  const [logged, setLogged] = useState({});
  const [activeIds, setActiveIds] = useState(DEFAULT_ACTIVE);
  const [showManage, setShowManage] = useState(false);
  const [customCategories, setCustomCategories] = useState(() => loadCustomTrackers());
  const [dailyLogId, setDailyLogId] = useState(null);
  const [planContext, setPlanContext] = useState(null);

  const todayStr = getTodayISODate();

  // Pre-populate tracking values from today's canonical DailyLog.
  useEffect(() => {
    let cancelled = false;

    async function loadTodayTracking() {
      const activeMasterPlan = await loadActiveCanonicalMasterPlan();
      const linkedDailyLog = await loadLinkedDailyLogForDate(todayStr, activeMasterPlan);

      if (cancelled) return;

      setPlanContext(activeMasterPlan);
      setDailyLogId(linkedDailyLog?.id || null);

      const loggedValues = buildLoggedFromDailyLog(linkedDailyLog);

      // Weight persists across days — if today has no weight, load the most recent one
      if (!loggedValues.weight) {
        const recentLogs = await backend.entities.DailyLog.list('-date', 10).catch(() => []);
        const lastWithWeight = recentLogs.find(l => l.date !== todayStr && l.weight_kg != null && l.weight_kg !== 0);
        if (lastWithWeight) {
          loggedValues.weight = String(lastWithWeight.weight_kg);
        }
      }

      if (cancelled) return;
      setLogged(loggedValues);
    }

    loadTodayTracking().catch(() => {
      if (!cancelled) {
        setPlanContext(null);
        setDailyLogId(null);
        setLogged({});
      }
    });

    return () => {
      cancelled = true;
    };
  }, [todayStr]);

  // Live-sync: when workout completes it writes calories_burned to DailyLog —
  // reflect that immediately in the Track UI without a page reload.
  useEffect(() => {
    const unsub = backend.entities.DailyLog.subscribe((event) => {
      if (event.type === 'update' || event.type === 'create') {
        const log = event.data;
        if (!log || log.date !== todayStr) return;
        setLogged(prev => {
          const next = { ...prev };
          if (log.steps != null && log.steps !== 0) next.steps = String(log.steps);
          if (log.calories_burned != null && log.calories_burned !== 0) {
            next.cals_burned = String(log.calories_burned);
          }
          if (log.calories_consumed != null && log.calories_consumed !== 0) {
            next.cals_consumed = String(log.calories_consumed);
          }
          if (log.sleep_hours != null && log.sleep_hours !== 0) next.sleep = String(log.sleep_hours);
          if (log.water_liters != null && log.water_liters !== 0) next.water = String(log.water_liters);
          return next;
        });
        setDailyLogId(id => id || log.id);
      }
    });
    return unsub;
  }, [todayStr]);

  const handleSave = async (categoryId, value) => {
    setActiveModal(null);

    const today = getTodayISODate();

    try {
      const activeMasterPlan = planContext || await loadActiveCanonicalMasterPlan();

      let targetDailyLog = null;

      if (dailyLogId) {
        const logsById = await backend.entities.DailyLog.filter({ id: dailyLogId }).catch(() => []);
        targetDailyLog = logsById[0] || null;
      }

      if (!targetDailyLog) {
        targetDailyLog = await loadLinkedDailyLogForDate(today, activeMasterPlan);
      }

      // Compute updates now that we have the existing log (needed for additive fields)
      const updates = getDailyLogUpdatesForCategory(categoryId, value, targetDailyLog);
      if (!updates) return;

      // Optimistic UI: for additive fields show the accumulated total, not the raw input
      const uiValue = ADDITIVE_FIELDS.includes(categoryId)
        ? String(Object.values(updates)[0])
        : value;
      setLogged(prev => ({ ...prev, [categoryId]: uiValue }));

      let result = null;

      if (targetDailyLog?.id) {
        result = await backend.entities.DailyLog.update(targetDailyLog.id, updates);
      } else {
        const source =
          activeMasterPlan?.source ||
          activeMasterPlan?.plan_payload?.source ||
          'manual';
        result = await backend.entities.DailyLog.create({
          date: today,
          source,
          source_plan_id: activeMasterPlan?.id || '',
          generation_batch_id: activeMasterPlan?.generation_batch_id || '',
          ...updates,
        });
      }

      if (result?.id) {
        setDailyLogId(result.id);
      } else if (targetDailyLog?.id) {
        setDailyLogId(targetDailyLog.id);
      }

      if (activeMasterPlan && !planContext) {
        setPlanContext(activeMasterPlan);
      }

      appCache.invalidate('home-dashboard');
      appCache.invalidate('nutrition-today-');
      await invalidateUserAIContext();
    } catch (err) {
      console.warn('[Track] Failed to save DailyLog update', err);
    }
  };

  const toggleWidget = (id) => {
    setActiveIds(prev => prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]);
  };

  const addCustomCategory = ({ label, unit }) => {
    const id = `custom_${Date.now()}`;
    const newCat = { id, label, unit, desc: 'Custom tracker', custom: true };
    setCustomCategories(prev => {
      const next = [...prev, newCat];
      saveCustomTrackers(next);
      return next;
    });
    setActiveIds(prev => [...prev, id]);
  };

  const removeCustomCategory = (id) => {
    setCustomCategories(prev => {
      const next = prev.filter(c => c.id !== id);
      saveCustomTrackers(next);
      return next;
    });
    setActiveIds(prev => prev.filter(x => x !== id));
  };

  const allCategories = [...ALL_CATEGORIES, ...customCategories];
  const activeCategories = allCategories.filter(c => activeIds.includes(c.id));

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      <div className="sticky top-0 z-40 px-5 pb-4" style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #ddd6c8', boxShadow: '0 2px 12px rgba(20,22,19,0.06)' }}>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Track</h1>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
              {new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Link to="/tracking-history"
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              History
            </Link>
            <motion.button whileTap={{ scale: 0.92 }} onClick={() => setShowManage(true)}
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              <SlidersHorizontal size={12} />
              Manage
            </motion.button>
          </div>
        </div>
      </div>

      <div className="px-5 pb-8 space-y-4 pt-5">
        <FoodLogger
          caloriesConsumed={logged.cals_consumed ? Number(logged.cals_consumed) : 0}
          caloriesBurned={logged.cals_burned ? Number(logged.cals_burned) : 0}
        />



        {/* Category Grid */}
        <div className="grid grid-cols-2 gap-3">
          <AnimatePresence mode="popLayout">
            {activeCategories.map((cat, i) => {
              const isLogged = !!logged[cat.id];
              return (
                <motion.button
                  key={cat.id}
                  layout
                  initial={{ opacity: 0, scale: 0.9 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.85 }}
                  transition={{ duration: 0.2 }}
                  onClick={() => setActiveModal(cat)}
                  className="relative p-4 rounded-2xl border text-left transition-all active:scale-95"
                  style={{
                    background: isLogged ? (cat.id === 'cals_burned' ? 'rgba(176,90,58,0.04)' : 'rgba(200,224,0,0.05)') : '#ffffff',
                    borderColor: isLogged
                      ? (cat.id === 'cals_burned' ? 'rgba(176,90,58,0.35)' : 'rgba(200,224,0,0.45)')
                      : '#e0d9cc',
                    boxShadow: isLogged ? (cat.id === 'cals_burned' ? '0 2px 10px rgba(176,90,58,0.08)' : '0 2px 10px rgba(200,224,0,0.1)') : '0 1px 6px rgba(20,22,19,0.07)',
                  }}
                >
                  {/* Edit pencil — always show when logged so it's clear you can update */}
                  <div className="absolute top-3 right-3">
                    {isLogged
                      ? <Pencil size={11} style={{ color: cat.id === 'cals_burned' ? '#b05a3a' : ACCENT_DARK, opacity: 0.7 }} />
                      : <Plus size={15} style={{ color: '#d9d1c2' }} />
                    }
                  </div>

                  <div className="w-10 h-10 rounded-xl flex items-center justify-center mb-3"
                    style={{ background: cat.id === 'cals_burned' ? 'rgba(176,90,58,0.12)' : 'rgba(200,224,0,0.12)' }}>
                    {cat.icon
                      ? <cat.icon size={20} style={{ color: cat.id === 'cals_burned' ? '#b05a3a' : '#8ea400' }} />
                      : <Pencil size={20} style={{ color: '#8ea400' }} />}
                  </div>

                  <p className="text-xs font-semibold uppercase tracking-wider mb-0.5" style={{ color: '#91968e' }}>{cat.label}</p>

                  {isLogged ? (
                    <div>
                      {cat.id === 'mood' ? (
                        <p className="text-3xl leading-tight">
                          {['😞','😕','😐','😊','😄'][Number(logged[cat.id]) - 1] || '😐'}
                        </p>
                      ) : (
                        <>
                          <p className="text-lg font-black leading-tight" style={{ color: '#141613' }}>
                            {Array.isArray(logged[cat.id])
                              ? logged[cat.id].length
                              : logged[cat.id]}
                          </p>
                          <p className="text-[10px] font-medium" style={{ color: cat.id === 'cals_burned' ? '#b05a3a' : ACCENT_DARK }}>
                            {Array.isArray(logged[cat.id]) ? 'habits' : cat.unit}
                          </p>
                        </>
                      )}
                    </div>
                  ) : (
                    <p className="text-xs" style={{ color: '#b8b4ac' }}>Tap to log</p>
                  )}
                </motion.button>
              );
            })}
          </AnimatePresence>

          {/* Add widget tile */}
          <motion.button
            layout
            whileTap={{ scale: 0.95 }}
            onClick={() => setShowManage(true)}
            className="p-5 rounded-2xl border-2 border-dashed flex flex-col items-center justify-center gap-2 min-h-[120px]"
            style={{ borderColor: '#d9d1c2', background: 'transparent' }}
          >
            <div className="w-10 h-10 rounded-xl flex items-center justify-center" style={{ background: '#f2efe7' }}>
              <Plus size={18} style={{ color: '#91968e' }} />
            </div>
            <p className="text-xs font-medium" style={{ color: '#91968e' }}>Add widget</p>
          </motion.button>
        </div>

        {/* Completion indicator */}
        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.5 }}
          className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 2px 10px rgba(20,22,19,0.07)' }}>
          {(() => {
            const loggedCount = activeCategories.filter(c => !!logged[c.id]).length;
            const total = activeCategories.length;
            const pct = total > 0 ? (loggedCount / total) * 100 : 0;
            return (
              <>
                <div className="flex items-center justify-between mb-2">
                  <span className="text-sm font-medium" style={{ color: '#141613' }}>Today's Logging</span>
                  <span className="text-sm font-bold" style={{ color: '#8ea400' }}>
                    {loggedCount}/{total}
                  </span>
                </div>
                <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
                  <motion.div className="h-full rounded-full" style={{ background: '#c8e000' }}
                    animate={{ width: `${pct}%` }}
                    transition={{ duration: 0.5 }} />
                </div>
              </>
            );
          })()}
        </motion.div>
      </div>

      <AnimatePresence>
        {activeModal && (
          <LogModal
            category={activeModal}
            onClose={() => setActiveModal(null)}
            onSave={(val) => handleSave(activeModal.id, val)}
            currentValue={logged[activeModal.id]}
          />
        )}
        {showManage && (
          <ManageWidgetsSheet
            activeIds={activeIds}
            onToggle={toggleWidget}
            onClose={() => setShowManage(false)}
            customCategories={customCategories}
            onAddCustom={addCustomCategory}
            onRemoveCustom={removeCustomCategory}
          />
        )}
      </AnimatePresence>
    </div>
  );
}