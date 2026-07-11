/**
 * splitOverrides.js
 *
 * Single source of truth for user edits to the weekly training split.
 *
 * The user's AI plan is the only split. Editing a day edits a WEEKLY TEMPLATE:
 * "Monday: Push" applies to every future Monday. Edits are persisted on the
 * active AIPlan row in two places, written atomically in ONE update:
 *
 *  (a) `split_overrides` — canonical weekday-keyed template map (recurrence,
 *      out-of-window dates, refine carry-forward).
 *  (b) mirrored into `weekly_overview.days[i]` (and plan_payload.weekly_overview)
 *      for in-window dates, so every existing overview reader (Home hero, Plan
 *      card, rest-day logic, aiContext) stays correct with no changes. The
 *      pristine AI fields are stashed once under `day.ai_original` so
 *      "Reset to AI" can restore them.
 *
 * Override shape (absent key = pure AI day):
 *   { day_type: 'training'|'rest', label: string,
 *     exercises: [{ name, sets, reps }], edited_at: ISO,
 *     origin: 'editor'|'custom_split_migration' }
 *
 * A new plan from the questionnaire has no overrides (fresh start, by design).
 * refinePlanFromChat carries overrides onto the new plan row (edits win).
 */

import { backend } from '@/api/backendClient';
import {
  userScopedFilter,
  bustPlanCache,
  invalidateUserAIContext,
} from '@/lib/personalizationSync';
import { withBackoff } from '@/lib/withBackoff';
import { appCache } from '@/lib/appCache';

export const WEEKDAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** Weekday name for a YYYY-MM-DD date string (noon-anchored to dodge TZ edges). */
export function weekdayNameForDate(dateStr) {
  return WEEKDAY_NAMES[new Date(dateStr + 'T12:00:00').getDay()];
}

function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** The user's template override for a specific date, or null for a pure AI day. */
export function getOverrideForDate(masterPlan, date) {
  if (!masterPlan?.split_overrides || !date) return null;
  return masterPlan.split_overrides[weekdayNameForDate(date)] || null;
}

// Overview-day fields the mirror overwrites (and therefore stashes/restores).
const MIRRORED_DAY_FIELDS = ['day_type', 'session_title', 'training_type', 'workout_needed'];

/**
 * Pure: return a copy of `overview` with `overrides` mirrored into its days.
 * - Overridden weekday: stash pristine AI fields once under `ai_original`,
 *   then apply the override's type/label.
 * - Previously-edited day whose weekday no longer has an override: restore
 *   from `ai_original` and drop the markers.
 */
export function applyOverridesToOverview(overview, overrides) {
  if (!overview || !Array.isArray(overview.days)) return overview;
  const map = overrides || {};
  const days = overview.days.map((day) => {
    const override = day?.date ? map[weekdayNameForDate(day.date)] : null;
    if (override) {
      const ai_original = day.ai_original || MIRRORED_DAY_FIELDS.reduce((acc, f) => {
        acc[f] = day[f];
        return acc;
      }, {});
      const isRest = override.day_type === 'rest';
      return {
        ...day,
        ai_original,
        edited_by_user: true,
        day_type: isRest ? 'rest' : 'training',
        workout_needed: !isRest,
        session_title: override.label,
        training_type: override.label,
      };
    }
    if (day?.edited_by_user && day.ai_original) {
      const restored = { ...day, ...day.ai_original };
      delete restored.ai_original;
      delete restored.edited_by_user;
      return restored;
    }
    return day;
  });
  return { ...overview, days };
}

/**
 * Build a complete WorkoutPlan payload directly from a user override — no LLM.
 * Deliberately NOT run through the LLM-output validator (4–8 exercise rule etc.
 * must never reject what the user typed). Caller wraps with withUserEmail().
 */
export function buildWorkoutPlanPayloadFromOverride(override, date, masterPlan) {
  return {
    date,
    name: override.label,
    type: override.label,
    duration: '~45 min',
    intensity: 'moderate',
    focus: '',
    workout_summary: '',
    warmup: '',
    cooldown: '',
    exercises: (override.exercises || []).map((ex) => ({
      name: ex.name,
      sets: Number(ex.sets) || 3,
      reps: String(ex.reps || '10'),
      rest: '60–90 sec',
      muscles: '',
      notes: '',
    })),
    notes: '',
    generated_by_ai: false,
    source: 'user_split_override',
    source_plan_id: masterPlan.id,
    generation_batch_id: masterPlan.generation_batch_id || '',
    status: 'planned',
    modifications: [],
    safety_notes: [],
    generation_status: 'ready',
  };
}

