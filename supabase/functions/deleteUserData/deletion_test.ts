import { deepEqual, equal, rejects } from "node:assert/strict";
import {
  collectUploads,
  deleteAccount,
  type DeletionUser,
} from "./deletion.ts";
import { createDeletionStore, type DeletionClient } from "./store.ts";
import { createDeletionBilling, type DeletionStripe } from "./billing.ts";

// In-memory fixtures only. No credentials, environment, real HTTP, Stripe, DB or account deletion.
const user: DeletionUser = {
  id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  email: 'qa,(quoted)"@example.invalid',
};
const foreign = "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee";
type Row = Record<string, unknown>;
type Result = { data?: unknown; error: unknown; count?: number | null };
class Query implements PromiseLike<Result> {
  filters: [string, unknown][] = [];
  start = 0;
  end = Infinity;
  constructor(
    private f: Fixture,
    private table: string,
    private deleting: boolean,
  ) {}
  eq(k: string, v: string) {
    this.filters.push([k, v]);
    return this;
  }
  is(k: string, v: null) {
    this.filters.push([k, v]);
    return this;
  }
  in(k: string, values: string[]) {
    this.filters.push([k, values]);
    return this;
  }
  order() {
    return this;
  }
  range(a: number, b: number) {
    this.start = a;
    this.end = b;
    return this;
  }
  limit(n: number) {
    this.end = n - 1;
    return this;
  }
  then<A = Result, B = never>(
    yes?: ((r: Result) => A | PromiseLike<A>) | null,
    no?: ((e: unknown) => B | PromiseLike<B>) | null,
  ): Promise<A | B> {
    return Promise.resolve().then(() => this.execute()).then(yes, no);
  }
  execute(): Result {
    this.f.queries.push({
      table: this.table,
      deleting: this.deleting,
      filters: [...this.filters],
    });
    if (
      this.f.queryFailure === this.table ||
      (this.deleting && this.f.deleteFailure === this.table)
    ) {
      return { error: { message: "private-fixture-detail" } };
    }
    if (this.deleting) this.f.beforeDelete?.(this.table);
    const original = this.f.tables.get(this.table) || [];
    const matches = original.filter((r) =>
      this.filters.every(([k, v]) => {
        const field = k.startsWith("data->>")
          ? (r.data as Row)?.[k.slice(7)] ?? null
          : k.startsWith("data->")
          ? JSON.stringify((r.data as Row)?.[k.slice(6)]) ?? null
          : r[k];
        return Array.isArray(v) ? v.includes(field) : field === v;
      })
    );
    if (this.deleting) {
      this.f.events.push(`rows:${this.table}`);
      this.f.tables.set(
        this.table,
        original.filter((r) => !matches.includes(r)),
      );
      return { error: null, count: matches.length };
    }
    const start = this.f.repeatRecords ? 0 : this.start;
    return {
      error: null,
      data: matches.sort((a, b) => String(a.id).localeCompare(String(b.id)))
        .slice(start, start + this.end - this.start + 1),
    };
  }
}
class Fixture {
  tables = new Map<string, Row[]>();
  files = new Set<string>();
  events: string[] = [];
  queries: {
    table: string;
    deleting: boolean;
    filters: [string, unknown][];
  }[] = [];
  listings: string[] = [];
  noOpRemove = false;
  removeFailure = false;
  authFailure = false;
  queryFailure = "";
  deleteFailure = "";
  beforeDelete?: (table: string) => void;
  repeatRecords = false;
  repeatFiles = false;
  missingBucket = false;
  malformedFiles = false;
  from = (table: string) => ({
    select: (_: string) => new Query(this, table, false),
    delete: (_: { count: "exact" }) => new Query(this, table, true),
  });
  storage = {
    from: (_bucket: string) => ({
      list: async (
        prefix: string,
        options: { offset: number; limit: number },
      ) => {
        this.listings.push(prefix);
        if (this.missingBucket) {
          return {
            data: null,
            error: { statusCode: "404", message: "Bucket not found" },
          };
        }
        if (this.malformedFiles) return { data: null, error: null };
        const entries = new Map<
          string,
          { name: string; id: string | null; metadata: null }
        >();
        for (const file of this.files) {
          if (file.startsWith(prefix + "/")) {
            const rest = file.slice(prefix.length + 1),
              name = rest.split("/")[0];
            entries.set(name, {
              name,
              id: rest.includes("/") ? null : "file-fixture",
              metadata: null,
            });
          }
        }
        const offset = this.repeatFiles ? 0 : options.offset;
        return {
          error: null,
          data: [...entries.values()].sort((a, b) =>
            a.name.localeCompare(b.name)
          ).slice(offset, offset + options.limit),
        };
      },
      remove: async (paths: string[]) => {
        this.events.push("uploads");
        if (this.removeFailure) {
          return {
            error: { message: "private-fixture-detail" },
          };
        }
        if (!this.noOpRemove) { for (const p of paths) this.files.delete(p); }
        return { error: null, data: [] };
      },
    }),
  };
  auth = {
    admin: {
      deleteUser: async (_id: string) => {
        this.events.push("auth");
        return {
          error: this.authFailure
            ? { message: "private-fixture-detail" }
            : null,
        };
      },
    },
  };
  store() {
    return createDeletionStore(this, "uploads");
  }
}
class BillingFixture implements DeletionStripe {
  events: string[] = [];
  failVerify = "";
  failCancel = "";
  owners = new Map<string, string>();
  status = "active";
  canceled = new Set<string>();
  missing = false;
  subscriptions = {
    retrieve: async (id: string) => {
      this.events.push("verify:" + id);
      if (this.missing) throw { code: "resource_missing" };
      if (this.failVerify === id) {
        throw { code: "api_error", message: "private-fixture-detail" };
      }
      return {
        status: this.canceled.has(id) ? "canceled" : this.status,
        metadata: { user_id: this.owners.get(id) || user.email! },
      };
    },
    cancel: async (id: string) => {
      this.events.push("cancel:" + id);
      if (this.failCancel === id) {
        throw {
          code: "api_error",
          message: "canceled subscription private-fixture-detail",
        };
      }
      this.canceled.add(id);
      return {};
    },
  };
  billing() {
    return createDeletionBilling(() => this);
  }
}
function sub(id: string, owner: string | null = user.id, data: Row = {}): Row {
  return {
    id,
    owner_id: owner,
    owner_email: user.email,
    created_by: user.email,
    user_email: user.email,
    data: { stripe_subscription_id: "sub_" + id, user_id: user.email, ...data },
  };
}
async function run(
  f: Fixture,
  b = new BillingFixture(),
  tables = ["goals", "goal_progress_entries", "user_subscriptions"],
) {
  return await deleteAccount(user, tables, f.store(), b.billing());
}

