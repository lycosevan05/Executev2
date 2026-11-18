import { knownStripeSubscriptionIDs } from "../_shared/billingProjection.ts";
import {
  type DeletionStore,
  type DeletionUser,
  pageSize,
  type UploadEntry,
  validateUser,
} from "./deletion.ts";

type Result = { data?: unknown; error: unknown; count?: number | null };
interface ReadQuery extends PromiseLike<Result> {
  eq(key: string, value: string): ReadQuery;
  is(key: string, value: null): ReadQuery;
  order(key: string, options: { ascending: boolean }): ReadQuery;
  range(from: number, to: number): ReadQuery;
  limit(count: number): ReadQuery;
}
interface DeleteQuery extends PromiseLike<Result> {
  eq(key: string, value: string): DeleteQuery;
  is(key: string, value: null): DeleteQuery;
  in(key: string, values: string[]): DeleteQuery;
}
export interface DeletionClient {
  from(table: string): {
    select(columns: string): ReadQuery;
    delete(options: { count: "exact" }): DeleteQuery;
  };
  storage: {
    from(bucket: string): {
      list(
        prefix: string,
        options: {
          limit: number;
          offset: number;
          sortBy: { column: string; order: string };
        },
      ): PromiseLike<Result>;
      remove(paths: string[]): PromiseLike<Result>;
    };
  };
  auth: { admin: { deleteUser(id: string): PromiseLike<{ error: unknown }> } };
}
const emailColumns = ["owner_email", "created_by", "user_email"];
const legacyRowLimit = 10000;
const subscriptionTable = "user_subscriptions";
const stripeColumn = "data->>stripe_subscription_id";
const stripeLinksColumn = "data->stripe_subscription_ids";

type Scope = { key: string; value: string; legacy: boolean };
function identityColumns(table: string): string[] {
  return table === subscriptionTable
    ? [...emailColumns, "data->>user_id"]
    : emailColumns;
}
function legacyScopes(
  table: string,
  email: string | null | undefined,
): Scope[] {
  return email
    ? identityColumns(table).map((key) => ({ key, value: email, legacy: true }))
    : [];
}
function scoped(query: ReadQuery, scope: Scope): ReadQuery {
  // Separate .eq calls encode the exact email; never interpolate it into PostgREST .or syntax.
  return scope.legacy
    ? query.is("owner_id", null).eq(scope.key, scope.value)
    : query.eq(scope.key, scope.value);
}
function rows(result: Result): Record<string, unknown>[] {
  if (
    result.error || !Array.isArray(result.data) ||
    result.data.some((r) => !r || typeof r !== "object" || Array.isArray(r))
  ) {
    throw new Error("Account record enumeration failed; cleanup stopped.");
  }
  return result.data as Record<string, unknown>[];
}
type RowFilter = [column: string, value: string | null];
interface RowSnapshot {
  id: string;
  filters: RowFilter[];
  subscriptionIds: string[];
  billingProjection?: BillingProjectionSnapshot;
}

export type BillingProjectionSnapshot = {
  id: string;
  owner_id: string | null;
  owner_email: string | null;
  created_by: string | null;
  user_email: string | null;
  data: Record<string, unknown>;
};

type BillingFenceOptions = {
  requireBillingFenceForSubscriptions?: boolean;
  requireStripeOnly?: boolean;
  closeBillingProjection?: (
    user: DeletionUser,
    snapshots: BillingProjectionSnapshot[],
  ) => PromiseLike<Result>;
};

type RetirementSnapshot =
  & { id: string }
  & Record<
    | "owner_id"
    | "owner_email"
    | "created_by"
    | "user_email"
    | "legacy_user_id"
    | "stripe_id"
    | "stripe_ids_json",
    string | null
  >;
type RetireSubscriptions = (
  user: DeletionUser,
  snapshots: RetirementSnapshot[],
) => PromiseLike<Result>;

async function retireSnapshots(
  retire: RetireSubscriptions,
  user: DeletionUser,
  snapshots: readonly RowSnapshot[],
): Promise<number> {
  for (let offset = 0; offset < snapshots.length; offset += pageSize) {
    const batch = snapshots.slice(offset, offset + pageSize).map((snapshot) => {
      const filters = new Map(snapshot.filters);
      return {
        id: snapshot.id,
        owner_id: filters.get("owner_id") ?? null,
        owner_email: filters.get("owner_email") ?? null,
        created_by: filters.get("created_by") ?? null,
        user_email: filters.get("user_email") ?? null,
        legacy_user_id: filters.get("data->>user_id") ?? null,
        stripe_id: filters.get(stripeColumn) ?? null,
        stripe_ids_json: filters.get(stripeLinksColumn) ?? null,
      };
    });
    const result = await retire(user, batch);
    if (result.error || result.data !== batch.length) {
      throw new Error(
        "Account subscriptions changed or could not be fully retired; retry account deletion.",
      );
    }
  }
  return snapshots.length;
}

