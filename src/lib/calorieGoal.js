/**
 * Calorie goal resolution helpers for Execute.
 *
 * resolveCalorieTarget — canonical priority chain for calorie goal across all pages.
 * estimateCalorieGoal  — Mifflin-St Jeor BMR estimate (pure, no side effects).
 * resolveCalorieBudget — dynamic daily budget = base target + logged exercise calories.
 */

/**
 * Resolves the best available calorie target from available data.
 *
 * Priority order:
 *   1. NutritionProfile.calorie_target when calorie_target_source === 'manual' and value > 0
 *   2. Legacy UserProfile.calorie_goal when calorie_goal_source === 'manual'
 *   3. Active AIPlan nutrition target
 *   4. estimateCalorieGoal fallback
 *   5. null
 *
 * @returns {{ calories: number|null, source: 'manual'|'ai_plan'|'estimated'|null }}
 */
export function resolveCalorieTarget({ nutritionProfile, userProfile, activePlan }) {
  // 1. Manual NutritionProfile target
  if (
    nutritionProfile?.calorie_target_source === 'manual' &&
    nutritionProfile?.calorie_target > 0
  ) {
    return { calories: nutritionProfile.calorie_target, source: 'manual' };
  }

  // 2. Legacy UserProfile manual goal
  if (
    userProfile?.calorie_goal_source === 'manual' &&
    userProfile?.calorie_goal > 0
  ) {
    return { calories: userProfile.calorie_goal, source: 'manual' };
  }

  // 3. Active AI plan nutrition target
  const aiCalories =
    activePlan?.nutrition_targets?.calories ||
    activePlan?.plan_payload?.nutrition_targets?.calories ||
    null;
  if (aiCalories > 0) {
    return { calories: aiCalories, source: 'ai_plan' };
  }

  // 4. Estimated from biometrics
  const estimated = estimateCalorieGoal(userProfile, nutritionProfile);
  if (estimated) {
    return { calories: estimated, source: 'estimated' };
  }

  return { calories: null, source: null };
}

/**
 * Estimates a daily calorie goal using the Mifflin-St Jeor BMR formula
 * with a custom NEAT matrix.
 *
 * Step 1 — Standard BMR (Mifflin-St Jeor):
 *   Male:   (10 × W) + (6.25 × H) - (5 × A) + 5
 *   Female: (10 × W) + (6.25 × H) - (5 × A) - 161
 *
 * Step 2 — Athletic BMR adjustment:
 *   5+ times/week or twice-a-day → BMR × 1.15, otherwise use standard BMR.
 *
 * Step 3 — NEAT addition by activity tier:
 *   Sedentary (0x):  +100 kcal
 *   1–2x/week:       +200 kcal
 *   3–4x/week:       +250 kcal
 *   5+x/week:        +300 kcal
 *   2x/day (athlete):+400 kcal
 *
 * Step 4 — Goal-based deficit/surplus applied to (adjusted BMR + NEAT).
 *
 * Returns null if age, weight_kg, height_cm, or sex are missing.
 */