/**
 * Reconcile already-generated future WorkoutPlan rows of `weekday` with the
 * new override. Past dates are never touched; today is skipped when a
 * WorkoutLog exists for today (a started/finished session stays intact — the
 * edit applies from the next occurrence).
 *
 * - exercises present → update-in-place (row id stays stable for
 *   DailyLog.planned_workout_id / WorkoutLog.workout_plan_id)
 * - rest / type-only / reset → archive (day returns to "Build"; matches the
 *   refine convention, recoverable, filtered by chooseBestWorkoutPlan)
 */
export async function propagateOverrideToFutureRows({ masterPlan, weekday, override }) {
  const today = todayISO();
  const todayLogFilter = await userScopedFilter({ date: today });

  const [rows, todayLogs] = await Promise.all([
    withBackoff(
      () => backend.entities.WorkoutPlan.filter({ source_plan_id: masterPlan.id }),
    ).catch(() => []),
    withBackoff(
      () => backend.entities.WorkoutLog.filter(todayLogFilter),
    ).catch(() => []),
  ]);

  const todayLocked = todayLogs.length > 0;
  const affected = (Array.isArray(rows) ? rows : []).filter((row) =>
    row &&
    row.status !== 'archived' &&
    row.date &&
    row.date >= today &&
    !(todayLocked && row.date === today) &&
    weekdayNameForDate(row.date) === weekday
  );

  for (const row of affected) {
    if (override && override.day_type !== 'rest' && override.exercises?.length > 0) {
      await withBackoff(
        () => backend.entities.WorkoutPlan.update(
          row.id,
          buildWorkoutPlanPayloadFromOverride(override, row.date, masterPlan),
        ),
      ).catch(() => {});
    } else {
      // rest, type-only, or reset — archive; the day regenerates on Build.
      await withBackoff(
        () => backend.entities.WorkoutPlan.update(row.id, { status: 'archived' }),
      ).catch(() => {});
    }
  }
}

function afterOverridesBookkeeping(updatedPlan) {
  bustPlanCache('daily');
  appCache.set('ai-plan:daily', updatedPlan);
  appCache.invalidate('workouts-today');
  appCache.invalidate('workouts-split');
  return invalidateUserAIContext().catch(() => {});
}

/**
 * Persist the full next override map in ONE AIPlan.update (canonical map +
 * mirrored overview in both locations), then reconcile future rows for each
 * changed weekday. Returns the updated plan record.
 */
export async function saveSplitOverrides({ masterPlan, nextOverrides, changedWeekdays }) {
  const overview =
    masterPlan.weekly_overview ||
    masterPlan.plan_payload?.weekly_overview ||
    null;
  const mirrored = applyOverridesToOverview(overview, nextOverrides);

  const updatedPlan = await withBackoff(
    () => backend.entities.AIPlan.update(masterPlan.id, {
      split_overrides: nextOverrides,
      weekly_overview: mirrored,
      plan_payload: { ...(masterPlan.plan_payload || {}), weekly_overview: mirrored },
    }),
  );

  for (const weekday of changedWeekdays) {
    await propagateOverrideToFutureRows({
      masterPlan,
      weekday,
      override: nextOverrides[weekday] || null,
    });
  }

  await afterOverridesBookkeeping(updatedPlan);
  return updatedPlan;
}

/**
 * Save (or reset, when `override` is null) a single weekday's template edit.
 * Returns the updated plan record.
 */
export async function saveSplitOverride({ masterPlan, weekday, override }) {
  const current = masterPlan.split_overrides || {};
  const nextOverrides = { ...current };
  if (override) {
    nextOverrides[weekday] = {
      ...override,
      edited_at: new Date().toISOString(),
      origin: override.origin || 'editor',
    };
  } else {
    delete nextOverrides[weekday];
  }
  return saveSplitOverrides({ masterPlan, nextOverrides, changedWeekdays: [weekday] });
}
