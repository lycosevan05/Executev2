/**
 * Singleton that keeps a plan generation in-flight even when the user navigates away.
 * The Plan page subscribes to it on mount and re-attaches if generation is ongoing.
 */

import { generateInitialPlanBundle } from '@/lib/generateInitialPlanBundle';
import { clearGenerationStartTime } from '@/components/plan/PlanGeneratingOverlay';

const STORAGE_KEY = 'evanlog_plan_generation';

let _promise = null;      // The active generation promise
let _listeners = [];      // Callbacks to notify when done
let _lastResult = null;   // { err, result } — replayed once to late subscribers
let _lastResultClaimed = false; // Set true after a subscriber consumes _lastResult

export function savePendingAnswers(answers, step) {
  try {
    const existing = loadPendingAnswers();
    const startedAt = existing?._startedAt || Date.now();
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ answers, step: step ?? undefined, _startedAt: startedAt }));
  } catch (_) {}
}

export function loadPendingAnswers() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    // Expire after 30 minutes
    if (Date.now() - (parsed._startedAt || 0) > 30 * 60 * 1000) {
      sessionStorage.removeItem(STORAGE_KEY);
      return null;
    }
    return parsed.answers || null;
  } catch (_) {
    return null;
  }
}

export function loadPendingStep() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return 0;
    const parsed = JSON.parse(raw);
    return parsed.step ?? 0;
  } catch (_) {
    return 0;
  }
}

export function clearPendingAnswers() {
  try { sessionStorage.removeItem(STORAGE_KEY); } catch (_) {}
}

export function isGenerating() {
  return _promise !== null;
}

/**
 * Start generation (or re-attach if already running).
 * Returns { promise } — the promise resolves with the plan result or rejects on error.
 */
export function startGeneration(answers) {
  if (_promise) return _promise; // Already running — re-attach

  savePendingAnswers(answers);

  // Safety timeout: if generation takes more than 3 minutes, treat as failed
  const timeoutPromise = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('Plan generation timed out. Please try again.')), 3 * 60 * 1000)
  );

  // Reset replay buffer for the new generation
  _lastResult = null;
  _lastResultClaimed = false;

  _promise = Promise.race([generateInitialPlanBundle(answers), timeoutPromise])
    .then(result => {
      clearPendingAnswers();
      clearGenerationStartTime();
      _lastResult = { err: null, result };
      _lastResultClaimed = false;
      _listeners.forEach(cb => cb(null, result));
      return result;
    })
    .catch(err => {
      clearPendingAnswers();
      clearGenerationStartTime();
      _lastResult = { err, result: null };
      _lastResultClaimed = false;
      _listeners.forEach(cb => cb(err, null));
      throw err;
    })
    .finally(() => {
      _promise = null;
      _listeners = [];
    });

  return _promise;
}

/**
 * Subscribe to the current or just-completed generation.
 * If a generation is in-flight, the callback fires when it finishes.
 * If a generation finished recently (and hasn't been claimed yet), the callback
 * is invoked once asynchronously with that result — this covers the "user
 * navigated away mid-generation and came back" case.
 * Returns an unsubscribe function.
 */
export function subscribeToGeneration(cb) {
  // Late subscriber: a result is buffered and not yet claimed → replay it once
  if (!_promise && _lastResult && !_lastResultClaimed) {
    _lastResultClaimed = true;
    const buffered = _lastResult;
    // Async so callers can set up state before the callback fires
    Promise.resolve().then(() => cb(buffered.err, buffered.result));
    return () => {};
  }

  if (!_promise) return () => {};
  _listeners.push(cb);
  return () => {
    _listeners = _listeners.filter(l => l !== cb);
  };
}