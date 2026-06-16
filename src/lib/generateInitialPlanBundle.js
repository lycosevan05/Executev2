/**
 * generateInitialPlanBundle.js
 *
 * Phase 3 — Lightweight Plan Overview Generation
 *
 * Replaces the slow all-in-one bundle with a fast, focused overview.
 * Creates ONE AIPlan with plan summary, nutrition targets, training split,
 * recovery strategy, and a 7-day weekly overview.
 *
 * Does NOT create WorkoutPlan, MealPlan, or DailyLog records.
 */

import { backend } from '@/api/backendClient';
import {
  savePlanQuestionnairePersonalization,
  invalidateUserAIContext,
  userScopedFilter,
  withUserEmail,
  bustPlanCache,
} from '@/lib/personalizationSync';
import { buildAnswerContext, calcTDEE } from '@/lib/generateInitialPlans';
import { getPlanDaySessionTitle, isGenericPlanDayTitle } from '@/lib/planDayDisplay';
import { structurePastedPlan } from '@/lib/plans/structurePastedPlan';
import { normalizeActivityLevel, resolveByoSession, resolveByoMealFocus } from '@/lib/plans/byoCadence';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function generateBatchId() {
  return `batch_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

// For a BYO ("Input your own plan") custom user the overview always covers BOTH a
// training split and nutrition targets — one side authoritative-from-structuring,
// the other AI-built (or fallen back to AI). So both "wants" are true for custom.
function wantsWorkoutPlan(a) {
  return a.planType === 'workout' || a.planType === 'daily_performance' || a.planType === 'custom';
}
function wantsNutritionPlan(a) {
  return a.planType === 'nutrition' || a.planType === 'daily_performance' || a.planType === 'custom';
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

// ─── JSON unwrapping helpers ──────────────────────────────────────────────────

const KNOWN_FIELDS = ['plan_summary', 'nutrition_targets', 'training_split', 'recovery_strategy', 'weekly_overview'];

function parseMaybeJson(value) {
  if (value && typeof value === 'object') return value;
  if (typeof value !== 'string') return null;
  // Strip markdown code fences
  const stripped = value.replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/, '').trim();
  try { return JSON.parse(stripped); } catch { return null; }
}

function hasOverviewFields(obj) {
  if (!obj || typeof obj !== 'object') return false;
  return KNOWN_FIELDS.some(k => obj[k] != null);
}

function unwrapOverviewResponse(raw) {
  const parsed = parseMaybeJson(raw);
  if (!parsed) throw new Error('LLM returned a non-parseable response');

  // Direct match
  if (hasOverviewFields(parsed)) return parsed;

  // Try common wrapper keys
  const wrappers = ['overview', 'plan', 'result', 'data', 'response', 'output', 'content', 'text', 'message'];
  for (const key of wrappers) {
    const inner = parseMaybeJson(parsed[key]);
    if (hasOverviewFields(inner)) return inner;
  }

  // Last resort: return parsed as-is and let validation surface the error
  return parsed;
}

// ─── Derive suggested days per week from questionnaire answers ────────────────

function deriveDaysPerWeek(answers) {
  // Explicit training days from questionnaire takes highest priority
  const trainingDaysMap = {
    '2_or_less': 2,
    '3_5': 4,
    '5_7': 6,
    'seven_plus': 7,
    // legacy single-day values
    '2': 2, '3': 3, '4': 4, '5': 5, '6': 6,
  };
  if (answers.trainingDays && trainingDaysMap[String(answers.trainingDays)] != null) {
    return trainingDaysMap[String(answers.trainingDays)];
  }
  const desiredMap = { light: 2, moderate: 3, high: 5, full: 6 };
  const currentMap = { monthly: 1, '2x_week': 2, '4x_week': 4, daily: 6 };
  if (answers.desiredActivity && desiredMap[answers.desiredActivity] != null) {
    return desiredMap[answers.desiredActivity];
  }
  if (answers.currentActivity && currentMap[answers.currentActivity] != null) {
    return currentMap[answers.currentActivity];
  }
  return 3;
}

// ─── Prompt ───────────────────────────────────────────────────────────────────

const DAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const DESIRED_OUTCOME_LABELS = {
  look_fitter: 'Look noticeably fitter',
  feel_stronger: 'Feel stronger and more athletic',
  energy_confidence: 'Better energy and confidence',
  rebuild_consistency: 'Rebuild consistency',
  sport_performance: 'Improve performance in a sport or activity',
  health_control: 'Feel in control of their health again',
};

const BARRIER_LABELS = {
  lose_motivation: 'Loses motivation after a few weeks',
  overwhelmed: 'Gets overwhelmed by complicated plans',
  food_consistency: 'Struggles with food consistency',
  changing_schedule: 'Schedule changes a lot',
  burnout: 'Pushes too hard and burns out',
  unsure_what_todo: 'Not sure what to do each day',
};

const COACHING_STYLE_LABELS = {
  direct: 'Direct and performance-focused',
  encouraging: 'Encouraging and supportive',
  simple: 'Simple and practical',
  data_driven: 'Data-driven and analytical',
  high_accountability: 'High-accountability',
  ruthless: 'Ruthless — direct, performance-focused, no sugar-coating',
};

const OPTIMIZE_PRIORITY_LABELS = {
  fastest: 'Fastest progress — push hard for results',
  consistent: 'Easiest consistency — habits the user can stick to',
  balanced: 'Balanced — progress without burning out',
  injury_safe: 'Injury-safe / low-stress — protect the body first',
};

function mapIdsToLabels(ids, labelMap) {
  const arr = Array.isArray(ids) ? ids : (ids ? String(ids).split(/[,;]\s*/) : []);
  return arr.map(id => labelMap[id] || id).filter(Boolean);
}

function buildOverviewPrompt(answers, macros, weekStart, suggestedDaysPerWeek, byoFallbackSides = []) {
  const wantsWorkout = wantsWorkoutPlan(answers);
  const wantsNutrition = wantsNutritionPlan(answers);
  const answerCtx = buildAnswerContext(answers);
  const weekDates = getWeekDates(weekStart);

  // Resolve session length preference.
  // If user picked "best" (Flexible / whatever is best), the AI chooses the optimal
  // duration per day with no anchor. Otherwise the user's choice is a soft target
  // that the AI can deviate from per day based on intensity, sport load & recovery.
  const sessionLengthMap = { '20': 20, '30': 30, '45': 45, '60': 60, '75': 75 };
  const userPickedFlexible = String(answers.sessionLength || '').toLowerCase() === 'best';
  const targetSessionMinutes = sessionLengthMap[String(answers.sessionLength)]
    || Number(answers.sessionDurationMin)
    || 50;

  // Build day entries dynamically so labels match actual dates
  const dayEntries = weekDates.map((date, i) => {
    const label = DAY_SHORT[new Date(date + 'T12:00:00').getDay()];
    if (!wantsWorkout) {
      // Nutrition-only: all days are non-training; focus on nutrition & recovery
      return `      {
        "date": "${date}",
        "day_label": "${label}",
        "day_type": "rest",
        "session_title": "string — user-facing card title, 3-7 words, specific to the day's nutrition/recovery purpose",
        "training_type": "Nutrition & Habit Focus",
        "workout_needed": false,
        "nutrition_focus": "string — 1 brief nutrition priority for this day",
        "recovery_focus": "string — 1 brief lifestyle or wellness note",
        "priority": "string — the single most important nutrition or habit action today"
      }`;
    }
    return `      {
        "date": "${date}",
        "day_label": "${label}",
        "day_type": "training | recovery | rest | mobility",
        "session_title": "string — user-facing card title, 3-7 words. Name the actual training stimulus or performance purpose. Never use generic labels like 'sport practice', 'training', or only 'Soccer - team practice'. For sport days combine sport + purpose, e.g. 'Soccer Practice Fuel + Recovery', 'Soccer Skill + Mobility Session', 'Soccer Match Day Readiness'. For gym days use the specific stimulus, e.g. 'Lower Power - Sprint Transfer'.",
        "training_type": "string — for gym training days: the session name (e.g. 'Upper Body Strength'). For sport days: the sport name (e.g. 'Basketball practice', 'Jiu-Jitsu class'). For rest/recovery/mobility days: describe the focus.",
        "session_kind": "gym | sport | recovery | rest | mobility — explicit category so daily exertion is clear",
        "workout_needed": true,
        "session_duration_min": ${userPickedFlexible
          ? `"number — YOU choose the optimal duration for THIS specific day based on session_kind, intensity, training stimulus, sport load, and recovery needs. There is NO user-specified target. Sensible ranges by kind: mobility/activation 15–25 min, recovery 20–30 min, short focused gym 30–40 min, standard hypertrophy/strength 45–65 min, heavy/long lift or high-volume 60–80 min, sport solo skill 30–60 min, team practice 60–90 min, game 60–120 min. Vary across the week. For rest days set 0."`
          : `"number — minutes for THIS specific day. The user's preferred average session length is ${targetSessionMinutes} min, but treat that as a soft target — you may deviate by up to ±15 min per day based on session_kind, intensity, sport load, and recovery. Sensible ranges: mobility/activation 15–25 min, recovery 20–30 min, lighter gym ${Math.max(20, targetSessionMinutes - 15)}–${targetSessionMinutes} min, standard gym ${targetSessionMinutes} min, heavy/long lift up to ${targetSessionMinutes + 15} min, sport solo skill 30–60 min, team practice 60–90 min, game 60–120 min. The weekly average for gym days should stay close to ${targetSessionMinutes} min. For rest days set 0."`},
        "nutrition_focus": "string — 1 brief nutrition priority for this day (fuel for sport day vs gym day vs recovery)",
        "recovery_focus": "string — 1 brief recovery note for this day",
        "priority": "string — the single most important thing to do today (gym, sport practice, or recovery — not both)"
      }`;
  }).join(',\n');

  const desiredOutcomeLabels = mapIdsToLabels(answers.desiredOutcomeFeeling, DESIRED_OUTCOME_LABELS);
  const desiredOutcomeLabel = desiredOutcomeLabels.join('; ');
  const barrierLabels = mapIdsToLabels(answers.mainBarrier, BARRIER_LABELS);
  const barrierLabel = barrierLabels.join('; ');
  const coachingStyleLabel = COACHING_STYLE_LABELS[answers.coachingStyle] || '';
  const optimizeLabel = OPTIMIZE_PRIORITY_LABELS[answers.optimize] || '';

  // ── BYO ("Input your own plan"): seed the overview from the STRUCTURED plan
  // (not raw paste). Only for sides the user actually supplied and that did NOT
  // fall back to AI. The model must reproduce these faithfully.
  let byoSeedBlock = '';
  if (answers.planType === 'custom') {
    const structured = answers.byoStructured?.structured || null;
    const fellBack = new Set(byoFallbackSides);
    const blocks = [];
    if (structured?.workout && !fellBack.has('workout')) {
      blocks.push(`USER-PROVIDED TRAINING PLAN (authoritative — lay out weekly_overview.days faithfully from this; do NOT invent a different split):
${JSON.stringify(structured.workout)}`);
    }
    if (structured?.nutrition && !fellBack.has('nutrition')) {
      const n = structured.nutrition;
      const macroNote = n.stated_calories
        ? `The user's plan states ${n.stated_calories} kcal/day — USE THESE EXACT targets in nutrition_targets instead of any computed default.`
        : '';
      blocks.push(`USER-PROVIDED NUTRITION PLAN (authoritative — reflect this structure/foods in nutrition_focus per day). ${macroNote}
${JSON.stringify(n)}`);
    }
    if (blocks.length > 0) {
      byoSeedBlock = `\n\nUSER-PROVIDED PLAN (REPRODUCE FAITHFULLY):\n${blocks.join('\n\n')}\n`;
    }
  }

  return `You are an elite personal performance strategist writing a personalized performance blueprint for a real person.
Generate a lightweight personalized performance overview based on the user's questionnaire answers.

IMPORTANT RULES:
- Return ONLY valid JSON. No markdown, no commentary, no backticks.
- Do NOT generate detailed workouts, exercise lists, sets, or reps.
- Do NOT generate detailed meal plans, ingredient lists, or recipes.
- Do NOT include DailyLog or checklist data.
- Do not diagnose injuries, treat medical conditions, or guarantee outcomes.
- For injury concerns, always recommend professional consultation.
- Adapt intensity and volume to the user's readiness level and stated limitations.
- Every weekly day MUST include a "session_title" that is suitable for the visible app card title. It must be specific, concrete, and useful at a glance.
- "training_type" is the structured category/load label. "session_title" is the human-facing name. Do not make them identical when training_type is generic.
- Never use vague visible titles like "sport practice", "team practice", "workout", "training", or only "Soccer - team practice". For external sport practices, name the performance purpose the app controls: fueling, recovery, mobility, readiness, or the specific adaptation around that practice.
- "priority" should be a short action or dominant focus for the day, not a generic title.
- STRICTLY respect the user's dietary style(s). If they follow vegan, keto, pescatarian, paleo, gluten-free, etc., all nutrition narratives, meal suggestions, and nutrition guidance MUST comply with those restrictions. Never suggest foods that violate the user's stated dietary style.
- SPORT-SPECIFIC EXERCISE SELECTION (CRITICAL): If the user listed a sport AND a performance focus (e.g. "soccer + top speed", "basketball + vertical jump", "jiu-jitsu + grip endurance"), the gym sessions MUST contain exercises that DIRECTLY transfer to that adaptation. Be specific in training_focus / training_narrative — name the actual training methods (e.g. for soccer top speed: max-velocity sprints, A-skips, wickets, hip flexor power, single-leg RDLs, Nordic curls, plyometric bounds; for basketball vertical: depth jumps, trap-bar jumps, French contrast, calf complexes). Do NOT give generic "leg day" advice when a sport focus is stated — name the specific quality being trained and how it transfers.
- SPORT SESSION INTEGRATION (CRITICAL): The user has provided an EXPLICIT WEEKLY SCHEDULE in the USER PROFILE section under "Primary sport WEEKLY SCHEDULE" (and optionally "Second sport WEEKLY SCHEDULE"). Each weekday lists the sport session type(s) booked on that day: solo technical/skill, team practice, and/or game/competition. You MUST place these sport sessions on the EXACT calendar weekdays they appear in the schedule — match them to the corresponding date in WEEK DATES (today + next 6 days) by weekday name. Mark those days as day_type "training" with training_type set to a clear, specific sport label (e.g. "Soccer - solo technical", "Soccer - team practice", "Soccer - match"). If a day has multiple sport types (e.g. solo + team), combine them in training_type (e.g. "Soccer - solo + team practice"). Differentiate the three session types because their energy cost is very different. Then write a separate session_title that is more descriptive than the sport label, e.g. "Soccer Practice Fuel + Recovery", "Soccer Skill + Mobility Session", or "Soccer Match Day Readiness".
- DAILY ENERGY EXPENDITURE & EXERTION BALANCE (CRITICAL): The user's TOTAL weekly load = gym sessions + solo technical sessions + team practices + games + second sport sessions. Treat each type as a different exertion cost when sequencing the week:
  • Solo technical / skill sessions = LOW-MODERATE cost. Can be paired with most things, but avoid stacking on heavy lower-body lift days for sports that load the same pattern.
  • Team practices = MODERATE-HIGH cost (conditioning + sport-specific intensity). Do NOT pair with a hard lower-body gym session on the same day. Place upper-body, mobility, or rest the day after.
  • Games / competitions = HIGHEST cost (peak intensity + nervous system stress). The day BEFORE a game must be light (mobility, activation, or rest). The day AFTER a game must be active recovery or rest — never a hard lift or hard practice.
  • Never stack two high-intensity sessions on the same calendar day unless the user trains that way.
  • If the user has 2 sports, alternate them so neither sport's primary movement pattern is overloaded.
  • If TOTAL weekly sessions (gym + all sport types + second sport) exceed 6 hard days, REDUCE gym sessions so combined load respects recovery — never exceed 6 hard sessions per week unless aggressiveness is "hard" AND current training is "5_plus".
  • If sport load is high (team practices + games ≥ 3/week), gym sessions should bias toward strength + power + injury-resilience work, NOT competing conditioning.
  • Each day's "priority" field MUST reflect the dominant load that day (game, practice, gym, or recovery) — not split focus.
  • Each day's "nutrition_focus" MUST reflect energy demand: higher carbs and pre-fuel on game/team-practice days, leaner intake on rest/mobility days, post-game recovery emphasis (protein + carbs + fluids) the day after games.
- The number of GYM training days MUST equal the user's stated target training days (${suggestedDaysPerWeek}) MINUS sport sessions already scheduled, but never below the minimum needed to support the sport. The TOTAL training days (gym + sport) may be higher.
- Session length: ${userPickedFlexible
  ? `The user chose "Flexible — whatever is best". You have FULL CONTROL of each day's duration. Pick the optimal length for each individual session based on training stimulus, sport load, recovery, and intensity. Sessions across the week SHOULD vary in length — do not give every day the same number. Narratives and intensity_guidance should reflect this adaptive approach rather than quoting a single fixed duration.`
  : `The user's preferred average session length is ${targetSessionMinutes} minutes. Treat it as a soft target: most gym sessions should land near ${targetSessionMinutes} min, but you may deviate per day by up to ±15 min when the session demands it (e.g. a heavy compound day runs longer, a deload or accessory day runs shorter). The weekly average for gym days should stay close to ${targetSessionMinutes} min. Narratives and intensity_guidance should reflect this target.`}
