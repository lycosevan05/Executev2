/**
 * profilePlanSync.js
 *
 * Bridges the Profile customise panels with the active AIPlan.
 *
 * Rule: when an active AIPlan exists, its values are the source of truth for
 * everything the plan covers (calorie/macro targets, training days/week, session
 * length, training focus, sport, dietary style, etc.). The Profile panels display
 * those plan values as defaults. If the user explicitly saves a value from the
 * Profile, that saved value becomes a manual override and wins over the plan —
 * same pattern as the existing manual calorie target logic.
 *
 * Fallback order for every field:
 *   1. Manual override on the profile entity (when present and > 0 / non-empty)
 *   2. Active AIPlan value
 *   3. Starter-calculated target on the profile entity
 *   4. null / sensible default
 */

import { backend } from '@/api/backendClient';
import { loadActivePlan, userScopedFilter } from '@/lib/personalizationSync';

const TRAINING_DAYS_LABEL_TO_NUMBER = {
  '2_or_less': 2,
  '3_5': 4,
  '5_7': 6,
  'seven_plus': 7,
};

function firstNumber(...vals) {
  for (const v of vals) {
    const n = Number(v);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

function firstString(...vals) {
  for (const v of vals) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return '';
}

function firstArray(...vals) {
  for (const v of vals) {
    if (Array.isArray(v) && v.length > 0) return v;
  }
  return [];
}

/**
 * Extract structured fields from an active AIPlan in a shape the Profile panels can use.
 */
export function extractPlanProfileFields(activePlan) {
  if (!activePlan) return null;

  const nutritionTargets =
    activePlan.nutrition_targets ||
    activePlan.plan_payload?.nutrition_targets ||
    {};
  const trainingSplit =
    activePlan.training_split ||
    activePlan.plan_payload?.training_split ||
    {};
  const planSummary =
    activePlan.plan_summary ||
    activePlan.plan_payload?.plan_summary ||
    {};
  const questionnaire = activePlan.plan_payload?.questionnaire || {};

  // training_split.days_per_week may have been set programmatically;
  // also fall back to questionnaire.trainingDays label mapping.
  const planDaysPerWeek =
    Number(trainingSplit.days_per_week) > 0
      ? Number(trainingSplit.days_per_week)
      : TRAINING_DAYS_LABEL_TO_NUMBER[questionnaire.trainingDays] || null;

  return {
    // identity
    displayName: firstString(questionnaire.name),

    // nutrition targets
    calories: firstNumber(nutritionTargets.calories),
    protein_g: firstNumber(nutritionTargets.protein_g),
    carbs_g: firstNumber(nutritionTargets.carbs_g),
    fats_g: firstNumber(nutritionTargets.fat_g, nutritionTargets.fats_g),
    hydration_liters: firstNumber(nutritionTargets.hydration_liters),

    // nutrition prefs
    mealsPerDay: firstNumber(questionnaire.mealsPerDay && parseInt(String(questionnaire.mealsPerDay), 10)),
    dietStyles: firstArray(questionnaire.dietStyles),
    allergies: questionnaire.allergies
      ? String(questionnaire.allergies).split(/[,\n]+/).map(s => s.trim()).filter(Boolean)
      : [],
    dislikedFoods: questionnaire.foodsToAvoid
      ? String(questionnaire.foodsToAvoid).split(/[,\n]+/).map(s => s.trim()).filter(Boolean)
      : [],
    likedFoods: firstArray(questionnaire.selectedFoods),

    // training
    primaryGoal: firstString(planSummary.primary_goal),
    daysPerWeek: planDaysPerWeek,
    sessionDurationMin: firstNumber(trainingSplit.session_length_minutes, questionnaire.sessionDurationMin),
    splitType: firstString(trainingSplit.split_type),
    intensityGuidance: firstString(trainingSplit.intensity_guidance),
    equipment: firstArray(questionnaire.equipment),
    trainingLocation: firstString(questionnaire.trainingLocation),
    primarySport: firstString(questionnaire.primarySport),
    sportFocus: firstString(questionnaire.sportFocus),
  };
}

/**
 * Load the active AI plan plus all profile entities and merge them into "effective"
 * field values for the Profile UI. Each field also exposes its source so the UI
 * can show a small "from AI plan" hint.
 */
export async function loadProfileEffectiveValues() {
  const [plan, profiles, workoutProfiles, nutritionProfiles] = await Promise.all([
    loadActivePlan('daily').catch(() => null),
    backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []),
    backend.entities.WorkoutProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []),
    backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []),
  ]);

  const userProfile = profiles?.[0] || null;
  const workoutProfile = workoutProfiles?.[0] || null;
  const nutritionProfile = nutritionProfiles?.[0] || null;
  const planFields = extractPlanProfileFields(plan);

  return {
    activePlan: plan,
    userProfile,
    workoutProfile,
    nutritionProfile,
    planFields,
    // Convenience effective values with sources
    effective: {
      displayName: firstString(userProfile?.display_name, planFields?.displayName),
      displayNameSource: userProfile?.display_name ? 'profile' : (planFields?.displayName ? 'ai_plan' : 'none'),

      // Nutrition — manual override wins, then AI plan, then starter-calculated
      calories: pickWithSource(
        nutritionProfile?.calorie_target_source === 'manual' && Number(nutritionProfile?.calorie_target) > 0
          ? { value: Number(nutritionProfile.calorie_target), source: 'manual' } : null,
        planFields?.calories ? { value: planFields.calories, source: 'ai_plan' } : null,
        Number(nutritionProfile?.calorie_target) > 0
          ? { value: Number(nutritionProfile.calorie_target), source: 'starter' } : null,
      ),
      protein_g: pickWithSource(
        Number(nutritionProfile?.protein_target_g) > 0 && nutritionProfile?.calorie_target_source === 'manual'
          ? { value: Number(nutritionProfile.protein_target_g), source: 'manual' } : null,
        planFields?.protein_g ? { value: planFields.protein_g, source: 'ai_plan' } : null,
        Number(nutritionProfile?.protein_target_g) > 0
          ? { value: Number(nutritionProfile.protein_target_g), source: 'starter' } : null,
      ),
      carbs_g: pickWithSource(
        Number(nutritionProfile?.carbs_target_g) > 0 && nutritionProfile?.calorie_target_source === 'manual'
          ? { value: Number(nutritionProfile.carbs_target_g), source: 'manual' } : null,
        planFields?.carbs_g ? { value: planFields.carbs_g, source: 'ai_plan' } : null,
        Number(nutritionProfile?.carbs_target_g) > 0
          ? { value: Number(nutritionProfile.carbs_target_g), source: 'starter' } : null,
      ),
      fats_g: pickWithSource(
        Number(nutritionProfile?.fats_target_g) > 0 && nutritionProfile?.calorie_target_source === 'manual'
          ? { value: Number(nutritionProfile.fats_target_g), source: 'manual' } : null,
        planFields?.fats_g ? { value: planFields.fats_g, source: 'ai_plan' } : null,
        Number(nutritionProfile?.fats_target_g) > 0
          ? { value: Number(nutritionProfile.fats_target_g), source: 'starter' } : null,
      ),
      mealsPerDay: pickWithSource(
        Number(nutritionProfile?.meals_per_day) > 0
          ? { value: Number(nutritionProfile.meals_per_day), source: 'profile' } : null,
        planFields?.mealsPerDay ? { value: planFields.mealsPerDay, source: 'ai_plan' } : null,
      ),
      likedFoods: pickWithSource(
        nutritionProfile?.liked_foods?.length ? { value: nutritionProfile.liked_foods, source: 'profile' } : null,
        planFields?.likedFoods?.length ? { value: planFields.likedFoods, source: 'ai_plan' } : null,
      ),
      dislikedFoods: pickWithSource(
        nutritionProfile?.disliked_foods?.length ? { value: nutritionProfile.disliked_foods, source: 'profile' } : null,
        planFields?.dislikedFoods?.length ? { value: planFields.dislikedFoods, source: 'ai_plan' } : null,
      ),
      allergies: pickWithSource(
        nutritionProfile?.allergies?.length ? { value: nutritionProfile.allergies, source: 'profile' } : null,
        planFields?.allergies?.length ? { value: planFields.allergies, source: 'ai_plan' } : null,
      ),
      dietaryPreference: pickWithSource(
        nutritionProfile?.dietary_preference && nutritionProfile.dietary_preference !== 'none'
          ? { value: nutritionProfile.dietary_preference, source: 'profile' } : null,
        planFields?.dietStyles?.[0] ? { value: planFields.dietStyles[0], source: 'ai_plan' } : null,
      ),

      // Workout
      daysPerWeek: pickWithSource(
        Number(workoutProfile?.days_per_week) > 0 && workoutProfile?.updated_from_plan_questionnaire !== true
          ? { value: Number(workoutProfile.days_per_week), source: 'profile' } : null,
        planFields?.daysPerWeek ? { value: planFields.daysPerWeek, source: 'ai_plan' } : null,
        Number(workoutProfile?.days_per_week) > 0
          ? { value: Number(workoutProfile.days_per_week), source: 'starter' } : null,
      ),
      sessionDurationMin: pickWithSource(
        Number(workoutProfile?.session_duration_min) > 0 && workoutProfile?.updated_from_plan_questionnaire !== true
          ? { value: Number(workoutProfile.session_duration_min), source: 'profile' } : null,
        planFields?.sessionDurationMin ? { value: planFields.sessionDurationMin, source: 'ai_plan' } : null,
        Number(workoutProfile?.session_duration_min) > 0
          ? { value: Number(workoutProfile.session_duration_min), source: 'starter' } : null,
      ),
      primaryGoal: pickWithSource(
        firstString(workoutProfile?.primary_goal) ? { value: workoutProfile.primary_goal, source: 'profile' } : null,
        planFields?.primaryGoal ? { value: planFields.primaryGoal, source: 'ai_plan' } : null,
      ),
      equipment: pickWithSource(
        workoutProfile?.equipment_available?.length ? { value: workoutProfile.equipment_available, source: 'profile' } : null,
        planFields?.equipment?.length ? { value: planFields.equipment, source: 'ai_plan' } : null,
      ),
      primarySport: pickWithSource(
        firstString(workoutProfile?.primary_sport) ? { value: workoutProfile.primary_sport, source: 'profile' } : null,
        planFields?.primarySport ? { value: planFields.primarySport, source: 'ai_plan' } : null,
      ),
    },
  };
}

function pickWithSource(...candidates) {
  for (const c of candidates) {
    if (c && c.value != null && c.value !== '' && !(Array.isArray(c.value) && c.value.length === 0)) {
      return c;
    }
  }
  return { value: null, source: 'none' };
}

export function sourceLabel(source) {
  switch (source) {
    case 'manual':   return 'Manual override';
    case 'ai_plan':  return 'From AI plan';
    case 'profile':  return 'Saved preference';
    case 'starter':  return 'Starter target';
    default:         return '';
  }
}