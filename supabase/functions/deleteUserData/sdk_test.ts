import { deepEqual, equal } from "node:assert/strict";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createDeletionStore, type DeletionClient } from "./store.ts";

// Actual public SDK query/Storage/Auth serialization against an injected fetch fixture.
// --deny-net ensures no request can reach a database or provider.
Deno.test("actual SDK preserves exact quoted email, null-owner AND guard, range, count and storage/auth contracts", async () => {
  const calls: { method: string; url: URL; body: unknown }[] = [];
  const user = {
    id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    email: 'qa,(quoted)"@example.invalid',
  };
  const legacyId = "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee";
  const legacyRow = {
    id: legacyId,
    owner_id: null,
    owner_email: user.email,
    created_by: null,
    user_email: "",
  };
  const subscriptionId = "11111111-bbbb-cccc-dddd-eeeeeeeeeeee";
  const subscriptionRow = {
    id: subscriptionId,
    owner_id: null,
    owner_email: null,
    created_by: null,
    user_email: null,
    data: { user_id: user.email },
  };
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
          const isLegacyRead = method === "GET" &&
            url.pathname.endsWith("/goals") &&
            url.searchParams.has("offset") &&
            url.searchParams.get("owner_email") === "eq." + user.email;
          const isSubscriptionRead = method === "GET" &&
            url.pathname.endsWith("/user_subscriptions") &&
            url.searchParams.has("offset") &&
            url.searchParams.get("data->>user_id") === "eq." + user.email;
          const data = url.pathname.includes("/auth/")
            ? { id: "fixture" }
            : isLegacyRead
            ? [legacyRow]
            : isSubscriptionRead
            ? [subscriptionRow]
            : [];
          return new Response(JSON.stringify(data), {
            status: 200,
            headers: {
              "content-type": "application/json",
              "content-range": method === "DELETE" && url.searchParams.has("id")
                ? "*/1"
                : "*/0",
            },
          });
        },
      },
    },
  );
  const store = createDeletionStore(
    client as unknown as DeletionClient,
    "uploads",
  );
  const plan = await store.prepareRows(["goals", "user_subscriptions"], user);
  deepEqual(plan.subscriptionIds, []);
  equal(await plan.deleteRows("goals"), 1);
  equal(await plan.deleteRows("user_subscriptions"), 1);
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
  const legacyDelete = rest.find((c) =>
    c.method === "DELETE" && c.url.searchParams.has("id")
  )!;
  deepEqual(Object.fromEntries(legacyDelete.url.searchParams), {
    id: "in.(" + legacyId + ")",
    owner_id: "is.null",
    owner_email: "eq." + user.email,
    created_by: "is.null",
    user_email: "eq.",
  });
  const subscriptionDelete = rest.find((c) =>
    c.method === "DELETE" && c.url.pathname.endsWith("/user_subscriptions")
  )!;
  deepEqual(Object.fromEntries(subscriptionDelete.url.searchParams), {
    id: "in.(" + subscriptionId + ")",
    owner_id: "is.null",
    owner_email: "is.null",
    created_by: "is.null",
    user_email: "is.null",
    "data->>user_id": "eq." + user.email,
    "data->>stripe_subscription_id": "is.null",
  });
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
