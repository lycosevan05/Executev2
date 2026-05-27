/**
 * Centralized Personalization Sync Layer — Execute
 *
 * Supabase entities are the canonical source of truth.
 * All personalization-affecting writes go through this module.
 * After every write, UserAIContext is invalidated so the next AI call uses fresh data.
 */

import { backend } from '@/api/backendClient';
import { appCache } from '@/lib/appCache';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

export function getTodayISODate() {
  // Local-date YYYY-MM-DD so "today" follows the user's clock, not UTC.
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export async function getCurrentUserEmail() {
  // Return cached email if fresh — avoids repeated auth round-trips on every navigation
  if (_cachedUserEmail && Date.now() - _cachedUserEmailFetchedAt < USER_EMAIL_TTL) {
    return _cachedUserEmail;
  }
  const user = await backend.auth.me().catch(() => null);
  _cachedUserEmail = user?.email || '';
  _cachedUserEmailFetchedAt = Date.now();
  return _cachedUserEmail;
}

/** Pre-warm the email cache immediately (call on app boot). */
export async function prewarmUserEmail() {
  return getCurrentUserEmail();
}

export async function userScopedFilter(extra = {}) {
  const email = await getCurrentUserEmail();
  return email ? { ...extra, created_by: email } : extra;
}

export async function withUserEmail(data = {}) {
  const email = await getCurrentUserEmail();
  return email ? { ...data, user_email: email } : data;
}

// ─── Invalidate UserAIContext cache ───────────────────────────────────────────

export async function invalidatePersonalizationContext() {
  try {
    const user = await backend.auth.me();
    if (!user) return;
    const userId = user.email || user.id;
    const records = await backend.entities.UserAIContext.filter({ userId }).catch(() => []);
    if (records.length > 0) {
      await backend.entities.UserAIContext.update(records[0].id, {
        lastUpdatedAt: new Date(0).toISOString(),
      }).catch(() => {});
    }
  } catch {}
}

// ─── Profile entities ─────────────────────────────────────────────────────────

export async function saveUserProfile(updates) {
  const records = await backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []);
  let result;
  if (records.length > 0) {
    result = await backend.entities.UserProfile.update(records[0].id, updates);
  } else {
    result = await backend.entities.UserProfile.create(await withUserEmail(updates));
  }
  await invalidatePersonalizationContext();
  return result;
}

export async function saveWorkoutProfile(updates) {
  const records = await backend.entities.WorkoutProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []);
  let result;
  if (records.length > 0) {
    result = await backend.entities.WorkoutProfile.update(records[0].id, updates);
  } else {
    result = await backend.entities.WorkoutProfile.create(await withUserEmail(updates));
  }
  await invalidatePersonalizationContext();
  return result;
}

export async function saveNutritionProfile(updates) {
  const records = await backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []);
  let result;
  if (records.length > 0) {
    result = await backend.entities.NutritionProfile.update(records[0].id, updates);
  } else {
    result = await backend.entities.NutritionProfile.create(await withUserEmail(updates));
  }
  await invalidatePersonalizationContext();
  return result;
}

export async function saveInjuryProfile(updates) {
  const result = await backend.entities.InjuryProfile.create(await withUserEmail(updates));
  await invalidatePersonalizationContext();
  return result;
}

// ─── Goals ───────────────────────────────────────────────────────────────────

export async function createGoal(goalData) {
  const result = await backend.entities.Goal.create(await withUserEmail({ ...goalData, status: 'active' }));
  await invalidatePersonalizationContext();
  return result;
}

// Upsert the user's primary onboarding goal — prevents duplicates on re-runs
export async function upsertPrimaryGoal(goalData) {
  const existing = await backend.entities.Goal.filter(await userScopedFilter({ status: 'active' }), '-created_date', 20).catch(() => []);
  const onboardingGoal = existing.find(g => g.source === 'onboarding');
  if (onboardingGoal) {
    return backend.entities.Goal.update(onboardingGoal.id, { ...goalData, status: 'active' });
  }
  return backend.entities.Goal.create(await withUserEmail({ ...goalData, status: 'active', source: 'onboarding' }));
}

export async function updateGoal(id, updates) {
  const result = await backend.entities.Goal.update(id, updates);
  await invalidatePersonalizationContext();
  return result;
}

export async function deleteGoal(id) {
  await backend.entities.Goal.delete(id);
  await invalidatePersonalizationContext();
}

export async function archiveGoal(id) {
  const result = await backend.entities.Goal.update(id, { status: 'paused' });
  await invalidatePersonalizationContext();
  return result;
}

export async function loadActiveGoals() {
  return backend.entities.Goal.filter(await userScopedFilter({ status: 'active' }), '-created_date', 20).catch(() => []);
}

// ─── Injuries ────────────────────────────────────────────────────────────────

export async function loadActiveInjuries() {
  return backend.entities.InjuryProfile.filter(await userScopedFilter({ is_active: true }), '-created_date', 20).catch(() => []);
}

export async function createInjury(injuryData) {
  const result = await backend.entities.InjuryProfile.create({ ...injuryData, is_active: true });
  await invalidatePersonalizationContext();
  return result;
}

export async function updateInjury(id, updates) {
  const result = await backend.entities.InjuryProfile.update(id, updates);
  await invalidatePersonalizationContext();
  return result;
}

export async function archiveInjury(id) {
  const result = await backend.entities.InjuryProfile.update(id, { is_active: false });
  await invalidatePersonalizationContext();
  return result;
}

// ─── DailyLog canonical upsert ────────────────────────────────────────────────

function sameEntityValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestEntityFirst(a, b) {
  const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseBestDailyLog(records = [], masterPlan = null) {
  const safeRecords = Array.isArray(records) ? records.filter(Boolean).sort(newestEntityFirst) : [];
  if (!safeRecords.length) return null;

  if (masterPlan) {
    const exact = safeRecords.find(record =>
      sameEntityValue(record.source_plan_id, masterPlan.id) &&
      sameEntityValue(record.generation_batch_id, masterPlan.generation_batch_id)
    );
    if (exact) return exact;

    const sourcePlanMatch = safeRecords.find(record => sameEntityValue(record.source_plan_id, masterPlan.id));
    if (sourcePlanMatch) return sourcePlanMatch;
  }

  const canonical =
    safeRecords.find(record => record.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.source === 'plan_questionnaire_initial') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_initial') ||
    null;
  if (canonical) return canonical;

  return safeRecords[0] || null;
}

async function loadActiveCanonicalDailyMasterPlan() {
  const plans = await backend.entities.AIPlan
    .filter(await userScopedFilter({ plan_type: 'daily', status: 'active' }), '-generated_at', 25)
    .catch(() => []);

  const sortedPlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestEntityFirst) : [];

  return sortedPlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial') ||
    sortedPlans[0] ||
    null;
}

