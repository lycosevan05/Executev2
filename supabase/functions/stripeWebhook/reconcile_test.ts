import { deepEqual, equal } from "node:assert/strict";
import { createStripeHandler, type StripeEvent } from "./reconcile.ts";
import type {
  SubscriptionChange,
  SubscriptionRow,
} from "../revenuecatWebhook/reconcile.ts";

// Isolated provider/RPC fixtures. These do not exercise real signatures,
// provider delivery, SQL concurrency, Apple Sandbox or native purchase sheets.
const email = "mixed-provider@example.com";
const now = "2026-11-08T09:00:00Z";
const before = "2026-11-08T08:00:00Z";
const after = "2026-11-08T10:00:00Z";
const entitlement = "Execute Performance Premium";
type Data = Record<string, unknown>;
function stripe(status = "active", id = "sub_current"): Data {
  return {
    id,
    status,
    customer: "cus_fixture",
    metadata: { user_id: email },
    items: { data: [{ price: { id: "price_fixture" } }] },
    current_period_start: Date.parse(before) / 1000,
    current_period_end: Date.parse(after) / 1000,
    cancel_at_period_end: false,
  };
}
function revenueCat(
  active = false,
  overrides: Data = {},
  subscriptionOverrides: Data = {},
): Data {
  return {
    request_date: now,
    subscriber: {
      entitlements: active
        ? {
          [entitlement]: {
            product_identifier: "native_month",
            purchase_date: before,
            expires_date: after,
            ...overrides,
          },
        }
        : {},
      subscriptions: {
        native_month: {
          store: "app_store",
          is_sandbox: true,
          period_type: "normal",
          unsubscribe_detected_at: null,
          ...subscriptionOverrides,
        },
      },
    },
  };
}
function fixture(type = "customer.subscription.updated") {
  const rows = new Map<string, SubscriptionRow>([[email, {
    data: {
      user_id: email,
      plan: "premium",
      status: "active",
      stripe_subscription_id: "sub_current",
      stripe_customer_id: "cus_fixture",
      unrelated: "retained",
    },
    updated_date: before,
  }]]);
  const subscriptions = new Map<string, Data>([["sub_current", stripe()]]);
  let rc = revenueCat();
  let rcStatus = 200;
  let providerFailure: string | null = null;
  const calls: string[] = [];
  const reads: string[] = [];
  const batches: SubscriptionChange[][] = [];
  const event: StripeEvent = {
    id: "evt_fixture",
    type,
    data: { object: stripe("past_due") },
  };
  const deps: Parameters<typeof createStripeHandler>[0] = {
    webhookSecret: "webhook-fixture",
    stripeKey: "stripe-fixture",
    revenueCatKey: "rc-fixture",
    verifyEvent(body, signature, secret) {
      equal(signature, "fixture-signature");
      equal(secret, "webhook-fixture");
      return Promise.resolve(JSON.parse(body));
    },
    fetch: ((input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      calls.push(url.href);
      const isStripe = url.hostname === "api.stripe.com";
      equal(
        new Headers(init?.headers).get("Authorization"),
        isStripe ? "Bearer stripe-fixture" : "Bearer rc-fixture",
      );
      if (providerFailure && url.hostname === providerFailure) {
        return Promise.resolve(
          new Response("temporary failure", { status: 503 }),
        );
      }
      if (isStripe) {
        const id = decodeURIComponent(url.pathname.split("/").at(-1)!);
        const subscription = subscriptions.get(id);
        return Promise.resolve(
          subscription
            ? Response.json(subscription)
            : new Response("missing subscription", { status: 404 }),
        );
      }
      equal(url.hostname, "api.revenuecat.com");
      equal(decodeURIComponent(url.pathname.split("/").at(-1)!), email);
      return Promise.resolve(Response.json(rc, { status: rcStatus }));
    }) as typeof fetch,
    read(userID) {
      reads.push(userID);
      return Promise.resolve(structuredClone(rows.get(userID) ?? null));
    },
    apply(changes) {
      for (const change of changes) {
        equal(
          rows.get(change.user_id)?.updated_date ?? null,
          change.expected_updated_date,
        );
      }
      batches.push(structuredClone(changes));
      for (const change of changes) {
        rows.set(change.user_id, {
          data: {
            ...rows.get(change.user_id)?.data,
            ...change.data,
            user_id: change.user_id,
          },
          updated_date: `revision-${batches.length}`,
        });
      }
      return Promise.resolve();
    },
  };
  const request = (signature: string | null = "fixture-signature") =>
    new Request("https://fixture.invalid/stripe", {
      method: "POST",
      headers: signature ? { "stripe-signature": signature } : {},
      body: JSON.stringify(event),
    });
  const row = () => rows.get(email)!.data;
  return {
    deps,
    event,
    rows,
    subscriptions,
    calls,
    reads,
    batches,
    request,
    row,
    rc(value: Data) {
      rc = value;
    },
    rcStatus(value: number) {
      rcStatus = value;
    },
    fail(host: string | null) {
      providerFailure = host;
    },
  };
}