- The split_type MUST be feasible given the user's available equipment and training location. Never assume equipment that wasn't listed.
- If the user reported low current training frequency (never / 1–2 days) but selected an ambitious target, ramp progressively — do not start at peak volume.
- The optimization priority ("Fastest / Consistent / Balanced / Injury-safe") MUST shape intensity guidance, weekly volume, and the tone of narratives.
- The main barrier and preferred coaching style MUST shape coaching_commitment AND the tone of training_narrative + nutrition_narrative.
- Meals per day MUST match the user's stated preference. Reference it in nutrition_focus / nutrition_narrative.

LONG-TERM PLAN WRITING GUIDANCE (for long_term_plan fields only):
- Write like a high-level personal performance strategist — aspirational, vivid, and grounded.
- This section is what the user reads when they need to feel reminded of WHY they're doing this. Make it land emotionally.
- Tone: confident, motivating, specific, warm, never preachy or generic. Speak like a coach who knows them.
- Paint a picture of the version of themselves they're becoming. Reference what their life looks like 6-12 months from now if they stay consistent.
- Avoid generic phrases like: "strong foundation", "adequate recovery", "maximize your gains", "overall performance improvement", "high-protein diet", "prioritize sleep", "listen to your body", "stay consistent", "trust the process".
- Use language around: becoming, identity, momentum, sharpness, readiness, adaptation, capability, calm under load, sustainable intensity, the compounding effect of small wins.
- Speak directly to the user. Use "you" and "your" often.
- Vary sentence rhythm — mix one short punchy line with longer descriptive ones. Avoid monotone cadence.
- Make every sentence purposeful: insight, vision, or commitment. No filler transitions.
- LENGTH TARGETS (these are minimums to aim for, not caps — err on the side of richer prose):
    • performance_direction: 4-6 sentences. Open with a vivid statement of where they're headed, then anchor it to their specific situation.
    • training_narrative: 5-7 sentences. Reference their experience, schedule, equipment, intensity preference, and what each week of work will start unlocking.
    • nutrition_narrative: 5-7 sentences. Reference their food preferences, eating rhythm, calorie/macro targets, and how nutrition compounds with training.
    • recovery_narrative: 5-7 sentences. Reference their limitations if any. Frame recovery as the multiplier on every session. Use non-clinical language: readiness, adaptation, restoration — not treatment or therapy.
    • first_milestone: 3-4 sentences. Specific and achievable within 3-4 weeks. Frame it around how the user will feel, move, and perform — not just a number. End with what reaching it proves about them.
    • coaching_commitment: 3-5 sentences. Directly name their stated barrier and preferred coaching style. Make them feel seen. End with a line they could read on a hard day.

