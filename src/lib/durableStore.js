/**
 * durableStore — async key/value storage that survives a true iOS cold launch.
 *
 * Routes by platform:
 *   - native (iOS/Android) → @capacitor/preferences (persists across app kill)
 *   - web                  → localStorage (persists across tab/app close in WKWebView)
 *
 * Why not sessionStorage? It is wiped when iOS kills the app, which is the root
 * cause of the cold-launch flash-of-empty-state. Preferences/localStorage both
 * survive that.
 *
 * All values are JSON-(de)serialized. Every call is wrapped in try/catch so a
 * storage failure degrades to a no-op / null rather than throwing into callers.
 */

import { Preferences } from '@capacitor/preferences';
import { isNative } from '@/lib/platform';

// NOTE: Preferences is imported statically (not via a dynamic `import()`).
// On the iOS `capacitor://localhost` WebView a dynamic import of the plugin
// chunk could hang and never resolve, wedging every durable read/write. A
// static import is bundled into the main chunk and resolved at load, so the
// native bridge is always reachable. The plugin ships a web implementation too,
// but we only invoke it under `isNative()` (web uses localStorage below).

export const durableStore = {
  /** Read and JSON-parse the value at `key`. Returns null on miss/error. */
  async getItem(key) {
    try {
      if (isNative()) {
        const { value } = await Preferences.get({ key });
        return value ? JSON.parse(value) : null;
      }
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  },

  /** JSON-serialize and persist `value` at `key`. No-op on error. */
  async setItem(key, value) {
    try {
      const raw = JSON.stringify(value);
      if (isNative()) {
        await Preferences.set({ key, value: raw });
        return;
      }
      localStorage.setItem(key, raw);
    } catch {
      // Storage full or unavailable — silently ignore.
    }
  },

  /** Remove a single key. No-op on error. */
  async removeItem(key) {
    try {
      if (isNative()) {
        await Preferences.remove({ key });
        return;
      }
      localStorage.removeItem(key);
    } catch {
      // ignore
    }
  },

  /** List all stored keys. Returns [] on error. */
  async keys() {
    try {
      if (isNative()) {
        const { keys } = await Preferences.keys();
        return keys || [];
      }
      const out = [];
      for (let i = 0; i < localStorage.length; i += 1) {
        const k = localStorage.key(i);
        if (k) out.push(k);
      }
      return out;
    } catch {
      return [];
    }
  },
};