export async function loadDailyLogByDate(date, options = {}) {
  const masterPlan = options.masterPlan || await loadActiveCanonicalDailyMasterPlan();

  if (masterPlan?.id && masterPlan?.generation_batch_id) {
    const linked = await backend.entities.DailyLog.filter({
      date,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id,
    }).catch(() => []);

    const linkedLog = chooseBestDailyLog(linked, masterPlan);
    if (linkedLog) return linkedLog;
  }

  const records = await backend.entities.DailyLog.filter(await userScopedFilter({ date })).catch(() => []);
  return chooseBestDailyLog(records, masterPlan);
}

export async function upsertDailyLog(date, updates, options = {}) {
  const masterPlan = options.masterPlan || await loadActiveCanonicalDailyMasterPlan();
  const existing = await loadDailyLogByDate(date, { masterPlan });

  let result;

  if (existing?.id) {
    result = await backend.entities.DailyLog.update(existing.id, updates);
  } else {
    const source = masterPlan
      ? (masterPlan.source || masterPlan.plan_payload?.source || 'manual')
      : 'manual';
    result = await backend.entities.DailyLog.create(await withUserEmail({
      date,
      source,
      source_plan_id: masterPlan?.id || '',
      generation_batch_id: masterPlan?.generation_batch_id || '',
      ...updates,
    }));
  }

  await invalidatePersonalizationContext();

  // Async: refresh dynamic readiness when sleep, steps, or calories change
  const today = getTodayISODate();
  const readinessFields = ['sleep_hours', 'steps', 'calories_consumed', 'protein_consumed_g', 'workout_done', 'calories_burned'];
  const hasReadinessField = readinessFields.some(f => f in updates);
  if (date === today && hasReadinessField) {
    import('@/lib/readinessScore').then(m => m.refreshDynamicReadiness(today)).catch(() => {});
  }

  return result;
}
export async function togglePlanItemComplete(date, itemId, options = {}) {
  if (!date || !itemId) return null;

  let targetLog = null;

  if (options.daily_log_id) {
    const logsById = await backend.entities.DailyLog
      .filter({ id: options.daily_log_id })
      .catch(() => []);
    targetLog = logsById[0] || null;
  }

  if (!targetLog && options.source_plan_id && options.generation_batch_id) {
    const linkedLogs = await backend.entities.DailyLog
      .filter({
        date,
        source_plan_id: options.source_plan_id,
        generation_batch_id: options.generation_batch_id,
      })
      .catch(() => []);
    targetLog = linkedLogs[0] || null;
  }

  if (!targetLog && options.source_plan_id) {
    const sourceLogs = await backend.entities.DailyLog
      .filter({
        date,
        source_plan_id: options.source_plan_id,
      })
      .catch(() => []);
    targetLog = sourceLogs[0] || null;
  }

  if (!targetLog) {
    targetLog = await loadDailyLogByDate(date).catch(() => null);
  }

  const existingCompleted = Array.isArray(targetLog?.plan_items_completed)
    ? targetLog.plan_items_completed
    : [];

  const exists = existingCompleted.includes(itemId);
  const newCompleted = exists
    ? existingCompleted.filter(id => id !== itemId)
    : [...existingCompleted, itemId];

  const updates = {
    plan_items_completed: newCompleted,
  };

  let result = null;

  if (targetLog?.id) {
    result = await backend.entities.DailyLog.update(targetLog.id, updates);
  } else {
    result = await upsertDailyLog(date, updates);
  }

  await invalidatePersonalizationContext();

  return {
    dailyLog: result,
    newCompleted,
    completed: !exists,
  };
}
// ─── FoodLog ─────────────────────────────────────────────────────────────────

export async function upsertFoodLog(date, mealData) {
  const result = await backend.entities.FoodLog.create(await withUserEmail({ date, ...mealData }));

  const foodLogs = await backend.entities.FoodLog.filter(await userScopedFilter({ date })).catch(() => []);

  const totalCals = foodLogs.reduce((s, f) => s + (f.total_calories || f.calories || 0), 0);
  const totalProtein = foodLogs.reduce((s, f) => s + (f.total_protein_g || f.protein || 0), 0);
  const totalCarbs = foodLogs.reduce((s, f) => s + (f.total_carbs_g || f.carbs || 0), 0);
  const totalFats = foodLogs.reduce((s, f) => s + (f.total_fats_g || f.fats || f.fat || 0), 0);

  await upsertDailyLog(date, {
    calories_consumed: totalCals,
    protein_consumed_g: totalProtein,
    carbs_consumed_g: totalCarbs,
    fats_consumed_g: totalFats,
  }).catch(() => {});

  // Async: refresh readiness score after nutrition update (today only)
  const today = getTodayISODate();
  if (date === today) {
    import('@/lib/readinessScore').then(m => m.refreshDynamicReadiness(today)).catch(() => {});
  }

  return result;
}


// ─── ReadinessCheckIn (upsert by date) ───────────────────────────────────────

export async function upsertReadinessCheckIn(date, checkInData) {
  const existing = await backend.entities.ReadinessCheckIn.filter(await userScopedFilter({ date })).catch(() => []);
  let result;
  if (existing.length > 0) {
    result = await backend.entities.ReadinessCheckIn.update(existing[0].id, checkInData);
  } else {
    result = await backend.entities.ReadinessCheckIn.create(await withUserEmail({ date, ...checkInData }));
  }
  await invalidatePersonalizationContext();
  return result;
}

// ─── WorkoutPlan (upsert by date) ────────────────────────────────────────────

export async function upsertWorkoutPlan(date, planData) {
  const existing = await backend.entities.WorkoutPlan.filter(await userScopedFilter({ date })).catch(() => []);
  let result;
  if (existing.length > 0) {
    result = await backend.entities.WorkoutPlan.update(existing[0].id, planData);
  } else {
    result = await backend.entities.WorkoutPlan.create(await withUserEmail({ date, ...planData }));
  }
  await invalidatePersonalizationContext();
  return result;
}

// ─── MealPlan (upsert by date) ───────────────────────────────────────────────

export async function upsertMealPlan(date, planData) {
  const existing = await backend.entities.MealPlan.filter(await userScopedFilter({ date })).catch(() => []);
  let result;
  if (existing.length > 0) {
    result = await backend.entities.MealPlan.update(existing[0].id, planData);
  } else {
    result = await backend.entities.MealPlan.create(await withUserEmail({ date, ...planData }));
  }
  await invalidatePersonalizationContext();
  return result;
}

// ─── WorkoutLog ───────────────────────────────────────────────────────────────

export async function saveWorkoutLog(logData) {
  let result;
  if (logData.id) {
    result = await backend.entities.WorkoutLog.update(logData.id, logData);
  } else {
    result = await backend.entities.WorkoutLog.create(logData);
  }
  await invalidatePersonalizationContext();
  return result;
}

// ─── AIPlan — Long-term plan (plan_type: "daily") ────────────────────────────

