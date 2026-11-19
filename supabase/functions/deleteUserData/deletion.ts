/** Local, dependency-free orchestration. No credentials, network or deployment on import. */
import type { CheckoutDrainPlan } from "../_shared/stripeCheckoutGuard.ts";
export interface DeletionUser {
  id: string;
  email?: string | null;
}
export interface UploadEntry {
  name: string;
  id?: string | null;
  metadata?: unknown;
}
export interface RecordDeletionPlan {
  subscriptionIds: readonly string[];
  closeBillingProjection?: () => Promise<void>;
  deleteRows(table: string): Promise<number>;
}
export interface DeletionStore {
  prepareRows(
    tables: readonly string[],
    user: DeletionUser,
  ): Promise<RecordDeletionPlan>;
  listUploads(prefix: string, offset: number): Promise<UploadEntry[]>;
  removeUploads(paths: string[]): Promise<void>;
  assertRowsAbsent(table: string, user: DeletionUser): Promise<void>;
  deleteAuthentication(id: string): Promise<void>;
}
export interface DeletionBilling {
  verifyOwner(
    id: string,
    user: DeletionUser,
    options?: { requireExisting?: boolean },
  ): Promise<void>;
  cancel(id: string): Promise<void>;
}
export type AppleRevocationOutcome = "revoked" | "manual_required";
export const pageSize = 100;
const maxObjects = 10000;
export function validateUser(user: DeletionUser) {
  if (!/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(user.id)) {
    throw new Error("Invalid account identity; no deletion performed.");
  }
}

export async function collectUploads(
  store: DeletionStore,
  userId: string,
): Promise<string[]> {
  validateUser({ id: userId });
  const files: string[] = [];
  const seen = new Set<string>();
  const pending = [{ prefix: userId, depth: 0 }];
  while (pending.length) {
    const { prefix, depth } = pending.pop()!;
    if (depth > 32) {
      throw new Error("Upload nesting exceeds safe cleanup limit.");
    }
    for (let offset = 0;; offset += pageSize) {
      const entries = await store.listUploads(prefix, offset);
      if (!Array.isArray(entries) || entries.length > pageSize) {
        throw new Error("Upload listing was incomplete.");
      }
      for (const entry of entries) {
        if (
          !entry || typeof entry.name !== "string" || !entry.name ||
          /[\\/\u0000]/.test(entry.name) || entry.name === "." ||
          entry.name === ".."
        ) {
          throw new Error("Unsafe upload path; cleanup stopped.");
        }
        const path = `${prefix}/${entry.name}`;
        if (seen.has(path)) throw new Error("Upload listing made no progress.");
        seen.add(path);
        if (seen.size > maxObjects) {
          throw new Error("Upload count exceeds safe cleanup limit.");
        }
        if (typeof entry.id === "string" && entry.id) files.push(path);
        else if (entry.id == null && entry.metadata == null) {
          pending.push({ prefix: path, depth: depth + 1 });
        } else throw new Error("Unknown upload entry; cleanup stopped.");
      }
      if (entries.length < pageSize) break;
    }
  }
  return files;
}

async function assertUploadsAbsent(store: DeletionStore, userId: string) {
  if ((await collectUploads(store, userId)).length) {
    throw new Error("Uploaded files remain; retry account deletion.");
  }
}

export async function deleteAccount(
  user: DeletionUser,
  tables: readonly string[],
  store: DeletionStore,
  billing: DeletionBilling,
  closeAndDrainUploads?: (ownerId: string) => Promise<void>,
  revokeAppleAuthorization?: () => Promise<AppleRevocationOutcome | undefined>,
  closeAndDrainCheckout?: () => Promise<CheckoutDrainPlan>,
) {
  validateUser(user);
  // Complete read-only enumeration before the first irreversible/provider operation.
  const plan = await store.prepareRows(tables, user);
  const ids = [...new Set(plan.subscriptionIds)];
  if (ids.some((id) => !/^sub_[A-Za-z0-9_]+$/.test(id))) {
    throw new Error("Invalid subscription reference; cleanup stopped.");
  }
  let uploads = await collectUploads(store, user.id);
  for (const id of ids) await billing.verifyOwner(id, user);
  if (closeAndDrainUploads) {
    await closeAndDrainUploads(user.id);
    // Files that finished before their dispatch was acknowledged can be newer
    // than the read-only preflight. Inventory them after the upload drain.
    uploads = await collectUploads(store, user.id);
  }
  let checkout: CheckoutDrainPlan | undefined;
  if (closeAndDrainCheckout) {
    if (!plan.closeBillingProjection) {
      throw new Error(
        "Checkout drain requires a verified billing projection fence.",
      );
    }
    checkout = await closeAndDrainCheckout();
    const discovered = [...new Set(checkout.subscriptionIds)];
    if (discovered.some((id) => !/^sub_[A-Za-z0-9_]+$/.test(id))) {
      throw new Error("Invalid subscription reference from Stripe checkout.");
    }
    for (const id of discovered) {
      // Checkout is direct provider evidence. A missing subscription cannot
      // be treated as a stale billing-row reference.
      await billing.verifyOwner(id, user, { requireExisting: true });
    }
    ids.push(...discovered.filter((id) => !ids.includes(id)));
  }
  await plan.closeBillingProjection?.();
  const appleRevocation = await revokeAppleAuthorization?.();
  for (const id of ids) await billing.cancel(id);
  for (let offset = 0; offset < uploads.length; offset += pageSize) {
    await store.removeUploads(uploads.slice(offset, offset + pageSize));
  }
  // Confirm removal before touching database records.
  await assertUploadsAbsent(store, user.id);
  const results: Record<string, string> = {
    storage: `deleted ${uploads.length}`,
  };
  for (const table of tables) {
    results[table] = `deleted ${await plan.deleteRows(table)}`;
  }
  for (const table of tables) await store.assertRowsAbsent(table, user);
  // Detect uploads made during database cleanup before removing the retry path.
  await assertUploadsAbsent(store, user.id);
  await checkout?.finish();
  // Retain authentication on any earlier partial failure so the account can retry.
  await store.deleteAuthentication(user.id);
  results.authentication = "deleted";
  return {
    success: true,
    results,
    ...(appleRevocation && { apple_revocation: appleRevocation }),
  };
}
