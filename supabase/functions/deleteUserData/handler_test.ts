import { deepEqual, equal } from "node:assert/strict";
import { createDeletionHandler } from "./handler.ts";
const user = {
  id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  email: "fixture@example.invalid",
};
Deno.test("HTTP GET and OPTIONS cannot trigger authentication or deletion", async () => {
  let calls = 0;
  const handler = createDeletionHandler({
    getUser: async () => {
      calls++;
      return user;
    },
    remove: async () => {
      calls++;
    },
  });
  equal(
    (await handler(new Request("https://fixture.invalid", { method: "GET" })))
      .status,
    405,
  );
  equal(
    (await handler(
      new Request("https://fixture.invalid", { method: "OPTIONS" }),
    )).status,
    200,
  );
  equal(calls, 0);
});
Deno.test("HTTP unauthorized response forwarded with no cleanup invocation", async () => {
  let deleted = false;
  const handler = createDeletionHandler({
    getUser: async () => {
      throw new Response("Unauthorized", { status: 401 });
    },
    remove: async () => {
      deleted = true;
    },
  });
  equal(
    (await handler(new Request("https://fixture.invalid", { method: "POST" })))
      .status,
    401,
  );
  equal(deleted, false);
});
Deno.test("HTTP body cannot choose foreign account; only authenticated identity used", async () => {
  const handler = createDeletionHandler({
    getUser: async () => user,
    remove: async (actual) => {
      deepEqual(actual, user);
      return { success: true };
    },
  });
  const result = await handler(
    new Request("https://fixture.invalid", {
      method: "POST",
      body: JSON.stringify({
        user_id: "foreign",
        email: "other@example.invalid",
      }),
    }),
  );
  equal(result.status, 200);
  deepEqual(await result.json(), { success: true });
});
Deno.test("HTTP failure never exposes raw provider, file or account identifiers", async () => {
  const handler = createDeletionHandler({
    getUser: async () => user,
    remove: async () => {
      throw new Error("private-fixture-provider-token/path/account");
    },
  });
  const result = await handler(
    new Request("https://fixture.invalid", { method: "POST" }),
  );
  equal(result.status, 500);
  equal((await result.text()).includes("private-fixture"), false);
});
