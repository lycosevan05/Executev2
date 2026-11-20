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
  livemode?: boolean;
  data: { object: BillingData };
}

export type BillingEnvironment = "SANDBOX" | "PRODUCTION";

export interface VerifiedStripeChange {
  owner_id: string;
  customer_id: string;
  expected_email: string;
  expected_updated_date: string | null;
  data: BillingData;
}

interface VerifiedStripeWriter {
  environment: BillingEnvironment;
  read(ownerId: string): Promise<unknown>;
  apply(changes: VerifiedStripeChange[]): Promise<void>;
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
  verified?: VerifiedStripeWriter | false;
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

const canonicalUUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

function ownerFor(stripeObject: BillingData): string {
  const owner = object(stripeObject.metadata).execute_owner_uuid;
  if (typeof owner !== "string" || !canonicalUUID.test(owner)) {
    throw new Error("Stripe owner binding is unavailable");
  }
  return owner;
}

function requireStripeEnvironment(value: unknown, env: BillingEnvironment) {
  if (value !== (env === "PRODUCTION")) {
    throw new Error("Stripe environment mismatch");
  }
}

async function getJson(
  deps: StripeDependencies,
  url: string,
  key: string,
  stripe = false,
  environment?: BillingEnvironment,
): Promise<BillingData> {
  const response = await deps.fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`,
      "Cache-Control": "no-cache",
      ...(stripe ? { "Stripe-Version": "2024-04-10" } : {}),
      ...(environment
        ? { "X-Is-Sandbox": String(environment === "SANDBOX") }
        : {}),
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

async function verifyStripeCustomer(
  deps: StripeDependencies,
  id: string,
  owner: string,
  email: string,
  environment: BillingEnvironment,
): Promise<void> {
  const customer = await getJson(
    deps,
    `https://api.stripe.com/v1/customers/${encodeURIComponent(id)}`,
    deps.stripeKey!,
    true,
  );
  requireStripeEnvironment(customer.livemode, environment);
  if (
    customer.id !== id || customer.deleted === true ||
    ownerFor(customer) !== owner || emailFor(customer) !== email
  ) {
    throw new Error("Stripe customer ownership changed");
  }
}

async function reconcileVerifiedStripe(
  deps: StripeDependencies,
  writer: VerifiedStripeWriter,
  event: StripeEvent,
  signed: BillingData,
  id: string,
): Promise<boolean> {
  const { environment } = writer;
  requireStripeEnvironment(event.livemode, environment);
  const initial = await stripeSubscription(deps, id);
  requireStripeEnvironment(initial.livemode, environment);
  const owner = ownerFor(initial);
  const email = emailFor(initial);
  const initialCustomer = identifier(initial.customer);
  if (!initialCustomer) throw new Error("Missing Stripe customer");
  if (
    signed.customer != null && identifier(signed.customer) !== initialCustomer
  ) {
    throw new Error("Stripe event customer mismatch");
  }
  if (signed.metadata != null) {
    const metadata = object(signed.metadata);
    if (
      (metadata.execute_owner_uuid !== undefined &&
        metadata.execute_owner_uuid !== owner) ||
      (metadata.user_id !== undefined && metadata.user_id !== email)
    ) throw new Error("Stripe event identity mismatch");
  }
  await verifyStripeCustomer(deps, initialCustomer, owner, email, environment);
  const subject = object(await writer.read(owner));
  if (subject.state === "retired") return false;
  const rcCustomer = subject.customer_id;
  if (
    subject.state !== "active" || subject.owner_id !== owner ||
    subject.email !== email || subject.environment !== environment ||
    typeof rcCustomer !== "string" || !canonicalUUID.test(rcCustomer) ||
    rcCustomer === owner
  ) throw new Error("Verified billing subject is unavailable");
  const row = subject.subscription === null
    ? null
    : object(subject.subscription);
  const previous = row ? object(row.data) : {};
  const updatedDate = row === null ? null : row.updated_date;
  if (
    updatedDate !== null &&
    (typeof updatedDate !== "string" ||
      !Number.isFinite(Date.parse(updatedDate)))
  ) {
    throw new Error("Invalid billing projection revision");
  }
  if (row && updatedDate === null) {
    throw new Error("Missing billing projection revision");
  }

  // Read provider state again after the projection revision is known, and
  // validate every Stripe customer represented by the resulting batch.
  const confirmedCustomers = new Map<string, Promise<void>>();
  const ids = knownStripeSubscriptionIDs(previous, id);
  const [snapshots, rcBody] = await Promise.all([
    Promise.all(ids.map(async (knownID) => {
      const snapshot = await stripeSubscription(deps, knownID);
      requireStripeEnvironment(snapshot.livemode, environment);
      const customer = identifier(snapshot.customer);
      if (
        ownerFor(snapshot) !== owner || emailFor(snapshot) !== email ||
        !customer ||
        (knownID === id && customer !== initialCustomer)
      ) throw new Error("Stripe identity changed");
      let confirmation = confirmedCustomers.get(customer);
      if (!confirmation) {
        confirmation = verifyStripeCustomer(
          deps,
          customer,
          owner,
          email,
          environment,
        );
        confirmedCustomers.set(customer, confirmation);
      }
      await confirmation;
      return snapshot;
    })),
    getJson(
      deps,
      `https://api.revenuecat.com/v1/subscribers/${
        encodeURIComponent(rcCustomer)
      }`,
      deps.revenueCatKey!,
      false,
      environment,
    ),
  ]);
  const rcProjection = revenueCatProjection(rcBody, rcCustomer);
  if (
    rcProjection.revenuecat_plan === "premium" &&
    rcProjection.revenuecat_environment !== environment
  ) {
    throw new Error("RevenueCat environment mismatch");
  }
  const projection = mergeProviderProjections(
    rcProjection,
    projectStripeSubscriptions(snapshots, previous, new Date().toISOString()),
  );
  await writer.apply([{
    owner_id: owner,
    customer_id: rcCustomer,
    expected_email: email,
    expected_updated_date: updatedDate,
    data: {
      ...projection,
      stripe_last_event_id: event.id ?? null,
      stripe_last_event_type: event.type,
    },
  }]);
  return true;
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
        livemode: typeof verified.livemode === "boolean"
          ? verified.livemode
          : undefined,
        data: { object: object(object(verified.data).object) },
      };
    } catch {
      return reply({ error: "Webhook signature verification failed." }, 400);
    }
    if (!handledTypes.has(event.type)) {
      return reply({ received: true, skipped: event.type });
    }
    if (deps.verified === false || !deps.stripeKey || !deps.revenueCatKey) {
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
      if (deps.verified) {
        const applied = await reconcileVerifiedStripe(
          deps,
          deps.verified,
          event,
          payload,
          id,
        );
        return reply(
          applied
            ? { received: true }
            : { received: true, skipped: "verified_retired_owner" },
        );
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
