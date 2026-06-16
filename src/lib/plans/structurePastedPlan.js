/**
 * structurePastedPlan — one dedicated LLM pre-call that turns a user's pasted /
 * uploaded training and/or nutrition plan into a normalized structure.
 *
 * Why a separate pre-call (not folded into generateInitialPlanBundle)?
 *   1. The derived training cadence feeds `calcTDEE` (which runs synchronously
 *      BEFORE the overview LLM call), so activity level must already exist.
 *   2. Sparse / garbled input needs an interactive clarification loop, which only
 *      the questionnaire UI can drive.
 *
 * Premium-safe: only ever invoked from inside the premium-gated questionnaire, or
 * once from generateInitialPlanBundle's crash-resilience path (itself reached only
 * via the gated submit).
 *
 * Returns the parsed contract (see RESPONSE_SCHEMA). Either:
 *   - { needs_clarification: true, clarification: { questions: [...] } }, or
 *   - { needs_clarification: false, structured: { workout?, nutrition? } }
 */

import { backend } from '@/api/backendClient';

function parseMaybeJson(value) {
  if (value && typeof value === 'object') return value;
  if (typeof value !== 'string') return null;
  const stripped = value.replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/, '').trim();
  try { return JSON.parse(stripped); } catch { return null; }
}

function unwrap(raw) {
  const parsed = parseMaybeJson(raw);
  if (!parsed) throw new Error('structurePastedPlan: non-parseable LLM response');
  if (typeof parsed.needs_clarification === 'boolean') return parsed;
  const wrappers = ['result', 'data', 'response', 'output', 'content', 'structured_plan'];
  for (const key of wrappers) {
    const inner = parseMaybeJson(parsed[key]);
    if (inner && typeof inner.needs_clarification === 'boolean') return inner;
  }
  return parsed;
}

const RESPONSE_SCHEMA = {
  type: 'object',
  required: ['needs_clarification'],
  properties: {
    needs_clarification: { type: 'boolean' },
    clarification: {
      type: 'object',
      properties: {
        questions: {
          type: 'array',
          items: {
            type: 'object',
            required: ['id', 'side', 'label', 'options'],
            properties: {
              id: { type: 'string' },
              side: { type: 'string' }, // 'workout' | 'nutrition'
              label: { type: 'string' },
              options: {
                type: 'array',
                items: {
                  type: 'object',
                  required: ['id', 'label'],
                  properties: { id: { type: 'string' }, label: { type: 'string' } },
                },
              },
            },
          },
        },
      },
    },
    structured: {
      type: 'object',
      properties: {
        workout: {
          type: 'object',
          properties: {
            training_split: {
              type: 'object',
              properties: {
                days_per_week: { type: 'number' },
                split_type: { type: 'string' },
              },
            },
            derived_activity_level: { type: 'string' }, // never|1_2_days|3_4_days|5_plus
            cadence: {
              type: 'object',
              properties: {
                type: { type: 'string' },    // weekly|rotating|ab
                advance: { type: 'string' }, // daily|training_days_only
                rest_weekdays: { type: 'array', items: { type: 'number' } },
                cycle: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      label: { type: 'string' },
                      is_rest: { type: 'boolean' },
                      exercises: { type: 'array' },
                    },
                  },
                },
              },
            },
            weekly_sessions: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  weekday: { type: ['number', 'null'] },
                  title: { type: 'string' },
                  exercises: { type: 'array' },
                },
              },
            },
          },
        },
        nutrition: {
          type: 'object',
          properties: {
            stated_calories: { type: ['number', 'null'] },
            stated_macros: {
              type: 'object',
              properties: {
                protein_g: { type: ['number', 'null'] },
                carbs_g: { type: ['number', 'null'] },
                fat_g: { type: ['number', 'null'] },
              },
            },
            meals_per_day: { type: ['number', 'null'] },
            daily_focus: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  weekday: { type: ['number', 'null'] },
                  focus: { type: 'string' },
                  example_meals: { type: 'array' },
                },
              },
            },
          },
        },
      },
    },
  },
};

