/**
 * platform.js
 *
 * Tiny helper around Capacitor's platform detection so the rest of the
 * codebase can branch on `'ios' | 'android' | 'web'` without importing
 * @capacitor/core everywhere.
 *
 * Safe to import in any environment. Falls back to 'web' if Capacitor is
 * not initialised (e.g. SSR or unit tests).
 */

import { Capacitor } from '@capacitor/core';

export function getPlatform() {
  try {
    return Capacitor.getPlatform(); // 'ios' | 'android' | 'web'
  } catch {
    return 'web';
  }
}

export function isNative() {
  try {
    return Capacitor.isNativePlatform();
  } catch {
    return false;
  }
}

export const isIOS = () => getPlatform() === 'ios';
export const isAndroid = () => getPlatform() === 'android';
export const isWeb = () => getPlatform() === 'web';