Deno.test("unavailable staged retirement stops before provider or storage operations", async () => {
  const fixture = new Fixture();
  const billing = new BillingFixture();
  const store = createDeletionStore(
    fixture,
    "uploads",
    async (_, snapshots) => {
      deepEqual(snapshots, []);
      return { error: new Error("fixture RPC unavailable") };
    },
  );
  await rejects(
    () => deleteAccount(user, ["user_subscriptions"], store, billing.billing()),
    /Subscription retirement is unavailable/,
  );
  deepEqual(billing.events, []);
  deepEqual(fixture.listings, []);
  deepEqual(fixture.events, []);
});

Deno.test("a staged deletion waits for the upload drain and inventories again on retry", async () => {
  const fixture = new Fixture();
  const file = `${user.id}/finished-during-preflight.jpg`;
  const remove = (drain: (ownerId: string) => Promise<void>) =>
    deleteAccount(
      user,
      ["goals"],
      fixture.store(),
      new BillingFixture().billing(),
      drain,
    );

  await rejects(() =>
    remove(async (ownerId) => {
      equal(ownerId, user.id);
      throw new Error("Upload cleanup is waiting for a verified drain.");
    }), /waiting for a verified drain/);
  deepEqual(fixture.events, []);

  const result = await remove(async (ownerId) => {
    equal(ownerId, user.id);
    fixture.files.add(file);
  });
  equal(fixture.files.has(file), false);
  equal(result.results.storage, "deleted 1");
  deepEqual(fixture.events, ["uploads", "rows:goals", "auth"]);
});

