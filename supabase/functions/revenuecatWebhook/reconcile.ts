import {
  knownStripeSubscriptionIDs,
  mergeProviderProjections,
  projectStripeSubscriptions,
} from "../_shared/billingProjection.ts";

export interface RevenueCatEvent {
  id?: string;
  type: string;
  app_id?: string;
  environment?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  transferred_from?: string[];
  transferred_to?: string[];
}

type Data = Record<string, unknown>;
export interface SubscriptionRow {
  data: Data;
  updated_date: string;
}
export interface SubscriptionChange {
  user_id: string;
  expected_updated_date: string | null;
  data: Data;
}
export type BillingEnvironment = "SANDBOX" | "PRODUCTION";

export interface VerifiedSubscriptionChange {
  owner_id: string;
  customer_id: string;
  expected_email: string | null;
  expected_updated_date: string | null;
  data: Data;
}

export interface VerifiedReconciliation {
  appId: string;
  environment: BillingEnvironment;
  products: ReadonlySet<string>;
  resolve: (identifier: string) => Promise<unknown>;
  apply: (changes: VerifiedSubscriptionChange[]) => Promise<void>;
}

export interface Dependencies {
  webhookSecret?: string;
  revenueCatKey?: string;
  stripeKey?: string;
  fetch: typeof fetch;
  read: (userId: string) => Promise<SubscriptionRow | null>;
  apply: (changes: SubscriptionChange[]) => Promise<void>;
  // Absent uses the legacy integration. Null denotes incomplete verified configuration.
  verified?: VerifiedReconciliation | null;
}

const handledTypes = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "SUBSCRIPTION_EXTENDED",
  "TEMPORARY_ENTITLEMENT_GRANT",
  "NON_RENEWING_PURCHASE",
  "REFUND_REVERSED",
  "CANCELLATION",
  "EXPIRATION",
  "BILLING_ISSUE",
  "SUBSCRIPTION_PAUSED",
  "TRANSFER",
]);
const entitlementId = "Execute Performance Premium";

function object(value: unknown): Data {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid provider response");
  }
  return value as Data;
}

function ids(value: unknown): string[] {
  if (
    !Array.isArray(value) || value.length > 100 ||
    !value.every((id) =>
      typeof id === "string" && id.length > 0 && id.length <= 1000
    )
  ) {
    throw new Error("Invalid customer IDs");
  }
  return value;
}

export function affectedEmails(event: RevenueCatEvent): string[] {
  let candidates: string[];
  if (event.type === "TRANSFER") {
    const from = ids(event.transferred_from);
    const to = ids(event.transferred_to);
    if (!from.length || !to.length) {
      throw new Error("Missing transfer participants");
    }
    candidates = [...from, ...to];
  } else {
    candidates = [event.app_user_id, event.original_app_user_id]
      .filter((id): id is string => typeof id === "string");
    if (event.aliases !== undefined) candidates.push(...ids(event.aliases));
  }
  // App identity is the unchanged Supabase email, never an RC anonymous ID.
  return [...new Set(candidates.filter((id) => /^[^\s@]+@[^\s@]+$/.test(id)))]
    .sort();
}

function date(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) {
    throw new Error("Invalid provider date");
  }
  return value;
}

