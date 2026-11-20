import { handleCors, json } from "../_shared/cors.ts";

type Scope = {
  actualUrl?: string;
  approvedUrl?: string;
  project?: string;
  environment?: string;
};

interface Dependencies {
  scope(): Scope;
  authenticatedOwner(request: Request): Promise<string>;
  readSubject(project: string, owner: string): Promise<unknown>;
}

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const projectPattern = /^[A-Za-z0-9_-]{1,100}$/;
const hostedSupabase = /^https:\/\/[a-z0-9-]+\.supabase\.co$/;

function record(input: unknown): Record<string, unknown> | undefined {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? input as Record<string, unknown>
    : undefined;
}

function subscription(input: unknown, owner: string) {
  if (input === null) return null;
  const data = record(record(input)?.data);
  if (!data || data.user_id !== owner) throw new Error("Invalid snapshot");
  const fields: Record<string, string | boolean> = { user_id: owner };
  for (
    const name of [
      "plan",
      "status",
      "store",
      "current_period_end",
      "stripe_subscription_id",
    ]
  ) {
    const value = data[name];
    if (value != null) {
      if (typeof value !== "string" || value.length > 1000) {
        throw new Error("Invalid snapshot");
      }
      fields[name] = value;
    }
  }
  if (data.cancel_at_period_end != null) {
    if (typeof data.cancel_at_period_end !== "boolean") {
      throw new Error("Invalid snapshot");
    }
    fields.cancel_at_period_end = data.cancel_at_period_end;
  }
  return fields;
}

export function createIdentityHandler(deps: Dependencies) {
  return async (request: Request): Promise<Response> => {
    const cors = handleCors(request);
    if (cors) return cors;
    if (request.method !== "POST") {
      return json({ error: "Method unavailable." }, 405);
    }
    const { actualUrl, approvedUrl, project, environment } = deps.scope();
    if (
      !actualUrl || actualUrl !== approvedUrl ||
      !hostedSupabase.test(actualUrl) || !project ||
      !projectPattern.test(project) ||
      (environment !== "SANDBOX" && environment !== "PRODUCTION")
    ) {
      return json({ error: "Verified billing is unavailable." }, 503);
    }

    // The body is intentionally irrelevant. Only validated Auth can select
    // the owner, and reading this endpoint never enrolls a customer.
    let owner: string;
    try {
      owner = (await deps.authenticatedOwner(request)).toLowerCase();
      if (!uuid.test(owner)) throw new Error("Invalid owner");
    } catch {
      return json({ error: "Unauthorized." }, 401);
    }
    try {
      const subject = record(await deps.readSubject(project, owner));
      if (
        subject &&
        ["unresolved", "blocked", "retired"].some((state) =>
          state === subject.state
        )
      ) {
        return json({ error: "Verified billing is unavailable." }, 409);
      }
      const customerID = subject?.customer_id;
      if (
        subject?.state !== "active" || subject.owner_id !== owner ||
        subject.environment !== environment || typeof customerID !== "string" ||
        !uuid.test(customerID) || customerID === owner
      ) throw new Error("Invalid subject");
      const response = json({
        owner_id: owner,
        customer_id: customerID,
        subscription: subscription(subject.subscription, owner),
      });
      response.headers.set("Cache-Control", "no-store");
      return response;
    } catch {
      return json({ error: "Verified billing is unavailable." }, 503);
    }
  };
}
