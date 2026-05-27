/**
 * ensureDailyLogForDate.js
 *
 * Phase 5A — Deterministic DailyLog helper.
 *
 * Creates or updates exactly one DailyLog for a date using the active
 * lightweight AIPlan.weekly_overview. No AI calls. No WorkoutPlan or
 * MealPlan records created.
 */

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, loadDailyLogByDate } from '@/lib/personalizationSync';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

// ─── Internal helpers ─────────────────────────────────────────────────────────

function newestFirst(a, b) {
  const aDate = a?.updated_date || a?.created_date || '';
  const bDate = b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function hasExercises(plan) {
  return Array.isArray(plan?.exercises) && plan.exercises.length > 0;
}

function hasMeals(plan) {
  const meals = plan?.meals;
  if (!meals) return false;
  if (Array.isArray(meals)) return meals.length >= 3;
  return !!(meals.breakfast || meals.lunch || meals.dinner);
}

/**
 * Pick best linked record from a list, preferring master plan linkage.
 * kind: 'workout' | 'meal'
 */
function chooseBestLinkedRecord(records = [], masterPlan = null, kind = 'workout') {
  const safe = Array.isArray(records) ? records.filter(Boolean).sort(newestFirst) : [];
  if (!safe.length) return null;

  if (masterPlan?.id) {
    // Exact batch + source match
    const exact = safe.find(r =>
      r.source_plan_id === masterPlan.id &&
      r.generation_batch_id === masterPlan.generation_batch_id
    );
    if (exact) return exact;

    // Source plan match
    const sourceMatch = safe.find(r => r.source_plan_id === masterPlan.id);
    if (sourceMatch) return sourceMatch;
  }

  // Prefer plan_questionnaire_overview
  const overviewMatch = safe.find(r => r.source === 'plan_questionnaire_overview');
  if (overviewMatch) return overviewMatch;

  // Prefer records with useful data
  if (kind === 'workout') {
    const withExercises = safe.find(hasExercises);
    if (withExercises) return withExercises;
  } else if (kind === 'meal') {
    const withMeals = safe.find(hasMeals);
    if (withMeals) return withMeals;
  }

  return safe[0] || null;
}

function buildChecklistItems(date, overviewDay) {
  const items = [];
  const sessionTitle = getPlanDaySessionTitle(overviewDay, 'Complete workout');

  if (overviewDay.workout_needed !== false) {
    items.push({
      id: `workout:${date}`,
      type: 'workout',
      title: sessionTitle,
      description: overviewDay.priority || "Complete today's workout",
      status: 'planned',
    });
  }

  items.push({
    id: `nutrition:${date}`,
    type: 'nutrition',
    title: 'Hit nutrition target',
    description: overviewDay.nutrition_focus || 'Stay aligned with your nutrition targets',
    status: 'planned',
  });

  items.push({
    id: `recovery:${date}`,
    type: 'recovery',
    title: 'Recovery focus',
    description: overviewDay.recovery_focus || 'Complete your recovery focus',
    status: 'planned',
  });

  return items;
}

function buildRecoveryTasks(date, overviewDay) {
  return [
    {
      id: `recovery_${date}_1`,
      type: 'recovery',
      title: overviewDay.recovery_focus || 'Recovery focus',
      description: overviewDay.recovery_focus || 'Complete your recovery focus',
      duration_minutes: 10,
      status: 'planned',
    },
  ];
}

function calculateChecklistStats(items, completedIds = []) {
  const total = items.length;
  const completed = items.filter(item => completedIds.includes(item.id)).length;
  const pct = total > 0 ? Math.round((completed / total) * 100) : 0;
  return { checklist_total_count: total, checklist_completed_count: completed, checklist_adherence_pct: pct };
}

// ─── Main export ──────────────────────────────────────────────────────────────

/**
 * Ensures one DailyLog exists for the given date, populated deterministically
 * from the active AIPlan.weekly_overview.
 *
 * @param {string} date - YYYY-MM-DD
 * @param {{
 *   masterPlan?: object,
 *   createIfMissing?: boolean,
 *   linkExistingPlans?: boolean
 * }} options
 * @returns {Promise<{ status: string, dailyLog: object|null, masterPlan: object|null, overviewDay: object|null }>}
 */
export async function ensureDailyLogForDate(date, options = {}) {
  const {
    masterPlan: masterPlanOption,
    createIfMissing = true,
    linkExistingPlans = true,
  } = options;

  try {
    // 1. Load master plan
    const masterPlan = masterPlanOption || await loadActiveAIPlan('daily').catch(() => null);

    // 2. Extract weekly overview
    const overview =
      masterPlan?.weekly_overview ||
      masterPlan?.plan_payload?.weekly_overview ||
      null;

    // 3. Find overview day
    const overviewDay = overview?.days?.find(day => day.date === date) || null;

    // 4. No master plan at all — nothing we can do
    if (!masterPlan) {
      return { status: 'no_plan', dailyLog: null, masterPlan: null, overviewDay: null };
    }

    // 5. Load existing DailyLog
    const existing = await loadDailyLogByDate(date, { masterPlan }).catch(() => null);

    // 6. Build deterministic checklist items (only when overviewDay available)
    const planned_checklist_items = overviewDay ? buildChecklistItems(date, overviewDay) : (existing?.planned_checklist_items || []);
    const planned_recovery_tasks = overviewDay ? buildRecoveryTasks(date, overviewDay) : (existing?.planned_recovery_tasks || []);

    // 7. Preserve existing completion state
    const completedIds = existing?.plan_items_completed || [];
    const stats = calculateChecklistStats(planned_checklist_items, completedIds);

    // 8. Optionally link existing child plans
    let planned_workout_id = existing?.planned_workout_id || null;
    let planned_meal_plan_id = existing?.planned_meal_plan_id || null;

    if (linkExistingPlans) {
      // Look up WorkoutPlan
      let workoutCandidates = [];
      if (masterPlan.id && masterPlan.generation_batch_id) {
        workoutCandidates = await backend.entities.WorkoutPlan.filter({
          date,
          source_plan_id: masterPlan.id,
          generation_batch_id: masterPlan.generation_batch_id,
        }).catch(() => []);
      }
      if (!workoutCandidates.length) {
        workoutCandidates = await backend.entities.WorkoutPlan.filter({ date }).catch(() => []);
      }
      const bestWorkout = chooseBestLinkedRecord(workoutCandidates, masterPlan, 'workout');
      if (bestWorkout?.id) planned_workout_id = bestWorkout.id;

      // Look up MealPlan
      let mealCandidates = [];
      if (masterPlan.id && masterPlan.generation_batch_id) {
        mealCandidates = await backend.entities.MealPlan.filter({
          date,
          source_plan_id: masterPlan.id,
          generation_batch_id: masterPlan.generation_batch_id,
        }).catch(() => []);
      }
      if (!mealCandidates.length) {
        mealCandidates = await backend.entities.MealPlan.filter({ date }).catch(() => []);
      }
      const bestMeal = chooseBestLinkedRecord(mealCandidates, masterPlan, 'meal');
      if (bestMeal?.id) planned_meal_plan_id = bestMeal.id;
    }

    const source =
      masterPlan.source ||
      masterPlan.plan_payload?.source ||
      'plan_questionnaire_overview';

    const planningFields = {
      source,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id || '',
      planned_checklist_items,
      checklist_items: planned_checklist_items,
      planned_recovery_tasks,
      planned_workout_id,
      planned_meal_plan_id,
      checklist_total_count: stats.checklist_total_count,
      checklist_completed_count: stats.checklist_completed_count,
      checklist_adherence_pct: stats.checklist_adherence_pct,
      daily_plan_source: 'deterministic_from_ai_plan',
    };

    let dailyLog;

    if (existing?.id) {
      // 9. Update only deterministic planning fields — never overwrite tracked data
      dailyLog = await backend.entities.DailyLog.update(existing.id, planningFields);
    } else {
      // 10. No existing log
      if (!createIfMissing) {
        return { status: 'missing', dailyLog: null, masterPlan, overviewDay };
      }

      // 11. Create new DailyLog
      dailyLog = await backend.entities.DailyLog.create({
        date,
        ...planningFields,
        plan_items_completed: [],
        checklist_completed_count: 0,
        checklist_adherence_pct: 0,
      });
    }

    return { status: 'ready', dailyLog, masterPlan, overviewDay };

  } catch (err) {
    console.error('[ensureDailyLogForDate] Error:', err);
    return { status: 'error', dailyLog: null, masterPlan: null, overviewDay: null, error: err?.message };
  }
}
