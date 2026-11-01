import { deepEqual, equal } from "node:assert/strict";
import {
  affectedEmails,
  createHandler,
  type Dependencies,
  revenueCatProjection,
  type SubscriptionChange,
  type SubscriptionRow,
} from "./reconcile.ts";

const a = "a@example.com";
const b = "b@example.com";
const now = "2026-10-21T21:00:00Z";
const end = "2026-10-21T22:00:00Z";
const entitlement = "Execute Performance Premium";
function snapshot(active = true, overrides: Record<string, unknown> = {}) {
  return {
    request_date: now,
    subscriber: {
      entitlements: active
        ? {
          [entitlement]: {
            product_identifier: "native_month",
            purchase_date: now,
            expires_date: end,
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
        },
      },
    },
  };
}
function fixture() {
  const rows = new Map<string, SubscriptionRow>([[a, {
    data: { plan: "premium", status: "active", user_id: a },
    updated_date: "2026-10-21T20:00:00Z",
  }]]);
  const snapshots = new Map([[a, snapshot(false)], [b, snapshot()]]);
  const reads: string[] = [];
  const calls: string[] = [];
  let writes = 0;
  const deps: Dependencies = {
    webhookSecret: "test-secret",
    revenueCatKey: "server-key",
    stripeKey: "stripe-key",
    fetch: ((input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      calls.push(url.href);
      equal(
        new Headers(init?.headers).get("Authorization"),
        url.hostname === "api.stripe.com"
          ? "Bearer stripe-key"
          : "Bearer server-key",
      );
      if (url.hostname === "api.stripe.com") {
        return Promise.resolve(Response.json({
          id: "sub_existing",
          status: "active",
          current_period_start: 1792616400,
          current_period_end: 1792702800,
        }));
      }
      const userId = decodeURIComponent(url.pathname.split("/").at(-1)!);
      return Promise.resolve(Response.json(snapshots.get(userId)));
    }) as typeof fetch,
    read(userId) {
      reads.push(userId);
      return Promise.resolve(structuredClone(rows.get(userId) ?? null));
    },
    apply(changes) {
      writes++;
      for (const change of changes) {
        equal(
          rows.get(change.user_id)?.updated_date ?? null,
          change.expected_updated_date,
        );
      }
      for (const change of changes) {
        rows.set(change.user_id, {
          data: {
            ...rows.get(change.user_id)?.data,
            ...change.data,
            user_id: change.user_id,
          },
          updated_date: `revision-${writes}`,
        });
      }
      return Promise.resolve();
    },
  };
  const event = {
    id: "transfer-1",
    type: "TRANSFER",
    transferred_from: ["$RCAnonymousID:old", a],
    transferred_to: [b, "$RCAnonymousID:new"],
  };
  const request = (body: unknown = { event }, auth = "Bearer test-secret") =>
    new Request("https://webhook.test", {
      method: "POST",
      headers: { Authorization: auth },
      body: JSON.stringify(body),
    });
  return {
    rows,
    snapshots,
    deps,
    reads,
    calls,
    event,
    request,
    writes: () => writes,
  };
}