export async function upsertAdaptivePlan(planData) {
  // Archive existing active plans of same type
  const existingActive = await backend.entities.AIPlan.filter(await userScopedFilter({
    plan_type: planData.plan_type || 'daily',
    status: 'active',
  })).catch(() => []);
  for (const old of existingActive) {
    await backend.entities.AIPlan.update(old.id, { status: 'archived' }).catch(() => {});
  }
  const result = await backend.entities.AIPlan.create(await withUserEmail({
    ...planData,
    status: 'active',
    generated_at: new Date().toISOString(),
    date_range_start: planData.date_range_start || getTodayISODate(),
  }));
  // Immediately update both cache layers so all pages see the new plan without a round-trip
  const planType = planData.plan_type || 'daily';
  _aiPlanCache[await getScopedPlanCacheKey(planType)] = { plan: result, fetchedAt: Date.now() };
  appCache.set(`ai-plan:${planType}`, result);
  await invalidatePersonalizationContext();
  return result;
}

// Backward-compatible alias
export const upsertAIPlan = upsertAdaptivePlan;

export async function updateAIPlan(id, updates) {
  const result = await backend.entities.AIPlan.update(id, {
    ...updates,
    updated_at: new Date().toISOString(),
  });
  bustPlanCache('daily');
  bustPlanCache('weekly');
  await invalidatePersonalizationContext();
  return result;
}

export async function archiveAIPlan(id) {
  const result = await backend.entities.AIPlan.update(id, { status: 'archived', updated_at: new Date().toISOString() });
  bustPlanCache('daily');
  bustPlanCache('weekly');
  await invalidatePersonalizationContext();
  return result;
}

// ─── In-memory AIPlan cache (30-minute TTL) ───────────────────────────────────
// Prevents redundant API calls on every tab switch and avoids 429 rate-limit errors.
// IMPORTANT: stale cache is ALWAYS preferred over returning null — this prevents the
// "plan disappears on tab switch" bug caused by transient network/rate-limit failures.
const _aiPlanCache = {};
const PLAN_CACHE_TTL = 30 * 60_000; // 30 minutes

// ─── Cached user email ────────────────────────────────────────────────────────
// getCurrentUserEmail() is called on almost every data fetch. Caching it avoids
// an extra async round-trip on every navigation.
let _cachedUserEmail = null;
let _cachedUserEmailFetchedAt = 0;
const USER_EMAIL_TTL = 60 * 60_000; // 60 minutes

function getPlanCacheKey(planType, email = '') {
  return `${email || 'anonymous'}:${planType}`;
}

export async function getScopedPlanCacheKey(planType = 'daily') {
  return getPlanCacheKey(planType, await getCurrentUserEmail());
}

export function bustPlanCache(planType = 'daily') {
  Object.keys(_aiPlanCache).forEach(key => {
    if (key.endsWith(`:${planType}`) || key === planType) delete _aiPlanCache[key];
  });
  appCache.invalidate(`ai-plan:${planType}`);
  // Also bust every page that derives from the active plan so they re-fetch.
  appCache.invalidate('home-dashboard');
  appCache.invalidate('plan-page');
  appCache.invalidate('workouts-');   // workouts-today, workouts-split, workouts-history
  appCache.invalidate('nutrition-');  // nutrition-week-*
  appCache.invalidate('meal-plan:');  // meal-plan:<date>
}

// Backward-compatible alias
export const bustAIPlanCache = bustPlanCache;

export async function loadActivePlan(planType = 'daily') {
  const cacheKey = await getScopedPlanCacheKey(planType);
  const appCacheKey = `ai-plan:${planType}`;
  const cached = _aiPlanCache[cacheKey];

  // Tier 1: in-memory fresh cache — zero latency
  if (cached?.plan && (Date.now() - cached.fetchedAt < PLAN_CACHE_TTL)) {
    return cached.plan;
  }

  // Tier 2: sessionStorage-backed appCache — survives React re-mounts
  const storedPlan = appCache.get(appCacheKey);
  if (storedPlan && appCache.isFresh(appCacheKey)) {
    // Re-hydrate in-memory cache too
    _aiPlanCache[cacheKey] = { plan: storedPlan, fetchedAt: Date.now() };
    return storedPlan;
  }

  // Attempt network fetch — but NEVER discard a stale plan on failure
  let records = null;
  try {
    records = await backend.entities.AIPlan
      .filter(await userScopedFilter({ plan_type: planType, status: 'active' }), '-generated_at');
  } catch {
    // Network/rate-limit error — return stale plan rather than null so pages don't go blank
    const fallback = cached?.plan || storedPlan || null;
    return fallback;
  }

  if (!Array.isArray(records) || records.length === 0) {
    // Empty result — only replace cache if we had no stale plan (avoid wiping valid data)
    const fallback = cached?.plan || storedPlan || null;
    if (!fallback) {
      _aiPlanCache[cacheKey] = { plan: null, fetchedAt: Date.now() };
      appCache.set(appCacheKey, null);
    }
    return fallback;
  }

  const safeRecords = records.filter(Boolean).sort((a, b) => {
    const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
    const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
    return String(bDate).localeCompare(String(aDate));
  });

  const plan = (planType === 'daily' || planType === 'weekly')
    ? (
        safeRecords.find(p => p.source === 'plan_questionnaire_overview') ||
        safeRecords.find(p => p.plan_payload?.source === 'plan_questionnaire_overview') ||
        safeRecords.find(p => p.source === 'plan_questionnaire_initial') ||
        safeRecords.find(p => p.plan_payload?.source === 'plan_questionnaire_initial') ||
        safeRecords[0] ||
        null
      )
    : (safeRecords[0] || null);

  _aiPlanCache[cacheKey] = { plan, fetchedAt: Date.now() };
  appCache.set(appCacheKey, plan); // persist to sessionStorage
  return plan;
}

// ─── AIPlan — Weekly plan (plan_type: "weekly") ───────────────────────────────

