/**
 * Unified AI Context System for Execute
 *
 * getUserAIContext() builds a rich, personalized prompt string entirely
 * from Supabase entities. It uses the canonical Plan Questionnaire master AIPlan
 * as the plan source of truth and distinguishes planned recommendations from
 * completed user behavior.
 */

import { backend } from '@/api/backendClient';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

const STALE_MS = 5 * 60 * 1000;
const CONTEXT_VERSION = 'canonical_ssot_v1';

export async function getUserPersonalizationContext({ forceRefresh = false } = {}) {
  try {
    const user = await backend.auth.me();
    const userId = user?.email || user?.id || 'anonymous';

    if (!forceRefresh) {
      const cached = await loadCachedContext(userId);
      if (cached) return cached;
    }

    return buildFullContext(userId);
  } catch {
    return buildEmptyFallbackContext();
  }
}

async function loadCachedContext(userId) {
  try {
    const records = await backend.entities.UserAIContext.filter({ userId });
    if (!records.length) return null;

    const record = records[0];

    if (!record.lastUpdatedAt) return null;
    if (!record.profileSummary?.includes(CONTEXT_VERSION)) return null;

    const age = Date.now() - new Date(record.lastUpdatedAt).getTime();
    if (age > STALE_MS) return null;

    return assembleContextString(record);
  } catch {
    return null;
  }
}

async function buildFullContext(userId) {
  const todayISO = getTodayISODate();

  const [
    rGoals,
    rWorkoutProfile,
    rNutritionProfile,
    rUserProfile,
    rInjuries,
    rWorkoutLogs,
    rFoodLogs,
    rReadiness,
    rDailyLogs,
    rActiveMasterPlan,
  ] = await Promise.allSettled([
    backend.entities.Goal.filter({ status: 'active' }, '-created_date', 10),
    backend.entities.WorkoutProfile.list('-updated_date', 1),
    backend.entities.NutritionProfile.list('-updated_date', 1),
    backend.entities.UserProfile.list('-updated_date', 1),
    backend.entities.InjuryProfile.filter({ is_active: true }, '-created_date', 10),
    backend.entities.WorkoutLog.list('-date', 10),
    backend.entities.FoodLog.list('-date', 10),
    backend.entities.ReadinessCheckIn.list('-date', 7),
    backend.entities.DailyLog.list('-date', 14),
    loadActiveCanonicalMasterPlan(),
  ]);

  const goals = getValue(rGoals, []);
  const workoutProfile = getValue(rWorkoutProfile, [])[0] || null;
  const nutritionProfile = getValue(rNutritionProfile, [])[0] || null;
  const userProfile = getValue(rUserProfile, [])[0] || null;
  const injuries = getValue(rInjuries, []);
  const workoutLogs = getValue(rWorkoutLogs, []);
  const foodLogs = getValue(rFoodLogs, []);
  const readinessList = getValue(rReadiness, []);
  const dailyLogs = getValue(rDailyLogs, []);
  const activeMasterPlan = getValue(rActiveMasterPlan, null);

  const [
    todayDailyLog,
    todayWorkoutPlan,
    todayMealPlan,
  ] = await Promise.all([
    loadLinkedEntityForDate(backend.entities.DailyLog, todayISO, activeMasterPlan),
    loadLinkedEntityForDate(backend.entities.WorkoutPlan, todayISO, activeMasterPlan),
    loadLinkedEntityForDate(backend.entities.MealPlan, todayISO, activeMasterPlan),
  ]);

  const profileSummary = buildProfileSummary(userProfile, activeMasterPlan);
  const goalsSummary = buildGoalsSummary(goals);
  const fitnessSummary = buildFitnessSummary(workoutProfile, activeMasterPlan);
  const nutritionSummary = buildNutritionSummary(nutritionProfile, activeMasterPlan, todayMealPlan);
  const injurySummary = buildInjurySummary(injuries);
  const equipmentSummary = buildEquipmentSummary(workoutProfile);
  const preferencesSummary = buildPreferencesSummary(userProfile, workoutProfile, nutritionProfile);
  const masterPlanSummary = buildMasterPlanSummary(activeMasterPlan, todayDailyLog, todayWorkoutPlan, todayMealPlan);
  const recentWorkoutSummary = buildRecentWorkoutSummary(workoutLogs, todayWorkoutPlan, dailyLogs, activeMasterPlan);
  const recentNutritionSummary = buildRecentNutritionSummary(foodLogs, todayMealPlan, dailyLogs, nutritionProfile, activeMasterPlan);
  const recentRecoverySummary = buildRecentRecoverySummary(readinessList, dailyLogs, todayDailyLog, activeMasterPlan);
  const weeklyPlanSummary = buildWeeklyPlanSummary(activeMasterPlan);

  const contextRecord = {
    userId,
    profileSummary,
    goalsSummary,
    fitnessSummary,
    nutritionSummary,
    injurySummary,
    equipmentSummary,
    preferencesSummary,
    recentWorkoutSummary,
    recentNutritionSummary,
    recentRecoverySummary,
    lastUpdatedAt: new Date().toISOString(),
  };

  saveContextEntity(userId, contextRecord).catch(() => {});

  return assembleContextString(contextRecord, {
    masterPlanSummary,
    weeklyPlanSummary,
  });
}

