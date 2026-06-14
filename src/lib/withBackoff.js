/**
 * withBackoff.js
 *
 * Retry an async operation with full-jitter exponential backoff.
 * Used to absorb transient PostgREST 429 / 503 / 5xx responses in the
 * workout-plan build path so a throttled request retries instead of failing
 * the whole day.
 */

const DEFAULTS = {
  retries: 5,
  baseMs: 300,
  capMs: 8000,
  deadlineMs: 30000,
};

/**
 * Decide whether an error is worth retrying. PostgREST 429s do not always
 * surface a clean numeric status through the backend error wrapper, so we also
 * match on the message/code text.
 */
function defaultRetryable(err) {
  const status = err?.status;
  if (status === 429 || status === 503 || (typeof status === 'number' && status >= 500)) {
    return true;
  }
  const text = `${err?.message || ''} ${err?.code || ''}`;
  return /\b429\b|rate.?limit|too many|service unavailable|\b503\b/i.test(text);
}

/**
 * Parse a server-provided retry hint (ms) from a thrown backend error, if any.
 * Supports `retry-after-ms` (ms) and `retry-after` (seconds) carried on the
 * error or its `data`/`headers`.
 */
function retryAfterMs(err) {
  const headers = err?.headers || err?.data?.headers;
  const ms = headers?.['retry-after-ms'] ?? err?.retryAfterMs;
  if (ms != null && !Number.isNaN(Number(ms))) return Number(ms);
  const secs = headers?.['retry-after'] ?? err?.retryAfter;
  if (secs != null && !Number.isNaN(Number(secs))) return Number(secs) * 1000;
  return 0;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @template T
 * @param {() => Promise<T>} fn
 * @param {{ retries?: number, baseMs?: number, capMs?: number, deadlineMs?: number, retryable?: (err: any) => boolean }} [options]
 * @returns {Promise<T>}
 */
export async function withBackoff(fn, options = {}) {
  const { retries, baseMs, capMs, deadlineMs } = { ...DEFAULTS, ...options };
  const retryable = options.retryable || defaultRetryable;
  const start = Date.now();

  let attempt = 0;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      return await fn();
    } catch (err) {
      attempt += 1;
      const elapsed = Date.now() - start;
      if (attempt > retries || elapsed >= deadlineMs || !retryable(err)) {
        throw err;
      }
      // Full jitter: random in [0, base * 2^(attempt-1)], honoring server hint as a minimum.
      const expo = Math.min(capMs, baseMs * 2 ** (attempt - 1));
      const jittered = Math.random() * expo;
      let wait = Math.max(retryAfterMs(err), jittered);
      // Never sleep past the overall deadline.
      wait = Math.min(wait, Math.max(0, deadlineMs - elapsed));
      await sleep(wait);
    }
  }
}
