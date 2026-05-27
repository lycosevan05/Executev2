/**
 * goalSync.js
 *
 * Derives Goals automatically from the user's active AIPlan + profiles,
 * and writes GoalProgressEntry records from daily/workout logs.
 *
 * Called on Progress page load. Never overwrites manually created goals.
 */

import { backend } from '@/api/backendClient';

const TODAY = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

const toLocalISO = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

// ─── Derive plan-based goals ───────────────────────────────────────────────────

/**
 * Given an active AIPlan + WorkoutProfile + UserProfile, produce a list of
 * candidate Goal definitions that should exist for this user.
 */
function deriveGoalsFromPlan({ plan, workoutProfile, userProfile, nutritionProfile }) {
  const candidates = [];
  const today = TODAY();

  // Derive a 30-day target date
  const in30 = new Date();
  in30.setDate(in30.getDate() + 30);
  const target30 = toLocalISO(in30);

  const in90 = new Date();
  in90.setDate(in90.getDate() + 90);
  const target90 = toLocalISO(in90);

  // ── Weekly workout sessions ──────────────────────────────────────────────────
  const daysPerWeek = workoutProfile?.days_per_week || plan?.plan_payload?.training_split?.sessions_per_week;
  if (daysPerWeek) {
    candidates.push({
      _key: 'weekly_workouts',
      title: `Train ${daysPerWeek}x per week`,
      category: 'fitness',
      target_value: daysPerWeek,
      current_value: 0,
      unit: 'sessions/week',
      emoji: '🏋️',
      metric_source: 'workout_log',
      metric_field: 'sessions_this_week',
      target_direction: 'complete_count',
      target_mode: 'recurring',
      cadence: 'weekly',
      priority: 'high',
      start_date: today,
      target_date: target30,
      source: 'ai_plan',
    });
  }

  // ── Daily steps ───────────────────────────────────────────────────────────────
  const stepGoal = userProfile?.step_goal_daily || 10000;
  candidates.push({
    _key: 'daily_steps',
    title: `Hit ${stepGoal.toLocaleString()} steps daily`,
    category: 'fitness',
    target_value: stepGoal,
    current_value: 0,
    unit: 'steps/day',
    emoji: '🚶',
    metric_source: 'daily_log',
    metric_field: 'steps',
    target_direction: 'complete_count',
    target_mode: 'recurring',
    cadence: 'daily',
    priority: 'medium',
    start_date: today,
    target_date: target30,
    source: 'ai_plan',
  });

  // ── Calorie target ────────────────────────────────────────────────────────────
  const calTarget =
    nutritionProfile?.calorie_target ||
    plan?.nutrition_targets?.calories ||
    plan?.plan_payload?.nutrition_targets?.calories;
  if (calTarget) {
    candidates.push({
      _key: 'daily_calories',
      title: `Hit ${calTarget} kcal daily`,
      category: 'nutrition',
      target_value: calTarget,
      current_value: 0,
      unit: 'kcal/day',
      emoji: '🍽️',
      metric_source: 'daily_log',
      metric_field: 'calories_consumed',
      target_direction: 'complete_count',
      target_mode: 'recurring',
      cadence: 'daily',
      priority: 'medium',
      start_date: today,
      target_date: target30,
      source: 'ai_plan',
    });
  }

  // ── Protein target ────────────────────────────────────────────────────────────
  const proteinTarget =
    nutritionProfile?.protein_target_g ||
    plan?.nutrition_targets?.protein_g ||
    plan?.plan_payload?.nutrition_targets?.protein_g;
  if (proteinTarget) {
    candidates.push({
      _key: 'daily_protein',
      title: `Eat ${proteinTarget}g protein daily`,
      category: 'nutrition',
      target_value: proteinTarget,
      current_value: 0,
      unit: 'g protein/day',
      emoji: '💪',
      metric_source: 'daily_log',
      metric_field: 'protein_consumed_g',
      target_direction: 'complete_count',
      target_mode: 'recurring',
      cadence: 'daily',
      priority: 'medium',
      start_date: today,
      target_date: target30,
      source: 'ai_plan',
    });
  }

  // ── Hydration ────────────────────────────────────────────────────────────────
  const waterGoal = userProfile?.water_goal_liters || 2.5;
  candidates.push({
    _key: 'daily_water',
    title: `Drink ${waterGoal}L water daily`,
    category: 'habit',
    target_value: waterGoal,
    current_value: 0,
    unit: 'L/day',
    emoji: '💧',
    metric_source: 'daily_log',
    metric_field: 'water_liters',
    target_direction: 'complete_count',
    target_mode: 'recurring',
    cadence: 'daily',
    priority: 'low',
    start_date: today,
    target_date: target30,
    source: 'ai_plan',
  });

  // ── Sleep target ──────────────────────────────────────────────────────────────
  const sleepGoal = userProfile?.sleep_goal_hours || 8;
  candidates.push({
    _key: 'daily_sleep',
    title: `Sleep ${sleepGoal} hours nightly`,
    category: 'sleep',
    target_value: sleepGoal,
    current_value: 0,
    unit: 'hrs/night',
    emoji: '🌙',
    metric_source: 'daily_log',
    metric_field: 'sleep_hours',
    target_direction: 'complete_count',
    target_mode: 'recurring',
    cadence: 'daily',
    priority: 'medium',
    start_date: today,
    target_date: target30,
    source: 'ai_plan',
  });

  // ── Body weight goal (from plan primary_goal or UserProfile goals) ────────────
  const planGoal = plan?.plan_summary?.primary_goal || plan?.plan_payload?.plan_summary?.primary_goal || '';
  const userGoals = userProfile?.goals || [];
  const wantsFatLoss = /fat.loss|lose|cut/i.test(planGoal) || userGoals.some(g => /fat.loss|lose|cut/i.test(g));
  const wantsMuscle = /muscle|gain|bulk/i.test(planGoal) || userGoals.some(g => /muscle|gain|bulk/i.test(g));

  if (userProfile?.weight_kg) {
    if (wantsFatLoss) {
      const targetWeight = Math.round((userProfile.weight_kg - 5) * 10) / 10;
      candidates.push({
        _key: 'body_weight',
        title: `Reach ${targetWeight}kg body weight`,
        category: 'body',
        target_value: targetWeight,
        current_value: userProfile.weight_kg,
        start_value: userProfile.weight_kg,
        unit: 'kg',
        emoji: '⚖️',
        metric_source: 'daily_log',
        metric_field: 'weight_kg',
        target_direction: 'decrease',
        target_mode: 'absolute',
        cadence: 'weekly',
        priority: 'high',
        start_date: today,
        target_date: target90,
        source: 'ai_plan',
      });
    } else if (wantsMuscle) {
      const targetWeight = Math.round((userProfile.weight_kg + 3) * 10) / 10;
      candidates.push({
        _key: 'body_weight',
        title: `Reach ${targetWeight}kg body weight`,
        category: 'body',
        target_value: targetWeight,
        current_value: userProfile.weight_kg,
        start_value: userProfile.weight_kg,
        unit: 'kg',
        emoji: '⚖️',
        metric_source: 'daily_log',
        metric_field: 'weight_kg',
        target_direction: 'increase',
        target_mode: 'absolute',
        cadence: 'weekly',
        priority: 'high',
        start_date: today,
        target_date: target90,
        source: 'ai_plan',
      });
    }
  }

  return candidates;
}

