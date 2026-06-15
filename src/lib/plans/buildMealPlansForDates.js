/**
 * buildMealPlansForDates.js
 *
 * Orchestrates a multi-day meal-plan build. Fetches all day-invariant context
 * exactly ONCE, then runs per-day generation concurrently with a small cap.
 *
 * Why: each per-day generation used to re-read user profile and nutrition profile
 * — invariant across days. Building 7 days fanned out invariant PostgREST requests
 * in tight bursts and tripped the rate limit. Hoisting the invariant reads + capping
 * concurrency removes the burst; per-day calls now do only genuinely per-day reads
 * (existing-plan lookup, FoodLog) plus the LLM call.
 *
 * Mirrors buildWorkoutPlansForDates.js. Key divergence: getOrCreateMealPlanForDate
 * RETURNS { status: 'error' } instead of throwing, so a day's success is detected by
 * result.status === 'ready' (the sole success sentinel) — not by try/catch alone.
 */

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, userScopedFilter } from '@/lib/personalizationSync';
import { withBackoff } from '@/lib/withBackoff';
import { getOrCreateMealPlanForDate } from '@/lib/plans/getOrCreateMealPlanForDate';

// Safety valve: bounds concurrent per-day DB ops AND concurrent OpenAI calls.
const DAY_BUILD_CONCURRENCY = 4;

/**
 * Run an async mapper over items with a fixed concurrency cap. Preserves input
 * order in the returned array; never rejects (per-item errors are captured by
 * the mapper itself).
 */
async function pooledMap(items, limit, mapper) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await mapper(items[i], i);
    }
  };
  const workers = Array.from({ length: Math.min(limit, items.length) }, worker);
  await Promise.all(workers);
  return results;
}

/**
 * @param {string[]} dates - YYYY-MM-DD strings to build.
 * @param {{ masterPlan?: object }} [options]
 * @returns {Promise<Array<{ date: string, status: string, mealPlan: object|null, error: Error|string|null }>>}
 */
export async function buildMealPlansForDates(dates, options = {}) {
  if (!Array.isArray(dates) || dates.length === 0) return [];

  // 1. Resolve the master plan once.
  const masterPlan = options.masterPlan || await loadActiveAIPlan('daily').catch(() => null);
  if (!masterPlan) {
    return dates.map((date) => ({
      date,
      status: 'no_plan',
      mealPlan: null,
      error: new Error('No active master plan'),
    }));
  }

  // 2. Fetch invariant context EXACTLY ONCE (wrapped in backoff for DB 429s).
  const userScope = await userScopedFilter();
  const [userProfiles, nutritionProfiles] = await withBackoff(
    () => Promise.all([
      backend.entities.UserProfile.filter(userScope, '-updated_date', 1),
      backend.entities.NutritionProfile.filter(userScope, '-updated_date', 1),
    ]),
  );

  const context = {
    userProfile: userProfiles?.[0] || null,
    nutritionProfile: nutritionProfiles?.[0] || null,
  };

  // Proof-of-once: this line must appear exactly once per plan build.
  console.info('[mealBuild] invariant context fetched once for', dates.length, 'days');

  // 3. Generate per-day concurrently (no invariant fan-out), capped.
  return pooledMap(dates, DAY_BUILD_CONCURRENCY, async (date) => {
    try {
      const result = await getOrCreateMealPlanForDate(date, {
        generate: true,
        masterPlan,
        context,
      });
      // 4. The callee returns {status:'error'} instead of throwing; treat anything
      // other than the 'ready' success sentinel as a failed day (isolated, named).
      if (result.status !== 'ready') {
        console.error('[mealBuild] day failed', date, result.status, result.error || '');
      }
      return { date, status: result.status, mealPlan: result.mealPlan, error: result.error || null };
    } catch (error) {
      // Belt-and-suspenders: an unexpected throw still isolates this one day.
      console.error('[mealBuild] day failed', date, error?.message || error);
      return { date, status: 'needs_generation', mealPlan: null, error };
    }
  });
}
