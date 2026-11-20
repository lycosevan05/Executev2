import { beforeEach, describe, expect, it, vi } from 'vitest';
import { bustSubscriptionCache, loadUserSubscription, peekCachedSubscription } from './subscription';

const { me, filter, rpc } = vi.hoisted(() => ({
  me: vi.fn(),
  filter: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock('@/api/backendClient', () => ({
  backend: { auth: { me }, entities: { UserSubscription: { filter } } },
  supabase: { rpc },
}));

const first = { id: 'first-id', email: 'first@example.invalid' };
const legacyPremium = { plan: 'premium', status: 'active' };

describe('billing projection compatibility', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    bustSubscriptionCache();
    me.mockResolvedValue(first);
    filter.mockResolvedValue([legacyPremium]);
  });

  it.each([
    { data: { state: 'legacy' }, error: null },
    { data: null, error: { code: 'PGRST202' } },
  ])('preserves legacy access during staged deployment (%j)', async (reply) => {
    rpc.mockResolvedValue(reply);
    expect(await loadUserSubscription()).toEqual(legacyPremium);
    expect(filter).toHaveBeenCalledWith({ user_id: first.email }, '-updated_date', 1);
  });

  it.each([
    { data: { state: 'verified', subscription: { plan: 'free' } }, error: null },
    { data: { state: 'verified', subscription: null }, error: null },
    { data: { state: 'unavailable' }, error: null },
    { data: null, error: { code: '42501' } },
  ])('does not replace a verified or unavailable result with an email row (%j)', async (reply) => {
    rpc.mockResolvedValue(reply);
    expect(await loadUserSubscription()).toEqual(reply.data?.subscription ?? null);
    expect(filter).not.toHaveBeenCalled();
  });

  it('skips the cached subscription after a same-email owner switch', async () => {
    rpc.mockResolvedValueOnce({ data: { state: 'verified', subscription: legacyPremium } })
      .mockResolvedValueOnce({ data: { state: 'verified', subscription: null } });
    expect(await loadUserSubscription()).toEqual(legacyPremium);
    me.mockResolvedValue({ ...first, id: 'replacement-id' });
    expect(await loadUserSubscription()).toBeNull();
    expect(peekCachedSubscription()).toBeNull();
  });

  it('does not publish an in-flight result after the cache was cleared', async () => {
    let finish;
    rpc.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
    const pending = loadUserSubscription(true);
    await vi.waitFor(() => expect(rpc).toHaveBeenCalled());
    bustSubscriptionCache();
    finish({ data: { state: 'verified', subscription: legacyPremium } });
    expect(await pending).toBeNull();
    expect(peekCachedSubscription()).toBeNull();
  });

  it('unblocks startup when billing stalls and discards the late response', async () => {
    vi.useFakeTimers();
    try {
      let finish;
      rpc.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
      const pending = loadUserSubscription();
      await vi.advanceTimersByTimeAsync(8000);
      expect(await pending).toBeNull();
      finish({ data: { state: 'verified', subscription: legacyPremium } });
      await vi.advanceTimersByTimeAsync(0);
      expect(peekCachedSubscription()).toBeNull();
      expect(filter).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});
