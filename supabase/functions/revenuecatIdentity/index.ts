import { createServiceClient, getUser } from "../_shared/records.ts";
import { createIdentityHandler } from "./handler.ts";

Deno.serve(createIdentityHandler({
  scope: () => ({
    actualUrl: Deno.env.get("SUPABASE_URL"),
    approvedUrl: Deno.env.get("EXECUTE_VERIFIED_BILLING_SUPABASE_URL"),
    project: Deno.env.get("EXECUTE_VERIFIED_BILLING_PROJECT"),
    environment: Deno.env.get("EXECUTE_VERIFIED_BILLING_ENVIRONMENT"),
  }),
  authenticatedOwner: async (request) => (await getUser(request)).id,
  async readSubject(project, owner) {
    const { data, error } = await createServiceClient().rpc(
      "read_verified_billing_subject",
      { p_project: project, p_owner_id: owner },
    );
    if (error) throw error;
    return data;
  },
}));
