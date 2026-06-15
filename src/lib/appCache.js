/**
 * appCache — Two-tier cache: in-memory (instant) + durable (survives cold launch).
 *
 * Tier 1: in-memory Map (`STORE`) — zero latency, the source of truth for the
 *         synchronous `get`/`isFresh` readers.
 * Tier 2: durable store (Capacitor Preferences native / localStorage web, via
 *         `durableStore`) — survives a true iOS app kill, unlike the old
 *         sessionStorage tier which was wiped on kill and caused the
 *         cold-launch flash-of-empty-state.
 *
 * Because the durable tier is ASYNC, `get`/`isFresh` only read the in-memory
 * `STORE`. The durable tier is replayed into `STORE` once, at boot, by
 * `bootHydrate()`. Screens that read on mount must `await whenHydrated()` before
 * trusting `get()` (otherwise they observe an un-hydrated, empty cache).
 *
 * Multi-user safety: every durable entry is namespaced + tagged by the owning
 * user id and stamped with a schema version — `{ v, uid, value, timestamp }`
 * under key `appCache:u:<uid>:<logicalKey>`. Only the active user's entries are
 * hydrated; a schema bump drops all stale-shaped entries.
 */

import { durableStore } from '@/lib/durableStore';

const STORE = new Map();

// Bump to invalidate every durable entry written by an older app version.
const SCHEMA_VERSION = 1;

const DATA_PREFIX = 'appCache:u:';
const META_LAST_UID = 'appCache:__meta__:lastActiveUid';

// Boot hydration must never hang the loading floor forever; if the durable read
// stalls past this, resolve hydrate-empty (floor → cold load, never infinite).
const BOOT_TIMEOUT_MS = 3000;
// Durable entries older than this are pruned at boot (storage hygiene). Far
// longer than any freshness TTL so SWR can still paint a stale plan on launch.
const DURABLE_MAX_AGE_MS = 7 * 24 * 60 * 60_000;
// Cap per-day meal-plan entries so `meal-plan:<date>` cannot grow unbounded.
const MEAL_PLAN_KEEP = 14;

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

// ─── durable key helpers ─────────────────────────────────────────────────────
function prefixFor(uid) {
  return `${DATA_PREFIX}${uid}:`;
}
function dataKey(uid, logicalKey) {
  return `${prefixFor(uid)}${logicalKey}`;
}
function logicalKeyFrom(fullKey, uid) {
  return fullKey.slice(prefixFor(uid).length);
}

// ─── module state ────────────────────────────────────────────────────────────
let activeUid = null;       // owning user id whose entries live in STORE
let hydrated = false;       // has the first boot hydration settled?

// Single serialized op-chain. Every operation that touches activeUid / STORE
// bulk state (clear / hydrate / activate) is enqueued here so they can never
// interleave (no mid-deletion reads, no racy empty hydrate). `bootHydrate` is
// enqueued first (at module init) so an auth-driven switch always awaits it.
//
// CRITICAL (Invariant 4 / "whenHydrated must ALWAYS resolve"): `.catch` only
// isolates a *rejected* op — a never-settling (hung) durable call (e.g. a
// Capacitor Preferences bridge stall on device) would leave `work()` pending
// forever, wedging `opChain` and every screen awaiting `whenHydrated()`. So
// every op is also raced against a hard cap; on a hang the chain advances
// (hydrate-empty) rather than hanging. Far longer than any healthy durable op,
// so it only ever fires on a true stall.
const OP_TIMEOUT_MS = 8000;
let opChain = Promise.resolve();
function enqueue(work) {
  opChain = opChain.then(() => {
    let timer;
    const timeout = new Promise((resolve) => { timer = setTimeout(resolve, OP_TIMEOUT_MS); });
    return Promise.race([Promise.resolve().then(work), timeout])
      .catch((err) => {
        // A failed op must not wedge the chain for every later op.
        console.warn('[appCache] op failed:', err);
      })
      .finally(() => clearTimeout(timer));
  });
  return opChain;
}

function emit(name) {
  try {
    window.dispatchEvent(new CustomEvent(`appcache:${name}`));
  } catch {
    // non-DOM env (tests) — events are best-effort
  }
}