async function saveContextEntity(userId, data) {
  try {
    const existing = await backend.entities.UserAIContext.filter({ userId });
    if (existing.length > 0) {
      await backend.entities.UserAIContext.update(existing[0].id, data);
    } else {
      await backend.entities.UserAIContext.create(data);
    }
  } catch {}
}

function assembleContextString(record, extra = {}) {
  const masterPlanSummary = extra.masterPlanSummary || '';
  const weeklyPlanSummary = extra.weeklyPlanSummary || '';

  return `
=== USER PERSONALIZATION CONTEXT ===

[Active Master Plan Source Of Truth]
${masterPlanSummary || 'No active canonical Plan Questionnaire master AIPlan found'}

[Profile]
${record.profileSummary || 'No profile data available'}

[Goals]
${record.goalsSummary || 'No active goals set'}

[Fitness & Training]
${record.fitnessSummary || 'No workout preferences set'}

[Equipment]
${record.equipmentSummary || 'Not specified'}

[Injuries & Limitations]
${record.injurySummary || 'None logged'}

[Nutrition Preferences]
${record.nutritionSummary || 'No nutrition preferences set'}

[Preferences & Coaching Style]
${record.preferencesSummary || 'Not set'}

[Recent Workouts - completed behavior vs planned workouts]
${record.recentWorkoutSummary || 'No recent workouts logged'}

[Recent Nutrition - logged intake vs planned meals]
${record.recentNutritionSummary || 'No recent food logs'}

[Recent Recovery & Readiness]
${record.recentRecoverySummary || 'No recent check-ins'}

${weeklyPlanSummary ? `[Active Weekly Plan Projection]\n${weeklyPlanSummary}` : ''}

CRITICAL AI RULES - FOLLOW THESE WITHOUT EXCEPTION:
- The canonical plan source is the active daily AIPlan where source is "plan_questionnaire_overview". Fallback legacy source is "plan_questionnaire_initial".
- Weekly overview lives on active AIPlan.weekly_overview or active AIPlan.plan_payload.weekly_overview.
- Do not assume weekly child AIPlan records exist.
- Workouts are generated on demand for one date at a time.
- Meals are generated on demand for one date at a time.
- DailyLogs are deterministic execution records, not AI-generated plans.
- Child records with matching source_plan_id and generation_batch_id belong to the active master plan.
- Planned workouts, meals, recovery tasks, and checklist items are recommendations, not completed behavior.
- Completed workouts come from WorkoutLog records with status "completed".
- Logged nutrition comes from FoodLog and DailyLog records, not MealPlan alone.
- Readiness guidance may adapt today's advice, but must not replace the master plan.
- DISLIKED FOODS: Any food listed under "DISLIKED FOODS" must never appear in any meal, ingredient list, or suggestion.
- ALLERGIES/RESTRICTIONS: Never include any restricted or allergenic food.
- CALORIE TARGET: Use the active plan target if present. If not set, calculate carefully from available user data and state assumptions.
- Never give generic advice when user context is present.
- Always adapt recommendations to goals, injuries, equipment, diet, and recent logs.
- Do not recommend exercises that conflict with active injuries or limitations.
- Use safety language: "suggestion", "recommendation", "guidance". Never diagnose or treat.
- Keep advice practical, specific, and immediately actionable.
`.trim();
}

