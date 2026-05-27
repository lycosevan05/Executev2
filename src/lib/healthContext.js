/**
 * healthContext.js — LEGACY SHIM
 *
 * This module now provides only empty safe defaults and helper utilities.
 * All canonical personalization data lives in Supabase entities.
 * Do NOT add hardcoded user data here.
 */

export const EMPTY_CONTEXT = {
  profile: {
    name: '',
    age: null,
    weight_kg: null,
    height_cm: null,
  },
  goals: [],
  nutrition: {
    calorie_target: null,
    protein_target_g: null,
    carbs_target_g: null,
    fats_target_g: null,
    dietary_preference: 'none',
    allergies: [],
    disliked_foods: [],
    liked_foods: [],
    favorite_meals: [],
    meal_feedback: {},
    meals_per_day: 3,
    cooking_style: 'balanced',
    budget_level: 'moderate',
  },
  workout: {
    primary_goal: null,
    experience_level: 'intermediate',
    days_per_week: 4,
    session_duration_min: 50,
    preferred_split: 'full_body',
    cardio_preference: 'moderate',
    equipment: [],
    focus_areas: [],
  },
  limitations: [],
  coaching_style: 'balanced',
  today: {
    date: (() => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; })(),
    steps: 0,
    steps_goal: 10000,
    calories_consumed: 0,
    calories_goal: 2000,
    water_liters: 0,
    water_goal: 2.5,
    sleep_hours: 0,
    sleep_quality: 5,
    soreness: 3,
    stress: 3,
    motivation: 7,
    energy_logged: 7,
    workout_done: false,
    habits_completed: [],
    plan_items_completed: [],
    food_logs: [],
  },
  adherence: {
    workout_days_this_week: 0,
    workout_goal_days: 4,
    protein_on_target_days: 0,
    meal_tracking_days: 0,
  },
  scores: {
    recovery: 70,
  },
  onboarding_complete: false,
};

// Keep for backward compat — returns empty context, never hardcoded personal data
export function loadContext() {
  try {
    const raw = localStorage.getItem('execute_health_context') || localStorage.getItem('evanlog_health_context');
    if (!raw) return { ...EMPTY_CONTEXT };
    const saved = JSON.parse(raw);
    // Deep merge saved over empty defaults (never the other way)
    return deepMerge({ ...EMPTY_CONTEXT }, saved);
  } catch {
    return { ...EMPTY_CONTEXT };
  }
}

export function saveContext(ctx) {
  try {
    localStorage.setItem('execute_health_context', JSON.stringify(ctx));
  } catch {}
}

/**
 * Compute an energy score (0-100) from today's data and adherence.
 * Pure function — does not read from any store.
 */
export function computeEnergyScore(today = {}, adherence = {}) {
  const sleep = Math.min(today.sleep_hours || 0, 10);
  const sleepQ = today.sleep_quality || 5;
  const stress = today.stress || 5;
  const motivation = today.motivation || 5;
  const soreness = today.soreness || 5;

  const raw =
    sleep * 4 +
    sleepQ * 4 +
    (10 - stress) * 3 +
    motivation * 4 +
    (10 - soreness) * 3 +
    (adherence.workout_days_this_week || 0) * 5;

  const score = Math.round(Math.min(100, Math.max(0, raw)));

  const factors = [];
  if (sleep < 6) factors.push({ label: 'Short sleep', impact: 'negative' });
  else if (sleep >= 8) factors.push({ label: 'Good sleep', impact: 'positive' });
  if (stress >= 7) factors.push({ label: 'High stress', impact: 'negative' });
  if (motivation >= 8) factors.push({ label: 'High motivation', impact: 'positive' });
  if (soreness >= 7) factors.push({ label: 'High soreness', impact: 'negative' });

  return { score, factors };
}

// Simple deep merge helper
function deepMerge(target, source) {
  const out = { ...target };
  for (const key of Object.keys(source)) {
    if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])) {
      out[key] = deepMerge(target[key] || {}, source[key]);
    } else {
      out[key] = source[key];
    }
  }
  return out;
}