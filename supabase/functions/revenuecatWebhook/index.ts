import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createHandler } from "./reconcile.ts";
import { serviceClient, verifiedReconciliation } from "./configuration.ts";

// The public gateway remains verify_jwt=false; this handler requires the
// existing RevenueCat bearer secret before any provider lookup or DB write.
// REVENUECAT_SECRET_API_KEY: server-only REST API v1 key for this RC project.
// STRIPE_SECRET_KEY: existing Stripe key, only used for rows with a Stripe ID.
// Install the reconciliation and HTTP conflict migrations listed in the README first.
Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;
  let service: ReturnType<typeof serviceClient> | undefined;
  const database = () => service ??= serviceClient();
  const handle = createHandler({
    webhookSecret: Deno.env.get("REVENUECAT_WEBHOOK_SECRET"),
    revenueCatKey: Deno.env.get("REVENUECAT_SECRET_API_KEY"),
    stripeKey: Deno.env.get("STRIPE_SECRET_KEY"),
    fetch,
    verified: verifiedReconciliation(database),
    async read(userId) {
      const { data, error } = await database().from(
        "user_subscriptions",
      )
        .select("data,updated_date").eq("data->>user_id", userId).maybeSingle();
      if (error) throw error;
      return data;
    },
    async apply(changes) {
      const { data, error } = await database().rpc(
        "reconcile_revenuecat_subscriptions",
        {
          p_changes: changes,
        },
      );
      if (error) throw error;
      if (data !== changes.length) {
        throw new Error("Incomplete subscription reconciliation");
      }
    },
  });
  const response = await handle(req);
  for (const [key, value] of Object.entries(corsHeaders)) {
    response.headers.set(key, value);
  }
  return response;
});
