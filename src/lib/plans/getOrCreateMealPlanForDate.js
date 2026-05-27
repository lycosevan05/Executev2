/**
 * getOrCreateMealPlanForDate.js
 *
 * On-demand single-date meal plan loader/generator.
 * Never generates meals automatically — only when options.generate === true.
 * Never creates WorkoutPlan or DailyLog records.
 */

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, userScopedFilter, withUserEmail } from '@/lib/personalizationSync';
import { resolveCalorieTarget } from '@/lib/calorieGoal';
import { appCache } from '@/lib/appCache';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function newestFirst(a, b) {
  const aDate = a?.updated_date || a?.created_date || '';
  const bDate = b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function hasUsableMeals(plan) {
  const meals = plan?.meals;
  if (!meals) return false;
  if (Array.isArray(meals)) return meals.length >= 3;
  return !!(meals.breakfast || meals.lunch || meals.dinner || meals.snack);
}

function chooseBestMealPlan(plans = [], masterPlan = null) {
  const safe = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];
  if (!safe.length) return null;

  if (masterPlan) {
    // 1. Exact batch + source match
    const exact = safe.find(p =>
      p.source_plan_id === masterPlan.id &&
      p.generation_batch_id === masterPlan.generation_batch_id
    );
    if (exact) return exact;

    // 2. Source plan match
    const sourceMatch = safe.find(p => p.source_plan_id === masterPlan.id);
    if (sourceMatch) return sourceMatch;
  }

  // 3. plan_questionnaire_overview
  const overviewMatch = safe.find(p => p.source === 'plan_questionnaire_overview');
  if (overviewMatch) return overviewMatch;

  // 4. plan_payload.source overview
  const payloadOverview = safe.find(p => p.plan_payload?.source === 'plan_questionnaire_overview');
  if (payloadOverview) return payloadOverview;

  // 5. plan_questionnaire_initial
  const initialMatch = safe.find(p => p.source === 'plan_questionnaire_initial');
  if (initialMatch) return initialMatch;

  // 6. plan_payload.source initial
  const payloadInitial = safe.find(p => p.plan_payload?.source === 'plan_questionnaire_initial');
  if (payloadInitial) return payloadInitial;

  // 7. Newest with usable meals
  const withMeals = safe.find(hasUsableMeals);
  if (withMeals) return withMeals;

  // 8. Newest overall
  return safe[0] || null;
}

function normalizeNutritionTargets(raw = {}) {
  return {
    calories: raw.calories ?? raw.calorie_target ?? null,
    protein_g: raw.protein_g ?? raw.protein ?? null,
    carbs_g: raw.carbs_g ?? raw.carbs ?? null,
    fat_g: raw.fat_g ?? raw.fats_g ?? raw.fats ?? raw.fat ?? null,
    hydration_liters: raw.hydration_liters ?? raw.water_liters ?? 2.5,
  };
}

// ─── Validation ───────────────────────────────────────────────────────────────

function validateMealPlan(m) {
  const errors = [];
  if (!m?.total_calories) errors.push('total_calories missing');
  if (!m?.total_protein_g) errors.push('total_protein_g missing');
  if (!m?.meals) errors.push('meals missing');
  else {
    for (const key of ['breakfast', 'lunch', 'dinner']) {
      const meal = m.meals[key];
      if (!meal) { errors.push(`${key} missing`); continue; }
      if (!meal.name) errors.push(`${key}.name missing`);
      if (!meal.calories) errors.push(`${key}.calories missing`);
      if (!meal.protein && meal.protein !== 0) errors.push(`${key}.protein missing`);
      if (!Array.isArray(meal.ingredients) || meal.ingredients.length === 0) errors.push(`${key}.ingredients missing or empty`);
    }
  }
  if (errors.length > 0) throw new Error(`Meal plan validation failed: ${errors.join(', ')}`);
}

// ─── Main export ──────────────────────────────────────────────────────────────

/**
 * @param {string} date - YYYY-MM-DD
 * @param {{ planId?: string, generate?: boolean, masterPlan?: object }} options
 * @returns {Promise<{ status: string, mealPlan: object|null, masterPlan: object|null, overviewDay: object|null }>}
 */
