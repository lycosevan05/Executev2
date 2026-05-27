/**
 * getOrCreateWorkoutPlanForDate.js
 *
 * On-demand single-date workout plan loader/generator.
 * Never generates workouts automatically — only when options.generate === true.
 * Never creates MealPlan or DailyLog records.
 */

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, userScopedFilter, withUserEmail } from '@/lib/personalizationSync';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const NON_TRAINING_DAY_TYPES = ['rest', 'recovery', 'mobility'];

/**
 * Determine if an overview day is a rest/recovery day.
 * Uses day_type as primary source of truth.
 * Falls back to backward-compatible logic for old plans without day_type.
 */
function isNonTrainingDay(overviewDay) {
  if (!overviewDay) return false;

  // Primary: use explicit day_type if present
  if (overviewDay.day_type) {
    return NON_TRAINING_DAY_TYPES.includes(overviewDay.day_type);
  }

  // Backward compat for old AIPlans without day_type:
  if (overviewDay.workout_needed === false) {
    const t = (overviewDay.training_type || '').toLowerCase();
    // Only treat as rest if the label clearly says so
    if (/\brest\b|\brecovery\b|\boff\b|\bmobility\b|\bstretch/.test(t)) return true;
    // workout_needed false but label doesn't clearly say rest → treat as training (never hide a workout)
    return false;
  }

  return false; // workout_needed true → training day
}

