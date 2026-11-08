import {
  type BillingData,
  knownStripeSubscriptionIDs,
  mergeProviderProjections,
  projectStripeSubscriptions,
} from "../_shared/billingProjection.ts";
import {
  revenueCatProjection,
  type SubscriptionChange,
  type SubscriptionRow,
} from "../revenuecatWebhook/reconcile.ts";

export interface StripeEvent {
  id?: string;
  type: string;
  data: { object: BillingData };
}

export interface StripeDependencies {
  webhookSecret?: string;
  stripeKey?: string;
  revenueCatKey?: string;
  fetch: typeof fetch;
  verifyEvent: (
    body: string,
    signature: string,
    secret: string,
  ) => Promise<unknown>;
  read: (userId: string) => Promise<SubscriptionRow | null>;
  apply: (changes: SubscriptionChange[]) => Promise<void>;
}

const handledTypes = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.payment_succeeded",
  "invoice.payment_failed",
]);

function object(value: unknown): BillingData {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid provider object");
  }
  return value as BillingData;
}

function identifier(value: unknown): string | null {
  if (value == null) return null;
  const id = typeof value === "string" ? value : object(value).id;
  if (typeof id !== "string" || !id || id.length > 1000) {
    throw new Error("Invalid subscription identifier");
  }
  return id;
}

function emailFor(subscription: BillingData): string {
  const userId = object(subscription.metadata).user_id;
  if (typeof userId !== "string" || !/^[^\s@]+@[^\s@]+$/.test(userId)) {
    throw new Error("Stripe subscription identity is unavailable");
  }
  return userId;
}

async function getJson(
  deps: StripeDependencies,
  url: string,
  key: string,
  stripe = false,
): Promise<BillingData> {
  const response = await deps.fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`,
      "Cache-Control": "no-cache",
      ...(stripe ? { "Stripe-Version": "2024-04-10" } : {}),
    },
    signal: AbortSignal.timeout(8000),
  });
  // RevenueCat GET may create an empty customer and return 201. Its documented
  // GET response does not include 404; never infer a free customer from an error.
  if (response.status !== 200 && !(response.status === 201 && !stripe)) {
    throw new Error("Provider lookup failed");
  }
  return object(await response.json());
}

async function stripeSubscription(
  deps: StripeDependencies,
  id: string,
): Promise<BillingData> {
  const subscription = await getJson(
    deps,
    `https://api.stripe.com/v1/subscriptions/${encodeURIComponent(id)}`,
    deps.stripeKey!,
    true,
  );
  if (subscription.id !== id) throw new Error("Stripe subscription mismatch");
  return subscription;
}

export function createStripeHandler(
  deps: StripeDependencies,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const reply = (body: BillingData, status = 200) =>
      Response.json(body, { status });
    if (req.method !== "POST") {
      return reply({ error: "Method not allowed" }, 405);
    }
    if (!deps.webhookSecret) {
      return reply({ error: "Webhook authentication is not configured." }, 500);
    }
    const signature = req.headers.get("stripe-signature");
    if (!signature) return reply({ error: "Missing webhook signature." }, 400);
    let event: StripeEvent;
    try {
      const verified = object(
        await deps.verifyEvent(
          await req.text(),
          signature,
          deps.webhookSecret,
        ),
      );
      if (typeof verified.type !== "string" || !verified.type) {
        throw new Error("Missing event type");
      }
      event = {
        id: typeof verified.id === "string" ? verified.id : undefined,
        type: verified.type,
        data: { object: object(object(verified.data).object) },
      };
    } catch {
      return reply({ error: "Webhook signature verification failed." }, 400);
    }
    if (!handledTypes.has(event.type)) {
      return reply({ received: true, skipped: event.type });
    }
    if (!deps.stripeKey || !deps.revenueCatKey) {
      return reply(
        { error: "Customer reconciliation is not configured." },
        503,
      );
    }
    try {
      const payload = object(event.data.object);
      const id = event.type.startsWith("customer.subscription.")
        ? identifier(payload.id)
        : identifier(payload.subscription);
      if (!id) {
        if (event.type.startsWith("invoice.")) {
          return reply({ received: true, skipped: "non_subscription_invoice" });
        }
        throw new Error("Missing subscription identifier");
      }
      // Bootstrap identifies the email only. Read the revision, then re-read
      // all provider state; a bootstrap snapshot cannot race a newer DB write.
      const identitySnapshot = await stripeSubscription(deps, id);
      const userId = emailFor(identitySnapshot);
      const signedMetadata = payload.metadata;
      if (signedMetadata && typeof signedMetadata === "object") {
        const signedUser = object(signedMetadata).user_id;
        if (signedUser !== undefined && signedUser !== userId) {
          throw new Error("Stripe event identity mismatch");
        }
      }
      const row = await deps.read(userId);
      const previous = row?.data ?? {};
      const ids = knownStripeSubscriptionIDs(previous, id);
      const [snapshots, revenueCatBody] = await Promise.all([
        Promise.all(ids.map(async (knownID) => {
          const snapshot = await stripeSubscription(deps, knownID);
          if (emailFor(snapshot) !== userId) {
            throw new Error("Stripe identity changed");
          }
          return snapshot;
        })),
        getJson(
          deps,
          `https://api.revenuecat.com/v1/subscribers/${
            encodeURIComponent(userId)
          }`,
          deps.revenueCatKey,
        ),
      ]);
      const projection = mergeProviderProjections(
        revenueCatProjection(revenueCatBody, userId),
        projectStripeSubscriptions(
          snapshots,
          previous,
          new Date().toISOString(),
        ),
      );
      await deps.apply([{
        user_id: userId,
        expected_updated_date: row?.updated_date ?? null,
        data: {
          ...projection,
          stripe_last_event_id: event.id ?? null,
          stripe_last_event_type: event.type,
        },
      }]);
      return reply({ received: true });
    } catch {
      // Retry current truth after provider outages, unknown identities, malformed
      // snapshots, or revision conflicts. Never acknowledge a dropped invoice.
      return reply({
        error: "Subscription reconciliation failed; retry required.",
      }, 503);
    }
  };
}