// ─── Upsert plan-derived goals ────────────────────────────────────────────────

/**
 * Creates or skips plan-derived goals.
 * Never overwrites manually created goals or existing plan goals that have progress.
 */
export async function syncPlanGoals() {
  const [plans, workoutProfiles, userProfiles, nutritionProfiles, existingGoals] = await Promise.all([
    backend.entities.AIPlan.filter({ status: 'active' }, '-generated_at', 1).catch(() => []),
    backend.entities.WorkoutProfile.list('-updated_date', 1).catch(() => []),
    backend.entities.UserProfile.list('-updated_date', 1).catch(() => []),
    backend.entities.NutritionProfile.list('-updated_date', 1).catch(() => []),
    backend.entities.Goal.filter({ status: 'active' }, '-created_date', 50).catch(() => []),
  ]);

  const plan = plans[0] || null;
  if (!plan && !userProfiles[0]) return; // nothing to derive from

  const candidates = deriveGoalsFromPlan({
    plan,
    workoutProfile: workoutProfiles[0] || null,
    userProfile: userProfiles[0] || null,
    nutritionProfile: nutritionProfiles[0] || null,
  });

  // Map existing plan goals by their _key (stored in metric_field + metric_source combo)
  const existingPlanGoals = existingGoals.filter(g => g.source === 'ai_plan');

  const creates = [];
  for (const candidate of candidates) {
    const { _key, ...goalData } = candidate;
    // Check if a goal with same metric_field + metric_source already exists
    const alreadyExists = existingPlanGoals.some(
      g => g.metric_field === goalData.metric_field && g.metric_source === goalData.metric_source
    );
    if (!alreadyExists) {
      creates.push(backend.entities.Goal.create({ ...goalData, status: 'active' }).catch(() => null));
    }
  }

  if (creates.length > 0) {
    await Promise.all(creates);
  }
}