export async function getOrCreateMealPlanForDate(date, options = {}) {
  const { planId, generate = false } = options;
  const mealCacheKey = `meal-plan:${date}`;

  try {
    // A. If planId provided, try to load directly
    if (planId) {
      const plans = await backend.entities.MealPlan.filter({ id: planId }).catch(() => []);
      if (plans.length > 0 && hasUsableMeals(plans[0])) {
        const result = { status: 'ready', mealPlan: plans[0], masterPlan: options.masterPlan || null, overviewDay: null };
        appCache.set(mealCacheKey, result);
        return result;
      }
    }

    // A2. Check cache — if we have a ready result for this date, return instantly
    if (!generate) {
      const cached = appCache.get(mealCacheKey);
      if (cached?.status === 'ready' && cached?.mealPlan && appCache.isFresh(mealCacheKey)) {
        return cached;
      }
    }

    // B. Use provided masterPlan or load active AIPlan
    const masterPlan = options.masterPlan || await loadActiveAIPlan('daily').catch(() => null);

    if (!masterPlan) {
      return { status: 'no_plan', mealPlan: null, masterPlan: null, overviewDay: null };
    }

    // C. Extract weekly overview and find matching day (optional for meals)
    const overview =
      masterPlan.weekly_overview ||
      masterPlan.plan_payload?.weekly_overview ||
      null;

    const overviewDay = overview?.days?.find(d => d.date === date) || null;

    // D. Extract nutrition targets
    const rawTargets =
      masterPlan.nutrition_targets ||
      masterPlan.plan_payload?.nutrition_targets ||
      {};
    const nutritionTargets = normalizeNutritionTargets(rawTargets);

    // E. Check for existing MealPlan — run both queries in parallel
    const [exactPlans, datePlans] = await Promise.all([
      masterPlan.id && masterPlan.generation_batch_id
        ? backend.entities.MealPlan.filter(await userScopedFilter({
            date,
            source_plan_id: masterPlan.id,
            generation_batch_id: masterPlan.generation_batch_id,
          })).catch(() => [])
        : Promise.resolve([]),
      backend.entities.MealPlan.filter(await userScopedFilter({ date })).catch(() => []),
    ]);

    const existingPlans = exactPlans.length ? exactPlans : datePlans;

    const existing = chooseBestMealPlan(existingPlans, masterPlan);
    if (existing && hasUsableMeals(existing)) {
      const result = { status: 'ready', mealPlan: existing, masterPlan, overviewDay };
      appCache.set(mealCacheKey, result);
      return result;
    }

    // F. Needs generation but generate not requested
    if (!generate) {
      const result = { status: 'needs_generation', mealPlan: null, masterPlan, overviewDay };
      appCache.set(mealCacheKey, result);
      return result;
    }

    // G. Generate meal plan via AI — load supporting context in parallel
    const [
      userProfiles,
      nutritionProfiles,
      recentFoodLogs,
    ] = await Promise.allSettled([
      backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1),
      backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1),
      backend.entities.FoodLog.filter(await userScopedFilter({ date }), '-created_date', 10),
    ]);

    const userProfile = userProfiles.status === 'fulfilled' ? userProfiles.value?.[0] : null;
    const nutritionProfile = nutritionProfiles.status === 'fulfilled' ? nutritionProfiles.value?.[0] : null;
    const foodLogs = recentFoodLogs.status === 'fulfilled' ? recentFoodLogs.value : [];

    const planSummary = masterPlan.plan_summary || masterPlan.plan_payload?.plan_summary || {};
    const recoveryStrategy = masterPlan.recovery_strategy || masterPlan.plan_payload?.recovery_strategy || {};

    const allergies = nutritionProfile?.allergies?.join(', ') || 'None';
    const dislikedFoods = nutritionProfile?.disliked_foods?.join(', ') || 'None';
    const likedFoods = nutritionProfile?.liked_foods?.join(', ') || 'Not specified';
    const dietaryPref = nutritionProfile?.dietary_preference || 'none';
    const cookingStyle = nutritionProfile?.cooking_style || 'balanced';
    const mealsPerDay = nutritionProfile?.meals_per_day || 4;
    const struggles = nutritionProfile?.nutrition_struggles?.join(', ') || 'None';

    const foodLogSummary = foodLogs.length > 0
      ? foodLogs.map(f => f.notes || (f.foods?.[0]?.name) || 'Meal').slice(0, 5).join(', ')
      : 'No recent food logs';

    // Resolve canonical calorie target — manual user target takes priority over AI plan
    const resolvedCalories = resolveCalorieTarget({ nutritionProfile, userProfile, activePlan: masterPlan });
    const effectiveCalories = resolvedCalories.calories ?? nutritionTargets.calories;

    const prompt = `You are an elite sports nutritionist generating a single day of meals for one specific date.

CRITICAL RULES:
- Generate meals for ONLY ONE DATE: ${date}.
- Do NOT generate a weekly meal plan.
- Do NOT generate workouts or DailyLog data.
- Return ONLY valid JSON. No markdown, no commentary, no backticks.
- Use safe, practical nutrition guidance.
- Do NOT diagnose or treat any medical conditions.
- Respect all allergies and disliked foods strictly.
- Keep meals realistic, simple, and repeatable.

DATE: ${date}
NUTRITION FOCUS TODAY: ${overviewDay?.nutrition_focus || 'Balanced macros aligned with weekly plan'}
TODAY'S PRIORITY: ${overviewDay?.priority || ''}

NUTRITION TARGETS:
- Calories: ${effectiveCalories ?? 'Not set'} kcal${resolvedCalories.source === 'manual' ? ' (user personal target — follow precisely)' : ''}
- Protein: ${nutritionTargets.protein_g ?? (nutritionProfile?.protein_target_g || 'Not set')}g
- Carbs: ${nutritionTargets.carbs_g ?? (nutritionProfile?.carbs_target_g || 'Not set')}g
- Fat: ${nutritionTargets.fat_g ?? (nutritionProfile?.fats_target_g || 'Not set')}g
- Hydration: ${nutritionTargets.hydration_liters}L

PLAN SUMMARY:
${JSON.stringify(planSummary, null, 2)}

RECOVERY STRATEGY:
${JSON.stringify(recoveryStrategy, null, 2)}

USER PROFILE:
Age: ${userProfile?.age ?? 'N/A'}, Weight: ${userProfile?.weight_kg ?? 'N/A'} kg

NUTRITION PROFILE:
- Dietary preference: ${dietaryPref}
- Cooking style: ${cookingStyle}
- Meals per day: ${mealsPerDay}
- Allergies: ${allergies}
- Disliked foods: ${dislikedFoods}
- Preferred foods: ${likedFoods}
- Nutrition struggles: ${struggles}

RECENT FOOD LOGS: ${foodLogSummary}

Return this exact JSON shape only:

{
  "total_calories": number,
  "total_protein_g": number,
  "total_carbs_g": number,
  "total_fats_g": number,
  "hydration_liters": number,
  "meals": {
    "breakfast": {
      "name": "string",
      "calories": number,
      "protein": number,
      "carbs": number,
      "fats": number,
      "ingredients": ["string"],
      "instructions": "string",
      "prep_time_minutes": number,
      "notes": "string"
    },
    "lunch": {
      "name": "string",
      "calories": number,
      "protein": number,
      "carbs": number,
      "fats": number,
      "ingredients": ["string"],
      "instructions": "string",
      "prep_time_minutes": number,
      "notes": "string"
    },
    "dinner": {
      "name": "string",
      "calories": number,
      "protein": number,
      "carbs": number,
      "fats": number,
      "ingredients": ["string"],
      "instructions": "string",
      "prep_time_minutes": number,
      "notes": "string"
    },
    "snack": {
      "name": "string",
      "calories": number,
      "protein": number,
      "carbs": number,
      "fats": number,
      "ingredients": ["string"],
      "instructions": "string",
      "prep_time_minutes": number,
      "notes": "string"
    }
  },
  "grocery_items": ["string"],
  "notes": "string"
}

Breakfast, lunch, and dinner are required. Snack is preferred. Every meal must have name, calories, protein, carbs, fats, and ingredients.`;

    const aiResponse = await backend.integrations.Core.InvokeLLM({
      prompt,
      response_json_schema: {
        type: 'object',
        properties: {
          total_calories: { type: 'number' },
          total_protein_g: { type: 'number' },
          total_carbs_g: { type: 'number' },
          total_fats_g: { type: 'number' },
          hydration_liters: { type: 'number' },
          meals: { type: 'object' },
          grocery_items: { type: 'array', items: { type: 'string' } },
          notes: { type: 'string' },
        },
        required: ['total_calories', 'total_protein_g', 'meals'],
      },
    });

    validateMealPlan(aiResponse);

    // Save exactly one MealPlan record
    const createdPlan = await backend.entities.MealPlan.create(await withUserEmail({
      date,
      plan_type: 'daily',
      total_calories: aiResponse.total_calories,
      total_protein_g: aiResponse.total_protein_g,
      total_carbs_g: aiResponse.total_carbs_g || 0,
      total_fats_g: aiResponse.total_fats_g || 0,
      meals: aiResponse.meals,
      generated_by_ai: true,
      source: 'plan_questionnaire_overview',
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id || '',
      generation_status: 'ready',
      grocery_items: aiResponse.grocery_items || [],
      hydration_liters: aiResponse.hydration_liters || nutritionTargets.hydration_liters || 2.5,
      notes: aiResponse.notes || '',
    }));

    const generated = { status: 'ready', mealPlan: createdPlan, masterPlan, overviewDay };
    appCache.set(mealCacheKey, generated);
    return generated;

  } catch (err) {
    console.error('[getOrCreateMealPlanForDate] Error:', err);
    return { status: 'error', mealPlan: null, masterPlan: null, overviewDay: null, error: err?.message || 'Unknown error' };
  }
}