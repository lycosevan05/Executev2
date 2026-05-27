import Stripe from 'npm:stripe@14.21.0';
import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, upsertRecordBy } from '../_shared/records.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
  apiVersion: '2024-04-10',
});

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

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const body = await req.text();
  const sig = req.headers.get('stripe-signature');
  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET');

  if (!webhookSecret) {
    return json({ error: 'STRIPE_WEBHOOK_SECRET is not configured.' }, 500);
  }

  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret);
  } catch (err) {
    return json({ error: `Webhook signature verification failed: ${err.message}` }, 400);
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object;
        const userId = session.metadata?.user_id;
        if (!userId) break;

        const subscription = await stripe.subscriptions.retrieve(String(session.subscription));
        await upsertSubscription(userId, {
          plan: 'premium',
          status: subscription.status === 'trialing' ? 'trialing' : 'active',
          stripe_customer_id: session.customer,
          stripe_subscription_id: session.subscription,
          stripe_price_id: subscription.items.data[0]?.price?.id || '',
          current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
          current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
          cancel_at_period_end: subscription.cancel_at_period_end,
        });
        break;
      }

      case 'customer.subscription.created':
      case 'customer.subscription.updated': {
        const sub = event.data.object;
        const userId = sub.metadata?.user_id;
        if (!userId) break;

        const isPremiumStatus = sub.status === 'active' || sub.status === 'trialing';
        await upsertSubscription(userId, {
          plan: isPremiumStatus ? 'premium' : 'free',
          status: sub.status,
          stripe_customer_id: sub.customer,
          stripe_subscription_id: sub.id,
          stripe_price_id: sub.items.data[0]?.price?.id || '',
          current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
          current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
          cancel_at_period_end: sub.cancel_at_period_end,
        });
        break;
      }

      case 'customer.subscription.deleted': {
        const sub = event.data.object;
        const userId = sub.metadata?.user_id;
        if (!userId) break;

        await upsertSubscription(userId, {
          plan: 'free',
          status: 'canceled',
          stripe_subscription_id: sub.id,
          cancel_at_period_end: false,
        });
        break;
      }

      case 'invoice.payment_succeeded': {
        const invoice = event.data.object;
        const sub = await stripe.subscriptions.retrieve(String(invoice.subscription)).catch(() => null);
        const userId = sub?.metadata?.user_id;
        if (!sub || !userId) break;

        await upsertSubscription(userId, {
          plan: 'premium',
          status: 'active',
          current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
          current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
        });
        break;
      }

      case 'invoice.payment_failed': {
        const invoice = event.data.object;
        const sub = await stripe.subscriptions.retrieve(String(invoice.subscription)).catch(() => null);
        const userId = sub?.metadata?.user_id;
        if (!sub || !userId) break;

        await upsertSubscription(userId, {
          status: 'past_due',
        });
        break;
      }
    }
  } catch (err) {
    console.error('[stripeWebhook] Error handling event:', err.message);
  }

  return json({ received: true });
});