Deno.test("Stripe deletion cannot remove independently current RevenueCat access", async () => {
  const f = fixture("customer.subscription.deleted");
  f.subscriptions.set("sub_current", stripe("canceled"));
  f.rc(revenueCat(true));
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.row().status, "active");
  equal(f.row().revenuecat_plan, "premium");
  equal(f.row().unrelated, "retained");
  equal(f.batches.length, 1);
  equal(f.batches[0].length, 1);
});

Deno.test("checkout and paid invoice cannot revive a canceled current Stripe subscription", async () => {
  for (
    const type of ["checkout.session.completed", "invoice.payment_succeeded"]
  ) {
    const f = fixture(type);
    f.event.data.object = {
      subscription: "sub_current",
      metadata: { user_id: email },
      customer: "cus_fixture",
    };
    f.subscriptions.set("sub_current", stripe("canceled"));
    equal((await createStripeHandler(f.deps)(f.request())).status, 200);
    equal(f.row().plan, "free", type);
    equal(f.row().status, "canceled", type);
    equal(f.batches.length, 1);
  }
});

Deno.test("invoice lookup failures request retry and make no reconciliation write", async () => {
  for (const type of ["invoice.payment_succeeded", "invoice.payment_failed"]) {
    const f = fixture(type);
    f.event.data.object = { subscription: "sub_current" };
    f.fail("api.stripe.com");
    equal((await createStripeHandler(f.deps)(f.request())).status, 503);
    equal(f.batches.length, 0);
    equal(f.row().status, "active");
  }
});

Deno.test("delayed subscription update projects current Stripe snapshot instead of stale payload", async () => {
  const f = fixture();
  f.event.data.object = stripe("past_due");
  f.subscriptions.set("sub_current", stripe("active"));
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.row().status, "active");
  equal(
    f.calls.some((url) => url.endsWith("/subscriptions/sub_current")),
    true,
  );
});

Deno.test("failed Stripe invoice retains valid RevenueCat access", async () => {
  const f = fixture("invoice.payment_failed");
  f.event.data.object = { subscription: "sub_current" };
  f.subscriptions.set("sub_current", stripe("past_due"));
  f.rc(revenueCat(true));
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.row().status, "active");
});

Deno.test("stale saved RevenueCat flags cannot retain an expired current entitlement", async () => {
  const f = fixture("customer.subscription.deleted");
  Object.assign(f.row(), {
    revenuecat_plan: "premium",
    revenuecat_status: "active",
  });
  f.subscriptions.set("sub_current", stripe("canceled"));
  f.rc(revenueCat(true, { expires_date: before }));
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "free");
  equal(f.row().status, "canceled");
});