function buildEmptyFallbackContext() {
  return `
=== USER PERSONALIZATION CONTEXT ===

[Profile]
Profile data unavailable because backend context could not be loaded.

[Note]
User context could not be loaded. Provide general, safe guidance without making assumptions about body stats, goals, injuries, dietary restrictions, calorie targets, or training capacity.
Use safety language: "suggestion", "recommendation", "guidance". Never diagnose or treat.
`.trim();
}

function getTodayISODate() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.completed_at || a?.date || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.completed_at || b?.date || b?.updated_date || b?.created_date || '';
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

async function loadLinkedEntityForDate(entity, date, masterPlan) {
  if (!entity || !date) return null;

  if (masterPlan?.id && masterPlan?.generation_batch_id) {
    const linkedRecords = await entity.filter({
      date,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id,
    }).catch(() => []);

    const linkedRecord = chooseBestLinkedRecord(linkedRecords, masterPlan);
    if (linkedRecord) return linkedRecord;
  }

  const dateRecords = await entity.filter({ date }).catch(() => []);
  return chooseBestLinkedRecord(dateRecords, masterPlan);
}

// Weekly child AIPlan records are legacy and should not be queried.
// The weekly overview now lives on active master AIPlan.weekly_overview.
async function loadLinkedWeeklyPlan() {
  return null;
}

function getValue(result, fallback) {
  return result.status === 'fulfilled' ? result.value : fallback;
}

function formatArray(value) {
  return Array.isArray(value) && value.length ? value.join(', ') : '';
}

function buildProfileSummary(up, masterPlan) {
  const parts = [`Context version: ${CONTEXT_VERSION}`];

  if (!up) {
    parts.push('No profile set up yet');
  } else {
    if (up.display_name) parts.push(`Name: ${up.display_name}`);
    if (up.age) parts.push(`Age: ${up.age}`);
    if (up.sex) parts.push(`Sex: ${up.sex}`);
    if (up.weight_kg) parts.push(`Weight: ${up.weight_kg}kg`);
    if (up.height_cm) parts.push(`Height: ${up.height_cm}cm`);
    if (up.fitness_level) parts.push(`Fitness level: ${up.fitness_level}`);
    if (up.coaching_style) parts.push(`Coaching style: ${up.coaching_style}`);
  }

  if (masterPlan?.id) {
    parts.push(`Active master AIPlan id: ${masterPlan.id}`);
    parts.push(`Active generation_batch_id: ${masterPlan.generation_batch_id || 'missing'}`);
    parts.push(`Plan source: ${masterPlan.source || masterPlan.plan_payload?.source || 'unknown'}`);
  }

  return parts.join(' | ');
}

function buildGoalsSummary(goals) {
  if (!goals?.length) return 'No active goals set';

  return goals.map(g => {
    const parts = [`${g.title || 'Goal'}`];
    if (g.category) parts.push(`category: ${g.category}`);
    if (g.target_value) parts.push(`target: ${g.target_value} ${g.unit || ''}`.trim());
    if (g.timeline) parts.push(`timeline: ${g.timeline}`);
    if (g.priority) parts.push(`priority: ${g.priority}`);
    return `- ${parts.join(' | ')}`;
  }).join('\n');
}

