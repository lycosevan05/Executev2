/**
 * checklistPrefs — local (device) preferences for the daily checklist.
 *
 * Tracks which built-in default items the user has hidden. Stored in
 * durableStore so it survives a cold launch. Custom items live in Supabase;
 * default visibility is a per-device preference.
 */

import { durableStore } from '@/lib/durableStore';

const HIDDEN_DEFAULTS_KEY = 'checklist:hiddenDefaults';

// Built-in checklist items the user can show/hide. `type` matches the item
// type produced by buildItemsFromData in DailyChecklist.
export const DEFAULT_CHECKLIST_ITEMS = [
  { type: 'workout', label: "Today's Workout" },
  { type: 'nutrition', label: 'Nutrition Plan' },
  { type: 'recovery', label: 'Recovery Routine' },
];

/** Returns the array of hidden default types (e.g. ['recovery']). */
export async function getHiddenDefaults() {
  const v = await durableStore.getItem(HIDDEN_DEFAULTS_KEY);
  return Array.isArray(v) ? v : [];
}

/** Persists the array of hidden default types. */
export async function saveHiddenDefaults(types) {
  await durableStore.setItem(HIDDEN_DEFAULTS_KEY, Array.isArray(types) ? types : []);
}
