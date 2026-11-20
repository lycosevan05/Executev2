import { serviceClient } from "../revenuecatWebhook/configuration.ts";
import {
  constantTimeEqual,
  prepareOverdueVerifiedOwner,
} from "../revenuecatWebhook/reconcile.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const secret = Deno.env.get("EXECUTE_PRODUCTION_EXPIRY_OBSERVE_SECRET");
  if (
    !secret || secret.length < 32 ||
    !constantTimeEqual(
      req.headers.get("authorization") ?? "",
      `Bearer ${secret}`,
    )
  ) {
    return new Response(null, { status: 401 });
  }

  const owner = Deno.env.get("EXECUTE_PRODUCTION_EXPIRY_OBSERVE_OWNER");
  const project = Deno.env.get("EXECUTE_PRODUCTION_EXPIRY_OBSERVE_PROJECT");
  const products = Deno.env.get("EXECUTE_PRODUCTION_EXPIRY_OBSERVE_PRODUCTS")
    ?.split(",").map((value) => value.trim()) ?? [];
  const revenueCatKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
  let database: ReturnType<typeof serviceClient> | undefined;
  const client = () => database ??= serviceClient();
  if (
    Deno.env.get("SUPABASE_URL") !==
      "https://shoflbdwlmvttidoolvd.supabase.co" ||
    Deno.env.get("EXECUTE_PRODUCTION_EXPIRY_OBSERVE_ENABLED") !== "1" ||
    !owner || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(owner) ||
    !project || !/^[A-Za-z0-9_-]{1,100}$/.test(project) || !revenueCatKey ||
    !products.length || products.length > 24 ||
    products.some((product) => !/^[A-Za-z0-9_.-]{1,100}$/.test(product))
  ) return new Response(null, { status: 503 });

  try {
    const { data, error } = await client().rpc(
      "read_verified_billing_subject",
      {
        p_project: project,
        p_owner_id: owner,
      },
    );
    if (error || data?.state !== "active" || data.owner_id !== owner) {
      throw new Error("Verified canary is unavailable");
    }
    const scope = {
      environment: "PRODUCTION" as const,
      products: new Set(products),
      async resolve(identifier: string) {
        const result = await client().rpc("read_verified_billing_subject", {
          p_project: project,
          p_identifier: identifier,
        });
        if (result.error) throw result.error;
        return result.data;
      },
    };
    const proposed = await prepareOverdueVerifiedOwner(
      {
        fetch,
        revenueCatKey,
        stripeKey: Deno.env.get("STRIPE_SECRET_KEY"),
      },
      scope,
      data,
    );
    // No billing write, enrollment, queue or scheduling path.
    return Response.json({
      decision: !proposed
        ? "not_due"
        : proposed.data.plan === "premium"
        ? "would_preserve"
        : "would_expire",
    }, { headers: { "Cache-Control": "no-store" } });
  } catch {
    return Response.json({ error: "Expiry observation unavailable" }, {
      status: 503,
    });
  }
});
