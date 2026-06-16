/**
 * byoCadence — shared resolvers for "Input your own plan" (BYO).
 *
 * The user's pasted plan is structured ONCE (structurePastedPlan) and persisted
 * on the master AIPlan as `byo_structured` + `byo_cadence`. These helpers map a
 * calendar date onto that structure so each day's session / meal focus is a cheap,
 * constant-cost lookup — never a re-injection of the raw paste per day.
 *
 * Weekday convention: 0 = Sunday … 6 = Saturday (JS getDay()).
 */

const ACTIVITY_ENUM = ['never', '1_2_days', '3_4_days', '5_plus'];

const ACTIVITY_ALIASES = {
  '5+': '5_plus', '5_plus_days': '5_plus', '5-7': '5_plus', 'seven_plus': '5_plus',
  daily: '5_plus', '5': '5_plus', '6': '5_plus', '7': '5_plus',
  '3': '3_4_days', '4': '3_4_days', '3-4': '3_4_days', '3_4': '3_4_days', '4x_week': '3_4_days', '3_5': '3_4_days',
  '1': '1_2_days', '2': '1_2_days', '1-2': '1_2_days', '1_2': '1_2_days', '2x_week': '1_2_days',
  '0': 'never', none: 'never', rarely: 'never', monthly: 'never',
};

/**
 * Normalize a model-emitted activity token onto the canonical currentTraining enum
 * that calcTDEE keys on. Never assigns a raw off-enum token. Returns null when it
 * cannot be resolved (caller leaves currentTraining unset → 1.45 default).
 *
 * @param {string} raw
 * @param {number} [weeklySessionsLength] fallback signal when the token is unknown
 * @returns {'never'|'1_2_days'|'3_4_days'|'5_plus'|null}
 */
export function normalizeActivityLevel(raw, weeklySessionsLength) {
  const v = String(raw || '').trim().toLowerCase();
  if (ACTIVITY_ENUM.includes(v)) return v;
  if (ACTIVITY_ALIASES[v]) return ACTIVITY_ALIASES[v];
  const n = Number(weeklySessionsLength) || 0;
  if (n >= 5) return '5_plus';
  if (n >= 3) return '3_4_days';
  if (n >= 1) return '1_2_days';
  return null;
}

function daysBetween(anchorISO, targetISO) {
  const a = new Date(anchorISO + 'T12:00:00');
  const t = new Date(targetISO + 'T12:00:00');
  return Math.round((t - a) / 86400000);
}

// Count training days (weekdays NOT in rest_weekdays) in [anchor, target).
function trainingDaysSince(anchorISO, targetISO, restWeekdays) {
  const total = daysBetween(anchorISO, targetISO);
  if (total <= 0) return 0;
  const base = new Date(anchorISO + 'T12:00:00');
  let count = 0;
  for (let i = 0; i < total; i += 1) {
    const d = new Date(base);
    d.setDate(base.getDate() + i);
    if (!restWeekdays.includes(d.getDay())) count += 1;
  }
  return count;
}

/**
 * Resolve the workout session for a date from structured + cadence.
 * Honors rest weekdays explicitly. Returns null for a rest day or when nothing
 * can be resolved.
 *
 * @returns {{ title: string, exercises: any[] }|null}
 */
export function resolveByoSession(structured, cadence, anchorDateISO, targetDateISO) {
  const workout = structured?.workout;
  if (!workout) return null;
  const cad = cadence || workout.cadence || null;
  const targetWeekday = new Date(targetDateISO + 'T12:00:00').getDay();
  const restWeekdays = Array.isArray(cad?.rest_weekdays) ? cad.rest_weekdays : [];

  // 1. Always-rest calendar weekday → rest, regardless of cycle position.
  if (restWeekdays.includes(targetWeekday)) return null;

  // 2. Weekly plan with fixed weekday→session mapping.
  const weeklySessions = Array.isArray(workout.weekly_sessions) ? workout.weekly_sessions : [];
  if ((cad?.type === 'weekly' || !cad?.type) && weeklySessions.length > 0) {
    const match = weeklySessions.find(s => s.weekday === targetWeekday);
    if (match) return { title: match.title, exercises: match.exercises || [] };
    // Fixed weekly plans rest on unmapped weekdays.
    if (cad?.type === 'weekly') return null;
  }

  // 3. Rotating / A-B cycle.
  const cycle = Array.isArray(cad?.cycle) ? cad.cycle : [];
  if (cycle.length > 0) {
    let idx;
    if (cad?.advance === 'training_days_only') {
      idx = trainingDaysSince(anchorDateISO, targetDateISO, restWeekdays) % cycle.length;
    } else {
      const ds = daysBetween(anchorDateISO, targetDateISO);
      idx = ((ds % cycle.length) + cycle.length) % cycle.length;
    }
    const day = cycle[idx];
    if (!day || day.is_rest) return null;
    return { title: day.label, exercises: day.exercises || [] };
  }

  // 4. Last resort: rotate through weekly_sessions by elapsed training days.
  if (weeklySessions.length > 0) {
    const idx = trainingDaysSince(anchorDateISO, targetDateISO, restWeekdays) % weeklySessions.length;
    const s = weeklySessions[idx];
    return { title: s.title, exercises: s.exercises || [] };
  }

  return null;
}

/**
 * Resolve the nutrition focus for a date from structured nutrition.daily_focus.
 * @returns {{ focus: string, example_meals: any[] }|null}
 */
export function resolveByoMealFocus(structured, anchorDateISO, targetDateISO) {
  const focus = Array.isArray(structured?.nutrition?.daily_focus) ? structured.nutrition.daily_focus : [];
  if (focus.length === 0) return null;
  const targetWeekday = new Date(targetDateISO + 'T12:00:00').getDay();
  const byWeekday = focus.find(f => f.weekday === targetWeekday);
  if (byWeekday) return { focus: byWeekday.focus, example_meals: byWeekday.example_meals || [] };
  const ds = daysBetween(anchorDateISO, targetDateISO);
  const idx = ((ds % focus.length) + focus.length) % focus.length;
  const f = focus[idx];
  return { focus: f.focus, example_meals: f.example_meals || [] };
}
