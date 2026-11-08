export type BillingData = Record<string, unknown>;

const statuses = new Set([
  "incomplete",
  "incomplete_expired",
  "trialing",
  "active",
  "past_due",
  "canceled",
  "unpaid",
  "paused",
]);

function timestamp(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error("Invalid Stripe billing period");
  }
  const parsed = new Date(value * 1000);
  if (!Number.isFinite(parsed.getTime())) {
    throw new Error("Invalid Stripe date");
  }
  return parsed.toISOString();
}

/** Only current provider snapshots enter this projection; event state is ignored. */
export function stripeSubscriptionProjection(
  snapshot: BillingData,
  observedAt: string,
): BillingData {
  if (
    typeof snapshot.id !== "string" || !snapshot.id ||
    typeof snapshot.status !== "string" || !statuses.has(snapshot.status) ||
    !Number.isFinite(Date.parse(observedAt))
  ) throw new Error("Invalid Stripe subscription");
  const active = snapshot.status === "active" || snapshot.status === "trialing";
  const start = timestamp(snapshot.current_period_start);
  const end = timestamp(snapshot.current_period_end);
  if (active && (!start || !end || Date.parse(end) <= Date.parse(start))) {
    throw new Error("Missing Stripe billing period");
  }
  const items = snapshot.items;
  const data = items && typeof items === "object" && !Array.isArray(items)
    ? (items as BillingData).data
    : undefined;
  const first = Array.isArray(data) ? data[0] : undefined;
  const price = first && typeof first === "object" ? first.price : undefined;
  const priceID =
    price && typeof price === "object" && typeof price.id === "string"
      ? price.id
      : null;
  const customer = typeof snapshot.customer === "string"
    ? snapshot.customer
    : null;
  if (!customer || !priceID) {
    throw new Error("Missing Stripe customer or price");
  }
  return {
    stripe_subscription_id: snapshot.id,
    stripe_customer_id: customer,
    stripe_price_id: priceID,
    stripe_plan: active ? "premium" : "free",
    stripe_status: snapshot.status,
    stripe_observed_at: observedAt,
    stripe_current_period_start: start,
    stripe_current_period_end: end,
    stripe_cancel_at_period_end: snapshot.cancel_at_period_end === true,
    plan: active ? "premium" : "free",
    status: snapshot.status,
    store: "stripe",
    current_period_start: start,
    current_period_end: end,
    cancel_at_period_end: active && snapshot.cancel_at_period_end === true,
  };
}

/** Preserve either provider's current grant; never OR historical database flags. */
export function mergeProviderProjections(
  revenueCat: BillingData,
  stripe: BillingData,
): BillingData {
  const useRevenueCat = stripe.plan !== "premium" &&
    revenueCat.plan === "premium";
  const effective = useRevenueCat ? revenueCat : stripe;
  return {
    ...revenueCat,
    ...stripe,
    plan: effective.plan,
    status: effective.status,
    store: effective.store,
    current_period_start: effective.current_period_start,
    current_period_end: effective.current_period_end,
    cancel_at_period_end: effective.cancel_at_period_end,
  };
}

/** Bounded known links, including the original single-link schema. */
export function knownStripeSubscriptionIDs(
  data: BillingData,
  additionalID?: string,
): string[] {
  const raw = data.stripe_subscription_ids ?? [];
  if (!Array.isArray(raw) || raw.some((id) => typeof id !== "string" || !id)) {
    throw new Error("Invalid Stripe subscription links");
  }
  const legacy = data.stripe_subscription_id;
  if (legacy != null && legacy !== "" && typeof legacy !== "string") {
    throw new Error("Invalid Stripe subscription link");
  }
  const ids = [
    ...new Set([
      ...raw,
      ...(typeof legacy === "string" && legacy ? [legacy] : []),
      ...(additionalID ? [additionalID] : []),
    ]),
  ].sort();
  if (ids.length > 20 || ids.some((id) => id.length > 1000)) {
    throw new Error("Too many Stripe subscription links");
  }
  return ids;
}

/** Keep known independent purchases and prune terminal history after observation. */
export function projectStripeSubscriptions(
  snapshots: BillingData[],
  previous: BillingData,
  observedAt: string,
): BillingData {
  if (!snapshots.length || snapshots.length > 20) {
    throw new Error("Invalid Stripe subscription set");
  }
  const projections = snapshots.map((s) =>
    stripeSubscriptionProjection(s, observedAt)
  );
  const legacy = previous.stripe_subscription_id;
  const eligible = projections.filter((p) => p.plan === "premium");
  const selected = eligible.find((p) => p.stripe_subscription_id === legacy) ??
    eligible[0] ??
    projections.find((p) => p.stripe_subscription_id === legacy) ??
    projections[0];
  const retained = projections.filter((p) =>
    p.stripe_status !== "canceled" &&
      p.stripe_status !== "incomplete_expired" ||
    p.stripe_subscription_id === selected.stripe_subscription_id
  ).map((p) => p.stripe_subscription_id as string).sort();
  return { ...selected, stripe_subscription_ids: [...new Set(retained)] };
}
