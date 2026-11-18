import { json } from "../_shared/cors.ts";
import type { DeletionUser } from "../deleteUserData/deletion.ts";
import { createDeletionHandler } from "../deleteUserData/handler.ts";

type AcceptanceSettings = {
  mode?: string;
  actualProjectUrl?: string;
  approvedProjectUrl?: string;
  disposableOwnerId?: string;
};

const canonicalUuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

function acceptanceOwner(settings: AcceptanceSettings): string | undefined {
  const { mode, actualProjectUrl, approvedProjectUrl, disposableOwnerId } =
    settings;
  if (
    mode !== "disposable-account" || !actualProjectUrl ||
    actualProjectUrl !== approvedProjectUrl || !disposableOwnerId ||
    !canonicalUuid.test(disposableOwnerId)
  ) return;

  try {
    const url = new URL(actualProjectUrl);
    const local = url.protocol === "http:" && url.hostname === "127.0.0.1" &&
      url.port !== "";
    if (
      url.origin !== actualProjectUrl || (url.protocol !== "https:" && !local)
    ) {
      return;
    }
  } catch {
    return;
  }
  return disposableOwnerId;
}

export function createStagedDeletionHandler(dependencies: {
  readSettings(): AcceptanceSettings;
  getUser(req: Request): Promise<DeletionUser>;
  remove(user: DeletionUser): Promise<unknown>;
}) {
  return createDeletionHandler({
    async getUser(req) {
      const expectedOwner = acceptanceOwner(dependencies.readSettings());
      if (!expectedOwner) {
        throw json({ error: "Account deletion is unavailable." }, 503);
      }

      const user = await dependencies.getUser(req);
      if (user.id !== expectedOwner) {
        throw json({
          error: "Account deletion is unavailable for this account.",
        }, 403);
      }
      return user;
    },
    remove: dependencies.remove,
  });
}
