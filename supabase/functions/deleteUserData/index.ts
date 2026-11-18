import Stripe from "npm:stripe@14.21.0";
import {
  createServiceClient,
  ENTITY_TABLES,
  getUser,
} from "../_shared/records.ts";
import { deleteAccount } from "./deletion.ts";
import { createDeletionStore, type DeletionClient } from "./store.ts";
import { createDeletionBilling } from "./billing.ts";
import { createDeletionHandler } from "./handler.ts";

// Prepared locally; deployment and destructive/provider acceptance require separate approval.
Deno.serve(createDeletionHandler({
  getUser,
  async remove(user) {
    const service = createServiceClient();
    let stripe: Stripe | undefined;
    const billing = createDeletionBilling(() => {
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
        Deno.env.get("SUPABASE_UPLOAD_BUCKET") || "uploads",
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
    );
  },
}));
