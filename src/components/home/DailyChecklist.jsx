import { useState, useEffect, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Check, Loader2, SlidersHorizontal, AlertCircle } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, togglePlanItemComplete, invalidateUserAIContext, getTodayISODate } from '@/lib/personalizationSync';
import ChecklistCustomizeModal from './ChecklistCustomizeModal';
import { getHiddenDefaults } from '@/lib/checklistPrefs';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseBestLinkedRecord(records = [], masterPlan = null) {
  const safeRecords = Array.isArray(records) ? records.filter(Boolean).sort(newestFirst) : [];
  if (!safeRecords.length) return null;

  if (masterPlan) {
    const exact = safeRecords.find(r =>
      r.source_plan_id === masterPlan.id &&
      r.generation_batch_id === masterPlan.generation_batch_id
    );
    if (exact) return exact;
    const sourceMatch = safeRecords.find(r => r.source_plan_id === masterPlan.id);
    if (sourceMatch) return sourceMatch;
  }

  return safeRecords.find(r => r.source === 'plan_questionnaire_overview') ||
    safeRecords.find(r => r.plan_payload?.source === 'plan_questionnaire_overview') ||
    safeRecords.find(r => r.source === 'plan_questionnaire_initial') ||
    safeRecords.find(r => r.plan_payload?.source === 'plan_questionnaire_initial') ||
    safeRecords[0] || null;
}

async function loadLinkedEntityForDate(entity, date, masterPlan) {
  if (!entity || !date) return null;
  if (masterPlan?.id && masterPlan?.generation_batch_id) {
    const linked = await entity.filter({
      date,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id,
    }).catch(() => []);
    const best = chooseBestLinkedRecord(linked, masterPlan);
    if (best) return best;
  }
  const dateRecords = await entity.filter({ date }).catch(() => []);
  return chooseBestLinkedRecord(dateRecords, masterPlan);
}

// ─── Build canonical checklist items from today's data ────────────────────────

function buildItemsFromData({ workoutPlan, mealPlan, readiness, customItems, today, hiddenDefaults = [] }) {
  const items = [];
  const isHidden = (type) => hiddenDefaults.includes(type);

  // Workout item
  if (!isHidden('workout')) {
  if (workoutPlan) {
    items.push({
      id: `workout:${today}`,
      type: 'workout',
      title: workoutPlan.name || "Today's Workout",
      description: workoutPlan.type ? `${workoutPlan.type} · ${workoutPlan.duration || ''}`.trim().replace(/·\s*$/, '') : '',
      source: 'workout_plan',
      target_route: '/workouts',
      completed: false,
      completed_at: null,
    });
  } else {
    items.push({
      id: `workout:${today}`,
      type: 'workout',
      title: "Build today's workout",
      description: 'Tap to build a workout tailored to your plan.',
      source: 'placeholder',
      target_route: '/workouts',
      completed: false,
      completed_at: null,
    });
  }
  }

  // Nutrition item
  if (!isHidden('nutrition')) {
  if (mealPlan && mealPlan.total_calories) {
    items.push({
      id: `nutrition:${today}`,
      type: 'nutrition',
      title: 'Nutrition Plan',
      description: `${mealPlan.total_calories} kcal · ${mealPlan.total_protein_g || 0}g protein`,
      source: 'meal_plan',
      target_route: '/nutrition',
      completed: false,
      completed_at: null,
    });
  } else {
    items.push({
      id: `nutrition:${today}`,
      type: 'nutrition',
      title: "Build today's meals",
      description: 'Tap to build meals tailored to your nutrition targets.',
      source: 'placeholder',
      target_route: '/nutrition',
      completed: false,
      completed_at: null,
    });
  }
  }

  // Readiness check-in item
  if (!readiness) {
    items.push({
      id: `readiness:${today}`,
      type: 'readiness',
      title: 'Log Readiness',
      description: 'Log readiness to personalize today.',
      source: 'placeholder',
      target_route: '/recovery',
      completed: false,
      completed_at: null,
    });
  }

  // Recovery item
  if (!isHidden('recovery')) {
    items.push({
      id: `recovery:${today}`,
      type: 'recovery',
      title: 'Recovery Routine',
      description: readiness ? `Readiness score: ${readiness.readiness_score ?? '—'}/100` : 'Stretch & mobility work',
      source: 'recovery',
      target_route: '/recovery',
      completed: false,
      completed_at: null,
    });
  }

  // Custom items from Supabase entity
  for (const ci of customItems) {
    items.push({
      id: `custom:${ci.id}:${today}`,
      type: 'custom',
      title: ci.label,
      description: '',
      source: 'custom',
      custom_item_id: ci.id,
      target_route: null,
      completed: false,
      completed_at: null,
    });
  }

  return items;
}

