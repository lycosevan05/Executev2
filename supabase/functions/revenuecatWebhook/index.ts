import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createClient } from "@supabase/supabase-js";
import { createHandler, type VerifiedReconciliation } from "./reconcile.ts";

function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Subscription storage is not configured.");
  return createClient(url, key);
}

function verifiedReconciliation(
  client: () => ReturnType<typeof serviceClient>,
): VerifiedReconciliation | null | undefined {
  const project = Deno.env.get("EXECUTE_VERIFIED_BILLING_PROJECT");
  const url = Deno.env.get("EXECUTE_VERIFIED_BILLING_SUPABASE_URL");
  const appId = Deno.env.get("EXECUTE_VERIFIED_REVENUECAT_APP_ID");
  const environment = Deno.env.get("EXECUTE_VERIFIED_BILLING_ENVIRONMENT");
  const productList = Deno.env.get("EXECUTE_VERIFIED_REVENUECAT_PRODUCTS");
  if (
    [project, url, appId, environment, productList].every((value) =>
      value === undefined
    )
  ) return undefined;
  const products = productList?.split(",").map((value) => value.trim()) ?? [];
  if (
    !project || !/^[A-Za-z0-9_-]{1,100}$/.test(project) ||
    !url || url !== Deno.env.get("SUPABASE_URL") ||
    !appId || !/^[A-Za-z0-9_-]{1,100}$/.test(appId) ||
    (environment !== "SANDBOX" && environment !== "PRODUCTION") ||
    !products.length || products.length > 24 ||
    products.some((product) => !/^[A-Za-z0-9_.-]{1,100}$/.test(product))
  ) return null;

  return {
    appId,
    environment,
    products: new Set(products),
    async resolve(identifier) {
      const { data, error } = await client().rpc(
        "read_verified_billing_subject",
        {
          p_project: project,
          p_identifier: identifier,
        },
      );
      if (error) throw error;
      return data;
    },
    async apply(changes) {
      const { data, error } = await client().rpc(
        "apply_verified_billing_projections",
        {
          p_project: project,
          p_environment: environment,
          p_changes: changes,
        },
      );
      if (error) throw error;
      if (data !== changes.length) {
        throw new Error("Incomplete verified subscription reconciliation");
      }
    },
  };
}

// The public gateway remains verify_jwt=false; this handler requires the
// existing RevenueCat bearer secret before any provider lookup or DB write.
// REVENUECAT_SECRET_API_KEY: server-only REST API v1 key for this RC project.
// STRIPE_SECRET_KEY: existing Stripe key, only used for rows with a Stripe ID.
// Deploy 20261021000000_reconcile_revenuecat_subscriptions.sql first.
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
