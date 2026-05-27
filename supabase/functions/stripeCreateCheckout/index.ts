import Stripe from 'npm:stripe@14.21.0';
import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, findRecords, getUser } from '../_shared/records.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
  apiVersion: '2024-04-10',
});

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    const user = await getUser(req);
    const body = await req.json().catch(() => ({}));
    const priceId = body.price_id || Deno.env.get('STRIPE_PREMIUM_PRICE_ID');
    const appBaseUrl = Deno.env.get('APP_BASE_URL') || req.headers.get('origin') || 'http://localhost:5173';

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

    let customerId = existingSubs?.[0]?.stripe_customer_id as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email || undefined,
        name: user.user_metadata?.full_name || user.user_metadata?.name || user.email || undefined,
        metadata: { user_id: user.email || user.id, app: 'execute' },
      });
      customerId = customer.id;
    }

    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: [{ price: String(priceId), quantity: 1 }],
      success_url: `${appBaseUrl}/billing?success=true&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${appBaseUrl}/billing?canceled=true`,
      metadata: { user_id: user.email || user.id, app: 'execute' },
      subscription_data: {
        metadata: { user_id: user.email || user.id },
      },
      allow_promotion_codes: true,
    });

    return json({ url: session.url, session_id: session.id });
  } catch (error) {
    if (error instanceof Response) return error;
    return json({ error: error.message || 'stripeCreateCheckout failed.' }, 500);
  }
});