// Merge generated items with saved DailyLog completion state.
// Never erase completed state. Preserve completed_at.
function mergeWithSavedState(generatedItems, savedItems, planItemsCompleted) {
  const savedMap = {};
  for (const s of (savedItems || [])) {
    savedMap[s.id] = s;
  }
  const completedSet = new Set(planItemsCompleted || []);

  return generatedItems.map(item => {
    const saved = savedMap[item.id];
    const isCompleted = completedSet.has(item.id) || saved?.completed || false;
    return {
      ...item,
      completed: isCompleted,
      completed_at: isCompleted ? (saved?.completed_at || new Date().toISOString()) : null,
    };
  });
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function ChecklistRow({ item, onToggle, justCompleted }) {
  return (
    <motion.button
      onClick={() => onToggle(item.id)}
      className="w-full rounded-xl border overflow-hidden text-left transition-all"
      style={{
        background: item.completed ? 'rgba(200,224,0,0.06)' : '#ffffff',
        borderColor: item.completed ? 'rgba(200,224,0,0.3)' : '#e8e1d4',
      }}
      whileTap={{ scale: 0.98 }}
    >
      <div className="flex items-center gap-3 p-4">
        <motion.div
          className="w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0 border-2 transition-all"
          style={{
            borderColor: item.completed ? ACCENT_DARK : '#d9d1c2',
            background: item.completed ? 'rgba(200,224,0,0.15)' : 'transparent',
          }}
          animate={justCompleted === item.id ? { scale: [1, 1.3, 1] } : {}}
          transition={{ duration: 0.35 }}
        >
          <AnimatePresence>
            {item.completed && (
              <motion.div initial={{ scale: 0 }} animate={{ scale: 1 }} exit={{ scale: 0 }} transition={{ duration: 0.18 }}>
                <Check size={11} style={{ color: ACCENT_DARK }} />
              </motion.div>
            )}
          </AnimatePresence>
        </motion.div>

        <div className="flex-1 min-w-0">
          <p className="text-sm font-medium leading-tight"
            style={{ color: item.completed ? '#91968e' : '#141613', textDecoration: item.completed ? 'line-through' : 'none' }}>
            {item.title}
          </p>
          {item.description && (
            <p className="text-[11px] mt-0.5 leading-snug" style={{ color: '#91968e' }}>
              {item.description}
            </p>
          )}
        </div>

        <div className="w-1.5 h-1.5 rounded-full flex-shrink-0" style={{
          background: item.type === 'workout' ? '#b05a3a'
            : item.type === 'nutrition' ? '#8ea400'
            : item.type === 'recovery' ? '#5d8aa8'
            : item.type === 'readiness' ? '#c8e000'
            : '#7b6fa0',
        }} />
      </div>
    </motion.button>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function DailyChecklist({ onAllDone, onItemToggled }) {
  const [items, setItems] = useState([]);
  const [dailyLogId, setDailyLogId] = useState(null);
  const [planContext, setPlanContext] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saveError, setSaveError] = useState(null);
  const [saving, setSaving] = useState(false);
  const [justCompleted, setJustCompleted] = useState(null);
  const [showCustomize, setShowCustomize] = useState(false);

  const today = getTodayISODate();

  const loadChecklist = useCallback(async () => {
    setLoading(true);
    setSaveError(null);

    const activeMasterPlan = await loadActiveAIPlan('daily').catch(() => null);
    setPlanContext(activeMasterPlan);

    const [mealPlan, workoutPlan, dailyLog, readinessCheckins, customEntityItems, hiddenDefaults] = await Promise.all([
      loadLinkedEntityForDate(backend.entities.MealPlan, today, activeMasterPlan),
      loadLinkedEntityForDate(backend.entities.WorkoutPlan, today, activeMasterPlan),
      loadLinkedEntityForDate(backend.entities.DailyLog, today, activeMasterPlan),
      backend.entities.ReadinessCheckIn.filter({ date: today }).catch(() => []),
      backend.entities.CustomChecklistItem.filter({ is_active: true }).catch(() => []),
      getHiddenDefaults().catch(() => []),
    ]);

    const readiness = readinessCheckins[0] || null;

    setDailyLogId(dailyLog?.id || null);

    // Filter custom items active today
    const dayOfWeek = new Date().getDay();
    const todayStr = today;
    const activeCustom = customEntityItems.filter(ci => {
      if (ci.endsOn && todayStr > ci.endsOn) return false;
      if (ci.days && ci.days.length > 0 && !ci.days.includes(dayOfWeek)) return false;
      return true;
    });

    // Generate canonical items from today's data
    const generated = buildItemsFromData({ workoutPlan, mealPlan, readiness, customItems: activeCustom, today, hiddenDefaults });

    // Merge with saved DailyLog state — never erase completed items
    const savedItems = dailyLog?.checklist_items || dailyLog?.planned_checklist_items || [];
    const planItemsCompleted = dailyLog?.plan_items_completed || [];
    const merged = mergeWithSavedState(generated, savedItems, planItemsCompleted);

    setItems(merged);
    setLoading(false);
  }, [today]);

  useEffect(() => {
    loadChecklist();
  }, [loadChecklist]);

  const persistToggle = async (itemId, updatedItems) => {
    const completedItems = updatedItems.filter(i => i.completed);
    const completedCount = completedItems.length;
    const totalCount = updatedItems.length;
    const adherencePct = totalCount > 0 ? Math.round((completedCount / totalCount) * 100) : 0;
    const planItemsCompleted = completedItems.map(i => i.id);

    setSaving(true);
    setSaveError(null);
    try {
      if (dailyLogId) {
        // Fast path: directly update the known DailyLog with full checklist state
        await backend.entities.DailyLog.update(dailyLogId, {
          checklist_items: updatedItems,
          planned_checklist_items: updatedItems,
          checklist_completed_count: completedCount,
          checklist_total_count: totalCount,
          checklist_adherence_pct: adherencePct,
          plan_items_completed: planItemsCompleted,
        });
      } else {
        // No DailyLog yet — use togglePlanItemComplete which handles upsert safely
        const result = await togglePlanItemComplete(today, itemId, {
          source_plan_id: planContext?.id,
          generation_batch_id: planContext?.generation_batch_id,
        });
        // Cache the new DailyLog ID to avoid repeated upserts
        if (result?.dailyLog?.id) setDailyLogId(result.dailyLog.id);
      }

      await invalidateUserAIContext();
      onItemToggled?.();
    } catch {
      setSaveError('Could not save checklist update. Please try again.');
      await loadChecklist();
    } finally {
      setSaving(false);
    }
  };

  const handleToggle = (itemId) => {
    setItems(prev => {
      const updated = prev.map(item => {
        if (item.id !== itemId) return item;
        const nowDone = !item.completed;
        if (nowDone) setJustCompleted(itemId);
        return {
          ...item,
          completed: nowDone,
          completed_at: nowDone ? new Date().toISOString() : null,
        };
      });
      if (updated.every(i => i.completed)) setTimeout(() => onAllDone?.(), 400);
      persistToggle(itemId, updated);
      return updated;
    });
    setTimeout(() => setJustCompleted(null), 1200);
  };

  const handleCustomizeSave = () => {
    setShowCustomize(false);
    loadChecklist();
  };

  if (loading) {
    return (
      <div className="flex items-center gap-2.5 py-4 px-4 rounded-xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <Loader2 size={14} className="animate-spin" style={{ color: ACCENT_DARK }} />
        <p className="text-sm" style={{ color: '#91968e' }}>Building your daily checklist…</p>
      </div>
    );
  }

  const completedCount = items.filter(i => i.completed).length;
  const adherencePct = items.length > 0 ? Math.round((completedCount / items.length) * 100) : 0;

  return (
    <div>
      {/* Progress bar */}
      <div className="h-1.5 rounded-full overflow-hidden mb-3" style={{ background: '#e8e1d4' }}>
        <motion.div className="h-full rounded-full" style={{ background: ACCENT }}
          animate={{ width: `${adherencePct}%` }} transition={{ duration: 0.5 }} />
      </div>

      {/* Save error */}
      {saveError && (
        <div className="flex items-center gap-2 px-3 py-2.5 rounded-xl mb-3 border text-xs"
          style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
          <AlertCircle size={12} />
          {saveError}
        </div>
      )}

      {/* Checklist items */}
      <div className="space-y-2">
        {items.map(item => (
          <ChecklistRow
            key={item.id}
            item={item}
            onToggle={handleToggle}
            justCompleted={justCompleted}
          />
        ))}
      </div>

      {/* Customize button */}
      <motion.button
        whileTap={{ scale: 0.97 }}
        onClick={() => setShowCustomize(true)}
        className="w-full mt-3 flex items-center justify-center gap-2 py-3 rounded-xl border text-xs font-semibold"
        style={{ background: 'transparent', borderColor: '#e8e1d4', color: '#91968e' }}
      >
        <SlidersHorizontal size={12} />
        Customize Checklist
      </motion.button>

      <AnimatePresence>
        {showCustomize && (
          <ChecklistCustomizeModal
            onClose={() => setShowCustomize(false)}
            onSave={handleCustomizeSave}
          />
        )}
      </AnimatePresence>
    </div>
  );
}