USER PROFILE:
${answerCtx}
${optimizeLabel ? `- Optimization priority: ${optimizeLabel}` : ''}
${desiredOutcomeLabel ? `- Desired outcome(s): ${desiredOutcomeLabel}` : ''}
${barrierLabel ? `- Main barrier(s) to consistency: ${barrierLabel}` : ''}
${coachingStyleLabel ? `- Preferred coaching style: ${coachingStyleLabel}` : ''}
${byoSeedBlock}
CALCULATED NUTRITION TARGETS:
- Calories: ${macros.calories} kcal/day
- Protein: ${macros.protein}g/day
- Carbs: ${macros.carbs}g/day
- Fats: ${macros.fats}g/day

WEEK DATES (today + next 6 days):
${weekDates.join(', ')}

Return this exact JSON shape — nothing else:

{
  "plan_summary": {
    "primary_goal": "string — the user's main focus in ONE sentence, hard cap 140 chars. Plain prose, no lists.",
    "positioning_summary": "string — 2-3 sentences on their overall approach",
    "training_focus": "string — ONE crisp sentence on training philosophy, hard cap 180 chars. No lists, no semicolons stringing clauses together.",
    "nutrition_focus": "string — ONE crisp sentence on nutrition approach, hard cap 180 chars.",
    "recovery_focus": "string — ONE crisp sentence on recovery priorities, hard cap 180 chars."
  },
  "long_term_plan": {
    "performance_direction": "string — 4-6 sentences. Paint a vivid picture of what they're building toward and why this plan fits them specifically. Make it feel personal, motivating, and earned.",
    "training_narrative": "string — 5-7 sentences on their training approach. Reference their experience, schedule, equipment, and intensity preference. Describe what each week of work starts unlocking. No generic phrases.",
    "nutrition_narrative": "string — 5-7 sentences on how nutrition compounds with training to serve their specific goal. Reference their food preferences, eating rhythm, and calorie/macro targets where relevant.",
    "recovery_narrative": "string — 5-7 sentences framing recovery as the multiplier on every session. Reference their limitations if any. Use non-clinical language: readiness, adaptation, restoration — not treatment or therapy.",
    "first_milestone": "string — 3-4 sentences. A specific, achievable milestone within 3-4 weeks. Frame it around how the user will feel, move, and perform — not just a number. End with what reaching it proves about them.",
    "coaching_commitment": "string — 3-5 sentences directly addressing their stated barrier and coaching style. Make them feel seen. End with a line they could read on a hard day."
  },
  "nutrition_targets": {
    "calories": ${macros.calories},
    "protein_g": ${macros.protein},
    "carbs_g": ${macros.carbs},
    "fat_g": ${macros.fats},
    "hydration_liters": 2.5
  },
  "training_split": {
    "days_per_week": ${wantsWorkout ? suggestedDaysPerWeek : 0},
    "split_type": "${wantsWorkout ? 'string — a SHORT label, max 20 chars. Prefer canonical names: \"Upper/Lower\", \"Push/Pull/Legs\", \"Full Body\", \"2-Day Split\", \"3-Day Split\", \"4-Day Split\", \"Bro Split\". If none fits, invent a short label (≤20 chars) like \"PPL + Sport\". NEVER write a sentence here — this is a tile label.' : 'nutrition_only'}",
    "session_length_minutes": ${wantsWorkout
      ? (userPickedFlexible
          ? `"number — the typical/average session length YOU recommend across the week, based on the user's profile, goals, and split. Pick what fits best (e.g. 30–75 min)."`
          : targetSessionMinutes)
      : 0},
    "intensity_guidance": "string — ONE sentence on overall intensity approach, hard cap 140 chars."
  },
  "recovery_strategy": {
    "sleep_priority": "string — specific sleep recommendation",
    "mobility_focus": "string — specific mobility or stretching recommendation",
    "readiness_adjustment_rule": "string — how to adapt on low readiness days",
    "injury_guardrails": ["string — safe movement guideline given their limitations"]
  },
  "weekly_overview": {
    "week_start_date": "${weekStart}",
    "days": [
${dayEntries}
    ]
  }
}