function toLocalISO(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function getWeekStart(date = new Date()) {
  const d = new Date(date);
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setDate(d.getDate() + diff);
  d.setHours(0, 0, 0, 0);
  return toLocalISO(d);
}

export function getWeekEnd(weekStart) {
  const d = new Date(weekStart + 'T00:00:00');
  d.setDate(d.getDate() + 6);
  return toLocalISO(d);
}

export async function loadWeeklyPlan(weekStartDate) {
  const plans = await backend.entities.AIPlan.filter(await userScopedFilter({
    plan_type: 'weekly',
    status: 'active',
    date_range_start: weekStartDate,
  }), '-generated_at', 1).catch(() => []);
  return plans[0] || null;
}

export async function upsertWeeklyPlan() {
  throw new Error(
    'upsertWeeklyPlan is disabled. Weekly overview now lives on the active master AIPlan.weekly_overview.'
  );
}


// ─── Canonical personalization loader ────────────────────────────────────────

export async function loadCanonicalPersonalization() {
  const [
    profiles,
    workoutProfiles,
    nutritionProfiles,
    goals,
    injuries,
    todayLog,
    latestReadiness,
  ] = await Promise.allSettled([
    backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.WorkoutProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.Goal.filter(await userScopedFilter({ status: 'active' }), '-created_date', 20),
    backend.entities.InjuryProfile.filter(await userScopedFilter({ is_active: true }), '-created_date', 20),
    backend.entities.DailyLog.filter(await userScopedFilter({ date: getTodayISODate() })),
    backend.entities.ReadinessCheckIn.filter(await userScopedFilter(), '-date', 1),
  ]);

  return {
    userProfile: getValue(profiles, [])[0] || null,
    workoutProfile: getValue(workoutProfiles, [])[0] || null,
    nutritionProfile: getValue(nutritionProfiles, [])[0] || null,
    goals: getValue(goals, []),
    injuries: getValue(injuries, []),
    todayLog: getValue(todayLog, [])[0] || null,
    latestReadiness: getValue(latestReadiness, [])[0] || null,
  };
}

function getValue(result, fallback) {
  return result.status === 'fulfilled' ? result.value : fallback;
}

// ─── Today's Dashboard State (canonical, Supabase-only) ────────────────────────

export async function loadTodayDashboardState(date = new Date()) {
  const todayISO = (typeof date === 'string' ? date : date.toISOString()).split('T')[0];

  function sameValue(a, b) {
    return Boolean(a) && Boolean(b) && String(a) === String(b);
  }

  function newestFirst(a, b) {
    const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
    const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
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
      .filter(await userScopedFilter({ plan_type: 'daily', status: 'active' }), '-generated_at', 25)
      .catch(() => []);

    const sortedPlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];

    return sortedPlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
      sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
      sortedPlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
      sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial') ||
      sortedPlans[0] ||
      null;
  }

  async function loadLinkedEntityForDate(entity, targetDate, masterPlan) {
    if (!entity || !targetDate) return null;

    if (masterPlan?.id && masterPlan?.generation_batch_id) {
      const linkedRecords = await entity.filter(await userScopedFilter({
        date: targetDate,
        source_plan_id: masterPlan.id,
        generation_batch_id: masterPlan.generation_batch_id,
      })).catch(() => []);

      const linkedRecord = chooseBestLinkedRecord(linkedRecords, masterPlan);
      if (linkedRecord) return linkedRecord;
    }

    const dateRecords = await entity.filter(await userScopedFilter({ date: targetDate })).catch(() => []);
    return chooseBestLinkedRecord(dateRecords, masterPlan);
  }

  function normalizeWeeklyDay(day = {}) {
    const sessionTitle = getPlanDaySessionTitle(day, day.training_type || day.priority || '');
    return {
      ...day,
      dayFocus: day.dayFocus || day.day_focus || day.priority || sessionTitle || day.focus || day.summary || '',
      workout: day.workout || day.training || null,
      nutrition: day.nutrition || null,
      recovery: day.recovery || null,
    };
  }

  function pickTodayWeeklyDay(weeklyPayload) {
    const days = Array.isArray(weeklyPayload?.days) ? weeklyPayload.days : [];
    const day = days.find(d => d.date === todayISO) || null;
    return day ? normalizeWeeklyDay(day) : null;
  }

  function getMealCalories(mealPlanRecord) {
    return mealPlanRecord?.total_calories ||
      mealPlanRecord?.calories ||
      mealPlanRecord?.nutrition_targets?.calories ||
      null;
  }

  function getMealProtein(mealPlanRecord) {
    return mealPlanRecord?.total_protein_g ||
      mealPlanRecord?.total_protein ||
      mealPlanRecord?.protein ||
      null;
  }

  const [
    rUserProfile,
    rGoals,
    rInjuries,
    rReadinessToday,
    rReadinessLatest,
    rActiveMasterPlan,
  ] = await Promise.allSettled([
    backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.Goal.filter(await userScopedFilter({ status: 'active' }), '-created_date', 20),
    backend.entities.InjuryProfile.filter(await userScopedFilter({ is_active: true }), '-created_date', 20),
    backend.entities.ReadinessCheckIn.filter(await userScopedFilter({ date: todayISO })).catch(() => []),
    backend.entities.ReadinessCheckIn.filter(await userScopedFilter(), '-date', 1),
    loadActiveCanonicalMasterPlan(),
  ]);

  const _get = (r, fallback) => r.status === 'fulfilled' ? r.value : fallback;

  const userProfileRecord = _get(rUserProfile, [])[0] || null;
  const goals = _get(rGoals, []);
  const injuries = _get(rInjuries, []);
  const readinessToday = _get(rReadinessToday, [])[0] || null;
  const readinessLatest = _get(rReadinessLatest, [])[0] || null;
  const masterPlanRecord = _get(rActiveMasterPlan, null);

  const [
    dailyLogRecord,
    workoutPlanRecord,
    mealPlanRecord,
  ] = await Promise.all([
    loadLinkedEntityForDate(backend.entities.DailyLog, todayISO, masterPlanRecord),
    loadLinkedEntityForDate(backend.entities.WorkoutPlan, todayISO, masterPlanRecord),
    loadLinkedEntityForDate(backend.entities.MealPlan, todayISO, masterPlanRecord),
  ]);

  const workoutLogs = await backend.entities.WorkoutLog.filter(await userScopedFilter({ date: todayISO })).catch(() => []);
  const workoutLogRecord = chooseBestLinkedRecord(
    workoutLogs.filter(log => !workoutPlanRecord?.id || log.workout_plan_id === workoutPlanRecord.id || log.source_plan_id),
    masterPlanRecord
  ) || workoutLogs[0] || null;

  const readinessRecord = readinessToday || readinessLatest || null;

  const user = userProfileRecord ? {
    name: userProfileRecord.display_name || '',
    displayName: userProfileRecord.display_name || '',
    fitnessLevel: userProfileRecord.fitness_level || '',
    primaryGoal: goals[0]?.title || '',
    stepGoal: userProfileRecord.step_goal_daily || 10000,
    calorieGoal: userProfileRecord.calorie_goal || masterPlanRecord?.plan_payload?.nutrition_targets?.calories || null,
    sleepGoal: userProfileRecord.sleep_goal_hours || 8,
    waterGoal: userProfileRecord.water_goal_liters || masterPlanRecord?.plan_payload?.nutrition_targets?.hydration_target || 2.5,
  } : null;

  const readiness = readinessRecord ? {
    score: readinessRecord.readiness_score || null,
    energy: readinessRecord.energy || null,
    sleep: readinessRecord.sleep_quality || null,
    stress: readinessRecord.stress || null,
    soreness: readinessRecord.soreness || null,
    recommendation: readinessRecord.training_recommendation || '',
    checkedInAt: readinessRecord.date || null,
    isToday: readinessRecord.date === todayISO,
  } : null;

  const today = {
    date: todayISO,
    caloriesConsumed: dailyLogRecord?.calories_consumed || 0,
    caloriesBurned: dailyLogRecord?.calories_burned || 0,
    proteinConsumed: dailyLogRecord?.protein_consumed_g || 0,
    waterLiters: dailyLogRecord?.water_liters || 0,
    steps: dailyLogRecord?.steps || 0,
    sleepHours: dailyLogRecord?.sleep_hours || 0,
    workoutCompleted: dailyLogRecord?.workout_done || false,
    checklistItems: dailyLogRecord?.checklist_items || dailyLogRecord?.planned_checklist_items || [],
    checklistCompletedCount: dailyLogRecord?.checklist_completed_count || 0,
    checklistTotalCount: dailyLogRecord?.checklist_total_count || 0,
    checklistAdherencePct: dailyLogRecord?.checklist_adherence_pct || 0,
  };

  const workout = workoutPlanRecord ? {
    id: workoutPlanRecord.id,
    sourcePlanId: workoutPlanRecord.source_plan_id || '',
    generationBatchId: workoutPlanRecord.generation_batch_id || '',
    weeklyPlanId: workoutPlanRecord.weekly_plan_id || '',
    name: workoutPlanRecord.name || '',
    type: workoutPlanRecord.type || workoutPlanRecord.focus || '',
    durationMinutes: workoutPlanRecord.duration_min || workoutPlanRecord.duration_minutes || (workoutPlanRecord.duration ? parseInt(workoutPlanRecord.duration) : null),
    intensity: workoutPlanRecord.intensity || '',
    exercises: workoutPlanRecord.exercises || [],
    status: workoutLogRecord?.status || (dailyLogRecord?.workout_done ? 'completed' : 'planned'),
  } : null;

  const mealPlan = mealPlanRecord ? {
    id: mealPlanRecord.id,
    sourcePlanId: mealPlanRecord.source_plan_id || '',
    generationBatchId: mealPlanRecord.generation_batch_id || '',
    weeklyPlanId: mealPlanRecord.weekly_plan_id || '',
    caloriesTarget: getMealCalories(mealPlanRecord),
    proteinTarget: getMealProtein(mealPlanRecord),
    meals: mealPlanRecord.meals || {},
  } : null;

  const weeklyPayload =
    masterPlanRecord?.weekly_overview ||
    masterPlanRecord?.plan_payload?.weekly_overview ||
    null;
  const todayDayPlan = pickTodayWeeklyDay(weeklyPayload);
  const weeklyPlan = weeklyPayload ? {
    id: masterPlanRecord?.id || '',
    sourcePlanId: masterPlanRecord?.id || '',
    generationBatchId: masterPlanRecord?.generation_batch_id || '',
    title: weeklyPayload?.weeklyFocus || weeklyPayload?.weekly_focus || weeklyPayload?.title || masterPlanRecord?.plan_summary?.primary_goal || '',
    summary: weeklyPayload?.summary || masterPlanRecord?.plan_summary?.positioning_summary || masterPlanRecord?.summary || '',
    topAction: todayDayPlan?.dayFocus || '',
    currentDay: todayDayPlan,
    days: Array.isArray(weeklyPayload?.days) ? weeklyPayload.days.map(normalizeWeeklyDay) : [],
  } : null;

  let topAction = null;
  if (todayDayPlan?.dayFocus) {
    topAction = todayDayPlan.dayFocus;
  } else if (readiness?.recommendation) {
    topAction = readiness.recommendation;
  } else if (workout?.name) {
    topAction = `Complete today's workout: ${workout.name}`;
  } else if (masterPlanRecord?.summary) {
    topAction = masterPlanRecord.summary;
  }

  let aiSummary = null;
  if (readiness?.score != null && goals.length > 0) {
    const readinessScore = readiness.score;
    const primaryGoal = goals[0]?.title || '';
    const readinessAdj = readinessScore >= 75 ? 'solid' : readinessScore >= 50 ? 'moderate' : 'low';
    aiSummary = {
      topAction,
      reason: `Readiness is ${readinessAdj}${primaryGoal ? ` - on track for ${primaryGoal}` : ''}.`,
      nextBestAction: topAction,
    };
  } else if (readiness?.score != null) {
    aiSummary = {
      topAction,
      reason: `Readiness score: ${readiness.score}/100.`,
      nextBestAction: topAction,
    };
  } else if (masterPlanRecord?.summary) {
    aiSummary = {
      topAction,
      reason: masterPlanRecord.summary,
      nextBestAction: topAction,
    };
  }

  const hasEnoughPersonalizationData = !!(userProfileRecord && goals.length > 0);

  return {
    user,
    goals,
    limitations: injuries,
    readiness,
    today,
    workout,
    mealPlan,
    weeklyPlan,
    aiSummary,
    hasEnoughPersonalizationData,
    _raw: {
      userProfile: userProfileRecord,
      dailyLog: dailyLogRecord,
      readinessCheckIn: readinessRecord,
      masterPlan: masterPlanRecord,
      workoutPlan: workoutPlanRecord,
      mealPlan: mealPlanRecord,
      weeklyPlan: null,
    },
  };
}