Deno.test("RevenueCat grace preserves access only through its current provider grace expiry", async () => {
  for (const graceEnd of [after, before]) {
    const f = fixture("customer.subscription.deleted");
    f.subscriptions.set("sub_current", stripe("canceled"));
    f.rc(
      revenueCat(true, { expires_date: before }, {
        grace_period_expires_date: graceEnd,
      }),
    );
    equal((await createStripeHandler(f.deps)(f.request())).status, 200);
    equal(f.row().plan, graceEnd === after ? "premium" : "free");
  }
});

Deno.test("refund and reversal current snapshots compose correctly with independent Stripe access", async () => {
  for (const stripeStatus of ["active", "canceled"]) {
    for (const rcActive of [false, true]) {
      const f = fixture();
      f.subscriptions.set("sub_current", stripe(stripeStatus));
      f.rc(revenueCat(rcActive));
      equal((await createStripeHandler(f.deps)(f.request())).status, 200);
      equal(
        f.row().plan,
        stripeStatus === "active" || rcActive ? "premium" : "free",
      );
    }
  }
});

Deno.test("RevenueCat provider failure cannot cause guessed downgrade or acknowledgment", async () => {
  const f = fixture("customer.subscription.deleted");
  f.subscriptions.set("sub_current", stripe("canceled"));
  f.fail("api.revenuecat.com");
  equal((await createStripeHandler(f.deps)(f.request())).status, 503);
  equal(f.batches.length, 0);
  equal(f.row().plan, "premium");
});

Deno.test("duplicate delivery remains one customer row and reconciles current truth again", async () => {
  const f = fixture();
  const handle = createStripeHandler(f.deps);
  equal((await handle(f.request())).status, 200);
  f.subscriptions.set("sub_current", stripe("canceled"));
  equal((await handle(f.request())).status, 200);
  equal(f.rows.size, 1);
  equal(f.row().plan, "free");
  equal(f.batches.length, 2);
  equal(f.row().stripe_last_event_id, "evt_fixture");
});

Deno.test("revision conflicts request retry without accepting stale entitlement projection", async () => {
  const f = fixture();
  const original = structuredClone(f.row());
  f.deps.apply = () => Promise.reject(new Error("40001 revision conflict"));
  equal((await createStripeHandler(f.deps)(f.request())).status, 503);
  equal(f.batches.length, 0);
  deepEqual(f.row(), original);
});

Deno.test("interrupted incomplete Stripe purchase grants nothing and current active recovery grants once", async () => {
  const f = fixture("checkout.session.completed");
  f.event.data.object = {
    subscription: "sub_current",
    metadata: { user_id: email },
  };
  f.subscriptions.set("sub_current", stripe("incomplete"));
  const handle = createStripeHandler(f.deps);
  equal((await handle(f.request())).status, 200);
  equal(f.row().plan, "free");
  f.subscriptions.set("sub_current", stripe("active"));
  f.event.type = "invoice.payment_succeeded";
  f.event.id = "evt_recovered";
  equal((await handle(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.rows.size, 1);
});

Deno.test("late old subscription deletion preserves a currently active replacement subscription", async () => {
  const f = fixture("customer.subscription.deleted");
  f.event.data.object = stripe("canceled", "sub_old");
  f.subscriptions.set("sub_old", stripe("canceled", "sub_old"));
  f.subscriptions.set("sub_current", stripe("active"));
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.row().stripe_subscription_id, "sub_current");
});

Deno.test("missing replacement provider snapshot requests retry rather than switching to old subscription", async () => {
  const f = fixture("customer.subscription.deleted");
  f.event.data.object = stripe("canceled", "sub_old");
  f.subscriptions.set("sub_old", stripe("canceled", "sub_old"));
  f.subscriptions.delete("sub_current");
  equal((await createStripeHandler(f.deps)(f.request())).status, 503);
  equal(f.batches.length, 0);
});

Deno.test("Stripe current subscription identity mismatch cannot grant or alter another account", async () => {
  const f = fixture("checkout.session.completed");
  f.event.data.object = {
    subscription: "sub_current",
    metadata: { user_id: email },
  };
  f.subscriptions.set("sub_current", {
    ...stripe(),
    metadata: { user_id: "different@example.com" },
  });
  const response = await createStripeHandler(f.deps)(f.request());
  equal(response.status >= 400, true);
  equal(f.batches.length, 0);
});

Deno.test("missing signature is rejected before provider lookup or subscription read", async () => {
  const f = fixture();
  equal((await createStripeHandler(f.deps)(f.request(null))).status, 400);
  equal(f.calls.length, 0);
  equal(f.reads.length, 0);
  equal(f.batches.length, 0);
});

Deno.test("identity bootstrap snapshot cannot overwrite newer provider state observed after row read", async () => {
  const f = fixture("invoice.payment_succeeded");
  f.event.data.object = { subscription: "sub_current" };
  const read = f.deps.read;
  f.deps.read = async (userID) => {
    const row = await read(userID);
    // The bootstrap lookup was active. A concurrent lifecycle change completed
    // before this revision was read; the reconciliation must fetch truth again.
    f.subscriptions.set("sub_current", stripe("canceled"));
    return row;
  };
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "free");
  equal(f.row().status, "canceled");
});

