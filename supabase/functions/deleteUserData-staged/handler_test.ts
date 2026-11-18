import { deepEqual, equal } from "node:assert/strict";
import { createStagedDeletionHandler } from "./handler.ts";

const owner = {
  id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  email: "fixture@example.invalid",
};
const project = "https://disposable-fixture.example.invalid";
const accepted = {
  mode: "disposable-account",
  actualProjectUrl: project,
  approvedProjectUrl: project,
  disposableOwnerId: owner.id,
};
function request(method = "POST") {
  return new Request(project, {
    method,
    body: method === "POST"
      ? JSON.stringify({ user_id: owner.id, email: owner.email })
      : undefined,
  });
}

Deno.test("missing, malformed or mismatched acceptance settings fail closed before Auth", async () => {
  for (
    const settings of [
      {},
      { ...accepted, mode: "enabled" },
      { ...accepted, actualProjectUrl: "https://another.example.invalid" },
      { ...accepted, approvedProjectUrl: undefined },
      { ...accepted, disposableOwnerId: "all-users" },
      {
        ...accepted,
        actualProjectUrl: project + "/auth",
        approvedProjectUrl: project + "/auth",
      },
      {
        ...accepted,
        actualProjectUrl: "http://not-loopback.example.invalid:54321",
        approvedProjectUrl: "http://not-loopback.example.invalid:54321",
      },
    ]
  ) {
    let calls = 0;
    const handler = createStagedDeletionHandler({
      readSettings: () => settings,
      getUser: async () => {
        calls++;
        return owner;
      },
      remove: async () => {
        calls++;
      },
    });
    equal((await handler(request())).status, 503);
    equal(calls, 0);
  }
});

Deno.test("the staged route only admits the configured authenticated UUID", async () => {
  let removes = 0;
  const handler = createStagedDeletionHandler({
    readSettings: () => accepted,
    getUser: async () => ({
      // The same email and a matching body cannot select an owner.
      ...owner,
      id: "aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff",
    }),
    remove: async () => {
      removes++;
    },
  });
  equal((await handler(request())).status, 403);
  equal(removes, 0);
});

Deno.test("closing staged acceptance blocks the next request from the same authenticated owner", async () => {
  let mode: string | undefined = accepted.mode;
  let settingsReads = 0;
  let authCalls = 0;
  let removals = 0;
  const handler = createStagedDeletionHandler({
    readSettings: () => {
      settingsReads++;
      return { ...accepted, mode };
    },
    getUser: async () => {
      authCalls++;
      return owner;
    },
    remove: async (user) => {
      deepEqual(user, owner);
      removals++;
      return { success: true };
    },
  });
  equal((await handler(request("GET"))).status, 405);
  equal((await handler(request("OPTIONS"))).status, 200);
  equal(settingsReads, 0);
  equal((await handler(request())).status, 200);

  mode = undefined;
  equal((await handler(request())).status, 503);
  equal(settingsReads, 2);
  equal(authCalls, 1);
  equal(removals, 1);
});