// ─── Starter Profile: load + save (non-AI personalization) ───────────────────

export async function loadStarterPersonalization() {
  const [profiles, workoutProfiles, nutritionProfiles] = await Promise.allSettled([
    backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.WorkoutProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1),
  ]);
  return {
    userProfile: profiles.status === 'fulfilled' ? profiles.value?.[0] || null : null,
    workoutProfile: workoutProfiles.status === 'fulfilled' ? workoutProfiles.value?.[0] || null : null,
    nutritionProfile: nutritionProfiles.status === 'fulfilled' ? nutritionProfiles.value?.[0] || null : null,
  };
}

export async function saveStarterPersonalization({ userUpdates = {}, workoutUpdates = {}, nutritionUpdates = {}, injuryData = null }) {
  const saves = [];
  const now = new Date().toISOString();

  saves.push(saveUserProfile({
    ...userUpdates,
    profile_setup_completed: true,
    profile_setup_completed_at: now,
    updated_from_starter_profile: true,
    onboarding_complete: true,
  }));

  saves.push(saveWorkoutProfile({ ...workoutUpdates, updated_from_starter_profile: true }));
  saves.push(saveNutritionProfile({ ...nutritionUpdates, updated_from_starter_profile: true }));

  if (injuryData) {
    saves.push(saveInjuryProfile({ ...injuryData, source: 'starter_profile' }));
  }

  await Promise.all(saves);
  await invalidatePersonalizationContext();
}

/**
 * Converts saved Supabase profile entities into PlanQuestionnaire-compatible initialAnswers.
 * Also returns completedStepIds so the questionnaire can skip known questions.
 */