Deno.test("staged retirement keeps absent and JSON-null links distinct and requires an exact count", async () => {
  const fixture = new Fixture();
  fixture.tables.set("user_subscriptions", [
    sub("legacy", null, { stripe_subscription_ids: null }),
    sub("owned"),
  ]);
  const store = createDeletionStore(
    fixture,
    "uploads",
    async (owner, snapshots) => {
      deepEqual(owner, user);
      if (!snapshots.length) return { data: 0, error: null };
      deepEqual(snapshots.toSorted((a, b) => a.id.localeCompare(b.id)), [
        {
          id: "legacy",
          owner_id: null,
          owner_email: user.email,
          created_by: user.email,
          user_email: user.email,
          legacy_user_id: user.email,
          stripe_id: "sub_legacy",
          stripe_ids_json: "null",
        },
        {
          id: "owned",
          owner_id: user.id,
          owner_email: null,
          created_by: null,
          user_email: null,
          legacy_user_id: null,
          stripe_id: "sub_owned",
          stripe_ids_json: null,
        },
      ]);
      return { data: 1, error: null };
    },
  );
  const plan = await store.prepareRows(["user_subscriptions"], user);
  await rejects(() => plan.deleteRows("user_subscriptions"), /fully retired/);
  equal(fixture.queries.some((query) => query.deleting), false);
});

Deno.test("legacy exact email scopes preserve foreign owners, unrelated/null rows and progress", async () => {
  const f = new Fixture();
  for (const table of ["goals", "goal_progress_entries"]) {
    f.tables.set(table, [
      sub("owned"),
      sub("legacy", null),
      sub("foreign", foreign),
      {
        ...sub("other", null),
        owner_email: "other",
        created_by: "other",
        user_email: "other",
      },
    ]);
  }
  await run(f);
  for (const table of ["goals", "goal_progress_entries"]) {
    deepEqual(f.tables.get(table)?.map((r) => r.id), ["foreign", "other"]);
  }
  for (const q of f.queries.filter((q) => q.deleting)) {
    if (!q.filters.some(([k, v]) => k === "owner_id" && v === user.id)) {
      equal(q.filters.some(([k, v]) => k === "owner_id" && v === null), true);
      equal(q.filters.some(([, v]) => v === user.email), true);
    }
  }
  equal(f.events.at(-1), "auth");
});
Deno.test("ambiguous legacy fields stop ordinary and subscription cleanup before any writes", async () => {
  for (const table of ["goals", "user_subscriptions"]) {
    const f = new Fixture(), b = new BillingFixture();
    const conflicting = {
      ...sub("ambiguous", null),
      owner_email: "foreign@example.invalid",
    };
    f.tables.set(table, [sub("owned"), conflicting]);
    f.files.add(user.id + "/fixture.jpg");
    await rejects(() => run(f, b), /attribution is ambiguous/);
    deepEqual(f.tables.get(table), [sub("owned"), conflicting]);
    equal(f.files.size, 1);
    deepEqual(f.events, []);
    deepEqual(b.events, []);
  }
});

Deno.test("foreign subscription JSON owner conflicts with matching legacy email columns", async () => {
  const f = new Fixture(), b = new BillingFixture();
  const conflicting = sub("ambiguous_json", null, {
    user_id: "foreign@example.invalid",
  });
  f.tables.set("user_subscriptions", [conflicting]);
  await rejects(() => run(f, b), /attribution is ambiguous/);
  deepEqual(f.tables.get("user_subscriptions"), [conflicting]);
  deepEqual(f.events, []);
  deepEqual(b.events, []);
});

