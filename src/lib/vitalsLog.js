import { backend } from '@/api/backendClient';
import { appCache } from '@/lib/appCache';
import { getTodayISODate, invalidateUserAIContext } from '@/lib/personalizationSync';

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

export async function loadActiveCanonicalMasterPlan() {
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

export async function loadLinkedDailyLogForDate(date, masterPlan) {
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

export function buildLoggedFromDailyLog(dailyLog) {
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
export const ADDITIVE_FIELDS = ['steps', 'sleep', 'water'];

export function getDailyLogUpdatesForCategory(categoryId, value, existingLog) {
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

/**
 * Single-sourced DailyLog write for a vitals category. Owns the full
 * read → compute → optimistic → write → invalidate sequence so every caller
 * gets identical additive computation and invalidation ordering.
 *
 * `onOptimistic({ uiValue, updates, targetDailyLog })` fires post-read / pre-write
 * (the same point Track historically did its optimistic setLogged). Callers that
 * hold no cached context (e.g. Home) should instead apply their own read-free
 * optimism before calling this, since the reads below run cold.
 *
 * Returns { ok:false, reason } for unmapped categories, else
 * { ok:true, uiValue, nextDailyLogId, nextPlanContext }.
 */
export async function saveVitalLog({ categoryId, value, planContext = null, dailyLogId = null, onOptimistic = null }) {
  const today = getTodayISODate();

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
  if (!updates) return { ok: false, reason: 'no-mapping' };

  // Optimistic value: for additive fields show the accumulated total, not the raw input
  const uiValue = ADDITIVE_FIELDS.includes(categoryId)
    ? String(Object.values(updates)[0])
    : value;

  onOptimistic?.({ uiValue, updates, targetDailyLog });

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

  appCache.invalidate('home-dashboard');
  appCache.invalidate('nutrition-today-');
  await invalidateUserAIContext();

  return {
    ok: true,
    uiValue,
    nextDailyLogId: result?.id || targetDailyLog?.id || dailyLogId || null,
    nextPlanContext: activeMasterPlan || planContext || null,
  };
}