function newestFirst(a, b) {
  const aDate = a?.updated_date || a?.created_date || '';
  const bDate = b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function hasExercises(plan) {
  return Array.isArray(plan?.exercises) && plan.exercises.length > 0;
}

function chooseBestWorkoutPlan(plans = [], masterPlan = null) {
  const safe = Array.isArray(plans)
    ? plans.filter(p => p && p.status !== 'archived').sort(newestFirst)
    : [];
  if (!safe.length) return null;

  // Prioritize plans WITH exercises over those without
  const withEx = safe.filter(hasExercises);
  const pool = withEx.length > 0 ? withEx : safe;

  if (masterPlan) {
    // 1. Exact batch + source match (with exercises)
    const exact = pool.find(p =>
      p.source_plan_id === masterPlan.id &&
      p.generation_batch_id &&
      p.generation_batch_id === masterPlan.generation_batch_id
    );
    if (exact) return exact;

    // 2. Source plan ID match only (batch may differ or be empty)
    const sourceMatch = pool.find(p => p.source_plan_id === masterPlan.id);
    if (sourceMatch) return sourceMatch;
  }

  // Beyond this point we fall back to matching by source name. We must NOT return
  // workout rows that point at a *different* master plan (e.g. an old archived one
  // from before a refine) — otherwise refined plans get shadowed by stale workouts.
  const belongsToActiveOrLegacy = (p) =>
    !p.source_plan_id || (masterPlan && p.source_plan_id === masterPlan.id);

  // 3. plan_questionnaire_overview (with exercises preferred)
  const overviewMatch = pool.find(p => p.source === 'plan_questionnaire_overview' && belongsToActiveOrLegacy(p));
  if (overviewMatch) return overviewMatch;

  // 4. plan_questionnaire_initial (with exercises preferred)
  const initialMatch = pool.find(p => p.source === 'plan_questionnaire_initial' && belongsToActiveOrLegacy(p));
  if (initialMatch) return initialMatch;

  // 5. Newest with exercises (still filtered)
  const newestWithEx = withEx.find(belongsToActiveOrLegacy);
  if (newestWithEx) return newestWithEx;

  // 6. Newest overall that belongs to this plan (or has no plan link)
  return safe.find(belongsToActiveOrLegacy) || null;
}

// ─── Validation ───────────────────────────────────────────────────────────────

function validateWorkout(w) {
  const errors = [];
  if (!w?.name) errors.push('name missing');
  if (!w?.type) errors.push('type missing');
  if (!w?.duration) errors.push('duration missing');
  if (!w?.warmup) errors.push('warmup missing');
  if (!w?.cooldown) errors.push('cooldown missing');
  if (!Array.isArray(w?.exercises)) errors.push('exercises must be an array');
  else {
    if (w.exercises.length < 4 || w.exercises.length > 8) {
      errors.push(`exercises must be 4–8, got ${w.exercises.length}`);
    }
    w.exercises.forEach((ex, i) => {
      if (!ex.name) errors.push(`exercise ${i} missing name`);
      if (!ex.sets) errors.push(`exercise ${i} missing sets`);
      if (!ex.reps) errors.push(`exercise ${i} missing reps`);
      if (!ex.rest) errors.push(`exercise ${i} missing rest`);
      if (!ex.notes) errors.push(`exercise ${i} missing notes`);
    });
  }
  if (errors.length > 0) throw new Error(`Workout validation failed: ${errors.join(', ')}`);
}

// ─── Main export ──────────────────────────────────────────────────────────────

/**
 * @param {string} date - YYYY-MM-DD
 * @param {{ planId?: string, generate?: boolean, masterPlan?: object }} options
 * @returns {Promise<{ status: string, workoutPlan: object|null, masterPlan: object|null, overviewDay: object|null }>}
 */
export async function getOrCreateWorkoutPlanForDate(date, options = {}) {
  const { planId, generate = false } = options;

  // A. If planId provided, try to load directly — if found with exercises, return immediately
  if (planId) {
    const plans = await backend.entities.WorkoutPlan.filter({ id: planId }).catch(() => []);
    const found = plans.find(hasExercises) || null;
    if (found) {
      return { status: 'ready', workoutPlan: found, masterPlan: null, overviewDay: null };
    }
    // planId not found or incomplete — fall through to date-based lookup (do NOT let rest-day override)
  }

  // B. Load active master AIPlan (use provided masterPlan to skip the API call)
  const masterPlan = options.masterPlan || await loadActiveAIPlan('daily').catch(() => null);

  // D. No master plan
  if (!masterPlan) {
    return { status: 'no_plan', workoutPlan: null, masterPlan: null, overviewDay: null };
  }

  // C. Extract weekly overview and find matching day
  const overview =
    masterPlan.weekly_overview ||
    masterPlan.plan_payload?.weekly_overview ||
    null;

  const overviewDay = overview?.days?.find(d => d.date === date) || null;

  // E. Check for existing WorkoutPlan BEFORE checking overview.
  // Single query for all plans on this date (widest net). chooseBestWorkoutPlan()
  // below picks the best match by source_plan_id + generation_batch_id, so the
  // extra batch/source filters are redundant — and 3 parallel queries per day
  // was the main contributor to 429 rate-limit errors.
  const existingPlans = await backend.entities.WorkoutPlan
    .filter(await userScopedFilter({ date }))
    .catch(() => []);

  const existing = chooseBestWorkoutPlan(existingPlans, masterPlan);
  if (existing && hasExercises(existing)) {
    return { status: 'ready', workoutPlan: existing, masterPlan, overviewDay };
  }

  if (existing && generate) {
    await backend.entities.WorkoutPlan.delete(existing.id).catch(() => {});
  }

  // F. If no overview day found but master plan exists — still allow generation
  if (!overviewDay) {
    if (!generate) {
      return { status: 'needs_generation', workoutPlan: null, masterPlan, overviewDay: null };
    }
    // Fall through to generation with a generic training day context
  } else {
    // G. Check if it's a rest/recovery/mobility day using day_type (primary) or backward compat
    if (isNonTrainingDay(overviewDay)) {
      return { status: 'rest_day', workoutPlan: null, masterPlan, overviewDay };
    }

    // H. Needs generation but generate not requested
    if (!generate) {
      return { status: 'needs_generation', workoutPlan: null, masterPlan, overviewDay };
    }
  }

  // I. Generate workout via AI
  const [
    userProfiles,
    workoutProfiles,
    injuries,
    readinessToday,
    readinessLatest,
  ] = await Promise.allSettled([
    backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.WorkoutProfile.filter(await userScopedFilter(), '-updated_date', 1),
    backend.entities.InjuryProfile.filter(await userScopedFilter({ is_active: true })),
    backend.entities.ReadinessCheckIn.filter(await userScopedFilter({ date })),
    backend.entities.ReadinessCheckIn.filter(await userScopedFilter(), '-date', 1),
  ]);

  const userProfile = userProfiles.status === 'fulfilled' ? userProfiles.value?.[0] : null;
  const workoutProfile = workoutProfiles.status === 'fulfilled' ? workoutProfiles.value?.[0] : null;
  const activeInjuries = injuries.status === 'fulfilled' ? injuries.value : [];
  const readinessRecord =
    (readinessToday.status === 'fulfilled' && readinessToday.value?.[0]) ||
    (readinessLatest.status === 'fulfilled' && readinessLatest.value?.[0]) ||
    null;

  const planSummary = masterPlan.plan_summary || masterPlan.plan_payload?.plan_summary || {};
  const trainingSplit = masterPlan.training_split || masterPlan.plan_payload?.training_split || {};
  const recoveryStrategy = masterPlan.recovery_strategy || masterPlan.plan_payload?.recovery_strategy || {};

  const equipmentList = workoutProfile?.equipment_available?.join(', ') || 'not specified';
  const sessionLength = trainingSplit.session_length_minutes || 50;

  const injuryText = activeInjuries.length > 0
    ? activeInjuries.map(inj => `${inj.body_area}: ${inj.severity}${inj.description ? ' — ' + inj.description : ''}`).join('; ')
    : 'None reported';

  const readinessText = readinessRecord
    ? `Score: ${readinessRecord.readiness_score ?? 'N/A'}, Energy: ${readinessRecord.energy ?? 'N/A'}/10, Sleep quality: ${readinessRecord.sleep_quality ?? 'N/A'}/10, Soreness: ${readinessRecord.soreness ?? 'N/A'}/10, Stress: ${readinessRecord.stress ?? 'N/A'}/10`
    : 'No readiness data';
  const sessionTitle = getPlanDaySessionTitle(overviewDay, overviewDay?.training_type || 'General Training');

  const prompt = `You are an elite personal fitness coach generating a single workout session for one specific date.

CRITICAL RULES:
- Generate ONLY ONE workout for ${date}.
- Do NOT generate a weekly plan, meal plan, or DailyLog data.
- Return ONLY valid JSON. No markdown, no commentary, no backticks.
- Use safe, practical fitness language.
- Do NOT diagnose or treat injuries.
- If injuries or pain risks are present, use conservative substitutions and note professional consultation where appropriate.
- Respect injury guardrails strictly.

DATE: ${date}
VISIBLE SESSION TITLE FOR TODAY: ${sessionTitle}
TRAINING TYPE FOR TODAY: ${overviewDay?.training_type || 'General Training'}
TODAY'S PRIORITY: ${overviewDay?.priority || ''}
RECOVERY FOCUS: ${overviewDay?.recovery_focus || ''}

PLAN SUMMARY:
${JSON.stringify(planSummary, null, 2)}

TRAINING SPLIT:
${JSON.stringify(trainingSplit, null, 2)}

RECOVERY STRATEGY:
${JSON.stringify(recoveryStrategy, null, 2)}

USER PROFILE:
Age: ${userProfile?.age ?? 'N/A'}, Weight: ${userProfile?.weight_kg ?? 'N/A'} kg, Height: ${userProfile?.height_cm ?? 'N/A'} cm, Fitness level: ${userProfile?.fitness_level ?? 'N/A'}

WORKOUT PROFILE:
Goal: ${workoutProfile?.primary_goal ?? 'N/A'}, Experience: ${workoutProfile?.experience_level ?? 'N/A'}, Days/week: ${workoutProfile?.days_per_week ?? 'N/A'}, Preferred split: ${workoutProfile?.preferred_split ?? 'N/A'}

EQUIPMENT AVAILABLE: ${equipmentList}
SESSION LENGTH: ${sessionLength} minutes

INJURIES / LIMITATIONS: ${injuryText}

READINESS TODAY: ${readinessText}

Return this exact JSON shape only:

{
  "name": "string — specific workout name. It should be at least as descriptive as the visible session title and must not be generic like 'sport practice' or 'training'",
  "type": "string — e.g. Upper Body Strength, Lower Body Power, Full Body",
  "duration": "string — e.g. 45–55 min",
  "intensity": "low | moderate | high",
  "focus": "string — primary muscle groups or training focus",
  "workout_summary": "string — 1-2 sentence overview",
  "warmup": "string — specific warm-up description",
  "cooldown": "string — specific cool-down description",
  "exercises": [
    {
      "name": "string",
      "sets": number,
      "reps": "string — e.g. 8-10 or 12",
      "rest": "string — e.g. 90 sec",
      "muscles": "string",
      "notes": "string — coaching cue or modification tip"
    }
  ],
  "modifications": ["string — any exercise modifications for injuries or limitations"],
  "safety_notes": ["string — safety guidance, injury reminders"],
  "notes": "string — any extra coaching notes"
}

Include 4 to 8 exercises. Every exercise must have name, sets, reps, rest, and notes.`;

  const aiResponse = await backend.integrations.Core.InvokeLLM({
    prompt,
    response_json_schema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        type: { type: 'string' },
        duration: { type: 'string' },
        intensity: { type: 'string' },
        focus: { type: 'string' },
        workout_summary: { type: 'string' },
        warmup: { type: 'string' },
        cooldown: { type: 'string' },
        exercises: { type: 'array', items: { type: 'object' } },
        modifications: { type: 'array', items: { type: 'string' } },
        safety_notes: { type: 'array', items: { type: 'string' } },
        notes: { type: 'string' },
      },
      required: ['name', 'type', 'duration', 'warmup', 'cooldown', 'exercises'],
    },
  });

  validateWorkout(aiResponse);

  // Save WorkoutPlan
  const createdPlan = await backend.entities.WorkoutPlan.create(await withUserEmail({
    date,
    name: aiResponse.name,
    type: aiResponse.type,
    duration: aiResponse.duration,
    intensity: aiResponse.intensity || 'moderate',
    focus: aiResponse.focus || '',
    workout_summary: aiResponse.workout_summary || '',
    warmup: aiResponse.warmup,
    cooldown: aiResponse.cooldown,
    exercises: aiResponse.exercises,
    notes: aiResponse.notes || '',
    generated_by_ai: true,
    source: 'plan_questionnaire_overview',
    source_plan_id: masterPlan.id,
    generation_batch_id: masterPlan.generation_batch_id || '',
    status: 'planned',
    split_name: trainingSplit.split_type || '',
    readiness_score: readinessRecord?.readiness_score || null,
    modifications: aiResponse.modifications || [],
    safety_notes: aiResponse.safety_notes || [],
    generation_status: 'ready',
  }));

  // Optionally update existing DailyLog with planned_workout_id (do not create one)
  try {
    const dailyLogs = await backend.entities.DailyLog.filter(await userScopedFilter({ date })).catch(() => []);
    if (dailyLogs.length > 0) {
      await backend.entities.DailyLog.update(dailyLogs[0].id, { planned_workout_id: createdPlan.id }).catch(() => {});
    }
  } catch {
    // Non-critical — silently skip
  }

  return { status: 'ready', workoutPlan: createdPlan, masterPlan, overviewDay };
}
