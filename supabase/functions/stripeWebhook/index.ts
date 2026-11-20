import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";
import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createStripeHandler, type StripeDependencies } from "./reconcile.ts";

function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Subscription storage is not configured.");
  return createClient(url, key);
}

function verifiedWriter(): StripeDependencies["verified"] {
  const project = Deno.env.get("EXECUTE_VERIFIED_BILLING_PROJECT");
  const approvedURL = Deno.env.get("EXECUTE_VERIFIED_BILLING_SUPABASE_URL");
  const environment = Deno.env.get("EXECUTE_VERIFIED_BILLING_ENVIRONMENT");
  if (
    project === undefined && approvedURL === undefined &&
    environment === undefined
  ) {
    return undefined;
  }
  if (
    !project || !/^[A-Za-z0-9_-]{1,100}$/.test(project) || !approvedURL ||
    approvedURL !== Deno.env.get("SUPABASE_URL") ||
    (environment !== "SANDBOX" && environment !== "PRODUCTION")
  ) return false;
  return {
    environment,
    async read(ownerId) {
      const { data, error } = await serviceClient().rpc(
        "read_verified_billing_subject",
        {
          p_project: project,
          p_owner_id: ownerId,
        },
      );
      if (error) throw error;
      return data;
    },
    async apply(changes) {
      const { data, error } = await serviceClient().rpc(
        "apply_verified_billing_projections",
        {
          p_project: project,
          p_environment: environment,
          p_changes: changes,
        },
      );
      if (error) throw error;
      if (data !== changes.length) {
        throw new Error("Incomplete verified Stripe reconciliation");
      }
    },
  };
}

// The SDK is used only for raw-body signature verification, never provider API
// calls. Current Stripe REST lookups retain the existing 2024-04-10 API header.
const cryptoProvider = Stripe.createSubtleCryptoProvider();
Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const handler = createStripeHandler({
    webhookSecret: Deno.env.get("STRIPE_WEBHOOK_SECRET"),
    stripeKey: Deno.env.get("STRIPE_SECRET_KEY"),
    revenueCatKey: Deno.env.get("REVENUECAT_SECRET_API_KEY"),
    verified: verifiedWriter(),
    fetch,
    verifyEvent: (body, signature, secret) =>
      Stripe.webhooks.constructEventAsync(
        body,
        signature,
        secret,
        undefined,
        cryptoProvider,
      ),
    async read(userId) {
      const { data, error } = await serviceClient().from("user_subscriptions")
        .select("data,updated_date").eq("data->>user_id", userId).maybeSingle();
      if (error) throw error;
      return data;
    },
    async apply(changes) {
      const { data, error } = await serviceClient().rpc(
        "reconcile_revenuecat_subscriptions",
        { p_changes: changes },
      );
      if (error) throw error;
      if (data !== changes.length) {
        throw new Error("Incomplete subscription reconciliation");
      }
    },
  });
  const response = await handler(req);
  for (const [key, value] of Object.entries(corsHeaders)) {
    response.headers.set(key, value);
  }
  return response;
});
