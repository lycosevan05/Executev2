import { createIdentityHandler } from "./handler.ts";

const owner = "11111111-1111-1111-1111-111111111111";
const other = "22222222-2222-2222-2222-222222222222";
const customer = "33333333-3333-3333-3333-333333333333";
const origin = "https://isolated.supabase.co";
const scope = {
  actualUrl: origin,
  approvedUrl: origin,
  project: "fixture-project",
  environment: "SANDBOX",
};

function assertEqual(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error("Unexpected identity response");
  }
}

function post(body: Record<string, unknown> = {}) {
  return new Request(origin + "/functions/v1/revenuecatIdentity", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function subject(overrides: Record<string, unknown> = {}) {
  return {
    state: "active",
    owner_id: owner,
    customer_id: customer,
    environment: "SANDBOX",
    subscription: null,
    ...overrides,
  };
}

Deno.test("a forged request body cannot choose the account and private fields stay off the response", async () => {
  const handler = createIdentityHandler({
    scope: () => scope,
    authenticatedOwner: () => Promise.resolve(owner),
    readSubject: (project, selected) => {
      assertEqual([project, selected], [scope.project, owner]);
      return Promise.resolve(subject({
        subscription: {
          data: {
            user_id: owner,
            email: "private@example.invalid",
            plan: "premium",
            store: "app_store",
            cancel_at_period_end: false,
            verified_billing_project: "fixture-project",
          },
        },
      }));
    },
  });
  const result = await handler(post({ owner_id: other }));
  assertEqual(result.status, 200);
  assertEqual(result.headers.get("Cache-Control"), "no-store");
  assertEqual(await result.json(), {
    owner_id: owner,
    customer_id: customer,
    subscription: {
      user_id: owner,
      plan: "premium",
      store: "app_store",
      cancel_at_period_end: false,
    },
  });
});

Deno.test("missing scope or Auth cannot access a verified billing subject", async () => {
  for (
    const [approvedUrl, status] of [
      [undefined, 503],
      ["https://foreign.supabase.co", 503],
      [origin, 401],
    ] as const
  ) {
    const handler = createIdentityHandler({
      scope: () => ({ ...scope, approvedUrl }),
      authenticatedOwner: () => Promise.reject(new Error("No verified Auth")),
      readSubject: () => {
        throw new Error("Subject lookup must not run");
      },
    });
    const result = await handler(post());
    assertEqual(result.status, status);
  }
});

Deno.test("ineligible and mismatched subjects cannot return an SDK customer ID", async () => {
  for (
    const [response, status] of [
      [{ state: "unresolved" }, 409],
      [{ state: "blocked" }, 409],
      [{ state: "retired" }, 409],
      [subject({ owner_id: other }), 503],
      [subject({ customer_id: owner }), 503],
      [subject({ environment: "PRODUCTION" }), 503],
      [subject({ subscription: { data: { user_id: other } } }), 503],
    ] as const
  ) {
    const handler = createIdentityHandler({
      scope: () => scope,
      authenticatedOwner: () => Promise.resolve(owner),
      readSubject: () => Promise.resolve(response),
    });
    const result = await handler(post());
    assertEqual(result.status, status);
    assertEqual(Object.keys(await result.json()), ["error"]);
  }
});