CRITICAL RULES FOR WEEKLY OVERVIEW:
${wantsWorkout ? `- Choose the best training split for this user based on their goals, schedule, equipment, experience, and limitations. Do not force a fixed split.
- Every day MUST include day_type. Use exactly one of: training, recovery, rest, mobility.
- Every day MUST include session_title. This is the app's visible card title.
- day_type is the source of truth for whether a day is a workout day or not.
- If day_type is "training", workout_needed MUST be true.
- If day_type is "recovery", "rest", or "mobility", workout_needed MUST be false.
- Never set day_type to "training" and workout_needed to false.
- Never set day_type to "rest" and workout_needed to true.
- training_type for training days: write the actual session name.
- training_type for rest/recovery/mobility days: describe the recovery or rest focus.
- session_title must be more specific than training_type whenever training_type is a sport label.
- The number of days with day_type "training" should match the user's desired training frequency.`
: `- This is a NUTRITION-ONLY plan. Do NOT create any training days.
- All 7 days MUST have day_type "rest". workout_needed MUST be false for every day.
- training_type for every day: use "Nutrition & Habit Focus".
- session_title for every day should name the day's habit or nutrition focus, not just "Nutrition".
- Focus weekly overview on nutrition priorities, hydration targets, meal timing, and daily habit actions.`}
`;
}

// ─── Validation ───────────────────────────────────────────────────────────────

const VALID_DAY_TYPES = ['training', 'recovery', 'rest', 'mobility'];
const REST_KEYWORDS = /\b(rest|recovery|off|active recovery|mobility|stretching)\b/i;

/**
 * Infer day_type from legacy fields (backward compatibility for old AIPlans).
 * Also used during normalization if AI omitted day_type.
 */
function inferDayType(day) {
  if (day.workout_needed === true) return 'training';
  if (day.workout_needed === false) {
    const t = (day.training_type || '').toLowerCase();
    if (/\bmobility\b|\bstretch/.test(t)) return 'mobility';
    if (/\brecovery\b|\bactive recovery\b/.test(t)) return 'recovery';
    // If workout_needed is false but label doesn't clearly say rest/recovery, still treat as rest
    // (safer: a hidden workout is worse than an accidentally shown rest)
    return 'rest';
  }
  return 'training'; // default to training to never hide a scheduled workout
}

function normalizeAndValidateOverview(overview, answers = {}) {
  const errors = [];
  const dateRegex = /^\d{4}-\d{2}-\d{2}$/;
  const wantsWorkout = wantsWorkoutPlan(answers);

  if (!overview?.plan_summary) errors.push('plan_summary is required');
  if (!overview?.nutrition_targets) errors.push('nutrition_targets is required');
  if (wantsWorkout && !overview?.training_split) errors.push('training_split is required');
  if (!overview?.recovery_strategy) errors.push('recovery_strategy is required');

  const days = overview?.weekly_overview?.days;
  if (!Array.isArray(days)) {
    errors.push('weekly_overview.days must be an array');
  } else {
    if (days.length !== 7) errors.push(`weekly_overview.days must have exactly 7 days, got ${days.length}`);

    days.forEach((d, i) => {
      if (!dateRegex.test(d.date)) errors.push(`Day ${i} has invalid date: ${d.date}`);
      if (!d.training_type) errors.push(`Day ${i} missing training_type`);
      if (!d.nutrition_focus) errors.push(`Day ${i} missing nutrition_focus`);
      if (!d.recovery_focus) errors.push(`Day ${i} missing recovery_focus`);
      if (!d.priority) errors.push(`Day ${i} missing priority`);
      if (!d.session_title || isGenericPlanDayTitle(d.session_title)) {
        d.session_title = getPlanDaySessionTitle(
          d,
          d.day_type === 'training' ? 'Performance Session' : 'Recovery Focus'
        );
      }

      // Normalize day_type — add it if missing, fix mismatches
      if (!d.day_type || !VALID_DAY_TYPES.includes(d.day_type)) {
        d.day_type = inferDayType(d);
      }

      // Enforce workout_needed alignment with day_type (day_type wins)
      if (d.day_type === 'training') {
        d.workout_needed = true;
      } else {
        d.workout_needed = false;
      }
    });

    // Align training_split.days_per_week to match actual training days (overview wins)
    if (overview.training_split) {
      const actualTrainingDays = days.filter(d => d.day_type === 'training').length;
      overview.training_split.days_per_week = actualTrainingDays;
    }
  }

  if (errors.length > 0) {
    throw new Error(`Overview validation failed:\n${errors.join('\n')}`);
  }
}

// ─── Main export ──────────────────────────────────────────────────────────────

/**
 * generateInitialPlanBundle(answers)
 *
 * Fast lightweight initial plan overview.
 * Creates one active AIPlan with high-level overview only.
 * Does NOT create WorkoutPlan, MealPlan, or DailyLog records.
 *
 * @param {object} answers - Raw answers from PlanQuestionnaire
 * @returns {{ success: boolean, aiPlan: object, plan: object, overview: object }}
 */
export async function generateInitialPlanBundle(answers) {
  const generation_batch_id = generateBatchId();
  console.log(`[generateInitialPlanBundle] Starting lightweight overview. Batch: ${generation_batch_id}`);

  // ── Step 1: Save questionnaire personalization ─────────────────────────────
  console.log('[generateInitialPlanBundle] Step 1: Saving questionnaire personalization…');
  await savePlanQuestionnairePersonalization(answers);

  // ── Step 2: Invalidate stale AI context ────────────────────────────────────
  await invalidateUserAIContext();

  // ── Step 2b: BYO ("Input your own plan") — ensure structured data + derive
  // activity for TDEE. Runs BEFORE calcTDEE so derived activity can raise the
  // multiplier for a high-volume paste-workout / AI-nutrition athlete.
  const byoFallbackSides = [];
  if (answers.planType === 'custom') {
    const targets = Array.isArray(answers.byoTargets) ? answers.byoTargets : [];
    const declaredFallback = answers.byoStructured?.fallback || null;
    if (declaredFallback === 'both') byoFallbackSides.push('workout', 'nutrition');
    else if (declaredFallback) byoFallbackSides.push(declaredFallback);

    let structured = answers.byoStructured?.structured || null;

    // Crash-resilience: structuring never ran (app killed between steps) but the
    // text survives. Re-run ONCE. A needs_clarification result here cannot be
    // answered (no UI past the questionnaire), so it degrades to graceful fallback
    // for the affected side(s). This path NEVER throws, hangs, or blocks.
    const hasText = (answers.byoWorkoutText || '').trim() || (answers.byoMealText || '').trim();
    if (!structured && !declaredFallback && targets.length > 0 && hasText) {
      try {
        const res = await structurePastedPlan({
          byoWorkoutText: answers.byoWorkoutText || '',
          byoMealText: answers.byoMealText || '',
          byoTargets: targets,
        });
        if (res && res.needs_clarification === false && res.structured) {
          structured = res.structured;
          answers.byoStructured = { resolved: true, structured };
        } else {
          for (const side of targets) {
            if (!byoFallbackSides.includes(side)) byoFallbackSides.push(side);
          }
        }
      } catch {
        for (const side of targets) {
          if (!byoFallbackSides.includes(side)) byoFallbackSides.push(side);
        }
      }
    }

    // Derive activity level from the structured workout → feeds calcTDEE. Validate
    // against the canonical enum; never assign a raw off-enum token.
    if (structured?.workout && !byoFallbackSides.includes('workout') && !answers.currentTraining) {
      const normalized = normalizeActivityLevel(
        structured.workout.derived_activity_level,
        structured.workout.weekly_sessions?.length,
      );
      if (normalized) answers.currentTraining = normalized;
    }
  }

  // ── Step 3: Calculate macros + week dates ─────────────────────────────────
  const macros = calcTDEE(answers);

  // BYO macro override: a stated-calorie nutrition paste wins over the computed
  // default (unless that side fell back to AI).
  if (answers.planType === 'custom' && !byoFallbackSides.includes('nutrition')) {
    const nut = answers.byoStructured?.structured?.nutrition;
    const statedCal = Number(nut?.stated_calories) || 0;
    if (statedCal > 0) {
      macros.calories = statedCal;
      if (Number(nut.stated_macros?.protein_g) > 0) macros.protein = Number(nut.stated_macros.protein_g);
      if (Number(nut.stated_macros?.carbs_g) > 0) macros.carbs = Number(nut.stated_macros.carbs_g);
      if (Number(nut.stated_macros?.fat_g) > 0) macros.fats = Number(nut.stated_macros.fat_g);
    }
  }
  // Always start from today so all 7 days are upcoming regardless of day of week
  const today = new Date();
  today.setHours(12, 0, 0, 0);
  const weekStart = toLocalISO(today);
  const weekEndDate = new Date(today);
  weekEndDate.setDate(today.getDate() + 6);
  const weekEnd = toLocalISO(weekEndDate);
  const suggestedDaysPerWeek = deriveDaysPerWeek(answers);
  console.log(`[generateInitialPlanBundle] Macros: ${macros.calories} kcal | Week: ${weekStart} → ${weekEnd} | Days/week: ${suggestedDaysPerWeek}`);

  // ── Step 4: Single lightweight LLM call ───────────────────────────────────
  console.log('[generateInitialPlanBundle] Step 4: Invoking LLM for overview…');
  const prompt = buildOverviewPrompt(answers, macros, weekStart, suggestedDaysPerWeek, byoFallbackSides);

  const rawOverview = await backend.integrations.Core.InvokeLLM({
    prompt,
    response_json_schema: {
      type: 'object',
      required: ['plan_summary', 'nutrition_targets', 'training_split', 'recovery_strategy', 'weekly_overview'],
      properties: {
        plan_summary: {
          type: 'object',
          required: ['primary_goal', 'positioning_summary'],
          properties: {
            primary_goal: { type: 'string' },
            positioning_summary: { type: 'string' },
            training_focus: { type: 'string' },
            nutrition_focus: { type: 'string' },
            recovery_focus: { type: 'string' },
          },
        },
        long_term_plan: { type: 'object' },
        nutrition_targets: {
          type: 'object',
          required: ['calories', 'protein_g', 'carbs_g', 'fat_g'],
          properties: {
            calories: { type: 'number' },
            protein_g: { type: 'number' },
            carbs_g: { type: 'number' },
            fat_g: { type: 'number' },
            hydration_liters: { type: 'number' },
          },
        },
        training_split: {
          type: 'object',
          required: ['days_per_week', 'split_type'],
          properties: {
            days_per_week: { type: 'number' },
            split_type: { type: 'string' },
            session_length_minutes: { type: 'number' },
            intensity_guidance: { type: 'string' },
          },
        },
        recovery_strategy: { type: 'object' },
        weekly_overview: {
          type: 'object',
          required: ['week_start_date', 'days'],
          properties: {
            week_start_date: { type: 'string' },
            days: {
              type: 'array',
              items: {
                type: 'object',
                required: ['date', 'day_type', 'session_title', 'training_type', 'workout_needed', 'priority'],
                properties: {
                  date: { type: 'string' },
                  day_label: { type: 'string' },
                  day_type: { type: 'string' },
                  session_title: { type: 'string' },
                  training_type: { type: 'string' },
                  session_kind: { type: 'string' },
                  workout_needed: { type: 'boolean' },
                  session_duration_min: { type: 'number' },
                  nutrition_focus: { type: 'string' },
                  recovery_focus: { type: 'string' },
                  priority: { type: 'string' },
                },
              },
            },
          },
        },
      },
    },
  });

  console.log('[generateInitialPlanBundle] ✓ LLM response received');
  const overview = unwrapOverviewResponse(rawOverview);

  // ── Step 5: Validate + normalize day_type / workout_needed ────────────────
  normalizeAndValidateOverview(overview, answers);
  console.log('[generateInitialPlanBundle] ✓ Validation passed');

  // ── Step 5b: BYO — map structured plan onto each overview day (cheap per-day
  // reads downstream; no raw-text re-injection). Only for supplied, non-fallback
  // sides.
  const byoStructured = answers.planType === 'custom' ? (answers.byoStructured?.structured || null) : null;
  const byoCadence = byoStructured?.workout?.cadence || null;
  if (byoStructured) {
    const days = overview?.weekly_overview?.days || [];
    const includeWorkout = !byoFallbackSides.includes('workout');
    const includeNutrition = !byoFallbackSides.includes('nutrition');
    for (const day of days) {
      if (includeWorkout && byoStructured.workout) {
        const session = resolveByoSession(byoStructured, byoCadence, weekStart, day.date);
        if (session) day.byo_session = session;
      }
      if (includeNutrition && byoStructured.nutrition) {
        const focus = resolveByoMealFocus(byoStructured, weekStart, day.date);
        if (focus) day.byo_meal_focus = focus;
      }
    }
  }

  // ── Step 6: Archive existing active plans ─────────────────────────────────
  bustPlanCache('daily');
  const existingActive = await backend.entities.AIPlan.filter(await userScopedFilter({ status: 'active' })).catch(() => []);
  for (const old of existingActive) {
    await backend.entities.AIPlan.update(old.id, { status: 'archived' }).catch(() => {});
  }

  // ── Step 7: Create master AIPlan ──────────────────────────────────────────
  console.log('[generateInitialPlanBundle] Step 7: Creating AIPlan…');
  const now = new Date().toISOString();

  const aiPlan = await backend.entities.AIPlan.create(await withUserEmail({
    plan_type: 'daily',
    status: 'active',
    generation_status: 'overview_ready',
    source: 'plan_questionnaire_overview',
    created_from: 'plan_questionnaire',
    date_range_start: weekStart,
    date_range_end: weekEnd,
    generation_batch_id,
    generated_at: now,

    // High-level summaries — prefer long_term_plan narratives for richer text
    summary: overview.long_term_plan?.training_narrative || overview.plan_summary?.positioning_summary || overview.plan_summary?.primary_goal || '',
    nutrition_guidance: overview.long_term_plan?.nutrition_narrative || overview.plan_summary?.nutrition_focus || '',
    recovery_advice: overview.long_term_plan?.recovery_narrative || overview.plan_summary?.recovery_focus || '',
    workout_suggestion: overview.plan_summary?.training_focus || '',
    focus_areas: [overview.training_split?.split_type].filter(Boolean),

    // Top-level structured overview fields
    plan_summary: overview.plan_summary,
    nutrition_targets: overview.nutrition_targets,
    training_split: overview.training_split,
    recovery_strategy: overview.recovery_strategy,
    weekly_overview: overview.weekly_overview,

    // Full overview also stored in plan_payload for downstream consumers
    plan_payload: {
      generation_status: 'overview_ready',
      source: 'plan_questionnaire_overview',
      plan_summary: overview.plan_summary,
      long_term_plan: overview.long_term_plan || null,
      nutrition_targets: overview.nutrition_targets,
      training_split: overview.training_split,
      recovery_strategy: overview.recovery_strategy,
      weekly_overview: overview.weekly_overview,
      questionnaire: answers,
      generated_at: now,
      generation_batch_id,

      // BYO ("Input your own plan") — structured once, read cheaply per day. Raw
      // text kept ONLY for the per-day fallback when a structured day is missing.
      ...(answers.planType === 'custom' ? {
        byo_targets: Array.isArray(answers.byoTargets) ? answers.byoTargets : [],
        byo_workout_text: (byoStructured?.workout && !byoFallbackSides.includes('workout')) ? (answers.byoWorkoutText || '') : '',
        byo_meal_text: (byoStructured?.nutrition && !byoFallbackSides.includes('nutrition')) ? (answers.byoMealText || '') : '',
        byo_structured: byoStructured,
        byo_cadence: byoCadence,
        byo_fallback_sides: byoFallbackSides,
      } : {}),
    },
  }));

  console.log(`[generateInitialPlanBundle] ✓ AIPlan created: ${aiPlan.id}`);
  bustPlanCache('daily');
  await invalidateUserAIContext();

  console.log('[generateInitialPlanBundle] ✓ Overview ready. Workouts will be built on demand to avoid request spikes.');

  return {
    success: true,
    aiPlan,
    // alias for backward compat
    plan: aiPlan,
    masterPlan: aiPlan,
    overview,
    generation_batch_id,
  };
}
