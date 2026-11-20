import {
  serviceClient,
  verifiedReconciliation,
} from "../revenuecatWebhook/configuration.ts";
import {
  constantTimeEqual,
  reconcileOverdueSandboxOwner,
} from "../revenuecatWebhook/reconcile.ts";

Deno.serve(async (req) => {
  const reply = (status: number, data: Record<string, unknown>) =>
    Response.json(data, { status });
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  const secret = Deno.env.get("EXECUTE_SANDBOX_EXPIRY_JOB_SECRET");
  if (
    !secret || secret.length < 32 ||
    !constantTimeEqual(
      req.headers.get("authorization") ?? "",
      `Bearer ${secret}`,
    )
  ) return reply(401, { error: "Unauthorized" });

  const project = Deno.env.get("EXECUTE_VERIFIED_BILLING_PROJECT");
  const url = Deno.env.get("SUPABASE_URL");
  const revenueCatKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
  let database: ReturnType<typeof serviceClient> | undefined;
  const client = () => database ??= serviceClient();
  const verified = verifiedReconciliation(client);
  if (
    !project || !revenueCatKey || verified?.environment !== "SANDBOX" ||
    url !== "https://rnhwzvliewgsxhqysiom.supabase.co"
  ) return reply(503, { error: "Isolated Sandbox reconciliation unavailable" });

  const due = await client().rpc("list_due_verified_sandbox_app_store_owners", {
    p_project: project,
  });
  if (due.error || !Array.isArray(due.data)) {
    return reply(503, { error: "Sandbox due-owner read failed" });
  }
  const deps = {
    fetch,
    revenueCatKey,
    stripeKey: Deno.env.get("STRIPE_SECRET_KEY"),
  };
  const results = await Promise.allSettled(
    due.data.map((owner) =>
      reconcileOverdueSandboxOwner(deps, verified, owner)
    ),
  );
  const updated = results.filter((result) =>
    result.status === "fulfilled" && result.value
  ).length;
  const retry = results.filter((result) => result.status === "rejected").length;
  return reply(retry ? 503 : 200, { checked: results.length, updated, retry });
});
