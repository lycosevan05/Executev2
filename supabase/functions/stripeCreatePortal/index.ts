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
    const appBaseUrl = Deno.env.get('APP_BASE_URL') || req.headers.get('origin') || 'http://localhost:5173';

    if (!Deno.env.get('STRIPE_SECRET_KEY')) {
      return json({ error: 'STRIPE_SECRET_KEY is not configured.' }, 500);
    }

    const service = createServiceClient();
    const subs = await findRecords(
      service,
      'user_subscriptions',
      { user_id: user.email },
      { limit: 1 },
    );

    const customerId = subs?.[0]?.stripe_customer_id;
    if (!customerId) {
      return json({ error: 'No Stripe customer found.' }, 400);
    }

    const session = await stripe.billingPortal.sessions.create({
      customer: String(customerId),
      return_url: `${appBaseUrl}/billing`,
    });

    return json({ url: session.url });
  } catch (error) {
    if (error instanceof Response) return error;
    return json({ error: error.message || 'stripeCreatePortal failed.' }, 500);
  }
});