Deno.test("one exact legacy field is enough when the other fields are unset, and UUID ownership is authoritative", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("goals", [{
    ...sub("one_legacy", null),
    owner_email: null,
    user_email: "",
  }, {
    ...sub("foreign_uuid", foreign),
    owner_email: user.email,
  }]);
  f.tables.set("user_subscriptions", [{
    ...sub("authoritative"),
    owner_email: "historical@example.invalid",
    created_by: "historical@example.invalid",
  }, {
    ...sub("json_legacy", null),
    owner_email: null,
    created_by: "",
    user_email: null,
  }]);
  const result = await run(f, b);
  equal(result.results.goals, "deleted 1");
  equal(result.results.user_subscriptions, "deleted 2");
  deepEqual(f.tables.get("goals")?.map(({ id }) => id), ["foreign_uuid"]);
  deepEqual(f.tables.get("user_subscriptions"), []);
  deepEqual(b.events, [
    "verify:sub_authoritative",
    "verify:sub_json_legacy",
    "cancel:sub_authoritative",
    "cancel:sub_json_legacy",
  ]);
});

Deno.test("overlapping preflight scopes must observe the same legacy attribution", async () => {
  const f = new Fixture();
  f.tables.set("goals", [sub("changed", null)]);
  const original = f.from;
  f.from = (table) => {
    if (
      table === "goals" && f.queries.some((query) =>
        query.table === table &&
        query.filters.some(([column]) => column === "owner_email")
      )
    ) {
      f.tables.set("goals", [{ ...sub("changed", null), owner_email: null }]);
    }
    return original(table);
  };
  await rejects(() => run(f), /enumeration is inconsistent/);
  deepEqual(f.events, []);
});

Deno.test("conditional delete preserves reassigned legacy rows and changed subscription references", async () => {
  for (const table of ["goals", "user_subscriptions"]) {
    const f = new Fixture(), b = new BillingFixture();
    const before = sub("racing", table === "goals" ? null : user.id);
    const changed = table === "goals"
      ? { ...before, owner_email: "new-owner@example.invalid" }
      : sub("racing", user.id, { stripe_subscription_id: "sub_new" });
    f.tables.set(table, [before]);
    f.beforeDelete = (target) => {
      if (target === table) f.tables.set(target, [changed]);
    };
    await rejects(() => run(f, b), /records changed/);
    deepEqual(f.tables.get(table), [changed]);
    equal(f.events.includes("auth"), false);
    equal(b.events.includes("cancel:sub_new"), false);
  }
});

Deno.test("all known Stripe links across subscription schemas are verified and included in cleanup", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [
    sub("selected", user.id, {
      stripe_subscription_ids: ["sub_selected", "sub_independent"],
    }),
    sub("list_only", null, {
      stripe_subscription_id: null,
      stripe_subscription_ids: ["sub_legacy", "sub_independent"],
    }),
    sub("single_only", user.id, { stripe_subscription_ids: null }),
    sub("foreign", foreign, { stripe_subscription_ids: ["sub_foreign_two"] }),
  ]);
  b.canceled.add("sub_selected");

  const result = await run(f, b);
  const verified = b.events.filter((event) => event.startsWith("verify:"));
  deepEqual(verified.sort(), [
    "verify:sub_independent",
    "verify:sub_legacy",
    "verify:sub_selected",
    "verify:sub_single_only",
  ]);
  deepEqual(b.events.slice(0, verified.length).sort(), verified);
  deepEqual(b.events.slice(verified.length).sort(), [
    "cancel:sub_independent",
    "cancel:sub_legacy",
    "cancel:sub_single_only",
  ]);
  equal(result.results.user_subscriptions, "deleted 3");
  deepEqual(f.tables.get("user_subscriptions")?.map(({ id }) => id), [
    "foreign",
  ]);
});