function buildFitnessSummary(wp, masterPlan) {
  const parts = [];

  if (wp) {
    if (wp.primary_goal) parts.push(`Goal: ${wp.primary_goal}`);
    if (wp.experience_level) parts.push(`Level: ${wp.experience_level}`);
    if (wp.days_per_week) parts.push(`${wp.days_per_week}x/week`);
    if (wp.session_duration_min) parts.push(`${wp.session_duration_min} min/session`);
    if (wp.preferred_split) parts.push(`Split: ${wp.preferred_split}`);
    if (wp.cardio_preference) parts.push(`Cardio: ${wp.cardio_preference}`);
    if (wp.aggressiveness) parts.push(`Plan aggressiveness: ${wp.aggressiveness}`);
    if (wp.plan_type) parts.push(`Plan type: ${wp.plan_type}`);
    if (wp.limitations_summary) parts.push(`Limitations summary: ${wp.limitations_summary}`);
    if (wp.desired_activity_level) parts.push(`Desired activity level: ${wp.desired_activity_level}`);
    if (wp.current_activity_level) parts.push(`Current activity level: ${wp.current_activity_level}`);
    if (wp.focus_areas?.length) parts.push(`Focus: ${wp.focus_areas.join(', ')}`);
  }

  const trainingStrategy = masterPlan?.plan_payload?.long_term_plan?.training_strategy;
  if (trainingStrategy) parts.push(`Active plan training strategy: ${trainingStrategy}`);

  return parts.join(' | ') || 'No workout preferences set';
}

function buildNutritionSummary(np, masterPlan, todayMealPlan) {
  const parts = [];

  const planTargets = masterPlan?.plan_payload?.nutrition_targets || {};

  const calories = planTargets.calories || np?.calorie_target || todayMealPlan?.total_calories || null;
  const protein = planTargets.protein || np?.protein_target_g || todayMealPlan?.total_protein_g || todayMealPlan?.total_protein || null;
  const carbs = planTargets.carbs || np?.carbs_target_g || todayMealPlan?.total_carbs_g || todayMealPlan?.total_carbs || null;
  const fats = planTargets.fat || planTargets.fats || np?.fats_target_g || todayMealPlan?.total_fats_g || todayMealPlan?.total_fat || null;
  const hydration = planTargets.hydration_target || np?.hydration_target || null;

  parts.push(`Daily calorie target: ${calories || 'NOT SET'}`);
  if (protein) parts.push(`Protein target: ${protein}g`);
  if (carbs) parts.push(`Carbs target: ${carbs}g`);
  if (fats) parts.push(`Fat target: ${fats}g`);
  if (hydration) parts.push(`Hydration target: ${hydration}L`);

  if (np?.dietary_preference) parts.push(`Dietary preference: ${np.dietary_preference}`);
  if (np?.meals_per_day) parts.push(`Meals per day: ${np.meals_per_day}`);
  if (np?.cooking_style) parts.push(`Cooking style: ${np.cooking_style}`);
  if (np?.nutrition_struggles?.length) parts.push(`Nutrition struggles: ${np.nutrition_struggles.join(', ')}`);
  if (np?.notes) parts.push(`Nutrition notes: ${np.notes}`);

  const allergies = formatArray(np?.allergies) || 'None';
  parts.push(`Allergies/restrictions: ${allergies}`);

  const disliked = formatArray(np?.disliked_foods) || 'None';
  parts.push(`DISLIKED FOODS - NEVER include: ${disliked}`);

  const liked = formatArray(np?.liked_foods) || 'Not specified';
  parts.push(`Preferred/liked foods: ${liked}`);

  const nutritionStrategy = masterPlan?.plan_payload?.long_term_plan?.nutrition_strategy;
  if (nutritionStrategy) parts.push(`Active plan nutrition strategy: ${nutritionStrategy}`);

  if (todayMealPlan?.id) {
    parts.push(`Today's planned MealPlan id: ${todayMealPlan.id}`);
    parts.push(`MealPlan source_plan_id: ${todayMealPlan.source_plan_id || 'missing'}`);
    parts.push(`MealPlan generation_batch_id: ${todayMealPlan.generation_batch_id || 'missing'}`);
  }

  return parts.join('\n');
}

