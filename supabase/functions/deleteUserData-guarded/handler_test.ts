import { createGuardedReleaseDeletionHandler } from "./handler.ts";

const owner = "11111111-1111-4111-8111-111111111111";
const foreign = "22222222-2222-4222-8222-222222222222";
const project = "https://fixture.supabase.co";
const binding = { receipt_version: 1, expected_owner: owner };

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, received ${
        JSON.stringify(actual)
      }`,
    );
  }
}

function fixture() {
  const settings = {
    enabled: true,
    actualProjectUrl: project,
    approvedProjectUrl: project,
  };
  const calls: string[] = [];
  const flags = { authenticated: true, ready: true, throws: false };
  const handle = createGuardedReleaseDeletionHandler({
    readSettings: () => settings,
    getUser() {
      calls.push("auth");
      if (!flags.authenticated) throw new Response(null, { status: 401 });
      return Promise.resolve({ id: owner });
    },
    isReady() {
      calls.push("readiness");
      if (flags.throws) return Promise.reject(Error("private fixture details"));
      return Promise.resolve(flags.ready);
    },
    remove(user) {
      calls.push(user.id);
      return Promise.resolve({
        success: true,
        results: { authentication: "deleted" },
      });
    },
  });
  return { settings, flags, calls, handle };
}

function request(value: unknown = binding) {
  return new Request(
    "https://fixture.supabase.co/functions/v1/deleteUserData-guarded",
    {
      method: "POST",
      body: JSON.stringify(value),
      headers: { "Content-Type": "application/json" },
    },
  );
}

Deno.test("release deletion refuses disabled or non-exact hosted origins before authentication", async () => {
  for (
    const settings of [
      { enabled: false },
      { approvedProjectUrl: "https://other.supabase.co" },
      { actualProjectUrl: `${project}/`, approvedProjectUrl: `${project}/` },
      {
        actualProjectUrl: "http://127.0.0.1:54321",
        approvedProjectUrl: "http://127.0.0.1:54321",
      },
    ]
  ) {
    const f = fixture();
    Object.assign(f.settings, settings);
    equal((await f.handle(request())).status, 503);
    equal(f.calls, []);
  }
});

Deno.test("the legacy request, oversized body, and another owner cannot call deletion", async () => {
  for (
    const [body, status] of [
      [{}, 400],
      [{ ...binding, receipt_version: 2 }, 400],
      [{ ...binding, padding: "X".repeat(600) }, 400],
      [{ ...binding, expected_owner: foreign }, 403],
    ] as const
  ) {
    const f = fixture();
    equal((await f.handle(request(body))).status, status);
    equal(f.calls, ["auth"]);
  }
  const f = fixture();
  f.flags.authenticated = false;
  equal((await f.handle(request())).status, 401);
  equal(f.calls, ["auth"]);
});

Deno.test("false or failed read-only readiness leaves all account data alone", async () => {
  for (const shouldThrow of [false, true]) {
    const f = fixture();
    f.flags.ready = false;
    f.flags.throws = shouldThrow;
    const response = await f.handle(request());
    equal(response.status, 503);
    equal(await response.json(), { error: "Account deletion is unavailable." });
    equal(f.calls, ["auth", "readiness"]);
  }
});

Deno.test("ready guarded release replies with a versioned receipt for the verified owner", async () => {
  const f = fixture();
  const response = await f.handle(request());
  equal(response.status, 200);
  equal(await response.json(), {
    success: true,
    results: { authentication: "deleted" },
    receipt_version: 1,
    owner_id: owner,
  });
  equal(f.calls, ["auth", "readiness", owner]);
});