async function getJson(
  deps: Dependencies,
  url: string,
  key: string,
  extra: Record<string, string> = {},
  acceptCreatedCustomer = true,
): Promise<Data> {
  const response = await deps.fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`,
      "Cache-Control": "no-cache",
      ...extra,
    },
    signal: AbortSignal.timeout(8000),
  });
  const acceptedCreatedCustomer = acceptCreatedCustomer &&
    url.startsWith("https://api.revenuecat.com/v1/subscribers/") &&
    response.status === 201;
  if (response.status !== 200 && !acceptedCreatedCustomer) {
    throw new Error("Provider lookup failed");
  }
  return object(await response.json());
}

export function revenueCatProjection(body: Data, userId: string): Data {
  const subscriber = object(body.subscriber);
  const entitlements = object(subscriber.entitlements);
  const subscriptions = object(subscriber.subscriptions);
  const observedAt = date(body.request_date);
  if (!observedAt) throw new Error("Missing provider observation time");
  const now = Date.parse(observedAt);
  const rawEntitlement = entitlements[entitlementId];
  let active = false;
  let product: string | null = null;
  let end: string | null = null;
  let start: string | null = null;
  let subscription: Data = {};
  if (rawEntitlement !== undefined) {
    const entitlement = object(rawEntitlement);
    if (
      typeof entitlement.product_identifier !== "string" ||
      !entitlement.product_identifier
    ) {
      throw new Error("Invalid entitlement product");
    }
    product = entitlement.product_identifier;
    if (subscriptions[product] !== undefined) {
      subscription = object(subscriptions[product]);
    }
    const expires = date(entitlement.expires_date);
    // Current subscription grace (including explicit null) takes precedence;
    // older responses without that field retain the entitlement-level fallback.
    const grace = date(
      Object.hasOwn(subscription, "grace_period_expires_date")
        ? subscription.grace_period_expires_date
        : entitlement.grace_period_expires_date ?? null,
    );
    end = expires === null
      ? null
      : (grace && Date.parse(grace) > Date.parse(expires) ? grace : expires);
    start = date(entitlement.purchase_date);
    active = end === null || Date.parse(end) > now;
  }
  const status = active
    ? (subscription.period_type === "trial" ? "trialing" : "active")
    : "canceled";
  return {
    revenuecat_app_user_id: userId,
    revenuecat_product_id: product,
    revenuecat_environment: typeof subscription.is_sandbox === "boolean"
      ? (subscription.is_sandbox ? "SANDBOX" : "PRODUCTION")
      : null,
    revenuecat_plan: active ? "premium" : "free",
    revenuecat_status: status,
    revenuecat_observed_at: observedAt,
    plan: active ? "premium" : "free",
    status,
    store: typeof subscription.store === "string"
      ? subscription.store
      : "app_store",
    current_period_start: start,
    current_period_end: end,
    cancel_at_period_end: active &&
      (subscription.unsubscribe_detected_at != null ||
        !Object.keys(subscription).length),
  };
}

async function changeFor(
  deps: Dependencies,
  userId: string,
  event: RevenueCatEvent,
): Promise<SubscriptionChange> {
  // Read before network requests. The DB rejects this whole batch if any row
  // changes while providers are being read, including concurrent Stripe writes.
  const row = await deps.read(userId);
  const body = await getJson(
    deps,
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
    deps.revenueCatKey!,
  );
  let projection = revenueCatProjection(body, userId);
  projection = await mergeCurrentStripe(deps, row, projection, (snapshot) => {
    if (snapshot.metadata != null) {
      const metadata = object(snapshot.metadata);
      if (metadata.user_id != null && metadata.user_id !== userId) {
        throw new Error("Stripe subscription identity mismatch");
      }
    }
  });
  return {
    user_id: userId,
    expected_updated_date: row?.updated_date ?? null,
    data: eventProjection(projection, event),
  };
}

async function mergeCurrentStripe(
  deps: Dependencies,
  row: SubscriptionRow | null,
  projection: Data,
  checkOwner: (snapshot: Data) => void,
): Promise<Data> {
  const stripeIDs = knownStripeSubscriptionIDs(row?.data ?? {});
  if (!stripeIDs.length) return projection;
  if (!deps.stripeKey) throw new Error("Stripe reconciliation unavailable");
  const snapshots = await Promise.all(stripeIDs.map(async (id) => {
    const stripe = await getJson(
      deps,
      `https://api.stripe.com/v1/subscriptions/${encodeURIComponent(id)}`,
      deps.stripeKey!,
      { "Stripe-Version": "2024-04-10" },
    );
    if (stripe.id !== id) throw new Error("Invalid Stripe subscription");
    checkOwner(stripe);
    return stripe;
  }));
  return mergeProviderProjections(
    projection,
    projectStripeSubscriptions(
      snapshots,
      row?.data ?? {},
      projection.revenuecat_observed_at as string,
    ),
  );
}

function eventProjection(projection: Data, event: RevenueCatEvent): Data {
  return {
    ...projection,
    revenuecat_last_event_id: event.id ?? null,
    revenuecat_last_event_type: event.type,
  };
}

interface ActiveSubject {
  state: "active";
  owner_id: string;
  customer_id: string;
  email: string | null;
  subscription: SubscriptionRow | null;
}

