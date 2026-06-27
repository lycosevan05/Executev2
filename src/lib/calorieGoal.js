/**
 * Calorie goal resolution helpers for Execute.
 *
 * resolveCalorieTarget — canonical priority chain for calorie goal across all pages.
 * resolveCalorieBudget — dynamic daily budget = base target + logged exercise calories.
 */

/**
 * Resolves the best available calorie target from available data.
 *
 * Priority order:
 *   1. NutritionProfile.calorie_target when calorie_target_source === 'manual' and value > 0
 *   2. Active AIPlan nutrition target
 *   3. null
 *
 * @returns {{ calories: number|null, source: 'manual'|'ai_plan'|null }}
 */
export function resolveCalorieTarget({ nutritionProfile, userProfile, activePlan }) {
  // 1. Manual NutritionProfile target
  if (
    nutritionProfile?.calorie_target_source === 'manual' &&
    nutritionProfile?.calorie_target > 0
  ) {
    return { calories: nutritionProfile.calorie_target, source: 'manual' };
  }

  // 2. Active AI plan nutrition target
  const aiCalories =
    activePlan?.nutrition_targets?.calories ||
    activePlan?.plan_payload?.nutrition_targets?.calories ||
    null;
  if (aiCalories > 0) {
    return { calories: aiCalories, source: 'ai_plan' };
  }

  return { calories: null, source: null };
}

/**
 * Resolves the daily calorie BUDGET.
 *
 * Adds logged exercise calories to the user's daily eating budget so the
 * intake percentage reflects the adjusted total available for the day.
 *
 * @param {{ calories: number|null, source: string|null }} resolvedTarget
 * @param {number} caloriesBurned - from DailyLog.calories_burned
 * @returns {{ budget: number|null, exerciseBonus: number }}
 */
export function resolveCalorieBudget(resolvedTarget, caloriesBurned = 0) {
  const base = resolvedTarget?.calories;
  if (!base) return { budget: null, exerciseBonus: 0 };

  const exerciseBonus = Math.max(0, Math.round(caloriesBurned || 0));
  return { budget: Math.round(base + exerciseBonus), exerciseBonus };
}

/**
 * Resolves each macro target using priority chain:
 *   1. NutritionProfile target — ONLY if it's a manual override (calorie_target_source === 'manual')
 *   2. AIPlan nutrition_targets
 *   3. MealPlan totals
 *
 * The manual-vs-plan distinction is required so that when an AI plan is generated,
 * its macros immediately replace any stale macros from the profile.
 *
 * @returns {{ protein_g: number|null, carbs_g: number|null, fat_g: number|null }}
 */
export function resolveMacroTargets({ nutritionProfile, activePlan, mealPlan, userProfile }) {
  const planTargets =
    activePlan?.nutrition_targets ||
    activePlan?.plan_payload?.nutrition_targets ||
    {};

  const isManualProfile = nutritionProfile?.calorie_target_source === 'manual';

  function resolveOne(profileKey, planKey, mealKey) {
    const profileVal = Number(nutritionProfile?.[profileKey]) || 0;

    // 1. Manual profile override wins
    if (isManualProfile && profileVal > 0) return profileVal;

    // 2. Active AI plan
    const planVal = Number(planTargets[planKey]) || 0;
    if (planVal > 0) return planVal;

    // 3. Meal plan totals
    const mealVal = Number(mealPlan?.[mealKey]) || 0;
    if (mealVal > 0) return mealVal;

    return null;
  }

  // AIPlan may use either 'fat_g' or 'fats_g' for the fat macro
  const fatFromPlan = Number(planTargets.fat_g || planTargets.fats_g) || 0;
  const profileFat = Number(nutritionProfile?.fats_target_g) || 0;

  return {
    protein_g: resolveOne('protein_target_g', 'protein_g', 'total_protein_g'),
    carbs_g:   resolveOne('carbs_target_g',   'carbs_g',   'total_carbs_g'),
    fat_g: (() => {
      if (isManualProfile && profileFat > 0) return profileFat;
      if (fatFromPlan > 0) return fatFromPlan;
      const mealVal = Number(mealPlan?.total_fats_g) || 0;
      if (mealVal > 0) return mealVal;
      return null;
    })(),
  };
}