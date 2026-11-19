import Stripe from "npm:stripe@14.21.0";
import { createServiceClient, ENTITY_TABLES } from "../_shared/records.ts";
import {
  type AppleRevocationOutcome,
  deleteAccount,
  type DeletionUser,
} from "./deletion.ts";
import { createDeletionStore, type DeletionClient } from "./store.ts";
import { createDeletionBilling } from "./billing.ts";
import {
  createStripeCheckoutLedger,
  drainGuardedStripeCheckouts,
} from "../_shared/stripeCheckoutGuard.ts";

export async function removeAccount(
  user: DeletionUser,
  options: {
    allowStripe: boolean;
    requireUploadDrain?: boolean;
    enableStagedBilling?: boolean;
    revokeAppleAuthorization?: () => Promise<
      AppleRevocationOutcome | undefined
    >;
  } = { allowStripe: true },
) {
  const uploadsBucket = Deno.env.get("SUPABASE_UPLOAD_BUCKET") || "uploads";
  if (options.requireUploadDrain && uploadsBucket !== "uploads") {
    throw new Error("The configured bucket has no guarded upload cutover.");
  }
  const retireSubscriptions =
    Deno.env.get("EXECUTE_STAGED_STRIPE_RETIREMENT") ===
      "1";
  if (
    options.enableStagedBilling &&
    (!options.requireUploadDrain || !retireSubscriptions)
  ) {
    throw new Error("The staged billing deletion safeguards are unavailable.");
  }
  const service = createServiceClient();
  const checkoutGuard = options.enableStagedBilling === true &&
    Deno.env.get("EXECUTE_STRIPE_CHECKOUT_GUARD") === "1";
  let stripe: Stripe | undefined;
  const getStripe = () => {
    if (!options.allowStripe && !options.enableStagedBilling) {
      throw new Error("Stripe access is unavailable in this rehearsal.");
    }
    if (stripe) return stripe;
    const key = Deno.env.get("STRIPE_SECRET_KEY");
    if (!key) throw new Error("Subscription provider is not configured.");
    // Preserve the local pre-change request API version; deployed baseline has no Stripe path.
    stripe = new Stripe(key, {
      apiVersion: "2024-04-10" as Stripe.LatestApiVersion,
      ...(checkoutGuard ? { timeout: 8_000, maxNetworkRetries: 0 } : {}),
    });
    return stripe;
  };
  const billing = createDeletionBilling(getStripe, {
    requireOwnerUUID: options.requireUploadDrain === true,
  });
  return await deleteAccount(
    user,
    ENTITY_TABLES,
    // SDK tables are ungenerated; adapter validates every response at runtime.
    createDeletionStore(
      service as unknown as DeletionClient,
      uploadsBucket,
      retireSubscriptions
        ? (account, rows) =>
          service.rpc("retire_account_stripe_subscription_rows", {
            p_owner_id: account.id,
            p_email: account.email ?? null,
            p_rows: rows,
          })
        : undefined,
      {
        requireBillingFenceForSubscriptions:
          options.requireUploadDrain === true,
        requireStripeOnly: options.enableStagedBilling === true,
        closeBillingProjection: options.enableStagedBilling
          ? (account, rows) =>
            service.rpc("close_account_billing_projection", {
              p_owner_id: account.id,
              p_email: account.email ?? null,
              p_rows: rows,
            })
          : undefined,
      },
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
    checkoutGuard
      ? () =>
        drainGuardedStripeCheckouts(
          createStripeCheckoutLedger((name, args) => service.rpc(name, args)),
          () => getStripe().checkout.sessions,
          user,
        )
      : undefined,
  );
}