function buildInjurySummary(injuries) {
  if (!injuries?.length) return 'No active injuries or limitations';

  return injuries.map(i => {
    const parts = [];
    if (i.body_area) parts.push(i.body_area);
    if (i.severity) parts.push(`severity: ${String(i.severity).replace(/_/g, ' ')}`);
    if (i.description) parts.push(`description: ${i.description}`);
    if (i.notes) parts.push(`notes: ${i.notes}`);
    if (i.source) parts.push(`source: ${i.source}`);
    return `- ${parts.join(' | ')}`;
  }).join('\n');
}

function buildEquipmentSummary(wp) {
  const eq = wp?.equipment_available || [];
  return eq.length ? eq.join(', ') : 'Not specified - assume full gym access unless user says otherwise';
}

function buildPreferencesSummary(up, wp, np) {
  const parts = [];

  if (up?.coaching_style) parts.push(`Coaching style: ${up.coaching_style}`);
  if (wp?.preferred_split) parts.push(`Workout split: ${wp.preferred_split}`);
  if (wp?.cardio_preference) parts.push(`Cardio: ${wp.cardio_preference}`);
  if (np?.disliked_foods?.length) parts.push(`Foods to avoid: ${np.disliked_foods.join(', ')}`);
  if (np?.liked_foods?.length) parts.push(`Foods user likes: ${np.liked_foods.join(', ')}`);

  return parts.join(' | ') || 'No specific preferences set';
}

function buildMasterPlanSummary(masterPlan, todayDailyLog, todayWorkoutPlan, todayMealPlan) {
  if (!masterPlan) {
    return 'No active canonical master AIPlan found. User may need to complete the Plan Questionnaire.';
  }

  const payload = masterPlan.plan_payload || {};
  const planSummary = masterPlan.plan_summary || payload.plan_summary || {};
  const trainingSplit = masterPlan.training_split || payload.training_split || {};
  const nutritionTargets = masterPlan.nutrition_targets || payload.nutrition_targets || {};
  const recoveryStrategy = masterPlan.recovery_strategy || payload.recovery_strategy || {};

  const parts = [
    `Master AIPlan id: ${masterPlan.id}`,
    `Source: ${masterPlan.source || payload.source || 'unknown'}`,
    `Generation batch id: ${masterPlan.generation_batch_id || payload.generation_batch_id || 'missing'}`,
    `Created from: ${masterPlan.created_from || 'unknown'}`,
    `Status: ${masterPlan.status || 'unknown'}`,
  ];

  if (masterPlan.summary) parts.push(`Summary: ${masterPlan.summary}`);
  if (planSummary.primary_goal) parts.push(`Primary goal: ${planSummary.primary_goal}`);
  if (planSummary.training_focus) parts.push(`Training focus: ${planSummary.training_focus}`);
  if (planSummary.nutrition_focus) parts.push(`Nutrition focus: ${planSummary.nutrition_focus}`);
  if (planSummary.recovery_focus) parts.push(`Recovery focus: ${planSummary.recovery_focus}`);
  if (trainingSplit.split_type) parts.push(`Training split: ${trainingSplit.split_type}`);
  if (nutritionTargets.calories) parts.push(`Calorie target: ${nutritionTargets.calories}`);
  if (nutritionTargets.protein_g) parts.push(`Protein target: ${nutritionTargets.protein_g}g`);
  if (recoveryStrategy.readiness_adjustment_rule) parts.push(`Recovery adjustment rule: ${recoveryStrategy.readiness_adjustment_rule}`);

  if (masterPlan.weekly_overview || masterPlan.plan_payload?.weekly_overview) {
    parts.push('Weekly overview is stored on the active master AIPlan.');
  }

  if (todayWorkoutPlan?.id) {
    parts.push(`Today's planned workout: ${todayWorkoutPlan.name || todayWorkoutPlan.focus || 'Workout'} (${todayWorkoutPlan.id})`);
  }

  if (todayMealPlan?.id) {
    parts.push(`Today's planned meal plan id: ${todayMealPlan.id}`);
  }

  if (todayDailyLog?.id) {
    parts.push(`Today's linked DailyLog id: ${todayDailyLog.id}`);
    if (todayDailyLog.planned_recovery_tasks?.length) {
      parts.push(`Today's planned recovery tasks: ${todayDailyLog.planned_recovery_tasks.map(t => t.title || t.name || t.id || 'task').join(', ')}`);
    }
    if (todayDailyLog.planned_checklist_items?.length) {
      parts.push(`Today's planned checklist count: ${todayDailyLog.planned_checklist_items.length}`);
    }
  }

  return parts.join('\n');
}