Deno.test("current subscription grace wins over contradictory older entitlement grace", async () => {
  const f = fixture("customer.subscription.deleted");
  f.subscriptions.set("sub_current", stripe("canceled"));
  f.rc(
    revenueCat(
      true,
      { expires_date: before, grace_period_expires_date: after },
      { grace_period_expires_date: before },
    ),
  );
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "free");
});

Deno.test("known independent Stripe trial preserves access when other subscription ends and terminal history prunes", async () => {
  const f = fixture("customer.subscription.deleted");
  f.row().stripe_subscription_ids = [
    "sub_current",
    "sub_independent",
    "sub_terminal",
  ];
  f.subscriptions.set("sub_current", stripe("canceled"));
  f.subscriptions.set("sub_independent", stripe("trialing", "sub_independent"));
  f.subscriptions.set(
    "sub_terminal",
    stripe("incomplete_expired", "sub_terminal"),
  );
  equal((await createStripeHandler(f.deps)(f.request())).status, 200);
  equal(f.row().plan, "premium");
  equal(f.row().status, "trialing");
  equal(f.row().stripe_subscription_id, "sub_independent");
  deepEqual(f.row().stripe_subscription_ids, ["sub_independent"]);
});

Deno.test("RevenueCat created customer201 is current empty truth while404 remains retryable error", async () => {
  for (const status of [201, 404]) {
    const f = fixture("customer.subscription.deleted");
    f.rcStatus(status);
    f.subscriptions.set("sub_current", stripe("canceled"));
    equal(
      (await createStripeHandler(f.deps)(f.request())).status,
      status === 201 ? 200 : 503,
    );
    equal(f.batches.length, status === 201 ? 1 : 0);
    equal(f.row().plan, status === 201 ? "free" : "premium");
  }
});

Deno.test("malformed current Stripe customer or price cannot erase existing metadata or grant access", async () => {
  for (const field of ["customer", "items"]) {
    const f = fixture();
    const malformed = stripe();
    delete malformed[field];
    f.subscriptions.set("sub_current", malformed);
    equal((await createStripeHandler(f.deps)(f.request())).status, 503);
    equal(f.batches.length, 0);
    equal(f.row().stripe_customer_id, "cus_fixture");
  }
});

Deno.test("excessive known Stripe subscription links retry without partial projection", async () => {
  const f = fixture();
  f.row().stripe_subscription_ids = Array.from(
    { length: 21 },
    (_, i) => `sub_${i}`,
  );
  equal((await createStripeHandler(f.deps)(f.request())).status, 503);
  equal(f.batches.length, 0);
  equal(f.row().plan, "premium");
});
