import { describe, it, expect } from 'vitest';
import { syncDecide, classifySubState } from './planGuardDecision';

// isPremiumUser predicate mirror (plan === 'premium' && active/trialing)
const isPremiumRow = (sub) =>
  !!sub && sub.plan === 'premium' && (sub.status === 'active' || sub.status === 'trialing');

describe('classifySubState', () => {
  it('is active when premium is resolved true', () => {
    expect(classifySubState(true, null, isPremiumRow)).toBe('active');
    expect(classifySubState(true, { plan: 'free', status: 'expired' }, isPremiumRow)).toBe('active');
  });
  it('is lapsed when a cached row exists and is not premium', () => {
    expect(classifySubState(false, { plan: 'premium', status: 'expired' }, isPremiumRow)).toBe('lapsed');
    expect(classifySubState(false, { plan: 'free', status: 'active' }, isPremiumRow)).toBe('lapsed');
  });
  it('is unknown when there is no cached snapshot', () => {
    expect(classifySubState(false, null, isPremiumRow)).toBe('unknown');
  });
});

describe('syncDecide', () => {
  it('cold cache (no plan, still loading) holds the skeleton', () => {
    expect(syncDecide({
      subLoading: true, cacheReady: false, isPremium: false,
      generating: false, hasCachedPlan: false, subState: 'unknown',
    })).toBe('checking');
  });

  it('warm plan + active sub fast-allows while sub still revalidating', () => {
    expect(syncDecide({
      subLoading: true, cacheReady: true, isPremium: true,
      generating: false, hasCachedPlan: true, subState: 'active',
    })).toBe('allow');
  });

  it('warm plan + unknown sub fast-allows (revalidate in background)', () => {
    expect(syncDecide({
      subLoading: true, cacheReady: false, isPremium: false,
      generating: false, hasCachedPlan: true, subState: 'unknown',
    })).toBe('allow');
  });

  it('warm plan + LAPSED sub does NOT fast-allow: holds skeleton until settled', () => {
    // Still loading → must not paint entitled content; hold instead of allow.
    expect(syncDecide({
      subLoading: true, cacheReady: true, isPremium: false,
      generating: false, hasCachedPlan: true, subState: 'lapsed',
    })).toBe('checking');
  });

  it('settled premium with a cached plan allows', () => {
    expect(syncDecide({
      subLoading: false, cacheReady: true, isPremium: true,
      generating: false, hasCachedPlan: true, subState: 'active',
    })).toBe('allow');
  });

  it('settled premium, no cached plan → confirm (caller does authoritative read)', () => {
    expect(syncDecide({
      subLoading: false, cacheReady: true, isPremium: true,
      generating: false, hasCachedPlan: false, subState: 'active',
    })).toBe('confirm');
  });

  it('settled premium, no plan, generation in flight → never bounce', () => {
    expect(syncDecide({
      subLoading: false, cacheReady: true, isPremium: true,
      generating: true, hasCachedPlan: false, subState: 'active',
    })).toBe('allow');
  });

  it('settled non-premium is not plan-gated here → allow', () => {
    expect(syncDecide({
      subLoading: false, cacheReady: true, isPremium: false,
      generating: false, hasCachedPlan: false, subState: 'unknown',
    })).toBe('allow');
  });
});