function buildRecentWorkoutSummary(workoutLogs, currentPlan, dailyLogs, masterPlan) {
  const parts = [];

  if (currentPlan) {
    parts.push(`Planned workout today: ${currentPlan.name || currentPlan.focus || 'Workout'}`);
    parts.push(`Planned workout id: ${currentPlan.id}`);
    parts.push(`Planned workout source_plan_id: ${currentPlan.source_plan_id || 'missing'}`);
    parts.push(`Planned workout generation_batch_id: ${currentPlan.generation_batch_id || 'missing'}`);
    if (currentPlan.exercises?.length) parts.push(`Planned exercise count: ${currentPlan.exercises.length}`);
  }

  const completedLogs = (workoutLogs || []).filter(log => log.status === 'completed');
  if (completedLogs.length > 0) {
    parts.push('Recent completed workout sessions:');
    completedLogs.slice(0, 5).forEach(log => {
      const linked = masterPlan && sameValue(log.source_plan_id, masterPlan.id) ? 'linked to active plan' : 'not clearly linked to active plan';
      parts.push(`- ${log.date}: ${log.workout_name || 'Session'} | ${log.duration_minutes || log.workout_duration_min || '?'} min | ${linked}`);
    });
  }

  const workoutDays = (dailyLogs || []).filter(d => d.workout_done);
  if (workoutDays.length > 0) {
    parts.push(`DailyLog workout_done days: ${workoutDays.slice(0, 7).map(d => d.date).join(', ')}`);
  }

  if (!parts.length) return 'No recent completed workouts logged and no planned workout found for today';

  return parts.join('\n');
}

function buildRecentNutritionSummary(foodLogs, currentMealPlan, dailyLogs, np, masterPlan) {
  const parts = [];

  if (currentMealPlan) {
    parts.push(`Planned meal plan today id: ${currentMealPlan.id}`);
    parts.push(`MealPlan source_plan_id: ${currentMealPlan.source_plan_id || 'missing'}`);
    parts.push(`MealPlan generation_batch_id: ${currentMealPlan.generation_batch_id || 'missing'}`);
    if (currentMealPlan.total_calories) parts.push(`Planned calories: ${currentMealPlan.total_calories}`);
    if (currentMealPlan.total_protein_g || currentMealPlan.total_protein) parts.push(`Planned protein: ${currentMealPlan.total_protein_g || currentMealPlan.total_protein}g`);
  }

  if (foodLogs?.length > 0) {
    parts.push('Recent logged food intake:');
    foodLogs.slice(0, 5).forEach(log => {
      parts.push(`- ${log.date} (${log.meal_type || 'meal'}): ${log.total_calories || log.calories || '?'} kcal | protein ${log.total_protein_g || log.protein || '?'}g`);
    });
  }

  const nutritionDays = (dailyLogs || []).filter(d => d.calories_consumed > 0 || d.protein_consumed_g > 0).slice(0, 7);
  if (nutritionDays.length > 0) {
    parts.push(`Recent DailyLog nutrition: ${nutritionDays.map(d => `${d.date}: ${d.calories_consumed || 0} kcal, ${d.protein_consumed_g || 0}g protein`).join(' | ')}`);
  }

  if (np?.disliked_foods?.length) {
    parts.push(`Foods to avoid in any suggestions: ${np.disliked_foods.join(', ')}`);
  }

  if (!parts.length) return 'No recent food logs and no current planned meal found';

  if (masterPlan?.id) {
    parts.push(`Use active master plan id ${masterPlan.id} for nutrition context.`);
  }

  return parts.join('\n');
}