function buildPrompt({ byoWorkoutText, byoMealText, byoTargets, clarificationAnswers }) {
  const wantsWorkout = byoTargets.includes('workout');
  const wantsNutrition = byoTargets.includes('nutrition');

  const sections = [];
  if (wantsWorkout) {
    sections.push(
      `### USER-PROVIDED TRAINING PLAN (verbatim)\n<<<\n${(byoWorkoutText || '').slice(0, 12000)}\n>>>`,
    );
  }
  if (wantsNutrition) {
    sections.push(
      `### USER-PROVIDED NUTRITION PLAN (verbatim)\n<<<\n${(byoMealText || '').slice(0, 12000)}\n>>>`,
    );
  }

  let clarificationBlock = '';
  if (Array.isArray(clarificationAnswers) && clarificationAnswers.length > 0) {
    const lines = clarificationAnswers
      .map(c => `- (${c.side}) ${c.label}: ${c.answerLabel}`)
      .join('\n');
    clarificationBlock = `\n\n### CLARIFICATIONS THE USER ALREADY ANSWERED\nIncorporate these as ground truth. Do NOT re-ask them.\n${lines}`;
  }

  return `You are structuring a fitness/nutrition plan a user already follows, so we can
reproduce it faithfully and build any missing side around it.

Sides we are structuring: ${byoTargets.join(' + ') || '(none)'}.

${sections.join('\n\n')}${clarificationBlock}

TASK
For each requested side, normalize the plan into the \`structured\` object.

For TRAINING:
- Determine the split and how many distinct training days per week.
- Set \`derived_activity_level\` to EXACTLY one of: "never", "1_2_days", "3_4_days", "5_plus"
  (based on weekly training frequency). This drives the user's calorie target.
- Normalize cadence. \`cadence.type\` = "weekly" (fixed weekday→session),
  "rotating" (Day 1..N cycle, e.g. PPL), or "ab".
  - \`cadence.advance\` = "training_days_only" when the plan rests on fixed weekdays
    (e.g. trains weekdays, rests weekends) — the rotation only advances on training
    days. Use "daily" when the cycle advances every calendar day.
  - \`cadence.rest_weekdays\` = calendar weekdays that are ALWAYS rest (0=Sun..6=Sat).
  - \`cadence.cycle\` = ordered list of the rotation's days with exercises.
  - If you cannot confidently determine cadence, default to advance:"daily",
    rest_weekdays:[].
- \`weekly_sessions\` = the concrete sessions (weekday null if rotation-based).

For NUTRITION:
- \`stated_calories\` / \`stated_macros\`: ONLY if the plan explicitly states them, else null.
- \`meals_per_day\`, and \`daily_focus\` describing each day's emphasis + example meals.

CLARIFICATION RULE (critical)
If a requested side's text is too sparse, vague, or garbled to faithfully reproduce
(e.g. "idk", a title with no exercises, an unreadable scan), set
\`needs_clarification\`: true and return targeted MULTIPLE-CHOICE \`questions\` for that
side. If a side is effectively empty, the questions should reconstruct that side's
normal intake (training days/week, session length, location/equipment, intensity; or
meals/day, diet style) so we can still build a sensible default. Each question must
have a stable \`id\`, a \`side\` ("workout" or "nutrition"), a \`label\`, and 2-5 \`options\`
each with \`id\` + \`label\`. Only ask what you truly cannot infer.

When you have enough to reproduce every requested side faithfully, set
\`needs_clarification\`: false and return \`structured\`. Output ONLY the JSON object.`;
}

/**
 * @param {object} args
 * @param {string} [args.byoWorkoutText]
 * @param {string} [args.byoMealText]
 * @param {string[]} args.byoTargets  e.g. ['workout'] | ['nutrition'] | ['workout','nutrition']
 * @param {Array<{id,side,label,answerId,answerLabel}>} [args.clarificationAnswers]
 * @returns {Promise<object>} the unwrapped contract
 */
export async function structurePastedPlan({
  byoWorkoutText = '',
  byoMealText = '',
  byoTargets = [],
  clarificationAnswers = [],
} = {}) {
  const prompt = buildPrompt({ byoWorkoutText, byoMealText, byoTargets, clarificationAnswers });

  const raw = await backend.integrations.Core.InvokeLLM({
    prompt,
    max_output_tokens: 4096,
    response_json_schema: RESPONSE_SCHEMA,
    schema_name: 'structured_pasted_plan',
  });

  return unwrap(raw);
}
