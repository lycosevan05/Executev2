/**
 * byoDraft — durable crash-safety draft for "Input your own plan" (BYO) text.
 *
 * Persists the user's pasted training/nutrition text + chosen scope so a true
 * iOS hard-close (which wipes sessionStorage) doesn't lose a long typed plan.
 * Backed by durableStore (Capacitor Preferences on native / localStorage on web).
 *
 * STATED v1 LIMITATION: this is local-only — same install, same device. It is a
 * crash-safety net, NOT cross-device or cross-reinstall persistence.
 *
 * Keyed per active uid (`byo:draft:u:<uid>`) so two accounts on one device never
 * read each other's draft. When no uid is active we fall back to an anon key so a
 * pre-auth draft is still recoverable within the session.
 */

import { durableStore } from '@/lib/durableStore';
import { appCache } from '@/lib/appCache';

function draftKey() {
  const uid = appCache.getActiveUid() || 'anon';
  return `byo:draft:u:${uid}`;
}

/**
 * Persist the current BYO draft. Callers should debounce (~600ms) on textarea
 * change. No-op on storage failure (durableStore swallows errors).
 */
export async function saveByoDraft({ byoScope, byoWorkoutText, byoMealText }) {
  await durableStore.setItem(draftKey(), {
    byoScope: byoScope || null,
    byoWorkoutText: byoWorkoutText || '',
    byoMealText: byoMealText || '',
    savedAt: Date.now(),
  });
}

/** Restore the BYO draft for the active uid, or null on miss. */
export async function loadByoDraft() {
  return durableStore.getItem(draftKey());
}

/** Remove the BYO draft. Called only after a plan is successfully committed. */
export async function clearByoDraft() {
  await durableStore.removeItem(draftKey());
}