function buildRecentRecoverySummary(readinessList, dailyLogs, todayDailyLog, masterPlan) {
  const parts = [];

  if (readinessList?.length > 0) {
    parts.push('Recent readiness check-ins:');
    readinessList.slice(0, 5).forEach(r => {
      parts.push(`- ${r.date}: energy ${r.energy}/10, soreness ${r.soreness}/10, sleep ${r.sleep_quality}/10, stress ${r.stress}/10, readiness ${r.readiness_score || '?'}/100`);
      if (r.training_recommendation) parts.push(`  Recommendation: ${r.training_recommendation}`);
    });
  }

  const sleepDays = (dailyLogs || []).filter(d => d.sleep_hours > 0).slice(0, 7);
  if (sleepDays.length > 0) {
    const avg = (sleepDays.reduce((sum, d) => sum + Number(d.sleep_hours || 0), 0) / sleepDays.length).toFixed(1);
    parts.push(`Average sleep over ${sleepDays.length} logged days: ${avg}h`);
  }

  if (todayDailyLog?.planned_recovery_tasks?.length) {
    parts.push(`Today's planned recovery tasks: ${todayDailyLog.planned_recovery_tasks.map(t => t.title || t.name || t.id || 'task').join(', ')}`);
  }

  if (todayDailyLog?.recovery_score) {
    parts.push(`Today's DailyLog recovery score: ${todayDailyLog.recovery_score}`);
  }

  if (masterPlan?.plan_payload?.long_term_plan?.recovery_strategy) {
    parts.push(`Active plan recovery strategy: ${masterPlan.plan_payload.long_term_plan.recovery_strategy}`);
  }

  return parts.join('\n') || 'No recent recovery check-ins or recovery logs';
}

function buildWeeklyPlanSummary(masterPlan) {
  const payload =
    masterPlan?.weekly_overview ||
    masterPlan?.plan_payload?.weekly_overview ||
    null;
  if (!payload) return '';

  const parts = [];

  if (masterPlan?.id) parts.push(`Master AIPlan id: ${masterPlan.id}`);
  if (masterPlan?.generation_batch_id) parts.push(`Master generation_batch_id: ${masterPlan.generation_batch_id}`);
  parts.push(`Weekly overview source: ${masterPlan?.source || masterPlan?.plan_payload?.source || 'unknown'}`);

  if (payload.week_start_date) parts.push(`Week start: ${payload.week_start_date}`);

  if (Array.isArray(payload.days) && payload.days.length) {
    parts.push('Weekly day overview:');
    payload.days.slice(0, 7).forEach(day => {
      const sessionTitle = getPlanDaySessionTitle(day, day.training_type || day.dayFocus || day.day_focus || '');
      const training = day.training_type || day.dayFocus || day.day_focus || '';
      const nutrition = day.nutrition_focus || '';
      const recovery = day.recovery_focus || '';
      const priority = day.priority || '';
      parts.push(`- ${day.date || 'day'} (${day.day_label || ''}): ${sessionTitle}${training ? ` | type: ${training}` : ''}${priority ? ` | priority: ${priority}` : ''}${nutrition ? ` | nutrition: ${nutrition}` : ''}${recovery ? ` | recovery: ${recovery}` : ''}`);
    });
  }

  return parts.join('\n');
}

export async function refreshAIContext() {
  return getUserPersonalizationContext({ forceRefresh: true });
}

// Backward-compatible alias
export { getUserPersonalizationContext as getUserAIContext };