function nullableText(value: unknown): string | null {
  if (value === null || typeof value === "string") return value;
  throw new Error("Account record attribution is malformed; cleanup stopped.");
}

function rowSnapshot(
  row: Record<string, unknown>,
  table: string,
  scope: Scope,
  user: DeletionUser,
): RowSnapshot {
  const owner = scope.legacy ? null : user.id;
  if (typeof row.id !== "string" || !row.id || row.owner_id !== owner) {
    throw new Error(
      "Account record enumeration is inconsistent; cleanup stopped.",
    );
  }

  const filters: RowFilter[] = [["owner_id", owner]];
  let data: Record<string, unknown> | undefined;
  if (table === subscriptionTable) {
    if (!row.data || typeof row.data !== "object" || Array.isArray(row.data)) {
      throw new Error("Invalid subscription reference; cleanup stopped.");
    }
    data = row.data as Record<string, unknown>;
  }

  if (scope.legacy) {
    const identities: RowFilter[] = emailColumns.map((key) => [
      key,
      nullableText(row[key]),
    ]);
    if (data) {
      identities.push(["data->>user_id", nullableText(data.user_id ?? null)]);
    }
    if (
      !identities.some(([key, value]) =>
        key === scope.key && value === scope.value
      ) ||
      identities.some(([, value]) =>
        value !== null && value !== "" && value !== user.email
      )
    ) {
      throw new Error(
        "Legacy account record attribution is ambiguous; cleanup stopped.",
      );
    }
    filters.push(...identities);
  }

  let subscriptionIds: string[] = [];
  if (data) {
    try {
      subscriptionIds = knownStripeSubscriptionIDs(data);
    } catch {
      throw new Error("Invalid subscription reference; cleanup stopped.");
    }

    // Use a JSONB equality predicate for the raw list. An added link must
    // invalidate the deletion snapshot, even when the selected ID is unchanged.
    const rawList = data.stripe_subscription_ids;
    filters.push(
      [stripeColumn, nullableText(data.stripe_subscription_id ?? null)],
      [
        stripeLinksColumn,
        rawList === undefined ? null : JSON.stringify(rawList),
      ],
    );
  }
  const billingProjection = data && {
    id: row.id,
    owner_id: owner,
    owner_email: nullableText(row.owner_email),
    created_by: nullableText(row.created_by),
    user_email: nullableText(row.user_email),
    data,
  };
  return { id: row.id, filters, subscriptionIds, billingProjection };
}

async function snapshotTable(
  client: DeletionClient,
  table: string,
  user: DeletionUser,
): Promise<RowSnapshot[]> {
  const subscriptions = table === subscriptionTable;
  const scopes = legacyScopes(table, user.email);
  if (subscriptions) {
    scopes.unshift({ key: "owner_id", value: user.id, legacy: false });
  }
  const columns = subscriptions
    ? "id,owner_id,owner_email,created_by,user_email,data"
    : "id,owner_id,owner_email,created_by,user_email";
  const records = new Map<string, RowSnapshot>();
  for (const scope of scopes) {
    const seen = new Set<string>();
    for (let offset = 0;; offset += pageSize) {
      const page = rows(
        await scoped(client.from(table).select(columns), scope)
          .order("id", { ascending: true }).range(
            offset,
            offset + pageSize - 1,
          ),
      );
      if (page.length > pageSize) {
        throw new Error(
          "Account record enumeration is inconsistent; cleanup stopped.",
        );
      }
      for (const row of page) {
        const snapshot = rowSnapshot(row, table, scope, user);
        const previous = records.get(snapshot.id);
        if (
          seen.has(snapshot.id) ||
          (previous &&
            JSON.stringify(previous.filters) !==
              JSON.stringify(snapshot.filters))
        ) {
          throw new Error(
            "Account record enumeration is inconsistent; cleanup stopped.",
          );
        }
        seen.add(snapshot.id);
        records.set(snapshot.id, snapshot);
        if (records.size > legacyRowLimit) {
          throw new Error("Account record count exceeds safe cleanup limit.");
        }
      }
      if (page.length < pageSize) break;
    }
  }
  return [...records.values()];
}

async function deleteSnapshots(
  client: DeletionClient,
  table: string,
  snapshots: readonly RowSnapshot[],
): Promise<number> {
  const groups = new Map<string, { filters: RowFilter[]; ids: string[] }>();
  for (const snapshot of snapshots) {
    const key = JSON.stringify(snapshot.filters);
    const group = groups.get(key) ?? { filters: snapshot.filters, ids: [] };
    group.ids.push(snapshot.id);
    groups.set(key, group);
  }
  for (const { filters, ids } of groups.values()) {
    for (let offset = 0; offset < ids.length; offset += pageSize) {
      const batch = ids.slice(offset, offset + pageSize);
      let query = client.from(table).delete({ count: "exact" }).in("id", batch);
      for (const [column, value] of filters) {
        query = value === null
          ? query.is(column, null)
          : query.eq(column, value);
      }
      const result = await query;
      if (result.error || result.count !== batch.length) {
        throw new Error(
          "Account records changed or could not be fully deleted; retry account deletion.",
        );
      }
    }
  }
  return snapshots.length;
}