Deno.test("an added Stripe link invalidates a subscription snapshot with the same selected ID", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [sub("selected")]);
  const changed = sub("selected", user.id, {
    stripe_subscription_ids: ["sub_selected", "sub_independent"],
  });
  f.beforeDelete = (table) => {
    if (table === "user_subscriptions") f.tables.set(table, [changed]);
  };

  await rejects(() => run(f, b), /records changed/);
  deepEqual(f.tables.get("user_subscriptions"), [changed]);
  equal(f.events.includes("auth"), false);
  deepEqual(b.events, ["verify:sub_selected", "cancel:sub_selected"]);

  f.beforeDelete = undefined;
  const result = await run(f, b);
  equal(result.results.user_subscriptions, "deleted 1");
  equal(
    b.events.filter((event) => event === "cancel:sub_independent").length,
    1,
  );
  equal(f.events.at(-1), "auth");
});

Deno.test("a subscription created after inventory is preserved and blocks authentication removal", async () => {
  const f = new Fixture(), b = new BillingFixture(), store = f.store();
  const prepareRows = store.prepareRows;
  store.prepareRows = async (tables, u) => {
    const plan = await prepareRows(tables, u);
    f.tables.set("user_subscriptions", [sub("late")]);
    return plan;
  };
  await rejects(
    () => deleteAccount(user, ["user_subscriptions"], store, b.billing()),
    /records remain/,
  );
  deepEqual(f.tables.get("user_subscriptions"), [sub("late")]);
  equal(f.events.includes("auth"), false);
  deepEqual(b.events, []);
});

