/**
 * useCacheHydrated — boolean signal for whether appCache has finished hydrating.
 *
 * Drives the loading floor: screens render a skeleton while `false` so an empty,
 * not-yet-hydrated cache can never paint the `activePlan===null` CTA.
 *
 * It is event-driven (NOT a one-shot promise) so it RE-ARMS on an in-session
 * account switch: appCache emits `hydration:start` (→ false) when a purge +
 * re-hydrate begins and `hydration:done` (→ true) when it completes. A same-uid
 * no-op `activateUser` emits no event, so there is no floor flicker.
 */

import { useEffect, useState } from 'react';
import { appCache } from '@/lib/appCache';

export function useCacheHydrated() {
  const [ready, setReady] = useState(() => appCache.isHydrated());

  useEffect(() => {
    const onStart = () => setReady(false);
    const onDone = () => setReady(true);

    window.addEventListener('appcache:hydration:start', onStart);
    window.addEventListener('appcache:hydration:done', onDone);

    // Sync in case hydration settled between the initial render and this effect.
    setReady(appCache.isHydrated());

    return () => {
      window.removeEventListener('appcache:hydration:start', onStart);
      window.removeEventListener('appcache:hydration:done', onDone);
    };
  }, []);

  return ready;
}