// ─── durable bulk operations (run only on the op-chain) ──────────────────────
async function clearDurableData() {
  STORE.clear();
  try {
    const keys = await durableStore.keys();
    await Promise.all(
      keys
        .filter((k) => k.startsWith(DATA_PREFIX))
        .map((k) => durableStore.removeItem(k)),
    );
  } catch {
    // best-effort; STORE is already cleared so reads are safe
  }
}

async function hydrateActive() {
  if (!activeUid) return; // fresh / logged-out → nothing to replay
  let keys;
  try {
    keys = await durableStore.keys();
  } catch {
    return;
  }
  const mine = keys.filter((k) => k.startsWith(prefixFor(activeUid)));
  const loaded = await Promise.all(
    mine.map((k) => durableStore.getItem(k).then((payload) => [k, payload])),
  );
  for (const [k, payload] of loaded) {
    if (!payload) continue;
    // Drop foreign-uid or stale-schema entries (Invariants 1 & 6).
    if (payload.v !== SCHEMA_VERSION || payload.uid !== activeUid) {
      durableStore.removeItem(k);
      continue;
    }
    STORE.set(logicalKeyFrom(k, activeUid), {
      value: payload.value,
      timestamp: payload.timestamp,
    });
  }
}

async function pruneDurable() {
  let keys;
  try {
    keys = await durableStore.keys();
  } catch {
    return;
  }
  const now = Date.now();
  const mealPlan = []; // [{ key, timestamp }] for the active user
  for (const k of keys) {
    if (!k.startsWith(DATA_PREFIX)) continue;
    let payload;
    try {
      payload = await durableStore.getItem(k);
    } catch {
      continue;
    }
    if (!payload) continue;
    // Hard age cap + schema drop.
    if (payload.v !== SCHEMA_VERSION || now - (payload.timestamp || 0) > DURABLE_MAX_AGE_MS) {
      durableStore.removeItem(k);
      continue;
    }
    if (activeUid && k.startsWith(`${prefixFor(activeUid)}meal-plan:`)) {
      mealPlan.push({ key: k, timestamp: payload.timestamp || 0 });
    }
  }
  // Keep only the most-recent N meal-plan days; drop the rest.
  if (mealPlan.length > MEAL_PLAN_KEEP) {
    mealPlan.sort((a, b) => b.timestamp - a.timestamp);
    await Promise.all(
      mealPlan.slice(MEAL_PLAN_KEEP).map(({ key }) => durableStore.removeItem(key)),
    );
  }
}

function writeForUser(uid, key, value) {
  if (uid !== activeUid) return; // stale writer after a switch — drop it
  const timestamp = Date.now();
  STORE.set(key, { value, timestamp });
  if (uid) {
    // Fire-and-forget durable persist; a kill before flush loses one key,
    // recovered by a cold network load on next launch (never wrong content).
    durableStore.setItem(dataKey(uid, key), {
      v: SCHEMA_VERSION,
      uid,
      value,
      timestamp,
    });
  }
}

async function bootHydrateInner() {
  let lastUid = null;
  try {
    lastUid = await durableStore.getItem(META_LAST_UID);
  } catch {
    lastUid = null;
  }
  activeUid = typeof lastUid === 'string' && lastUid ? lastUid : null;
  await pruneDurable();
  await hydrateActive();
}