Deno.test("more than ten and multiple pages of subscriptions enumerated, deduped, foreign references excluded", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set(
    "user_subscriptions",
    Array.from({ length: 215 }, (_, i) => sub(String(i).padStart(3, "0")))
      .concat([sub("legacy", null), sub("foreign", foreign)]),
  );
  await run(f, b);
  equal(b.events.filter((e) => e.startsWith("cancel:")).length, 216);
  equal(b.events.includes("cancel:sub_foreign"), false);
  equal(b.events.slice(0, 216).every((e) => e.startsWith("verify:")), true);
  deepEqual(f.tables.get("user_subscriptions")?.map((r) => r.id), ["foreign"]);
});
Deno.test("no email skips all legacy matches but still deletes UUID-owned records", async () => {
  const f = new Fixture();
  f.tables.set("goals", [sub("own"), sub("legacy", null)]);
  await deleteAccount(
    { id: user.id },
    ["goals"],
    f.store(),
    new BillingFixture().billing(),
  );
  deepEqual(f.tables.get("goals")?.map((r) => r.id), ["legacy"]);
  equal(
    f.queries.every((q) => q.filters.every(([k]) => k === "owner_id")),
    true,
  );
});
Deno.test("recursive paginated storage removes placeholders and files only inside owner prefix", async () => {
  const f = new Fixture();
  for (let i = 0; i < 205; i++) {
    f.files.add(`${user.id}/${String(i).padStart(3, "0")}.jpg`);
  }
  f.files.add(`${user.id}/nested/deeper/photo.png`);
  f.files.add(`${user.id}/nested/.emptyFolderPlaceholder`);
  f.files.add(`${foreign}/keep.jpg`);
  const result = await run(f);
  equal(result.results.storage, "deleted 207");
  deepEqual([...f.files], [`${foreign}/keep.jpg`]);
  equal(f.events.filter((e) => e === "uploads").length, 3);
  equal(f.events.at(-1), "auth");
});
Deno.test("repeated record page stops before billing and deletions", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.repeatRecords = true;
  f.tables.set(
    "user_subscriptions",
    Array.from({ length: 101 }, (_, i) => sub(String(i))),
  );
  await rejects(() => run(f, b), /inconsistent/);
  deepEqual(b.events, []);
  deepEqual(f.events, []);
});
Deno.test("repeated upload listing stops before any mutation", async () => {
  const f = new Fixture();
  f.repeatFiles = true;
  for (let i = 0; i < 101; i++) f.files.add(`${user.id}/${i}`);
  await rejects(() => run(f), /no progress/);
  deepEqual(f.events, []);
});
Deno.test("unsafe folder name and excessive nesting fail before mutations", async () => {
  const f = new Fixture(), s = f.store();
  s.listUploads = async () => [{ name: "..", id: null }];
  await rejects(() => collectUploads(s, user.id), /Unsafe/);
  s.listUploads = async () => [{ name: "nested", id: null }];
  await rejects(() => collectUploads(s, user.id), /nesting/);
  deepEqual(f.events, []);
});
Deno.test("invalid identity cannot read or mutate anything", async () => {
  const f = new Fixture();
  await rejects(
    () =>
      deleteAccount(
        { id: "../other" },
        [],
        f.store(),
        new BillingFixture().billing(),
      ),
    /Invalid/,
  );
  deepEqual(f.listings, []);
  deepEqual(f.queries, []);
  deepEqual(f.events, []);
});
Deno.test("missing bucket is empty; malformed listing fails before billing", async () => {
  const f = new Fixture();
  f.missingBucket = true;
  await run(f);
  equal(f.events.at(-1), "auth");
  const bad = new Fixture(), b = new BillingFixture();
  bad.malformedFiles = true;
  await rejects(() => run(bad, b), /enumeration/);
  deepEqual(b.events, []);
  deepEqual(bad.events, []);
});
Deno.test("successful remove with no effect never reaches rows or authentication", async () => {
  const f = new Fixture();
  f.noOpRemove = true;
  f.files.add(`${user.id}/photo`);
  await rejects(() => run(f), /files remain/);
  deepEqual(f.events, ["uploads"]);
});
Deno.test("failed upload removal retains rows and authentication for retry", async () => {
  const f = new Fixture();
  f.files.add(`${user.id}/photo`);
  f.removeFailure = true;
  f.tables.set("goals", [sub("keep")]);
  await rejects(() => run(f), /removed/);
  equal(f.tables.get("goals")?.length, 1);
  deepEqual(f.events, ["uploads"]);
  f.removeFailure = false;
  await run(f);
  equal(f.events.at(-1), "auth");
});
Deno.test("all provider references verified before any cancellation; foreign metadata blocks all cleanup", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [sub("a"), sub("b")]);
  b.owners.set("sub_b", "foreign@example.invalid");
  await rejects(() => run(f, b), /ownership/);
  deepEqual(f.events, []);
  equal(b.events.some((e) => e.startsWith("cancel:")), false);
});
Deno.test("provider errors redacted and arbitrary canceled-message error not swallowed", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [sub("a")]);
  b.failCancel = "sub_a";
  await rejects(
    () => run(f, b),
    (e: Error) =>
      e.message.includes("cancellation failed") &&
      !e.message.includes("private-fixture"),
  );
  deepEqual(f.events, []);
  equal(f.tables.get("user_subscriptions")?.length, 1);
});
Deno.test("provider read failure or missing configuration prevents cleanup", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [sub("a")]);
  b.failVerify = "sub_a";
  await rejects(() => run(f, b), /ownership could not/);
  deepEqual(f.events, []);
  await rejects(
    () =>
      deleteAccount(
        user,
        [],
        f.store(),
        createDeletionBilling(() => {
          throw new Error("not configured");
        }),
      ),
    /ownership could not/,
  );
});
Deno.test("missing and already canceled provider subscriptions are retry safe; UUID owner supported", async () => {
  for (const mode of ["missing", "canceled", "uuid"]) {
    const f = new Fixture(), b = new BillingFixture();
    f.tables.set("user_subscriptions", [sub("a")]);
    if (mode === "missing") b.missing = true;
    if (mode === "canceled") b.status = "canceled";
    if (mode === "uuid") b.owners.set("sub_a", user.id);
    await run(f, b);
    equal(
      b.events.filter((e) => e.startsWith("cancel:")).length,
      mode === "uuid" ? 1 : 0,
    );
    equal(f.events.at(-1), "auth");
  }
});
Deno.test("table failure retains authentication, retry finishes without pretending transactionality", async () => {
  const f = new Fixture();
  f.tables.set("goals", [sub("a")]);
  f.tables.set("goal_progress_entries", [sub("b")]);
  f.deleteFailure = "goal_progress_entries";
  await rejects(() => run(f), /records could not/);
  equal(f.tables.get("goals")?.length, 0);
  equal(f.tables.get("goal_progress_entries")?.length, 1);
  equal(f.events.includes("auth"), false);
  f.deleteFailure = "";
  await run(f);
  equal(f.events.at(-1), "auth");
});
Deno.test("post-delete record appearance prevents authentication removal", async () => {
  const f = new Fixture(), store = f.store();
  const prepareRows = store.prepareRows;
  store.prepareRows = async (tables, u) => {
    const plan = await prepareRows(tables, u);
    return {
      subscriptionIds: plan.subscriptionIds,
      async deleteRows(table) {
        const count = await plan.deleteRows(table);
        f.tables.set(table, [sub("concurrent")]);
        return count;
      },
    };
  };
  await rejects(
    () => deleteAccount(user, ["goals"], store, new BillingFixture().billing()),
    /records remain/,
  );
  equal(f.events.includes("auth"), false);
});
Deno.test("an upload arriving during row cleanup retains authentication and is removed on retry", async () => {
  const f = new Fixture();
  const lateUpload = user.id + "/late/photo.jpg";
  const foreignUpload = foreign + "/keep.jpg";
  f.files.add(foreignUpload);
  f.tables.set("goals", [sub("owned"), sub("foreign", foreign)]);
  f.beforeDelete = (table) => {
    if (table === "goals") f.files.add(lateUpload);
  };

  await rejects(() => run(f), /Uploaded files remain/);
  equal(f.events.includes("auth"), false);
  deepEqual([...f.files], [foreignUpload, lateUpload]);
  deepEqual(f.tables.get("goals")?.map(({ id }) => id), ["foreign"]);

  f.beforeDelete = undefined;
  const result = await run(f);
  equal(result.results.storage, "deleted 1");
  equal(result.results.authentication, "deleted");
  deepEqual([...f.files], [foreignUpload]);
  equal(f.events.filter((event) => event === "auth").length, 1);
});
Deno.test("authentication failure is retryable after data cleanup", async () => {
  const f = new Fixture();
  f.authFailure = true;
  f.tables.set("goals", [sub("a")]);
  await rejects(() => run(f), /authentication removal failed/);
  equal(f.tables.get("goals")?.length, 0);
  f.authFailure = false;
  await run(f);
  equal(f.events.filter((e) => e === "auth").length, 2);
});
Deno.test("subscription malformed reference and enumeration errors stop before mutations", async () => {
  const f = new Fixture();
  f.tables.set("user_subscriptions", [
    sub("a", user.id, { stripe_subscription_id: 12 }),
  ]);
  await rejects(() => run(f), /Invalid subscription/);
  deepEqual(f.events, []);
  f.tables.set("user_subscriptions", [
    sub("a", user.id, { stripe_subscription_ids: ["sub_a", 42] }),
  ]);
  await rejects(() => run(f), /Invalid subscription/);
  deepEqual(f.events, []);
  f.tables.set("user_subscriptions", [
    sub("a", user.id, { stripe_subscription_id: "../other" }),
  ]);
  await rejects(() => run(f), /Invalid subscription/);
  deepEqual(f.events, []);
});
Deno.test("cancel cannot be called without explicit ownership preflight", async () => {
  const b = new BillingFixture();
  await rejects(() => b.billing().cancel("sub_unverified"), /not verified/);
  deepEqual(b.events, []);
});

