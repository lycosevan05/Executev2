export interface RevenueCatEvent {
  id?: string;
  type: string;
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
export interface Dependencies {
  webhookSecret?: string;
  revenueCatKey?: string;
  stripeKey?: string;
  fetch: typeof fetch;
  read: (userId: string) => Promise<SubscriptionRow | null>;
  apply: (changes: SubscriptionChange[]) => Promise<void>;
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
): Promise<Data> {
  const response = await deps.fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`,
      "Cache-Control": "no-cache",
      ...extra,
    },
    signal: AbortSignal.timeout(8000),
  });
  if (response.status !== 200) throw new Error("Provider lookup failed");
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
    const expires = date(entitlement.expires_date);
    const grace = date(entitlement.grace_period_expires_date ?? null);
    end = expires === null
      ? null
      : (grace && Date.parse(grace) > Date.parse(expires) ? grace : expires);
    start = date(entitlement.purchase_date);
    active = end === null || Date.parse(end) > now;
    if (subscriptions[product] !== undefined) {
      subscription = object(subscriptions[product]);
    }
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
  const projection = revenueCatProjection(body, userId);
  const stripeId = row?.data.stripe_subscription_id;
  if (stripeId != null && stripeId !== "") {
    if (typeof stripeId !== "string" || !deps.stripeKey) {
      throw new Error("Stripe reconciliation unavailable");
    }
    const stripe = await getJson(
      deps,
      `https://api.stripe.com/v1/subscriptions/${encodeURIComponent(stripeId)}`,
      deps.stripeKey,
      { "Stripe-Version": "2024-04-10" },
    );
    if (stripe.id !== stripeId || typeof stripe.status !== "string") {
      throw new Error("Invalid Stripe subscription");
    }
    if (stripe.status === "active" || stripe.status === "trialing") {
      if (
        typeof stripe.current_period_start !== "number" ||
        typeof stripe.current_period_end !== "number"
      ) {
        throw new Error("Missing Stripe billing period");
      }
      Object.assign(projection, {
        plan: "premium",
        status: stripe.status,
        store: "stripe",
        current_period_start: new Date(stripe.current_period_start * 1000)
          .toISOString(),
        current_period_end: new Date(stripe.current_period_end * 1000)
          .toISOString(),
        cancel_at_period_end: stripe.cancel_at_period_end === true,
      });
    }
  }
  return {
    user_id: userId,
    expected_updated_date: row?.updated_date ?? null,
    data: {
      ...projection,
      revenuecat_last_event_id: event.id ?? null,
      revenuecat_last_event_type: event.type,
    },
  };
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
    let users: string[];
    try {
      const payload = object(await req.json());
      event = object(payload.event) as unknown as RevenueCatEvent;
      if (typeof event.type !== "string" || !event.type) {
        throw new Error("Missing event type");
      }
      if (!handledTypes.has(event.type)) {
        return reply({ received: true, skipped: event.type });
      }
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