Deno.test("TRANSFER without app_user_id revokes source and grants destination in one batch", async () => {
  const f = fixture();
  let batch: SubscriptionChange[] = [];
  const apply = f.deps.apply;
  f.deps.apply = async (changes) => {
    batch = changes;
    await apply(changes);
  };
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(batch.length, 2);
  equal(f.writes(), 1);
  equal(f.rows.get(a)?.data.plan, "free");
  equal(f.rows.get(b)?.data.plan, "premium");
  equal(f.rows.get(b)?.data.revenuecat_environment, "SANDBOX");
  equal(f.rows.size, 2);
});
Deno.test("source keeps access when RevenueCat reports another active entitlement purchase", async () => {
  const f = fixture();
  f.snapshots.set(a, snapshot());
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(f.rows.get(a)?.data.plan, "premium");
});
Deno.test("destination is not blindly granted when current RevenueCat state has no entitlement", async () => {
  const f = fixture();
  f.snapshots.set(b, snapshot(false));
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(f.rows.get(b)?.data.plan, "free");
});
Deno.test("aliases are deduplicated; anonymous IDs never create subscription rows", async () => {
  const f = fixture();
  f.event.transferred_to.push(b, a);
  equal((await createHandler(f.deps)(f.request())).status, 200);
  deepEqual(f.reads, [a, b]);
  equal(f.rows.size, 2);
});
Deno.test("ordinary anonymous app_user_id resolves the email alias without changing its case", () => {
  deepEqual(
    affectedEmails({
      type: "RENEWAL",
      app_user_id: "$RCAnonymousID:x",
      aliases: ["A@Example.com", "A@Example.com"],
    }),
    ["A@Example.com"],
  );
});
Deno.test("late purchase/expiration events reconcile current provider truth instead of replaying stale access", async () => {
  for (
    const type of [
      "INITIAL_PURCHASE",
      "RENEWAL",
      "EXPIRATION",
      "CANCELLATION",
      "PRODUCT_CHANGE",
    ]
  ) {
    for (const active of [false, true]) {
      const f = fixture();
      f.snapshots.set(a, snapshot(active));
      equal(
        (await createHandler(f.deps)(
          f.request({ event: { type, app_user_id: a } }),
        )).status,
        200,
      );
      equal(f.rows.get(a)?.data.plan, active ? "premium" : "free");
    }
  }
});
Deno.test("duplicate transfer delivery is idempotent and re-reads current state", async () => {
  const f = fixture();
  const handle = createHandler(f.deps);
  equal((await handle(f.request())).status, 200);
  equal((await handle(f.request())).status, 200);
  equal(f.rows.size, 2);
  equal(f.rows.get(a)?.data.plan, "free");
  equal(f.rows.get(b)?.data.plan, "premium");
});
Deno.test("live Stripe subscription preserves premium and Stripe metadata on transfer source", async () => {
  const f = fixture();
  Object.assign(f.rows.get(a)!.data, {
    stripe_subscription_id: "sub_existing",
    stripe_customer_id: "cus_keep",
  });
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(f.rows.get(a)?.data.plan, "premium");
  equal(f.rows.get(a)?.data.store, "stripe");
  equal(f.rows.get(a)?.data.revenuecat_plan, "free");
  equal(f.rows.get(a)?.data.stripe_customer_id, "cus_keep");
});
Deno.test("an old canceled Stripe subscription does not preserve stale RevenueCat access", async () => {
  const f = fixture();
  f.rows.get(a)!.data.stripe_subscription_id = "sub_existing";
  const fetcher = f.deps.fetch;
  f.deps.fetch =
    ((url, init) =>
      String(url).includes("api.stripe.com")
        ? Promise.resolve(
          Response.json({ id: "sub_existing", status: "canceled" }),
        )
        : fetcher(url, init)) as typeof fetch;
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(f.rows.get(a)?.data.plan, "free");
});
Deno.test("Stripe lookup errors/missing credentials cannot revoke an independently paid account", async () => {
  for (const missingKey of [true, false]) {
    const f = fixture();
    f.rows.get(a)!.data.stripe_subscription_id = "sub_existing";
    if (missingKey) f.deps.stripeKey = undefined;
    else {
      const fetcher = f.deps.fetch;
      f.deps.fetch = ((url, init) =>
        String(url).includes("api.stripe.com")
          ? Promise.resolve(new Response("", { status: 404 }))
          : fetcher(url, init)) as typeof fetch;
    }
    equal((await createHandler(f.deps)(f.request())).status, 503);
    equal(f.writes(), 0);
    equal(f.rows.get(a)?.data.plan, "premium");
    equal(f.rows.has(b), false);
  }
});
Deno.test("one failed RevenueCat lookup prevents all transfer writes and requests retry", async () => {
  const f = fixture();
  const fetcher = f.deps.fetch;
  f.deps.fetch =
    ((url, init) =>
      String(url).includes(encodeURIComponent(b))
        ? Promise.resolve(new Response("", { status: 429 }))
        : fetcher(url, init)) as typeof fetch;
  equal((await createHandler(f.deps)(f.request())).status, 503);
  equal(f.writes(), 0);
});
Deno.test("DB revision conflict is not acknowledged as a successful transfer", async () => {
  const f = fixture();
  f.deps.apply = () => Promise.reject(new Error("40001"));
  equal((await createHandler(f.deps)(f.request())).status, 503);
  equal(f.rows.has(b), false);
});
Deno.test("missing/malformed provider data fails closed without making permanent grants", async () => {
  for (
    const invalid of [{}, { request_date: now, subscriber: {} }, {
      request_date: now,
      subscriber: { entitlements: {}, subscriptions: [] },
    }]
  ) {
    const f = fixture();
    f.deps.fetch = (() =>
      Promise.resolve(Response.json(invalid))) as typeof fetch;
    equal((await createHandler(f.deps)(f.request())).status, 503);
    equal(f.writes(), 0);
  }
});
Deno.test("authentication rejects missing/invalid bearer before provider or DB access", async () => {
  for (const auth of ["", "Bearer wrong"]) {
    const f = fixture();
    equal(
      (await createHandler(f.deps)(f.request(undefined, auth))).status,
      401,
    );
    equal(f.calls.length, 0);
    equal(f.reads.length, 0);
    equal(f.writes(), 0);
  }
});
Deno.test("TEST remains acknowledged without provider key or writes", async () => {
  const f = fixture();
  f.deps.revenueCatKey = undefined;
  equal(
    (await createHandler(f.deps)(f.request({ event: { type: "TEST" } })))
      .status,
    200,
  );
  equal(f.calls.length, 0);
  equal(f.writes(), 0);
});
Deno.test("missing server key asks RevenueCat to retry; malformed transfer is rejected", async () => {
  const f = fixture();
  f.deps.revenueCatKey = undefined;
  equal((await createHandler(f.deps)(f.request())).status, 503);
  equal(
    (await createHandler(f.deps)(
      f.request({ event: { type: "TRANSFER", transferred_to: [b] } }),
    )).status,
    400,
  );
});
Deno.test("entitlement expiry, grace, trials, cancellation and lifetime use current provider state", () => {
  equal(
    revenueCatProjection(
      snapshot(true, { expires_date: "2026-10-21T20:00:00Z" }),
      a,
    ).plan,
    "free",
  );
  equal(
    revenueCatProjection(
      snapshot(true, {
        expires_date: "2026-10-21T20:00:00Z",
        grace_period_expires_date: end,
      }),
      a,
    ).plan,
    "premium",
  );
  equal(
    revenueCatProjection(snapshot(true, { expires_date: null }), a).plan,
    "premium",
  );
  const trial = snapshot();
  trial.subscriber.subscriptions.native_month.period_type = "trial";
  equal(revenueCatProjection(trial, a).status, "trialing");
  const canceled = snapshot();
  Object.assign(canceled.subscriber.subscriptions.native_month, {
    unsubscribe_detected_at: now,
  });
  equal(revenueCatProjection(canceled, a).cancel_at_period_end, true);
});
