import Stripe from 'npm:stripe@14.21.0';
import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, findRecords, getUser } from '../_shared/records.ts';
import {
  acknowledgeExactCheckout,
  createStripeCheckoutLedger,
  exactCheckoutMetadata,
} from '../_shared/stripeCheckoutGuard.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
  apiVersion: '2024-04-10' as Stripe.LatestApiVersion,
});

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const guarded = Deno.env.get('EXECUTE_STRIPE_CHECKOUT_GUARD') === '1';

  try {
    const user = await getUser(req);
    const body = await req.json().catch(() => ({}));
    const priceId = body.price_id || Deno.env.get('STRIPE_PREMIUM_PRICE_ID');
    const configuredAppURL = Deno.env.get('APP_BASE_URL');
    const appBaseUrl = configuredAppURL || req.headers.get('origin') || 'http://localhost:5173';
    if (guarded && (!configuredAppURL || req.method !== 'POST')) {
      return json({ error: 'Guarded checkout is unavailable for this request.' }, 503);
    }

    if (!Deno.env.get('STRIPE_SECRET_KEY')) {
      return json({ error: 'STRIPE_SECRET_KEY is not configured.' }, 500);
    }
    if (!priceId) {
      return json({ error: 'STRIPE_PREMIUM_PRICE_ID is not configured.' }, 500);
    }

    const service = createServiceClient();
    const existingSubs = await findRecords(
      service,
      'user_subscriptions',
      { user_id: user.email },
      { limit: 1 },
    );

    const existing = existingSubs?.[0] as Record<string, unknown> | undefined;
    let customerId = typeof existing?.stripe_customer_id === 'string' ? existing.stripe_customer_id : undefined;
    if (guarded && customerId) {
      const customer = await stripe.customers.retrieve(customerId);
      if (customer.deleted || customer.metadata.execute_owner_uuid !== user.id ||
        customer.metadata.user_id !== user.email) {
        throw new Error('Stripe customer ownership is unavailable.');
      }
    }
    const ledger = guarded ? createStripeCheckoutLedger((name, args) => service.rpc(name, args)) : undefined;
    const dispatch = await ledger?.begin(user);
    if (ledger && !dispatch) {
      return json({ error: 'Checkout is unavailable for this account.' }, 409);
    }
    const ownershipMetadata = dispatch ? exactCheckoutMetadata(user, dispatch) : {
      user_id: user.email || user.id,
      execute_owner_uuid: user.id,
    };

    // Leave the dispatch pending after an ambiguous provider result. Neither
    // a timeout nor a later successful checkout proves this call was unsent.
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email || undefined,
        name: user.user_metadata?.full_name || user.user_metadata?.name || user.email || undefined,
        metadata: { ...ownershipMetadata, app: 'execute' },
      }, dispatch ? { idempotencyKey: `execute-checkout-customer:${dispatch}` } : undefined);
      customerId = customer.id;
    }

    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: [{ price: String(priceId), quantity: 1 }],
      success_url: `${appBaseUrl}/billing?success=true&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${appBaseUrl}/billing?canceled=true`,
      metadata: { ...ownershipMetadata, app: 'execute' },
      subscription_data: {
        metadata: ownershipMetadata,
      },
      allow_promotion_codes: true,
    }, dispatch ? { idempotencyKey: `execute-checkout-session:${dispatch}` } : undefined);

    if (ledger && dispatch) {
      const open = await acknowledgeExactCheckout(ledger, user, dispatch, session);
      if (!open || session.status !== 'open' || !session.url) {
        return json({ error: 'Checkout is unavailable for this account.' }, 409);
      }
    }

    return json({ url: session.url, session_id: session.id });
  } catch (error) {
    if (error instanceof Response) return error;
    if (guarded) return json({ error: 'Could not safely create a checkout session.' }, 503);
    return json({ error: error instanceof Error && error.message ? error.message : 'stripeCreateCheckout failed.' }, 500);
  }
});