export async function loadPlanQuestionnaireDefaults() {
  const { userProfile: up, workoutProfile: wp, nutritionProfile: np } = await loadStarterPersonalization();

  const initialAnswers = {};
  const completedStepIds = [];

  if (up) {
    if (up.age) { initialAnswers.age = String(up.age); }
    if (up.height_cm) { initialAnswers.heightCm = String(up.height_cm); }
    if (up.weight_kg) { initialAnswers.weightKg = String(up.weight_kg); }
    if (up.sex) { initialAnswers.sex = up.sex; }
    if (up.age && up.height_cm && up.weight_kg) completedStepIds.push('bodyStats');
  }

  // Map the starter profile's activity_level → questionnaire's currentTraining option.
  // The starter "Calculate your starting targets" already asked the user how active
  // they are; reuse that answer so the AI plan questionnaire doesn't ask the same
  // question again on first generation.
  const STARTER_ACTIVITY_TO_CURRENT_TRAINING = {
    sedentary: 'never',
    lightly_active: '1_2_days',
    moderately_active: '3_4_days',
    very_active: '5_plus',
    athlete: '5_plus',
  };
  const starterActivity = np?.activity_level || wp?.current_activity_level || '';
  const mappedCurrentTraining = STARTER_ACTIVITY_TO_CURRENT_TRAINING[starterActivity];
  if (mappedCurrentTraining) {
    initialAnswers.currentTraining = mappedCurrentTraining;
    completedStepIds.push('currentTraining');
  }

  // Pre-fill primary sport from the starter profile if the user already specified one.
  // We don't skip the step — they can still change/remove the sport — but the answer is pre-loaded.
  const starterSport = wp?.primary_sport && wp.primary_sport.trim();
  // Starter profile uses 'sport' as a generic placeholder; only treat as a real sport if it's something more specific
  if (starterSport && starterSport.toLowerCase() !== 'sport' && starterSport.toLowerCase() !== 'gym' && starterSport.toLowerCase() !== 'general_fitness') {
    initialAnswers.primarySport = starterSport;
    initialAnswers.hasPrimarySport = true;
  }

  // Note: location, equipment, and limitations are NOT pre-filled from starter profile
  // — those are only collected via the Plan Questionnaire.

  if (np) {
    if (np.liked_foods && np.liked_foods.length >= 3) {
      initialAnswers.selectedFoods = np.liked_foods;
      completedStepIds.push('favoriteFoods');
    }
    if (np.disliked_foods && np.disliked_foods.length > 0) {
      initialAnswers.foodsToAvoid = np.disliked_foods.join(', ');
    }
    if (np.allergies && np.allergies.length > 0) {
      initialAnswers.allergies = np.allergies.join(', ');
    }
    if (np.disliked_foods?.length > 0 || np.allergies?.length > 0) {
      completedStepIds.push('foodsToAvoid');
    }
  }

  return { initialAnswers, completedStepIds };
}

// ─── Plan Questionnaire Canonical Save ───────────────────────────────────────

/**
 * Maps PlanQuestionnaire answers into Supabase entities.
 * Only writes fields the user actually answered — never overwrites with blanks.
 * Call this before generating any AI plan.
 */