export function createDeletionStore(
  client: DeletionClient,
  bucket: string,
  retireSubscriptions?: RetireSubscriptions,
  billingFence: BillingFenceOptions = {},
): DeletionStore {
  const closeProjection = billingFence.closeBillingProjection;
  return {
    async prepareRows(tables, user) {
      validateUser(user);
      if (retireSubscriptions && tables.includes(subscriptionTable)) {
        // Verify the staged RPC is installed before canceling subscriptions or
        // removing uploads. An empty snapshot never changes durable state.
        const result = await retireSubscriptions(user, []);
        if (result.error || result.data !== 0) {
          throw new Error(
            "Subscription retirement is unavailable; cleanup stopped.",
          );
        }
      }
      // Inventory subscription references even when the caller supplies a smaller
      // table list. Production supplies the entire entity catalog.
      const snapshots = new Map<string, RowSnapshot[]>();
      for (const table of new Set([subscriptionTable, ...tables])) {
        snapshots.set(table, await snapshotTable(client, table, user));
      }
      const subscriptionRows = snapshots.get(subscriptionTable) ?? [];
      if (
        (closeProjection &&
          (!retireSubscriptions || !tables.includes(subscriptionTable))) ||
        (billingFence.requireBillingFenceForSubscriptions &&
          subscriptionRows.length && !closeProjection)
      ) {
        throw new Error(
          "Billing-linked deletion has no verified projection fence.",
        );
      }
      if (
        billingFence.requireStripeOnly &&
        subscriptionRows.some(({ billingProjection }) => {
          const data = billingProjection?.data ?? {};
          return data.store === "app_store" || data.store === "play_store" ||
            Object.entries(data).some(([key, value]) =>
              key.startsWith("revenuecat_") && value != null
            );
        })
      ) {
        throw new Error(
          "Non-Stripe billing ownership needs separate acceptance.",
        );
      }
      const subscriptionIds = subscriptionRows.flatMap(({ subscriptionIds }) =>
        subscriptionIds
      );
      return {
        subscriptionIds: [...new Set(subscriptionIds)],
        ...(closeProjection && {
          async closeBillingProjection() {
            const rows = subscriptionRows.map(({ billingProjection }) => {
              if (!billingProjection) {
                throw new Error("Billing projection inventory was incomplete.");
              }
              return billingProjection;
            });
            const result = await closeProjection(user, rows);
            if (result.error || result.data !== true) {
              throw new Error(
                "Billing projection fence could not be confirmed.",
              );
            }
          },
        }),
        async deleteRows(table) {
          const eligible = snapshots.get(table);
          if (!eligible || !tables.includes(table)) {
            throw new Error(
              "Account records must be inventoried before deletion.",
            );
          }
          if (table === subscriptionTable && retireSubscriptions) {
            return await retireSnapshots(retireSubscriptions, user, eligible);
          }
          // All subscriptions need inventoried Stripe references. Ordinary UUID
          // rows are authoritative and can be deleted without legacy discovery.
          let count = 0;
          if (table !== subscriptionTable) {
            const result = await client.from(table).delete({ count: "exact" })
              .eq("owner_id", user.id);
            if (
              result.error || !Number.isSafeInteger(result.count) ||
              result.count! < 0
            ) {
              throw new Error(
                "Account records could not be fully deleted; retry account deletion.",
              );
            }
            count = result.count!;
          }
          return count + await deleteSnapshots(client, table, eligible);
        },
      };
    },
    async listUploads(prefix, offset) {
      const result = await client.storage.from(bucket).list(prefix, {
        limit: pageSize,
        offset,
        sortBy: { column: "name", order: "asc" },
      });
      const error = result.error as
        | { statusCode?: string; message?: string }
        | null;
      if (error?.statusCode === "404" && error.message === "Bucket not found") {
        return [];
      }
      return rows(result) as unknown as UploadEntry[];
    },
    async removeUploads(paths) {
      const result = await client.storage.from(bucket).remove(paths);
      if (result.error) {
        throw new Error(
          "Uploaded files could not be removed; retry account deletion.",
        );
      }
    },
    async assertRowsAbsent(table, user) {
      const scopes = [
        { key: "owner_id", value: user.id, legacy: false },
        ...legacyScopes(table, user.email),
      ];
      for (const scope of scopes) {
        if (
          rows(await scoped(client.from(table).select("id"), scope).limit(1))
            .length
        ) throw new Error("Account records remain; retry account deletion.");
      }
    },
    async deleteAuthentication(id) {
      const result = await client.auth.admin.deleteUser(id);
      if (result.error) {
        throw new Error(
          "Account data cleanup finished but authentication removal failed; retry account deletion.",
        );
      }
    },
  };
}