// ─── Auto-track progress from daily logs ─────────────────────────────────────

/**
 * Reads recent DailyLogs + WorkoutLogs and writes GoalProgressEntry records
 * for all auto-tracked goals. Called on Progress page load.
 * Only writes entries for dates that don't already have one.
 */
export async function autoTrackGoalProgress(goals) {
  const today = TODAY();
  const sevenDaysAgo = new Date();
  sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
  const cutoff = toLocalISO(sevenDaysAgo);

  const autoGoals = goals.filter(g => g.metric_source && g.metric_source !== 'manual' && g.metric_field);
  if (!autoGoals.length) return;

  const [dailyLogs, workoutLogs, existingEntries] = await Promise.all([
    backend.entities.DailyLog.list('-date', 14).catch(() => []),
    backend.entities.WorkoutLog.filter({ status: 'completed' }, '-date', 14).catch(() => []),
    backend.entities.GoalProgressEntry.list('-date', 200).catch(() => []),
  ]);

  // Map existing entries: goal_id + date → true
  const entryKeys = new Set(existingEntries.map(e => `${e.goal_id}::${e.date}`));

  const writes = [];

  for (const goal of autoGoals) {
    if (goal.metric_source === 'daily_log') {
      const field = goal.metric_field;
      for (const log of dailyLogs) {
        if (!log.date || log.date < cutoff) continue;
        const val = log[field];
        if (val == null || val === 0) continue;
        const key = `${goal.id}::${log.date}`;
        if (!entryKeys.has(key)) {
          entryKeys.add(key);
          writes.push(
            backend.entities.GoalProgressEntry.create({
              goal_id: goal.id,
              date: log.date,
              value: val,
              target_value_snapshot: goal.target_value,
              source: 'daily_log',
              source_entity_id: log.id,
            }).catch(() => null)
          );
        }
      }

      // Update goal's current_value to today's value if available
      if (field !== 'weight_kg') {
        const todayLog = dailyLogs.find(l => l.date === today);
        if (todayLog && todayLog[field] != null && todayLog[field] !== goal.current_value) {
          writes.push(
            backend.entities.Goal.update(goal.id, { current_value: todayLog[field] }).catch(() => null)
          );
        }
      }
    }

    if (goal.metric_source === 'workout_log' && goal.metric_field === 'sessions_this_week') {
      // Count completed workouts this week
      const weekStart = getWeekStart();
      const sessionsThisWeek = workoutLogs.filter(l => l.date >= weekStart && l.date <= today).length;
      const key = `${goal.id}::${today}`;
      if (sessionsThisWeek > 0 && !entryKeys.has(key)) {
        entryKeys.add(key);
        writes.push(
          backend.entities.GoalProgressEntry.create({
            goal_id: goal.id,
            date: today,
            value: sessionsThisWeek,
            target_value_snapshot: goal.target_value,
            source: 'workout_log',
          }).catch(() => null)
        );
      }
      if (sessionsThisWeek !== goal.current_value) {
        writes.push(
          backend.entities.Goal.update(goal.id, { current_value: sessionsThisWeek }).catch(() => null)
        );
      }
    }
  }

  if (writes.length > 0) {
    await Promise.all(writes);
  }
}

function getWeekStart() {
  const d = new Date();
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setDate(d.getDate() + diff);
  return toLocalISO(d);
}