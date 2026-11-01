import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createClient } from "@supabase/supabase-js";
import { createHandler } from "./reconcile.ts";

function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Subscription storage is not configured.");
  return createClient(url, key);
}

// The public gateway remains verify_jwt=false; this handler requires the
// existing RevenueCat bearer secret before any provider lookup or DB write.
// REVENUECAT_SECRET_API_KEY: server-only REST API v1 key for this RC project.
// STRIPE_SECRET_KEY: existing Stripe key, only used for rows with a Stripe ID.
// Deploy 20261021000000_reconcile_revenuecat_subscriptions.sql first.
Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const handle = createHandler({
    webhookSecret: Deno.env.get("REVENUECAT_WEBHOOK_SECRET"),
    revenueCatKey: Deno.env.get("REVENUECAT_SECRET_API_KEY"),
    stripeKey: Deno.env.get("STRIPE_SECRET_KEY"),
    fetch,
    async read(userId) {
      const { data, error } = await serviceClient().from(
        "user_subscriptions",
      )
        .select("data,updated_date").eq("data->>user_id", userId).maybeSingle();
      if (error) throw error;
      return data;
    },
    async apply(changes) {
      const { data, error } = await serviceClient().rpc(
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