// ─── public API ──────────────────────────────────────────────────────────────
export const appCache = {
  /**
   * Get cached value from the in-memory STORE. Returns null on miss.
   * NOTE: durable entries are only visible after `whenHydrated()` resolves.
   */
  get(key) {
    const mem = STORE.get(key);
    return mem ? mem.value : null;
  },

  /** Returns true if the cached value exists AND is within its TTL. */
  isFresh(key, ttl) {
    const effectiveTTL = ttl ?? getTTL(key);
    const mem = STORE.get(key);
    if (mem) return Date.now() - mem.timestamp < effectiveTTL;
    return false;
  },

  /** Store a value under a key for the currently-active user. */
  set(key, value) {
    writeForUser(activeUid, key, value);
  },

  /**
   * Store a value only if `uid` is still the active user. Used by background
   * fetches that captured the uid at start, so a response that resolves after
   * an account switch cannot write the previous user's data (Invariant 1).
   */
  setForUser(uid, key, value) {
    writeForUser(uid, key, value);
  },

  /** Remove a single key or all keys matching a prefix (memory + durable). */
  invalidate(keyOrPrefix) {
    if (!keyOrPrefix) return;

    if (STORE.has(keyOrPrefix)) STORE.delete(keyOrPrefix);
    for (const k of [...STORE.keys()]) {
      if (k.startsWith(keyOrPrefix)) STORE.delete(k);
    }

    if (!activeUid) return;
    // Durable removal is async + prefix-scoped to the active user. The prefix
    // form also matches the exact key (a key is a prefix of itself).
    const prefix = dataKey(activeUid, keyOrPrefix);
    durableStore.keys().then((keys) => {
      for (const k of keys) {
        if (k.startsWith(prefix)) durableStore.removeItem(k);
      }
    }).catch(() => {});
  },

  /** Clear all cached data (memory + durable) for every user. */
  clear() {
    return enqueue(() => clearDurableData());
  },

  // ─── hydration lifecycle ───────────────────────────────────────────────────

  /** The active user id whose entries are loaded, or null. */
  getActiveUid() {
    return activeUid;
  },

  /** Has the first boot hydration settled? Drives the loading floor. */
  isHydrated() {
    return hydrated;
  },

  /**
   * Resolves once all currently-enqueued cache ops (boot hydrate, any pending
   * activate/clear) have settled. Load effects await this before reading cache.
   */
  whenHydrated() {
    return opChain;
  },

  /**
   * Replay the last-active user's durable entries into STORE at app start.
   * Enqueued first (module init below) so it always precedes any auth-driven
   * switch. Always settles the loading floor — even on empty/absent/failed
   * reads and on timeout — so the floor can never hang (Invariant 4).
   */
  bootHydrate() {
    return enqueue(() => {
      let timer;
      const timeout = new Promise((resolve) => {
        timer = setTimeout(resolve, BOOT_TIMEOUT_MS);
      });
      return Promise.race([bootHydrateInner().catch(() => {}), timeout]).finally(() => {
        clearTimeout(timer);
        hydrated = true;
        emit('hydration:done');
      });
    });
  },

  /**
   * Reconcile the cache to `uid`. Idempotent: same uid is a pure no-op (no
   * clear, no floor flicker). A genuinely different uid purges the previous
   * user's data behind the loading floor, then re-hydrates (Invariants 1 & 5).
   */
  activateUser(uid) {
    return enqueue(async () => {
      if (uid === activeUid) {
        // Same user — keep cache intact; just ensure lastActiveUid is persisted.
        if (uid) await durableStore.setItem(META_LAST_UID, uid);
        return;
      }
      // A genuine account switch is one non-null user → a *different* non-null
      // user; only that must purge the prior user's data behind the loading
      // floor. Going from no-user → a user (initial activation — e.g. the first
      // launch after this feature shipped, when no lastActiveUid exists yet) is
      // NOT a switch: boot already settled the floor and there is nothing to
      // purge. Re-arming the floor here would needlessly flicker and — if a
      // durable call stalls — could wedge `hydration:done` and hang every screen
      // gated on `useCacheHydrated`.
      const isSwitch = activeUid !== null;
      if (isSwitch) {
        emit('hydration:start');
        hydrated = false;
      }
      try {
        if (isSwitch) await clearDurableData();
        activeUid = uid;
        if (uid) await durableStore.setItem(META_LAST_UID, uid);
        else await durableStore.removeItem(META_LAST_UID);
        await hydrateActive();
      } finally {
        if (isSwitch) {
          // Always re-settle the floor, even if the durable purge/rehydrate
          // threw — a wedged floor is worse than a one-off empty hydrate.
          hydrated = true;
          emit('hydration:done');
        }
      }
    });
  },

  /** Tear down all user-scoped cache on logout. */
  deactivate() {
    return enqueue(async () => {
      emit('hydration:start');
      hydrated = false;
      await clearDurableData();
      activeUid = null;
      await durableStore.removeItem(META_LAST_UID);
      hydrated = true;
      emit('hydration:done');
    });
  },
};

// Kick boot hydration as a module-init side-effect so it is the FIRST op on the
// chain — before any React effect or auth check runs. Do NOT gate on network.
appCache.bootHydrate();
