/**
 * refinePlanFromChat.js
 *
 * Lets the Refine Plan chatbot actually modify the user's active master AIPlan.
 *
 * Flow:
 * 1. Caller passes the user's natural-language change request + the current master AIPlan.
 * 2. We ask the LLM to produce a revised overview in the EXACT shape used by
 *    generateInitialPlanBundle (plan_summary, long_term_plan, nutrition_targets,
 *    training_split, recovery_strategy, weekly_overview).
 * 3. We validate / normalize, archive the current active plan, and create a new one
 *    with a fresh generation_batch_id and source='refine_chat'.
 * 4. We bust plan caches so the dashboard, workouts page, meals page, etc. pick up
 *    the new plan immediately. WorkoutPlan / MealPlan projections are re-generated
 *    on demand by the existing getOrCreateWorkoutPlanForDate / MealPlanForDate
 *    helpers because they match on the new source_plan_id + generation_batch_id.
 */

import { backend } from '@/api/backendClient';
import {
  userScopedFilter,
  withUserEmail,
  bustPlanCache,
  invalidateUserAIContext,
} from '@/lib/personalizationSync';
import { getPlanDaySessionTitle, isGenericPlanDayTitle } from '@/lib/planDayDisplay';

const VALID_DAY_TYPES = ['training', 'recovery', 'rest', 'mobility'];
const DAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function generateBatchId() {
  return `refine_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function toLocalISO(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function getWeekDates(weekStart) {
  const base = new Date(weekStart + 'T00:00:00');
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(base);
    d.setDate(base.getDate() + i);
    return toLocalISO(d);
  });
}

function parseMaybeJson(value) {
  if (value && typeof value === 'object') return value;
  if (typeof value !== 'string') return null;
  const stripped = value.replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/, '').trim();
  try { return JSON.parse(stripped); } catch { return null; }
}

function inferDayType(day) {
  if (day.workout_needed === true) return 'training';
  if (day.workout_needed === false) {
    const t = (day.training_type || '').toLowerCase();
    if (/\bmobility\b|\bstretch/.test(t)) return 'mobility';
    if (/\brecovery\b|\bactive recovery\b/.test(t)) return 'recovery';
    return 'rest';
  }
  return 'training';
}

function normalizeAndValidateOverview(overview) {
  const errors = [];
  const dateRegex = /^\d{4}-\d{2}-\d{2}$/;

  if (!overview?.plan_summary) errors.push('plan_summary is required');
  if (!overview?.nutrition_targets) errors.push('nutrition_targets is required');
  if (!overview?.recovery_strategy) errors.push('recovery_strategy is required');

  const days = overview?.weekly_overview?.days;
  if (!Array.isArray(days)) {
    errors.push('weekly_overview.days must be an array');
  } else {
    if (days.length !== 7) errors.push(`weekly_overview.days must have exactly 7 days, got ${days.length}`);
    days.forEach((d, i) => {
      if (!dateRegex.test(d.date)) errors.push(`Day ${i} has invalid date: ${d.date}`);
      if (!d.training_type) errors.push(`Day ${i} missing training_type`);
      if (!d.priority) errors.push(`Day ${i} missing priority`);
      if (!d.session_title || isGenericPlanDayTitle(d.session_title)) {
        d.session_title = getPlanDaySessionTitle(
          d,
          d.day_type === 'training' ? 'Performance Session' : 'Recovery Focus'
        );
      }

      if (!d.day_type || !VALID_DAY_TYPES.includes(d.day_type)) {
        d.day_type = inferDayType(d);
      }
      d.workout_needed = d.day_type === 'training';
    });

    if (overview.training_split) {
      const actualTrainingDays = days.filter(d => d.day_type === 'training').length;
      overview.training_split.days_per_week = actualTrainingDays;
    }
  }

  if (errors.length > 0) {
    throw new Error(`Refine validation failed:\n${errors.join('\n')}`);
  }
}

function buildRefinePrompt(currentPlan, changeRequest, weekStart) {
  const weekDates = getWeekDates(weekStart);

  // Pull current overview from whichever location holds it
  const current = {
    plan_summary: currentPlan.plan_summary || currentPlan.plan_payload?.plan_summary || {},
    long_term_plan: currentPlan.plan_payload?.long_term_plan || {},
    nutrition_targets: currentPlan.nutrition_targets || currentPlan.plan_payload?.nutrition_targets || {},
    training_split: currentPlan.training_split || currentPlan.plan_payload?.training_split || {},
    recovery_strategy: currentPlan.recovery_strategy || currentPlan.plan_payload?.recovery_strategy || {},
    weekly_overview: currentPlan.weekly_overview || currentPlan.plan_payload?.weekly_overview || { days: [] },
  };

  const dayEntries = weekDates.map((date) => {
    const label = DAY_SHORT[new Date(date + 'T12:00:00').getDay()];
    return `      {
        "date": "${date}",
        "day_label": "${label}",
        "day_type": "training | recovery | rest | mobility",
        "session_title": "string - user-facing card title, 3-7 words, specific and non-generic",
        "training_type": "string",
        "session_kind": "gym | sport | recovery | rest | mobility",
        "workout_needed": true | false,
        "session_duration_min": "number — 0 for rest days",
        "nutrition_focus": "string",
        "recovery_focus": "string",
        "priority": "string"
      }`;
  }).join(',\n');

  return `You are Execute's plan refinement engine. The user has an active personalized plan and wants to change it.

YOUR JOB:
Apply the user's change request to the existing plan and return a complete REVISED overview in the exact same JSON shape. Only change what's needed to satisfy the request. Preserve everything else (goals, dietary style, equipment, intensity philosophy, sport schedule, etc.) unless the request explicitly contradicts it.

RULES:
- Return ONLY valid JSON. No markdown, no commentary, no backticks.
- Keep the same overall structure and tone.
- If the change reduces training days, redistribute volume across remaining days sensibly.
- If the change increases training days, add days that respect recovery (never two hard sessions back-to-back unless the user already does that).
- If the change is nutrition-related (calories, macros, meals/day, dietary style), update nutrition_targets AND the daily nutrition_focus lines.
- If the change targets a specific day, only edit that day's entry and any directly affected days.
- Never violate the user's stated dietary style, allergies, or injury limitations from the current plan.
- All 7 days MUST appear with valid dates (use the WEEK DATES below).
- day_type must be one of: training, recovery, rest, mobility.
- workout_needed must be true iff day_type === "training".
- Every weekly day MUST include session_title. This is the visible app card title.
- session_title must be specific and useful at a glance. Never use vague titles like "sport practice", "team practice", "workout", "training", or only "Soccer - team practice".
- Keep training_type as the structured category/load label; use session_title for the more descriptive name.

CURRENT PLAN (the source of truth — preserve everything not explicitly changed):
${JSON.stringify(current, null, 2)}

USER CHANGE REQUEST:
"${changeRequest}"

WEEK DATES (today + next 6 days, use these EXACT dates in order):
${weekDates.join(', ')}

Return this exact JSON shape — nothing else:

{
  "plan_summary": {
    "primary_goal": "string",
    "positioning_summary": "string",
    "training_focus": "string",
    "nutrition_focus": "string",
    "recovery_focus": "string"
  },
  "long_term_plan": {
    "performance_direction": "string",
    "training_narrative": "string",
    "nutrition_narrative": "string",
    "recovery_narrative": "string",
    "first_milestone": "string",
    "coaching_commitment": "string"
  },
  "nutrition_targets": {
    "calories": number,
    "protein_g": number,
    "carbs_g": number,
    "fat_g": number,
    "hydration_liters": number
  },
  "training_split": {
    "days_per_week": number,
    "split_type": "string",
    "session_length_minutes": number,
    "intensity_guidance": "string"
  },
  "recovery_strategy": {
    "sleep_priority": "string",
    "mobility_focus": "string",
    "readiness_adjustment_rule": "string",
    "injury_guardrails": ["string"]
  },
  "weekly_overview": {
    "week_start_date": "${weekStart}",
    "days": [
${dayEntries}
    ]
  },
  "change_summary": "1-2 sentence plain-English summary of what you changed and why."
}
`;
}

/**
 * Apply a natural-language plan change request and replace the active master AIPlan.
 *
 * @param {object} args
 * @param {string} args.changeRequest - The user's natural-language change request.
 * @param {object} args.currentPlan   - The currently active master AIPlan record.
 * @returns {Promise<{ success: boolean, newPlan: object, changeSummary: string }>}
 */
export async function refinePlanFromChat({ changeRequest, currentPlan }) {
  if (!changeRequest || !changeRequest.trim()) {
    throw new Error('changeRequest is required');
  }
  if (!currentPlan?.id) {
    throw new Error('currentPlan is required');
  }

  const weekStart = todayISO();
  const weekEndDate = new Date(weekStart + 'T00:00:00');
  weekEndDate.setDate(weekEndDate.getDate() + 6);
  const weekEnd = toLocalISO(weekEndDate);

  const prompt = buildRefinePrompt(currentPlan, changeRequest, weekStart);

  const rawResponse = await backend.integrations.Core.InvokeLLM({
    prompt,
    response_json_schema: {
      type: 'object',
      required: ['plan_summary', 'nutrition_targets', 'training_split', 'recovery_strategy', 'weekly_overview'],
      properties: {
        plan_summary: { type: 'object' },
        long_term_plan: { type: 'object' },
        nutrition_targets: { type: 'object' },
        training_split: { type: 'object' },
        recovery_strategy: { type: 'object' },
        weekly_overview: { type: 'object' },
        change_summary: { type: 'string' },
      },
    },
  });

  const revised = parseMaybeJson(rawResponse) || rawResponse;
  if (!revised || typeof revised !== 'object') {
    throw new Error('LLM returned a non-parseable refinement response');
  }

  normalizeAndValidateOverview(revised);

  // Archive every active plan so caches don't surface stale ones
  bustPlanCache('daily');
  const existingActive = await backend.entities.AIPlan
    .filter(await userScopedFilter({ status: 'active' }))
    .catch(() => []);
  for (const old of existingActive) {
    await backend.entities.AIPlan.update(old.id, { status: 'archived' }).catch(() => {});

    // Also archive child WorkoutPlan rows tied to the now-archived master plan so
    // chooseBestWorkoutPlan can't fall back to them via source-name matching.
    const childWorkouts = await backend.entities.WorkoutPlan
      .filter({ source_plan_id: old.id })
      .catch(() => []);
    for (const wp of childWorkouts) {
      await backend.entities.WorkoutPlan.update(wp.id, { status: 'archived' }).catch(() => {});
    }
  }

  const now = new Date().toISOString();
  const generation_batch_id = generateBatchId();

  // Preserve the questionnaire context from the previous plan so future generation steps
  // (workouts, meals) still have full user context.
  const previousQuestionnaire =
    currentPlan.plan_payload?.questionnaire ||
    currentPlan.plan_payload?.answers ||
    null;

  const newPlan = await backend.entities.AIPlan.create(await withUserEmail({
    plan_type: 'daily',
    status: 'active',
    generation_status: 'overview_ready',
    source: 'plan_questionnaire_overview', // keep same source key so existing selectors find it
    created_from: 'refine_chat',
    supersedes_plan_id: currentPlan.id,
    version: (currentPlan.version || 1) + 1,
    date_range_start: weekStart,
    date_range_end: weekEnd,
    generation_batch_id,
    generated_at: now,

    summary: revised.long_term_plan?.training_narrative || revised.plan_summary?.positioning_summary || revised.plan_summary?.primary_goal || '',
    nutrition_guidance: revised.long_term_plan?.nutrition_narrative || revised.plan_summary?.nutrition_focus || '',
    recovery_advice: revised.long_term_plan?.recovery_narrative || revised.plan_summary?.recovery_focus || '',
    workout_suggestion: revised.plan_summary?.training_focus || '',
    focus_areas: [revised.training_split?.split_type].filter(Boolean),

    plan_summary: revised.plan_summary,
    nutrition_targets: revised.nutrition_targets,
    training_split: revised.training_split,
    recovery_strategy: revised.recovery_strategy,
    weekly_overview: revised.weekly_overview,

    plan_payload: {
      generation_status: 'overview_ready',
      source: 'plan_questionnaire_overview',
      created_from: 'refine_chat',
      change_summary: revised.change_summary || '',
      plan_summary: revised.plan_summary,
      long_term_plan: revised.long_term_plan || null,
      nutrition_targets: revised.nutrition_targets,
      training_split: revised.training_split,
      recovery_strategy: revised.recovery_strategy,
      weekly_overview: revised.weekly_overview,
      questionnaire: previousQuestionnaire,
      generated_at: now,
      generation_batch_id,
      supersedes_plan_id: currentPlan.id,
    },
  }));

  bustPlanCache('daily');
  await invalidateUserAIContext();

  return {
    success: true,
    newPlan,
    changeSummary: revised.change_summary || 'Plan updated.',
  };
}
