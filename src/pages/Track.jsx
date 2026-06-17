import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Flame, X, Plus, UtensilsCrossed, ChevronRight, SlidersHorizontal, Check, Pencil } from 'lucide-react';
import { Link, useLocation } from 'react-router-dom';
import { backend } from '@/api/backendClient';
import { loadCustomTrackers, saveCustomTrackers } from '@/lib/customTrackers';
import { getTodayISODate } from '@/lib/personalizationSync';
import LogModal from '@/components/track/LogModal';
import { ALL_CATEGORIES, DEFAULT_ACTIVE, ACCENT, ACCENT_DARK } from '@/components/track/categories';
import {
  loadActiveCanonicalMasterPlan,
  loadLinkedDailyLogForDate,
  buildLoggedFromDailyLog,
  saveVitalLog,
} from '@/lib/vitalsLog';

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
  const location = useLocation();
  const openedTrackerKey = useRef(null);
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

    try {
      const res = await saveVitalLog({
        categoryId,
        value,
        planContext,
        dailyLogId,
        onOptimistic: ({ uiValue }) => setLogged(prev => ({ ...prev, [categoryId]: uiValue })),
      });
      if (!res.ok) return;
      setDailyLogId(res.nextDailyLogId);
      if (res.nextPlanContext && !planContext) setPlanContext(res.nextPlanContext);
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

  // Auto-open a logging modal when navigated here with an `openTracker` id
  // (e.g. tapping a vital card on Home). Fire once per navigation.
  useEffect(() => {
    const openTracker = location.state?.openTracker;
    if (!openTracker || openedTrackerKey.current === location.key) return;
    const cat = allCategories.find(c => c.id === openTracker);
    if (cat) {
      openedTrackerKey.current = location.key;
      setActiveModal(cat);
    }
  }, [location.key, location.state, allCategories]);

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