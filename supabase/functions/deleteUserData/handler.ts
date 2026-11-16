import { handleCors, json } from "../_shared/cors.ts";
import type { DeletionUser } from "./deletion.ts";
export function createDeletionHandler(dependencies: {
  getUser(req: Request): Promise<DeletionUser>;
  remove(user: DeletionUser): Promise<unknown>;
}) {
  return async (req: Request): Promise<Response> => {
    const cors = handleCors(req);
    if (cors) return cors;
    if (req.method !== "POST") {
      return json({ error: "Method not allowed." }, 405);
    }
    try {
      // The request body never selects the account; use authenticated identity only.
      const user = await dependencies.getUser(req);
      return json(await dependencies.remove(user));
    } catch (error) {
      if (error instanceof Response) return error;
      return json({
        error:
          "Account deletion could not finish. Your sign-in is retained where possible so you can retry. Contact support if this continues.",
      }, 500);
    }
  };
}
