/**
 * appCache — Two-tier cache: in-memory (instant) + sessionStorage (survives re-mounts).
 *
 * Tier 1: in-memory Map — zero latency, lost on full page reload.
 * Tier 2: sessionStorage — survives React re-mounts and fast-refresh, lost on tab close.
 *
 * This eliminates the "app forgets plan on tab switch" bug.
 */

const STORE = new Map();

// How long data is considered "fresh" (no background refresh needed)
const TTL_MAP = {
  'home-dashboard':  10 * 60_000,   // 10 min
  'plan-page':       15 * 60_000,   // 15 min
  'ai-plan:daily':   30 * 60_000,   // 30 min
  'ai-plan:weekly':  30 * 60_000,   // 30 min
  'user-email':      60 * 60_000,   // 60 min
  'user-profile':    15 * 60_000,   // 15 min
  default:           10 * 60_000,   // 10 min
};

function getTTL(key) {
  // Check prefix match first
  for (const k of Object.keys(TTL_MAP)) {
    if (k !== 'default' && key.startsWith(k)) return TTL_MAP[k];
  }
  return TTL_MAP.default;
}

function ssKey(key) {
  return `appCache:${key}`;
}

function readFromStorage(key) {
  try {
    const raw = sessionStorage.getItem(ssKey(key));
    if (!raw) return null;
    const entry = JSON.parse(raw);
    return entry || null;
  } catch {
    return null;
  }
}

function writeToStorage(key, entry) {
  try {
    sessionStorage.setItem(ssKey(key), JSON.stringify(entry));
  } catch {
    // Storage full or unavailable — silently ignore
  }
}

export const appCache = {
  /**
   * Get cached value. Checks memory first, then sessionStorage.
   * Always returns the value regardless of age — use isFresh() to decide whether to refresh.
   */
  get(key) {
    // Tier 1: memory
    const mem = STORE.get(key);
    if (mem) return mem.value;

    // Tier 2: sessionStorage (re-hydrate into memory on hit)
    const stored = readFromStorage(key);
    if (stored) {
      STORE.set(key, stored);
      return stored.value;
    }

    return null;
  },

  /** Returns true if the cached value exists AND is within its TTL. */
  isFresh(key, ttl) {
    const effectiveTTL = ttl ?? getTTL(key);

    const mem = STORE.get(key);
    if (mem) return Date.now() - mem.timestamp < effectiveTTL;

    const stored = readFromStorage(key);
    if (stored) {
      const fresh = Date.now() - stored.timestamp < effectiveTTL;
      if (fresh) STORE.set(key, stored); // re-hydrate
      return fresh;
    }

    return false;
  },

  /** Store a value under a key in both memory and sessionStorage. */
  set(key, value) {
    const entry = { value, timestamp: Date.now() };
    STORE.set(key, entry);
    writeToStorage(key, entry);
  },

  /** Remove a single key or all keys matching a prefix. */
  invalidate(keyOrPrefix) {
    if (!keyOrPrefix) return;

    // Exact match
    if (STORE.has(keyOrPrefix)) {
      STORE.delete(keyOrPrefix);
      try { sessionStorage.removeItem(ssKey(keyOrPrefix)); } catch {}
    }

    // Prefix match
    for (const k of STORE.keys()) {
      if (k.startsWith(keyOrPrefix)) {
        STORE.delete(k);
        try { sessionStorage.removeItem(ssKey(k)); } catch {}
      }
    }

    // Also scan sessionStorage for prefix matches not in memory
    try {
      const prefix = ssKey(keyOrPrefix);
      for (let i = sessionStorage.length - 1; i >= 0; i--) {
        const k = sessionStorage.key(i);
        if (k && k.startsWith(prefix)) sessionStorage.removeItem(k);
      }
    } catch {}
  },

  /** Clear everything (on logout). */
  clear() {
    STORE.clear();
    try {
      for (let i = sessionStorage.length - 1; i >= 0; i--) {
        const k = sessionStorage.key(i);
        if (k && k.startsWith('appCache:')) sessionStorage.removeItem(k);
      }
    } catch {}
  },
};