type VerifiedSubject = ActiveSubject | {
  state: "retired" | "blocked" | "unresolved";
};

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const anonymousId =
  /^\$RCAnonymousID:(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$/;

function providerId(value: unknown): string {
  if (
    typeof value !== "string" || !value.length || value.length > 100 ||
    value !== value.trim() || /[\p{Cc}/]/u.test(value)
  ) {
    throw new Error("Invalid verified customer ID");
  }
  return value;
}

function verifiedGroups(event: RevenueCatEvent): string[][] {
  const groups = event.type === "TRANSFER"
    ? [ids(event.transferred_from), ids(event.transferred_to)]
    : [[
      ...[event.app_user_id, event.original_app_user_id].filter(
        (id) => id !== undefined,
      ),
      ...(event.aliases === undefined ? [] : ids(event.aliases)),
    ]];
  const normalized = groups.map((group) =>
    [...new Set(group.map(providerId))].sort()
  );
  if (
    normalized.some((group) => !group.length) ||
    new Set(normalized.flat()).size > 24
  ) {
    throw new Error("Invalid verified customer group");
  }
  return normalized;
}

function readVerifiedSubject(
  value: unknown,
  expectedEnvironment: BillingEnvironment,
): VerifiedSubject {
  const subject = object(value);
  if (
    subject.state === "retired" || subject.state === "blocked" ||
    subject.state === "unresolved"
  ) return { state: subject.state };
  const { state, owner_id, customer_id, email } = subject;
  if (
    state !== "active" || subject.environment !== expectedEnvironment ||
    typeof owner_id !== "string" || !uuid.test(owner_id) ||
    typeof customer_id !== "string" || !uuid.test(customer_id) ||
    owner_id === customer_id || (email != null && typeof email !== "string")
  ) throw new Error("Invalid verified customer binding");
  let subscription: SubscriptionRow | null = null;
  if (subject.subscription !== null) {
    const row = object(subject.subscription);
    const data = object(row.data);
    if (
      typeof row.updated_date !== "string" ||
      !Number.isFinite(Date.parse(row.updated_date)) ||
      data.user_id !== owner_id
    ) throw new Error("Invalid verified subscription readback");
    subscription = { data, updated_date: row.updated_date };
  }
  return { state, owner_id, customer_id, email: email ?? null, subscription };
}

function sameBinding(first: ActiveSubject, second: ActiveSubject): boolean {
  return first.owner_id === second.owner_id &&
    first.customer_id === second.customer_id &&
    first.email === second.email &&
    first.subscription?.updated_date === second.subscription?.updated_date;
}

async function reconcileVerified(
  deps: Dependencies,
  verified: VerifiedReconciliation,
  event: RevenueCatEvent,
): Promise<boolean> {
  if (
    event.app_id !== verified.appId ||
    event.environment !== verified.environment
  ) throw new Error("Webhook app or environment is unconfirmed");
  if (!deps.revenueCatKey) {
    throw new Error("Customer reconciliation is unavailable");
  }

  // Reuse exact lookups across transfer sides and the provider's returned original ID.
  const resolutions = new Map<string, Promise<VerifiedSubject>>();
  const resolve = (identifier: string) => {
    const recorded = resolutions.get(identifier);
    if (recorded) return recorded;
    const pending = verified.resolve(identifier).then((value) =>
      readVerifiedSubject(value, verified.environment)
    );
    resolutions.set(identifier, pending);
    return pending;
  };

  const owners = new Map<string, ActiveSubject>();
  for (const group of verifiedGroups(event)) {
    const resolved = await Promise.all(group.map(async (identifier) => ({
      identifier,
      subject: await resolve(identifier),
    })));
    let active: ActiveSubject | undefined;
    let retired = false;
    for (const { identifier, subject } of resolved) {
      if (subject.state === "active") {
        if (active && !sameBinding(subject, active)) {
          throw new Error("Customer group spans conflicting bindings");
        }
        active = subject;
      } else if (subject.state === "retired") {
        retired = true;
      } else if (
        subject.state !== "unresolved" || !anonymousId.test(identifier)
      ) {
        throw new Error("Customer group ownership is unconfirmed");
      }
    }
    if (active) {
      const previous = owners.get(active.owner_id);
      if (retired || (previous && !sameBinding(active, previous))) {
        throw new Error("Customer group spans conflicting bindings");
      }
      owners.set(active.owner_id, active);
    } else if (!retired) {
      throw new Error("No verified customer in group");
    }
  }
  if (!owners.size) return false;

  const changes = await Promise.all(
    [...owners.values()].map(async (subject) => {
      const body = await getJson(
        deps,
        `https://api.revenuecat.com/v1/subscribers/${
          encodeURIComponent(subject.customer_id)
        }`,
        deps.revenueCatKey!,
        verified.environment === "SANDBOX" ? { "X-Is-Sandbox": "true" } : {},
        false,
      );
      const subscriber = object(body.subscriber);
      const original = providerId(subscriber.original_app_user_id);
      if (original !== subject.customer_id) {
        const identity = await resolve(original);
        if (
          !(identity.state === "active" && sameBinding(subject, identity)) &&
          !(identity.state === "unresolved" && anonymousId.test(original))
        ) throw new Error("RevenueCat subscriber ownership mismatch");
      }
      let projection = revenueCatProjection(body, subject.customer_id);
      const product = projection.revenuecat_product_id;
      if (
        product !== null && (typeof product !== "string" ||
          !verified.products.has(product) ||
          object(object(subscriber.subscriptions)[product]).store !==
            "app_store" ||
          (projection.revenuecat_plan === "premium" &&
            projection.revenuecat_environment !== verified.environment) ||
          (projection.revenuecat_environment !== null &&
            projection.revenuecat_environment !== verified.environment))
      ) throw new Error("Unconfirmed RevenueCat entitlement scope");

      projection = await mergeCurrentStripe(
        deps,
        subject.subscription,
        projection,
        (snapshot) => {
          const metadata = object(snapshot.metadata);
          if (
            metadata.execute_owner_uuid !== subject.owner_id ||
            (metadata.user_id !== subject.owner_id &&
              (subject.email === null || metadata.user_id !== subject.email)) ||
            snapshot.livemode !== (verified.environment === "PRODUCTION")
          ) throw new Error("Unconfirmed Stripe owner or environment");
        },
      );
      return {
        owner_id: subject.owner_id,
        customer_id: subject.customer_id,
        expected_email: subject.email,
        expected_updated_date: subject.subscription?.updated_date ?? null,
        data: eventProjection(projection, event),
      };
    }),
  );
  // The service-only RPC rechecks retirement, canonical ID and each revision.
  await verified.apply(changes);
  return true;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function createHandler(
  deps: Dependencies,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const reply = (data: Data, status = 200) => Response.json(data, { status });
    if (!deps.webhookSecret) {
      return reply({ error: "Webhook authentication is not configured." }, 500);
    }
    if (
      !constantTimeEqual(
        req.headers.get("authorization") ?? "",
        `Bearer ${deps.webhookSecret}`,
      )
    ) {
      return reply({ error: "Unauthorized" }, 401);
    }
    let event: RevenueCatEvent;
    try {
      const payload = object(await req.json());
      event = object(payload.event) as unknown as RevenueCatEvent;
      if (typeof event.type !== "string" || !event.type) {
        throw new Error("Missing event type");
      }
      if (!handledTypes.has(event.type)) {
        return reply({ received: true, skipped: event.type });
      }
    } catch {
      return reply({ error: "Invalid event payload." }, 400);
    }
    if (deps.verified !== undefined) {
      try {
        if (deps.verified === null) {
          throw new Error("Verified billing is not configured");
        }
        const applied = await reconcileVerified(deps, deps.verified, event);
        return reply(
          applied ? { received: true } : {
            received: true,
            skipped: "retired_subjects",
          },
        );
      } catch {
        return reply({
          error: "Subscription reconciliation failed; retry required.",
        }, 503);
      }
    }
    let users: string[];
    try {
      users = affectedEmails(event);
    } catch {
      return reply({ error: "Invalid event payload." }, 400);
    }
    if (!users.length) {
      return reply({ received: true, skipped: "no_email_app_user_id" });
    }
    if (!deps.revenueCatKey) {
      return reply(
        { error: "Customer reconciliation is not configured." },
        503,
      );
    }
    try {
      // Fetch every participant successfully before writing anything. One RPC
      // transaction applies both transfer sides, or none. Retries always fetch
      // current state; event payloads cannot replay an obsolete grant/revocation.
      const changes = await Promise.all(
        users.map((user) => changeFor(deps, user, event)),
      );
      await deps.apply(changes);
      return reply({ received: true });
    } catch {
      // Non-2xx asks RevenueCat to retry. Never acknowledge a partial transfer,
      // missing key, provider outage, malformed response, or DB revision conflict.
      return reply({
        error: "Subscription reconciliation failed; retry required.",
      }, 503);
    }
  };
}
