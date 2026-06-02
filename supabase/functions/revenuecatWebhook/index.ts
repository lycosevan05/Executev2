import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, upsertRecordBy } from '../_shared/records.ts';

/**
 * revenuecatWebhook
 *
 * Receives entitlement-change notifications from RevenueCat and mirrors them
 * into the same `user_subscriptions` Supabase table that `stripeWebhook` writes
 * to. The single table is the source of truth for `useSubscription().isPremium`
 * on both iOS and web.
 *
 * Auth: RevenueCat lets you configure a custom Authorization header per
 * webhook destination. We require it to equal Bearer <REVENUECAT_WEBHOOK_SECRET>
 * and reject everything else with 401.
 *
 * Identity: We configure the iOS SDK with the user's Supabase email as the
 * RevenueCat `appUserID`, so `event.app_user_id` here equals our `user_id`
 * column (which stores the email — matching stripeWebhook).
 *
 * Required env vars:
 *   REVENUECAT_WEBHOOK_SECRET   — shared secret matching the RevenueCat dashboard
 *   SUPABASE_URL                — auto-provided
 *   SERVICE_ROLE_KEY            — auto-provided (or SUPABASE_SERVICE_ROLE_KEY)
 */

interface RevenueCatEvent {
  type: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  product_id?: string;
  period_type?: 'NORMAL' | 'TRIAL' | 'INTRO' | 'PROMOTIONAL';
  purchased_at_ms?: number;
  expiration_at_ms?: number;
  environment?: 'SANDBOX' | 'PRODUCTION';
  entitlement_ids?: string[] | null;
  store?: string;
  transaction_id?: string;
  cancel_reason?: string;
  new_product_id?: string;
  transferred_to?: string[];
}

interface RevenueCatPayload {
  event?: RevenueCatEvent;
  api_version?: string;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function isoOrNull(ms: number | undefined): string | null {
  if (!ms || !Number.isFinite(ms)) return null;
  return new Date(ms).toISOString();
}

async function upsertSubscription(userId: string, data: Record<string, unknown>) {
  const service = createServiceClient();
  const payload = {
    ...data,
    user_id: userId,
    updated_at: new Date().toISOString(),
  };
  return upsertRecordBy(
    service,
    'user_subscriptions',
    { user_id: userId },
    payload,
    userId,
  );
}

/**
 * Translate a RevenueCat event into the subset of fields we store on
 * user_subscriptions. Returns null when the event should be ignored
 * (e.g. TEST, SUBSCRIBER_ALIAS, TRANSFER source-side).
 */
function buildUpdate(event: RevenueCatEvent): Record<string, unknown> | null {
  const base = {
    store: 'app_store',
    revenuecat_app_user_id: event.app_user_id,
    revenuecat_product_id: event.product_id,
    revenuecat_environment: event.environment,
    current_period_end: isoOrNull(event.expiration_at_ms),
    current_period_start: isoOrNull(event.purchased_at_ms),
  };

  switch (event.type) {
    case 'INITIAL_PURCHASE':
    case 'RENEWAL':
    case 'PRODUCT_CHANGE':
    case 'UNCANCELLATION':
    case 'SUBSCRIPTION_EXTENDED':
    case 'TEMPORARY_ENTITLEMENT_GRANT': {
      const status = event.period_type === 'TRIAL' ? 'trialing' : 'active';
      return {
        ...base,
        plan: 'premium',
        status,
        cancel_at_period_end: false,
      };
    }

    case 'NON_RENEWING_PURCHASE': {
      // One-off purchase — still grant premium until expiration_at_ms (or
      // indefinitely if RC doesn't provide one).
      return {
        ...base,
        plan: 'premium',
        status: 'active',
        cancel_at_period_end: true,
      };
    }

    case 'CANCELLATION': {
      // User cancelled future renewal; they keep premium until expiration.
      return {
        ...base,
        plan: 'premium',
        status: 'active',
        cancel_at_period_end: true,
      };
    }

    case 'EXPIRATION': {
      return {
        ...base,
        plan: 'free',
        status: 'canceled',
        cancel_at_period_end: false,
      };
    }

    case 'BILLING_ISSUE': {
      return {
        ...base,
        plan: 'premium',
        status: 'past_due',
      };
    }

    case 'SUBSCRIPTION_PAUSED': {
      return {
        ...base,
        plan: 'free',
        status: 'paused',
      };
    }

    case 'TRANSFER':
    case 'SUBSCRIBER_ALIAS':
    case 'TEST':
    default:
      return null;
  }
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const webhookSecret = Deno.env.get('REVENUECAT_WEBHOOK_SECRET');
  if (!webhookSecret) {
    return json({ error: 'REVENUECAT_WEBHOOK_SECRET is not configured.' }, 500);
  }

  const authHeader = req.headers.get('authorization') || '';
  const expected = `Bearer ${webhookSecret}`;
  if (!constantTimeEqual(authHeader, expected)) {
    return json({ error: 'Unauthorized' }, 401);
  }

  let payload: RevenueCatPayload;
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body.' }, 400);
  }

  const event = payload.event;
  if (!event || !event.type) {
    return json({ error: 'Missing event payload.' }, 400);
  }

  // Ignore unauthenticated / anonymous events (no app_user_id mapped).
  const userId = event.app_user_id;
  if (!userId) {
    return json({ received: true, skipped: 'no_app_user_id' });
  }

  const update = buildUpdate(event);
  if (!update) {
    // TEST, TRANSFER, SUBSCRIBER_ALIAS, or any unhandled type — acknowledge.
    return json({ received: true, skipped: event.type });
  }

  try {
    await upsertSubscription(userId, update);
  } catch (err) {
    console.error('[revenuecatWebhook] Error handling event:', err instanceof Error ? err.message : err);
    return json({ error: 'Internal error' }, 500);
  }

  return json({ received: true });
});