export function estimateCalorieGoal(profile, nutrition) {
  const { age, weight_kg, height_cm, sex } = profile || {};

  if (!age || !weight_kg || !height_cm || !sex) return null;

  // Step 1: Standard Mifflin-St Jeor BMR
  const standardBMR = sex === 'male'
    ? 10 * weight_kg + 6.25 * height_cm - 5 * age + 5
    : 10 * weight_kg + 6.25 * height_cm - 5 * age - 161;

  // Resolve activity tier from nutrition profile, falling back to days_per_week
  const activityLevel = nutrition?.activity_level || profile?.activity_level || '';

  // Map entity activity_level values → internal tier
  // tier: 0=sedentary, 1=1-2x, 2=3-4x, 3=5+x, 4=2x/day
  const tierMap = {
    sedentary:         0,
    lightly_active:    1,
    moderately_active: 2,
    very_active:       3,
    athlete:           4,
  };

  let tier;
  if (tierMap[activityLevel] !== undefined) {
    tier = tierMap[activityLevel];
  } else {
    // Approximate from days_per_week if activity_level isn't set
    const d = profile?.days_per_week || 0;
    if      (d >= 10) tier = 4; // 2x/day proxy
    else if (d >= 5)  tier = 3;
    else if (d >= 3)  tier = 2;
    else if (d >= 1)  tier = 1;
    else              tier = 0;
  }

  // Step 2: Athletic BMR adjustment (5+x or 2x/day)
  const adjustedBMR = (tier >= 3) ? standardBMR * 1.15 : standardBMR;

  // Step 3: NEAT addition by tier
  const neatByTier = [100, 200, 250, 300, 400];
  const neat = neatByTier[tier];

  const base = adjustedBMR + neat;

  // Step 4: Goal-based calorie adjustment
  const goal = nutrition?.primary_goal || '';
  const loseGoals     = ['fat_loss', 'lose_fat', 'lose_weight', 'weight_loss'];
  const gainGoals     = ['muscle_gain', 'build_muscle', 'gain_muscle'];
  const strengthGoals = ['get_stronger', 'strength', 'performance'];

  let calories;
  if      (loseGoals.includes(goal))     calories = base * 0.82; // ~18% deficit
  else if (gainGoals.includes(goal))     calories = base * 1.10; // ~10% surplus
  else if (strengthGoals.includes(goal)) calories = base * 1.05; // ~5% surplus
  else                                   calories = base;          // maintenance

  // Round to nearest 50
  return Math.round(calories / 50) * 50;
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
 * Estimates macro targets from a resolved calorie goal and user weight.
 * Pure display estimate — never persisted.
 * @returns {{ protein_g: number, carbs_g: number, fat_g: number }}
 */
export function estimateMacroTargets(calories, userProfile, nutritionProfile) {
  if (!calories) return null;
  const weightKg = userProfile?.weight_kg || 75;
  const goal = nutritionProfile?.primary_goal || userProfile?.goals?.[0] || '';
  const strengthGoals = ['build_muscle', 'muscle_gain', 'gain_muscle', 'get_stronger', 'strength'];
  const proteinPerKg = strengthGoals.includes(goal) ? 2.4 : 2.0;

  const protein_g = Math.round(weightKg * proteinPerKg);
  const fat_g = Math.round(weightKg * 1.0);
  const carbs_g = Math.max(50, Math.round((calories - protein_g * 4 - fat_g * 9) / 4));

  return { protein_g, carbs_g, fat_g };
}

/**
 * Resolves each macro target using priority chain:
 *   1. NutritionProfile target — ONLY if it's a manual override (calorie_target_source === 'manual')
 *   2. AIPlan nutrition_targets
 *   3. NutritionProfile starter-calculated target (non-manual)
 *   4. MealPlan totals
 *   5. Estimated macro fallback
 *
 * The manual-vs-starter distinction is required so that when an AI plan is generated,
 * its macros immediately replace any stale starter-calculated macros from the profile.
 *
 * @returns {{ protein_g: number|null, carbs_g: number|null, fat_g: number|null }}
 */
export function resolveMacroTargets({ nutritionProfile, activePlan, mealPlan, userProfile }) {
  const planTargets =
    activePlan?.nutrition_targets ||
    activePlan?.plan_payload?.nutrition_targets ||
    {};

  const resolved = resolveCalorieTarget({ nutritionProfile, userProfile, activePlan });
  const estimated = estimateMacroTargets(resolved.calories, userProfile, nutritionProfile);
  const isManualProfile = nutritionProfile?.calorie_target_source === 'manual';

  function resolveOne(profileKey, planKey, mealKey, estimatedKey) {
    const profileVal = Number(nutritionProfile?.[profileKey]) || 0;

    // 1. Manual profile override wins
    if (isManualProfile && profileVal > 0) return profileVal;

    // 2. Active AI plan
    const planVal = Number(planTargets[planKey]) || 0;
    if (planVal > 0) return planVal;

    // 3. Starter-calculated profile target (non-manual fallback)
    if (profileVal > 0) return profileVal;

    // 4. Meal plan totals
    const mealVal = Number(mealPlan?.[mealKey]) || 0;
    if (mealVal > 0) return mealVal;

    // 5. Estimated
    return estimated?.[estimatedKey] || null;
  }

  // AIPlan may use either 'fat_g' or 'fats_g' for the fat macro
  const fatFromPlan = Number(planTargets.fat_g || planTargets.fats_g) || 0;
  const profileFat = Number(nutritionProfile?.fats_target_g) || 0;

  return {
    protein_g: resolveOne('protein_target_g', 'protein_g', 'total_protein_g', 'protein_g'),
    carbs_g:   resolveOne('carbs_target_g',   'carbs_g',   'total_carbs_g',   'carbs_g'),
    fat_g: (() => {
      if (isManualProfile && profileFat > 0) return profileFat;
      if (fatFromPlan > 0) return fatFromPlan;
      if (profileFat > 0) return profileFat;
      const mealVal = Number(mealPlan?.total_fats_g) || 0;
      if (mealVal > 0) return mealVal;
      return estimated?.fat_g || null;
    })(),
  };
}