Deno.test("partial provider cancellation retains records and auth; retry skips previously canceled subscription", async () => {
  const f = new Fixture(), b = new BillingFixture();
  f.tables.set("user_subscriptions", [sub("a"), sub("b")]);
  b.failCancel = "sub_b";
  await rejects(() => run(f, b), /cancellation failed/);
  equal(b.canceled.has("sub_a"), true);
  equal(f.tables.get("user_subscriptions")?.length, 2);
  deepEqual(f.events, []);
  b.failCancel = "";
  await run(f, b);
  equal(b.events.filter((e) => e === "cancel:sub_a").length, 1);
  equal(f.events.at(-1), "auth");
});

Deno.test("staged billed deletion refuses email-only RevenueCat rows without verified fence", async () => {
  const fixture = new Fixture();
  const billing = new BillingFixture();
  fixture.tables.set("user_subscriptions", [
    sub("rc", null, {
      stripe_subscription_id: null,
      revenuecat_app_user_id: user.email,
      plan: "premium",
    }),
  ]);
  const store = createDeletionStore(fixture, "uploads", undefined, {
    requireBillingFenceForSubscriptions: true,
  });
  await rejects(
    () => deleteAccount(user, ["user_subscriptions"], store, billing.billing()),
    /no verified projection fence/,
  );
  deepEqual(billing.events, []);
  deepEqual(fixture.listings, []);
  deepEqual(fixture.events, []);
  equal(fixture.tables.get("user_subscriptions")?.length, 1);
});