export async function savePlanQuestionnairePersonalization(answers) {
  const saves = [];

  // ── 1. UserProfile ──────────────────────────────────────────────────────────
  const userProfileUpdates = {
    onboarding_complete: true,
    plan_questionnaire_completed: true,
    plan_questionnaire_completed_at: new Date().toISOString(),
    updated_from_plan_questionnaire: true,
  };
  if (answers.name && answers.name.trim()) userProfileUpdates.display_name = answers.name.trim();
  if (answers.age && Number(answers.age) > 0) userProfileUpdates.age = Number(answers.age);
  if (answers.heightCm && Number(answers.heightCm) > 0) userProfileUpdates.height_cm = Number(answers.heightCm);
  if (answers.weightKg && Number(answers.weightKg) > 0) userProfileUpdates.weight_kg = Number(answers.weightKg);
  if (answers.sex) userProfileUpdates.sex = answers.sex;

  // Map primary goal → fitness_level heuristic
  const activityDaysMap = { daily: 6, '4x_week': 4, '2x_week': 2, monthly: 1 };
  if (answers.currentActivity) {
    const days = activityDaysMap[answers.currentActivity] || 3;
    userProfileUpdates.fitness_level = days >= 5 ? 'advanced' : days >= 3 ? 'intermediate' : 'beginner';
  }

  saves.push(saveUserProfile(userProfileUpdates));

  // ── 2. Goals ────────────────────────────────────────────────────────────────
  const GOAL_TITLE_MAP = {
    lose_fat: 'Lose body fat',
    build_muscle: 'Build muscle',
    get_stronger: 'Get stronger',
    improve_fitness: 'Improve overall fitness',
    improve_flexibility: 'Improve flexibility',
    sport_specific: 'Sport-specific training',
    feel_better: 'Feel more energetic & healthy',
  };
  const GOAL_CATEGORY_MAP = {
    lose_fat: 'body',
    build_muscle: 'fitness',
    get_stronger: 'performance',
    improve_fitness: 'fitness',
    improve_flexibility: 'fitness',
    sport_specific: 'performance',
    feel_better: 'habit',
  };

  const rawGoals = answers.goal
    ? answers.goal.split(', ').map(g => g.trim()).filter(Boolean)
    : [];

  if (rawGoals.length > 0) {
    // Fetch existing questionnaire goals to upsert instead of duplicate
    const existingGoals = await backend.entities.Goal.filter(await userScopedFilter({ status: 'active' }), '-created_date', 30).catch(() => []);
    const questionnaireGoals = existingGoals.filter(g => g.source === 'plan_questionnaire');

    for (let i = 0; i < rawGoals.length; i++) {
      const gId = rawGoals[i];
      const title = GOAL_TITLE_MAP[gId] || gId;
      const category = GOAL_CATEGORY_MAP[gId] || 'fitness';
      const priority = i === 0 ? 'high' : 'medium';

      const existing = questionnaireGoals.find(
        g => g.title === title || (g.category === category && g.source === 'plan_questionnaire')
      );

      if (existing) {
        saves.push(backend.entities.Goal.update(existing.id, { title, category, priority, status: 'active' }));
      } else {
        saves.push(backend.entities.Goal.create(await withUserEmail({
          title, category, priority, status: 'active',
          source: 'plan_questionnaire',
          created_from_plan_questionnaire: true,
        })));
      }
    }
  }

  const wantsWorkout = answers.planType === 'workout' || answers.planType === 'daily_performance';
  const wantsNutrition = answers.planType === 'nutrition' || answers.planType === 'daily_performance';

  // ── 3. WorkoutProfile ───────────────────────────────────────────────────────
  const WORKOUT_GOAL_MAP = {
    lose_fat: 'fat_loss',
    build_muscle: 'muscle_gain',
    get_stronger: 'strength',
    improve_fitness: 'general_fitness',
    improve_flexibility: 'general_fitness',
    sport_specific: 'sport_performance',
    feel_better: 'general_fitness',
  };
  const DESIRED_DAYS_MAP = { light: 2, moderate: 3, high: 5, full: 6 };

  const workoutUpdates = { updated_from_plan_questionnaire: true };
  const primaryGoalId = rawGoals[0];
  if (primaryGoalId && WORKOUT_GOAL_MAP[primaryGoalId]) {
    workoutUpdates.primary_goal = WORKOUT_GOAL_MAP[primaryGoalId];
  }
  if (answers.currentActivity) {
    const days = activityDaysMap[answers.currentActivity] || 3;
    workoutUpdates.days_per_week = answers.desiredActivity
      ? (DESIRED_DAYS_MAP[answers.desiredActivity] || days)
      : days;
    workoutUpdates.experience_level = days >= 5 ? 'advanced' : days >= 3 ? 'intermediate' : 'beginner';
  }
  if (answers.equipment && answers.equipment.length > 0) {
    workoutUpdates.equipment_available = answers.equipment;
  }
  if (answers.aggressiveness) {
    workoutUpdates.aggressiveness = answers.aggressiveness;
  }
  if (answers.planType) {
    workoutUpdates.plan_type = answers.planType;
  }
  if (answers.activityDetail) {
    workoutUpdates.workout_styles = [answers.activityDetail];
  }
  if (answers.hasLimitations && answers.limitationsDetail) {
    workoutUpdates.limitations_summary = answers.limitationsDetail;
  }
  if (answers.desiredActivity) {
    workoutUpdates.desired_activity_level = answers.desiredActivity;
  }
  if (answers.currentActivity) {
    workoutUpdates.current_activity_level = answers.currentActivity;
  }
  if (answers.primarySport && answers.primarySport.trim()) {
    workoutUpdates.primary_sport = answers.primarySport.trim();
  }
  if (answers.sessionDurationMin && Number(answers.sessionDurationMin) > 0) {
    workoutUpdates.session_duration_min = Number(answers.sessionDurationMin);
  }
  if (answers.trainingLocation) {
    // Map 'mixed' / 'gym' / 'home' directly; questionnaire doesn't expose 'outdoors' separately.
    const locationMap = { gym: 'gym', home: 'home', mixed: 'mixed', outdoors: 'outdoors' };
    if (locationMap[answers.trainingLocation]) {
      workoutUpdates.training_location = locationMap[answers.trainingLocation];
    }
  }
  if (answers.hasLimitations !== null && answers.hasLimitations !== undefined) {
    workoutUpdates.has_limitations = !!answers.hasLimitations;
  }
  // Persist sport sessions and second sport in workout_styles for downstream AI context.
  const DAY_KEYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  const formatSched = (sched) => {
    if (!sched || typeof sched !== 'object') return '';
    const parts = DAY_KEYS
      .map(d => Array.isArray(sched[d]) && sched[d].length ? `${d}:${sched[d].join('+')}` : null)
      .filter(Boolean);
    return parts.length ? ` [${parts.join(', ')}]` : '';
  };
  const sportNotes = [];
  if (answers.primarySport?.trim()) {
    sportNotes.push(`${answers.primarySport.trim()}${formatSched(answers.primarySportSchedule)}`);
  }
  if (answers.secondSport?.trim()) {
    sportNotes.push(`${answers.secondSport.trim()}${formatSched(answers.secondSportSchedule)}`);
  }
  if (sportNotes.length > 0) {
    workoutUpdates.workout_styles = [
      ...(workoutUpdates.workout_styles || []),
      ...sportNotes,
    ];
  }

  if (wantsWorkout) saves.push(saveWorkoutProfile(workoutUpdates));

  // ── 4. NutritionProfile ─────────────────────────────────────────────────────
  const NUTRITION_GOAL_MAP = {
    lose_fat: 'fat_loss',
    build_muscle: 'muscle_gain',
    get_stronger: 'performance',
    improve_fitness: 'general_health',
    improve_flexibility: 'general_health',
    sport_specific: 'performance',
    feel_better: 'general_health',
  };

  const nutritionUpdates = {
    updated_from_plan_questionnaire: true,
    // When the AI plan questionnaire runs, the AI plan becomes the calorie source of truth.
    // This ensures the manual 'starter profile' target no longer overrides the AI plan targets.
    calorie_target_source: 'ai_plan',
    calorie_target: null,
    protein_target_g: null,
    carbs_target_g: null,
    fats_target_g: null,
  };
  if (primaryGoalId && NUTRITION_GOAL_MAP[primaryGoalId]) {
    nutritionUpdates.primary_goal = NUTRITION_GOAL_MAP[primaryGoalId];
  }
  if (answers.selectedFoods && answers.selectedFoods.length > 0) {
    nutritionUpdates.liked_foods = answers.selectedFoods;
  }
  if (answers.mealsPerDay) {
    // mealsPerDay arrives as '2' | '3' | '4' | '5+' — parse to number, treat '5+' as 5.
    const parsed = parseInt(String(answers.mealsPerDay), 10);
    if (Number.isFinite(parsed) && parsed > 0) {
      nutritionUpdates.meals_per_day = parsed;
    }
  }
  // Map dietStyles → NutritionProfile.dietary_preference (schema accepts a single enum).
  // Pick the first style that matches the enum so the profile reflects the user's primary preference.
  if (Array.isArray(answers.dietStyles) && answers.dietStyles.length > 0) {
    const DIETARY_PREF_ENUM = ['vegetarian', 'vegan', 'pescatarian', 'keto', 'paleo', 'gluten_free', 'dairy_free'];
    const matched = answers.dietStyles.find(d => DIETARY_PREF_ENUM.includes(d));
    if (matched) nutritionUpdates.dietary_preference = matched;
  }
  if (answers.allergies && answers.allergies.trim()) {
    nutritionUpdates.allergies = answers.allergies
      .split(/[,\n]+/)
      .map(a => a.trim())
      .filter(Boolean);
  }
  if (answers.foodsToAvoid && answers.foodsToAvoid.trim()) {
    // Parse comma-separated string into array
    const avoidList = answers.foodsToAvoid
      .split(/[,\n]+/)
      .map(f => f.trim())
      .filter(Boolean);
    if (avoidList.length > 0) {
      nutritionUpdates.disliked_foods = avoidList;
    }
  }
  if (answers.struggles && answers.struggles.length > 0) {
    nutritionUpdates.nutrition_struggles = answers.struggles;
  }
  if (answers.additionalNotes && answers.additionalNotes.trim()) {
    nutritionUpdates.notes = answers.additionalNotes.trim();
  }
  if (wantsNutrition) nutritionUpdates.plan_type = answers.planType;

  if (wantsNutrition) saves.push(saveNutritionProfile(nutritionUpdates));

  // ── 5. InjuryProfile ────────────────────────────────────────────────────────
  if (answers.hasLimitations && answers.limitationsDetail && answers.limitationsDetail.trim()) {
    saves.push(
      saveInjuryProfile({
        body_area: 'unspecified',
        severity: 'mild_discomfort',
        is_active: true,
        notes: answers.limitationsDetail.trim(),
        source: 'plan_questionnaire',
        description: answers.limitationsDetail.trim(),
      })
    );
  }

  // Await all writes — a failure here must stop plan generation
  await Promise.all(saves);
}

