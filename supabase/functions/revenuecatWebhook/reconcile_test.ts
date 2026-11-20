import { deepEqual, equal } from "node:assert/strict";
import {
  affectedEmails,
  createHandler,
  type Dependencies,
  revenueCatProjection,
  type SubscriptionChange,
  type SubscriptionRow,
  type VerifiedReconciliation,
  type VerifiedSubscriptionChange,
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
          customer: "cus_keep",
          items: { data: [{ price: { id: "price_keep" } }] },
          metadata: { user_id: a },
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
          Response.json({
            id: "sub_existing",
            customer: "cus_keep",
            items: { data: [{ price: { id: "price_keep" } }] },
            metadata: { user_id: a },
            status: "canceled",
          }),
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

Deno.test("refund reversal reconciles current active access instead of skipping", async () => {
  const f = fixture();
  f.snapshots.set(a, snapshot(true));
  const response = await createHandler(f.deps)(f.request({
    event: {
      id: "refund-reversed-active",
      type: "REFUND_REVERSED",
      app_user_id: a,
    },
  }));
  equal(response.status, 200);
  deepEqual(await response.json(), { received: true });
  equal(f.calls.length, 1);
  equal(f.writes(), 1);
  equal(f.rows.get(a)?.data.plan, "premium");
  equal(f.rows.get(a)?.data.revenuecat_last_event_type, "REFUND_REVERSED");
});
Deno.test("late refund reversal does not grant an expired current customer", async () => {
  const f = fixture();
  f.snapshots.set(a, snapshot(false));
  const response = await createHandler(f.deps)(f.request({
    event: {
      id: "refund-reversed-expired",
      type: "REFUND_REVERSED",
      app_user_id: a,
    },
  }));
  equal(response.status, 200);
  equal(f.calls.length, 1);
  equal(f.writes(), 1);
  equal(f.rows.get(a)?.data.plan, "free");
});
Deno.test("refund reversal provider failure requests retry without writing", async () => {
  const f = fixture();
  f.deps.fetch =
    (() => Promise.resolve(new Response("", { status: 503 }))) as typeof fetch;
  const response = await createHandler(f.deps)(f.request({
    event: {
      id: "refund-reversed-retry",
      type: "REFUND_REVERSED",
      app_user_id: a,
    },
  }));
  equal(response.status, 503);
  equal(f.writes(), 0);
  equal(f.rows.get(a)?.data.plan, "premium");
});

Deno.test("subscription-level billing grace grants only through its current end", () => {
  const body = snapshot(true, { expires_date: "2026-10-21T20:00:00Z" });
  Object.assign(body.subscriber.subscriptions.native_month, {
    grace_period_expires_date: end,
  });
  equal(revenueCatProjection(body, a).plan, "premium");
  Object.assign(body.subscriber.subscriptions.native_month, {
    grace_period_expires_date: "2026-10-21T20:30:00Z",
  });
  equal(revenueCatProjection(body, a).plan, "free");
});
Deno.test("newly created current RevenueCat customer is accepted without a grant", async () => {
  const f = fixture();
  f.deps.fetch = (() =>
    Promise.resolve(
      Response.json(snapshot(false), { status: 201 }),
    )) as typeof fetch;
  equal((await createHandler(f.deps)(f.request())).status, 200);
  equal(f.rows.get(a)?.data.plan, "free");
  equal(f.rows.get(b)?.data.plan, "free");
});
Deno.test("RC expiry preserves another known active Stripe subscription in either link order", async () => {
  for (const reverse of [false, true]) {
    const f = fixture();
    Object.assign(f.rows.get(a)!.data, {
      stripe_subscription_id: "sub_old",
      stripe_subscription_ids: reverse
        ? ["sub_new", "sub_old"]
        : ["sub_old", "sub_new"],
    });
    const fetcher = f.deps.fetch;
    f.deps.fetch = ((input, init) => {
      const url = String(input);
      if (!url.includes("api.stripe.com")) return fetcher(input, init);
      const id = url.split("/").at(-1)!;
      return Promise.resolve(
        Response.json({
          id,
          customer: "cus_keep",
          items: { data: [{ price: { id: "price_keep" } }] },
          metadata: { user_id: a },
          status: id === "sub_new" ? "active" : "canceled",
          current_period_start: 1792616400,
          current_period_end: 1792702800,
        }),
      );
    }) as typeof fetch;
    equal((await createHandler(f.deps)(f.request())).status, 200);
    equal(f.rows.get(a)?.data.plan, "premium");
    equal(f.rows.get(a)?.data.stripe_subscription_id, "sub_new");
    equal(f.rows.get(a)?.data.revenuecat_plan, "free");
  }
});
Deno.test("explicit Stripe owner mismatch aborts both RC transfer writes", async () => {
  const f = fixture();
  f.rows.get(a)!.data.stripe_subscription_id = "sub_existing";
  const fetcher = f.deps.fetch;
  f.deps.fetch =
    ((input, init) =>
      String(input).includes("api.stripe.com")
        ? Promise.resolve(
          Response.json({
            id: "sub_existing",
            customer: "cus_keep",
            items: { data: [{ price: { id: "price_keep" } }] },
            metadata: { user_id: b },
            status: "active",
            current_period_start: 1792616400,
            current_period_end: 1792702800,
          }),
        )
        : fetcher(input, init)) as typeof fetch;
  equal((await createHandler(f.deps)(f.request())).status, 503);
  equal(f.writes(), 0);
});

Deno.test("explicit subscription grace cannot be extended by a conflicting entitlement fallback", () => {
  for (const grace of [null, "2026-10-21T20:30:00Z"]) {
    const body = snapshot(true, {
      expires_date: "2026-10-21T20:00:00Z",
      grace_period_expires_date: end,
    });
    Object.assign(body.subscriber.subscriptions.native_month, {
      grace_period_expires_date: grace,
    });
    equal(revenueCatProjection(body, a).plan, "free");
  }
});

const ownerA = "11111111-1111-4111-8111-111111111111";
const ownerB = "22222222-2222-4222-8222-222222222222";
const customerA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const customerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const anonymous = "$RCAnonymousID:1234567890abcdef1234567890abcdef";
const appId = "native-dev-app";
const revision = "2026-10-21T20:00:00Z";

function verifiedFixture() {
  const legacy = fixture();
  const source: Record<string, unknown> = {
    state: "active",
    owner_id: ownerA,
    customer_id: customerA,
    email: a,
    environment: "SANDBOX",
    subscription: {
      data: { user_id: ownerA, plan: "premium", status: "active" },
      updated_date: revision,
    },
  };
  const destination: Record<string, unknown> = {
    state: "active",
    owner_id: ownerB,
    customer_id: customerB,
    email: b,
    environment: "SANDBOX",
    subscription: null,
  };
  const identities = new Map<string, unknown>([
    [customerA, source],
    [customerB, destination],
    ["VerifiedAlias", destination],
  ]);
  const providers = new Map<string, Response>([
    [customerA, verifiedSnapshot(customerA, false)],
    [customerB, verifiedSnapshot(customerB)],
  ]);
  const attempted: string[] = [];
  const resolutions: string[] = [];
  const batches: VerifiedSubscriptionChange[][] = [];
  const verified: VerifiedReconciliation = {
    appId,
    environment: "SANDBOX",
    products: new Set(["native_month"]),
    resolve(identifier) {
      resolutions.push(identifier);
      return Promise.resolve(
        identities.get(identifier) ?? { state: "unresolved" },
      );
    },
    apply(changes) {
      batches.push(changes);
      return Promise.resolve();
    },
  };
  const deps: Dependencies = {
    ...legacy.deps,
    verified,
    fetch: ((input: string | URL | Request) => {
      attempted.push(String(input));
      const id = decodeURIComponent(
        new URL(String(input)).pathname.split("/").at(-1)!,
      );
      return Promise.resolve(
        providers.get(id) ?? Response.json(null, { status: 404 }),
      );
    }) as typeof fetch,
  };
  const event = {
    id: "scoped-transfer",
    type: "TRANSFER",
    app_id: appId,
    environment: "SANDBOX",
    transferred_from: [customerA],
    transferred_to: [anonymous, "VerifiedAlias", customerB],
  };
  const deliver = (value: Record<string, unknown> = event, auth?: string) =>
    createHandler(deps)(legacy.request({ event: value }, auth));
  return {
    legacy,
    source,
    destination,
    identities,
    providers,
    attempted,
    resolutions,
    batches,
    verified,
    deps,
    event,
    deliver,
  };
}

function verifiedSnapshot(
  original: string,
  active = true,
  overrides: Record<string, unknown> = {},
  isSandbox = true,
  status = 200,
): Response {
  const value = snapshot(active, overrides);
  return Response.json({
    ...value,
    subscriber: {
      ...value.subscriber,
      original_app_user_id: original,
      subscriptions: {
        native_month: {
          ...value.subscriber.subscriptions.native_month,
          is_sandbox: isSandbox,
        },
      },
    },
  }, { status });
}

Deno.test("verified transfer reconciles two active owners atomically and deduplicates aliases", async () => {
  const f = verifiedFixture();
  equal((await f.deliver()).status, 200);
  equal(f.batches.length, 1);
  const [from, to] = f.batches[0];
  deepEqual(
    [
      from.owner_id,
      from.customer_id,
      from.expected_email,
      from.expected_updated_date,
      from.data.plan,
    ],
    [ownerA, customerA, a, revision, "free"],
  );
  deepEqual(
    [
      to.owner_id,
      to.customer_id,
      to.expected_email,
      to.expected_updated_date,
      to.data.plan,
    ],
    [ownerB, customerB, b, null, "premium"],
  );
  equal(to.data.user_id, undefined);
  equal(to.data.revenuecat_app_user_id, customerB);
  deepEqual(f.attempted.map((url) => url.split("/").at(-1)), [
    customerA,
    customerB,
  ]);
  deepEqual(f.legacy.reads, []);
  equal(f.legacy.writes(), 0);
});

Deno.test("verified transfer skips a retired source without looking it up at RevenueCat", async () => {
  const f = verifiedFixture();
  f.identities.set(customerA, { state: "retired" });
  equal((await f.deliver()).status, 200);
  deepEqual(f.batches[0].map((change) => change.owner_id), [ownerB]);
  deepEqual(f.attempted.map((url) => url.split("/").at(-1)), [customerB]);
});

Deno.test("verified retired-only event is acknowledged without a provider read or write", async () => {
  const f = verifiedFixture();
  f.identities.set(customerA, { state: "retired" });
  const response = await f.deliver({
    ...f.event,
    type: "EXPIRATION",
    app_user_id: customerA,
  });
  equal(response.status, 200);
  deepEqual(await response.json(), {
    received: true,
    skipped: "retired_subjects",
  });
  deepEqual(f.attempted, []);
  deepEqual(f.batches, []);
});

Deno.test("verified transfer rejects unresolved named, blocked, foreign or unbound anonymous participants", async () => {
  for (
    const participants of [
      [customerB, "UnknownAlias"],
      [customerB, "SuspendedAlias"],
      [customerA, customerB],
      [anonymous],
      [customerB, "verifiedAlias"],
    ]
  ) {
    const f = verifiedFixture();
    f.identities.set("SuspendedAlias", { state: "blocked" });
    equal(
      (await f.deliver({ ...f.event, transferred_to: participants })).status,
      503,
    );
    deepEqual(f.batches, []);
    deepEqual(f.attempted, []);
  }
});

Deno.test("verified integration pins authorization, app, event scope and ledger environment", async () => {
  const f = verifiedFixture();
  equal((await f.deliver(f.event, "Bearer invalid")).status, 401);
  for (
    const event of [
      { ...f.event, app_id: "different-app" },
      { ...f.event, environment: "PRODUCTION" },
      { ...f.event, environment: undefined },
    ]
  ) {
    equal((await f.deliver(event)).status, 503);
  }
  deepEqual(f.resolutions, []);
  f.destination.environment = "PRODUCTION";
  equal((await f.deliver()).status, 503);
  deepEqual(f.attempted, []);
  deepEqual(f.batches, []);
});

Deno.test("incomplete verified config cannot fall back to the legacy mailbox", async () => {
  const f = verifiedFixture();
  f.deps.verified = null;
  equal(
    (await f.deliver({ ...f.event, type: "RENEWAL", app_user_id: a })).status,
    503,
  );
  deepEqual(f.legacy.reads, []);
  equal(f.legacy.writes(), 0);
  deepEqual(f.attempted, []);
});

Deno.test("verified reconciliation rejects wrong provider scope, a foreign original or a new customer", async () => {
  for (
    const value of [
      verifiedSnapshot(customerA),
      verifiedSnapshot(customerB, true, {}, false),
      verifiedSnapshot(customerB, true, {
        product_identifier: "different_app",
      }),
      verifiedSnapshot(customerB, false, {}, true, 201),
    ]
  ) {
    const f = verifiedFixture();
    f.providers.set(customerB, value);
    equal((await f.deliver()).status, 503);
    deepEqual(f.batches, []);
  }
});

Deno.test("verified delayed expiry uses fresh renewal truth and a truly elapsed period returns Free", async () => {
  for (const [expiration, plan] of [[end, "premium"], [now, "free"]]) {
    const f = verifiedFixture();
    f.providers.set(
      customerA,
      verifiedSnapshot(customerA, true, { expires_date: expiration }),
    );
    equal(
      (await f.deliver({
        ...f.event,
        type: "EXPIRATION",
        app_user_id: customerA,
        aliases: [anonymous],
      })).status,
      200,
    );
    equal(f.batches.length, 1);
    equal(f.batches[0][0].expected_updated_date, revision);
    equal(f.batches[0][0].data.plan, plan);
    equal(f.batches[0][0].data.revenuecat_last_event_type, "EXPIRATION");
  }
});

Deno.test("verified webhook requires a matching immutable Stripe owner and environment", async () => {
  for (
    const [owner, live, status] of [
      [ownerA, false, 200],
      [ownerB, false, 503],
      [ownerA, true, 503],
    ] as const
  ) {
    const f = verifiedFixture();
    f.source.subscription = {
      data: { user_id: ownerA, stripe_subscription_id: "sub_bound" },
      updated_date: revision,
    };
    f.providers.set(
      "sub_bound",
      Response.json({
        id: "sub_bound",
        livemode: live,
        metadata: { user_id: a, execute_owner_uuid: owner },
        customer: "cus_bound",
        items: { data: [{ price: { id: "price_bound" } }] },
        status: "active",
        current_period_start: 1792616400,
        current_period_end: 1792702800,
      }),
    );
    equal((await f.deliver()).status, status);
    if (status === 200) {
      equal(f.batches[0][0].data.store, "stripe");
      equal(f.batches[0][0].data.plan, "premium");
    } else {
      deepEqual(f.batches, []);
    }
  }
});

Deno.test("verified owner-revision conflict from the atomic RPC requests retry", async () => {
  const f = verifiedFixture();
  f.verified.apply = () => Promise.reject(new Error("Revision changed"));
  equal((await f.deliver()).status, 503);
  equal(f.legacy.writes(), 0);
});
