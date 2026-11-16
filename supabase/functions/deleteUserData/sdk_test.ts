import { deepEqual, equal } from "node:assert/strict";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createDeletionStore, type DeletionClient } from "./store.ts";

// Actual public SDK query/Storage/Auth serialization against an injected fetch fixture.
// --deny-net ensures no request can reach a database or provider.
Deno.test("actual SDK preserves exact quoted email, null-owner AND guard, range, count and storage/auth contracts", async () => {
  const calls: { method: string; url: URL; body: unknown }[] = [];
  const client = createClient(
    "https://deletion-fixture.invalid",
    "not-a-real-service-key",
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
      global: {
        fetch: async (input, init) => {
          const request = init as
            | { method?: string; body?: string }
            | undefined;
          const url = new URL(String(input)), method = request?.method || "GET";
          calls.push({
            method,
            url,
            body: request?.body ? JSON.parse(request.body) : null,
          });
          const data = url.pathname.includes("/auth/") ? { id: "fixture" } : [];
          return new Response(JSON.stringify(data), {
            status: 200,
            headers: {
              "content-type": "application/json",
              "content-range": "*/0",
            },
          });
        },
      },
    },
  );
  const user = {
    id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    email: 'qa,(quoted)"@example.invalid',
  };
  const store = createDeletionStore(
    client as unknown as DeletionClient,
    "uploads",
  );
  deepEqual(await store.subscriptionIds(user), []);
  equal(await store.deleteRows("goals", user), 0);
  await store.assertRowsAbsent("goals", user);
  deepEqual(await store.listUploads(user.id, 100), []);
  await store.removeUploads([user.id + "/nested/file.jpg"]);
  await store.deleteAuthentication(user.id);
  const rest = calls.filter((c) => c.url.pathname.startsWith("/rest/"));
  for (const c of rest) {
    equal(c.url.searchParams.has("or"), false);
    if (c.url.searchParams.get("owner_id") !== "eq." + user.id) {
      equal(c.url.searchParams.get("owner_id"), "is.null");
      equal(
        [...c.url.searchParams.values()].includes("eq." + user.email),
        true,
      );
    }
  }
  equal(
    rest.some((c) =>
      c.url.searchParams.get("offset") === "0" &&
      c.url.searchParams.get("limit") === "100"
    ),
    true,
  );
  const listing = calls.find((c) => c.url.pathname.includes("/object/list/"))!;
  deepEqual(listing.body, {
    prefix: user.id,
    limit: 100,
    offset: 100,
    sortBy: { column: "name", order: "asc" },
  });
  equal(calls.at(-1)?.method, "DELETE");
  equal(calls.at(-1)?.url.pathname, "/auth/v1/admin/users/" + user.id);
});