Deno.test("staged billing fence requires a positive RPC and forwards the exact raw snapshot", async () => {
  const fixture = new Fixture();
  const subscription = sub("old");
  fixture.tables.set("user_subscriptions", [subscription]);
  let confirmed = false;
  const store = createDeletionStore(
    fixture,
    "uploads",
    async () => ({ error: null, data: 0 }),
    {
      requireBillingFenceForSubscriptions: true,
      closeBillingProjection: async (account, snapshots) => {
        deepEqual(account, user);
        deepEqual(snapshots, [subscription]);
        return { error: null, data: confirmed };
      },
    },
  );
  const plan = await store.prepareRows(["user_subscriptions"], user);
  if (
    !("closeBillingProjection" in plan) ||
    typeof plan.closeBillingProjection !== "function"
  ) {
    throw new Error("Missing staged billing callback");
  }
  const closeBillingProjection = plan.closeBillingProjection;
  await rejects(
    () => closeBillingProjection(),
    /fence could not be confirmed/,
  );
  confirmed = true;
  await closeBillingProjection();
  deepEqual(fixture.events, []);
});

Deno.test("staged Stripe cancellation requires trusted immutable UUID ownership", async () => {
  for (
    const [metadata, allowed] of [
      [{ user_id: user.email! }, false],
      [{ user_id: user.email!, execute_owner_uuid: foreign }, false],
      [{ user_id: foreign, execute_owner_uuid: user.id }, false],
      [{ user_id: user.id }, true],
      [{ user_id: user.email!, execute_owner_uuid: user.id }, true],
    ] as [Record<string, string>, boolean][]
  ) {
    let cancellations = 0;
    const billing = createDeletionBilling(() => ({
      subscriptions: {
        retrieve: async () => ({ status: "active", metadata }),
        cancel: async () => {
          cancellations++;
        },
      },
    }), { requireOwnerUUID: true });
    if (allowed) {
      await billing.verifyOwner("sub_a", user);
      await billing.cancel("sub_a");
      equal(cancellations, 1);
    } else {
      await rejects(
        () => billing.verifyOwner("sub_a", user),
        /ownership does not match/,
      );
      await rejects(() => billing.cancel("sub_a"), /not verified/);
      equal(cancellations, 0);
    }
  }
});
