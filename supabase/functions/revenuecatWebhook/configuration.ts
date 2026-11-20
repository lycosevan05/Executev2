import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import type { VerifiedReconciliation } from "./reconcile.ts";

export function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Subscription storage is not configured.");
  return createClient(url, key);
}

export function verifiedReconciliation(
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
