// @ts-check
/**
 * nutritionTotals.js
 *
 * Reconciles the TWO independent sources of "consumed today":
 *   1. FoodLog rows (LogFood page: manual / photo / barcode entries)
 *   2. Ticked planned meals (Nutrition page: meals_completed x MealPlan)
 *
 * Both used to overwrite the same DailyLog.calories_consumed/macros fields,
 * so whichever wrote last silently discarded the other. The stored value is
 * now the per-field MAX of the two freshly derived components ("you consumed
 * at least the larger estimate") — delete-safe because neither input is the
 * stale stored value.
 */

export const CONSUMED_FIELDS = [
  'calories_consumed',
  'protein_consumed_g',
  'carbs_consumed_g',
  'fats_consumed_g',
];

/** Sum a list of FoodLog rows into DailyLog-consumed-shaped totals. */
export function foodTotalsFromFoodLogs(foodLogs = []) {
  const logs = Array.isArray(foodLogs) ? foodLogs : [];
  return {
    calories_consumed: logs.reduce((sum, log) => sum + (Number(log?.total_calories) || 0), 0),
    protein_consumed_g: logs.reduce((sum, log) => sum + (Number(log?.total_protein_g) || 0), 0),
    carbs_consumed_g: logs.reduce((sum, log) => sum + (Number(log?.total_carbs_g) || 0), 0),
    fats_consumed_g: logs.reduce((sum, log) => sum + (Number(log?.total_fats_g) || 0), 0),
  };
}

/**
 * Sum the completed planned meals into DailyLog-consumed-shaped totals.
 * Accepts either an object map { meal_type: meal } (Nutrition's normalized
 * display shape) or a raw MealPlan.meals array/object of meal entries.
 */
export function tickedTotalsFromMealPlan(meals, mealsCompleted = []) {
  const completed = Array.isArray(mealsCompleted) ? mealsCompleted : [];
  const zero = {
    calories_consumed: 0,
    protein_consumed_g: 0,
    carbs_consumed_g: 0,
    fats_consumed_g: 0,
  };
  if (!meals || completed.length === 0) return zero;

  const entries = Array.isArray(meals)
    ? meals.map(meal => [meal?.meal_type || meal?.type || '', meal])
    : Object.entries(meals);

  return entries.reduce((acc, [type, meal]) => {
    if (!completed.includes(type) || !meal) return acc;
    return {
      calories_consumed: acc.calories_consumed + (Number(meal.calories) || 0),
      protein_consumed_g: acc.protein_consumed_g + (Number(meal.protein) || 0),
      carbs_consumed_g: acc.carbs_consumed_g + (Number(meal.carbs) || 0),
      fats_consumed_g: acc.fats_consumed_g + (Number(meal.fats ?? meal.fat) || 0),
    };
  }, zero);
}

/** Per-field max of two consumed-totals objects. */
export function reconcileConsumed(a = {}, b = {}) {
  return Object.fromEntries(
    CONSUMED_FIELDS.map(field => [
      field,
      Math.max(Number(a?.[field]) || 0, Number(b?.[field]) || 0),
    ])
  );
}

/**
 * Merge fresh food-log totals into an in-memory DailyLog without ever
 * lowering a field below what's already known (read-side reconcile for Home).
 */
export function mergeConsumedMax(baseLog, foodTotals) {
  const base = baseLog || {};
  return { ...base, ...reconcileConsumed(base, foodTotals) };
}