// ─── Weekly Plan Date Normalization ──────────────────────────────────────────

const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/**
 * Normalizes a weekly plan's day dates starting from weekStart.
 * Never trusts LLM-generated dates — always overwrites with computed values.
 * Ensures exactly 7 days, sets dayLabel and dayName programmatically.
 */
export function normalizeWeeklyPlanDates(plan, weekStart) {
  const base = new Date(weekStart + 'T00:00:00');
  const days = Array.from({ length: 7 }, (_, i) => {
    const d = new Date(base);
    d.setDate(base.getDate() + i);
    const dateStr = toLocalISO(d);
    const dayOfWeek = d.getDay();
    // Merge with LLM-generated day if available, but always overwrite date fields
    const llmDay = (plan.days || [])[i] || {};
    return {
      ...llmDay,
      date: dateStr,
      dayLabel: DAY_LABELS[dayOfWeek],
      dayName: DAY_NAMES[dayOfWeek],
    };
  });
  return { ...plan, days };
}

// ─── Legacy Weekly Plan Operationalization Disabled ──────────────────────────

export async function operationalizeWeeklyPlan() {
  throw new Error(
    'operationalizeWeeklyPlan is disabled. Child projections must be created by generateInitialPlanBundle so they stay linked to the canonical master AIPlan.'
  );
}

// ─── Migration: localStorage → Supabase (v2) ───────────────────────────────────

const MIGRATION_KEY = 'execute_backend_personalization_migrated_v2';

export async function runMigrationIfNeeded() {
  // Accept either the new or old migration flag
  if (localStorage.getItem(MIGRATION_KEY) === 'true' || localStorage.getItem('evanlog_backend_personalization_migrated_v2') === 'true') {
    // Ensure the new key is set so future checks pass quickly
    localStorage.setItem(MIGRATION_KEY, 'true');
    return;
  }

  // Only migrate if real localStorage data exists (not hardcoded defaults)
  const localCtxRaw = localStorage.getItem('execute_health_context') || localStorage.getItem('evanlog_health_context');

  // Check if backend profile already has data
  const existingProfile = await backend.entities.UserProfile.list('-updated_date', 1).catch(() => []);

  if (localCtxRaw && existingProfile.length === 0) {
    try {
      const ctx = JSON.parse(localCtxRaw);

      // Only migrate if there's real personal data (name set, age set, etc.)
      if (ctx.profile?.name || ctx.profile?.age || ctx.profile?.weight_kg) {
        await saveUserProfile({
          display_name: ctx.profile.name || '',
          age: ctx.profile.age || null,
          weight_kg: ctx.profile.weight_kg || null,
          height_cm: ctx.profile.height_cm || null,
          fitness_level: ctx.workout?.experience_level || 'intermediate',
          step_goal_daily: ctx.today?.steps_goal || 10000,
          calorie_goal: ctx.nutrition?.calorie_target || null,
          sleep_goal_hours: 8,
          water_goal_liters: ctx.today?.water_goal || 2.5,
          coaching_style: ctx.coaching_style || 'balanced',
        }).catch(() => {});
      }

      if (ctx.workout && Object.keys(ctx.workout).length > 0) {
        await saveWorkoutProfile({
          primary_goal: ctx.workout.primary_goal || null,
          experience_level: ctx.workout.experience_level || 'intermediate',
          days_per_week: ctx.workout.days_per_week || null,
          session_duration_min: ctx.workout.session_duration_min || null,
          preferred_split: ctx.workout.preferred_split || null,
          equipment_available: ctx.workout.equipment || [],
          cardio_preference: ctx.workout.cardio_preference || null,
          focus_areas: ctx.workout.focus_areas || [],
        }).catch(() => {});
      }

      if (ctx.nutrition && Object.keys(ctx.nutrition).length > 0) {
        await saveNutritionProfile({
          calorie_target: ctx.nutrition.calorie_target || null,
          protein_target_g: ctx.nutrition.protein_target_g || null,
          carbs_target_g: ctx.nutrition.carbs_target_g || null,
          fats_target_g: ctx.nutrition.fats_target_g || null,
          dietary_preference: ctx.nutrition.dietary_preference || 'none',
          allergies: ctx.nutrition.allergies || [],
          disliked_foods: ctx.nutrition.disliked_foods || [],
          liked_foods: ctx.nutrition.liked_foods || [],
          meals_per_day: ctx.nutrition.meals_per_day || 3,
          cooking_style: ctx.nutrition.cooking_style || null,
          budget_level: ctx.nutrition.budget_level || null,
        }).catch(() => {});
      }

      // Migrate active goals (only real ones from context)
      if (Array.isArray(ctx.goals)) {
        for (const g of ctx.goals.filter(g => g.active && g.title)) {
          await backend.entities.Goal.create({
            title: g.title,
            category: g.category || 'fitness',
            status: 'active',
          }).catch(() => {});
        }
      }

      // Migrate limitations to InjuryProfile
      if (Array.isArray(ctx.limitations)) {
        for (const l of ctx.limitations.filter(l => l.area)) {
          await createInjury({
            body_area: l.area,
            severity: l.severity || 'mild_discomfort',
            notes: l.notes || '',
            is_active: l.active !== false,
          }).catch(() => {});
        }
      }
    } catch {}
  }

   // Legacy localStorage plan migration intentionally disabled.
  // The Plan Questionnaire must create the canonical master AIPlan and all child projections.


  // Migrate custom checklist items from localStorage → CustomChecklistItem entity
  const CHECKLIST_MIGRATION_KEY = 'execute_checklist_migrated_to_dailylog';
  if (localStorage.getItem(CHECKLIST_MIGRATION_KEY) !== 'true' && localStorage.getItem('evanlog_checklist_migrated_to_dailylog') !== 'true') {
    try {
      const customRaw = localStorage.getItem('execute_custom_checklist_items') || localStorage.getItem('evanlog_custom_checklist_items');
      if (customRaw) {
        const customItems = JSON.parse(customRaw) || [];
        const existingCustom = await backend.entities.CustomChecklistItem.filter({ is_active: true }).catch(() => []);
        if (existingCustom.length === 0 && customItems.length > 0) {
          for (const ci of customItems) {
            if (ci.label) {
              await backend.entities.CustomChecklistItem.create({
                label: ci.label,
                days: ci.days || [0, 1, 2, 3, 4, 5, 6],
                endsOn: ci.endsOn || null,
                is_active: true,
              }).catch(() => {});
            }
          }
        }
      }
    } catch {}
    localStorage.setItem(CHECKLIST_MIGRATION_KEY, 'true');
  }

  localStorage.setItem(MIGRATION_KEY, 'true');
  await invalidatePersonalizationContext().catch(() => {});
}

// ─── Backward-compatible aliases ─────────────────────────────────────────────
export const invalidateUserAIContext = invalidatePersonalizationContext;
export const loadActiveAIPlan = loadActivePlan;
