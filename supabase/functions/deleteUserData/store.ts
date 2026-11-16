import {
  type DeletionStore,
  type DeletionUser,
  pageSize,
  type UploadEntry,
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
type Scope = { key: string; value: string; legacy: boolean };
function scopes(user: DeletionUser, subscriptions = false): Scope[] {
  const result: Scope[] = [{ key: "owner_id", value: user.id, legacy: false }];
  if (user.email) {
    for (
      const key of [
        "owner_email",
        "created_by",
        "user_email",
        ...(subscriptions ? ["data->>user_id"] : []),
      ]
    ) {
      result.push({ key, value: user.email, legacy: true });
    }
  }
  return result;
}
function scoped<T extends ReadQuery | DeleteQuery>(query: T, scope: Scope): T {
  // Separate .eq calls encode the exact email; never interpolate it into PostgREST .or syntax.
  return (scope.legacy
    ? query.is("owner_id", null).eq(scope.key, scope.value)
    : query.eq(scope.key, scope.value)) as T;
}
function rows(result: Result): Record<string, unknown>[] {
  if (
    result.error || !Array.isArray(result.data) ||
    result.data.some((r) => !r || typeof r !== "object")
  ) {
    throw new Error("Account record enumeration failed; cleanup stopped.");
  }
  return result.data as Record<string, unknown>[];
}
export function createDeletionStore(
  client: DeletionClient,
  bucket: string,
): DeletionStore {
  return {
    async subscriptionIds(user) {
      const records = new Map<string, Record<string, unknown>>();
      for (const scope of scopes(user, true)) {
        const seen = new Set<string>();
        for (let offset = 0;; offset += pageSize) {
          const page = rows(
            await scoped(client.from("user_subscriptions").select("*"), scope)
              .order("id", { ascending: true }).range(
                offset,
                offset + pageSize - 1,
              ),
          );
          for (const row of page) {
            if (
              typeof row.id !== "string" || !row.id || seen.has(row.id) ||
              (row.owner_id !== null && row.owner_id !== user.id)
            ) throw new Error("Subscription enumeration is inconsistent.");
            seen.add(row.id);
            records.set(row.id, row);
          }
          if (seen.size > 10000) {
            throw new Error("Subscription count exceeds safe cleanup limit.");
          }
          if (page.length < pageSize) break;
        }
      }
      const ids: string[] = [];
      for (const row of records.values()) {
        const data = row.data as Record<string, unknown> | null;
        const id = data?.stripe_subscription_id;
        if (id != null && id !== "") {
          if (typeof id !== "string") {
            throw new Error("Invalid subscription reference.");
          }
          ids.push(id);
        }
      }
      return [...new Set(ids)];
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
    async deleteRows(table, user) {
      let count = 0;
      for (const scope of scopes(user, table === "user_subscriptions")) {
        const result = await scoped(
          client.from(table).delete({ count: "exact" }),
          scope,
        );
        if (
          result.error || !Number.isSafeInteger(result.count) ||
          result.count! < 0
        ) {
          throw new Error(
            "Account records could not be fully deleted; retry account deletion.",
          );
        }
        count += result.count!;
      }
      return count;
    },
    async assertRowsAbsent(table, user) {
      for (const scope of scopes(user, table === "user_subscriptions")) {
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
