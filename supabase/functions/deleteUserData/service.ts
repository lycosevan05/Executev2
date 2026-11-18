import Stripe from "npm:stripe@14.21.0";
import { createServiceClient, ENTITY_TABLES } from "../_shared/records.ts";
import {
  type AppleRevocationOutcome,
  deleteAccount,
  type DeletionUser,
} from "./deletion.ts";
import { createDeletionStore, type DeletionClient } from "./store.ts";
import { createDeletionBilling } from "./billing.ts";

export async function removeAccount(
  user: DeletionUser,
  options: {
    allowStripe: boolean;
    requireUploadDrain?: boolean;
    revokeAppleAuthorization?: () => Promise<
      AppleRevocationOutcome | undefined
    >;
  } = { allowStripe: true },
) {
  const uploadsBucket = Deno.env.get("SUPABASE_UPLOAD_BUCKET") || "uploads";
  if (options.requireUploadDrain && uploadsBucket !== "uploads") {
    throw new Error("The configured bucket has no guarded upload cutover.");
  }
  const service = createServiceClient();
  let stripe: Stripe | undefined;
  const billing = createDeletionBilling(() => {
    if (!options.allowStripe) {
      throw new Error("Stripe access is unavailable in this rehearsal.");
    }
    if (stripe) return stripe;
    const key = Deno.env.get("STRIPE_SECRET_KEY");
    if (!key) throw new Error("Subscription provider is not configured.");
    // Preserve the local pre-change request API version; deployed baseline has no Stripe path.
    stripe = new Stripe(key, {
      apiVersion: "2024-04-10" as Stripe.LatestApiVersion,
    });
    return stripe;
  });
  return await deleteAccount(
    user,
    ENTITY_TABLES,
    // SDK tables are ungenerated; adapter validates every response at runtime.
    createDeletionStore(
      service as unknown as DeletionClient,
      uploadsBucket,
      Deno.env.get("EXECUTE_STAGED_STRIPE_RETIREMENT") === "1"
        ? (account, rows) =>
          service.rpc("retire_account_stripe_subscription_rows", {
            p_owner_id: account.id,
            p_email: account.email ?? null,
            p_rows: rows,
          })
        : undefined,
    ),
    billing,
    options.requireUploadDrain
      ? async (ownerId) => {
        const reply = await service.rpc(
          "close_and_list_guarded_account_upload_dispatches",
          { p_owner_id: ownerId },
        );
        if (reply.error || !Array.isArray(reply.data) || reply.data.length) {
          throw new Error("Upload cleanup is waiting for a verified drain.");
        }
      }
      : undefined,
    options.revokeAppleAuthorization,
  );
}
