/**
 * buildWorkoutPlansForDates.js
 *
 * Orchestrates a multi-day workout build. Fetches all day-invariant context
 * exactly ONCE, then runs per-day generation concurrently with a small cap.
 *
 * Why: each per-day generation used to re-read user profile, workout profile,
 * injuries and readiness — invariant across days. Building 7 days fanned out
 * ~40+ PostgREST requests in tight bursts and tripped the rate limit. Hoisting
 * the invariant reads + capping concurrency removes the burst; per-day calls now
 * do only genuinely per-day reads plus the LLM call.
 */

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, userScopedFilter } from '@/lib/personalizationSync';
import { withBackoff } from '@/lib/withBackoff';
import { getOrCreateWorkoutPlanForDate } from '@/lib/plans/getOrCreateWorkoutPlanForDate';

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
 * @param {string[]} dates - YYYY-MM-DD strings to build (training days only).
 * @param {{ masterPlan?: object }} [options]
 * @returns {Promise<Array<{ date: string, status: string, workoutPlan: object|null, error: Error|null }>>}
 */
export async function buildWorkoutPlansForDates(dates, options = {}) {
  if (!Array.isArray(dates) || dates.length === 0) return [];

  // 1. Resolve the master plan once.
  const masterPlan = options.masterPlan || await loadActiveAIPlan('daily').catch(() => null);
  if (!masterPlan) {
    return dates.map((date) => ({
      date,
      status: 'no_plan',
      workoutPlan: null,
      error: new Error('No active master plan'),
    }));
  }

  // 2. Fetch invariant context EXACTLY ONCE (wrapped in backoff for DB 429s).
  const [userScope, injuryScope, latestScope] = await Promise.all([
    userScopedFilter(),
    userScopedFilter({ is_active: true }),
    userScopedFilter(),
  ]);
  const [userProfiles, workoutProfiles, injuries, readinessLatest] = await withBackoff(
    () => Promise.all([
      backend.entities.UserProfile.filter(userScope, '-updated_date', 1),
      backend.entities.WorkoutProfile.filter(userScope, '-updated_date', 1),
      backend.entities.InjuryProfile.filter(injuryScope),
      backend.entities.ReadinessCheckIn.filter(latestScope, '-date', 1),
    ]),
  );

  const context = {
    userProfile: userProfiles?.[0] || null,
    workoutProfile: workoutProfiles?.[0] || null,
    activeInjuries: injuries || [],
    readinessRecord: readinessLatest?.[0] || null,
  };

  // Proof-of-once: this line must appear exactly once per plan build.
  console.info('[planBuild] invariant context fetched once for', dates.length, 'days');

  // 3. Generate per-day concurrently (no invariant fan-out), capped.
  return pooledMap(dates, DAY_BUILD_CONCURRENCY, async (date) => {
    try {
      const result = await getOrCreateWorkoutPlanForDate(date, {
        generate: true,
        masterPlan,
        context,
      });
      return { date, status: result.status, workoutPlan: result.workoutPlan, error: null };
    } catch (error) {
      // 4. Isolate a failed day — others still succeed; surface WHICH day failed.
      console.error('[planBuild] day failed', date, error?.message || error);
      return { date, status: 'needs_generation', workoutPlan: null, error };
    }
  });
}
