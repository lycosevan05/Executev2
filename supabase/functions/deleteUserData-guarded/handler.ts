import { json } from "../_shared/cors.ts";
import { createDeletionHandler } from "../deleteUserData/handler.ts";
import type {
  deleteAccount,
  DeletionUser,
} from "../deleteUserData/deletion.ts";

type ReleaseSettings = {
  enabled: boolean;
  actualProjectUrl?: string;
  approvedProjectUrl?: string;
};

const receiptVersion = 1;
const maxBindingBytes = 512;
const hostedOrigin = /^https:\/\/[a-z0-9-]+\.supabase\.co$/;

async function readRequestBinding(request: Request): Promise<unknown> {
  if (
    request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !==
      "application/json" || !request.body
  ) return;
  const reader = request.body.getReader();
  const buffer = new Uint8Array(maxBindingBytes);
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.length > buffer.length) {
        await reader.cancel();
        return;
      }
      buffer.set(value, length);
      length += value.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(
      buffer.subarray(0, length),
    ));
  } catch {
    return;
  } finally {
    reader.releaseLock();
  }
}

/** The release entrypoint must supply a read-only rollout readiness check for
 * the installed upload, billing and Apple custody prerequisites. */
export function createGuardedReleaseDeletionHandler(dependencies: {
  readSettings(): ReleaseSettings;
  getUser(req: Request): Promise<DeletionUser>;
  isReady(): Promise<boolean>;
  remove(user: DeletionUser): ReturnType<typeof deleteAccount>;
}) {
  const unavailable = () =>
    json({ error: "Account deletion is unavailable." }, 503);
  return createDeletionHandler({
    async getUser(req) {
      const { enabled, actualProjectUrl, approvedProjectUrl } = dependencies
        .readSettings();
      if (
        !enabled || !actualProjectUrl ||
        actualProjectUrl !== approvedProjectUrl ||
        !hostedOrigin.test(actualProjectUrl)
      ) throw unavailable();

      const user = await dependencies.getUser(req);
      const requested = await readRequestBinding(req) as {
        receipt_version?: unknown;
        expected_owner?: unknown;
      } | undefined;
      if (
        !requested || typeof requested !== "object" ||
        Array.isArray(requested) ||
        Object.keys(requested).length !== 2 ||
        requested.receipt_version !== receiptVersion
      ) {
        throw json(
          { error: "Account deletion request could not be verified." },
          400,
        );
      }
      // The body only corroborates the authenticated identity. It cannot select
      // the account that reaches the deletion implementation.
      if (requested.expected_owner !== user.id) {
        throw json(
          { error: "Account deletion request could not be verified." },
          403,
        );
      }
      if (!await dependencies.isReady().catch(() => false)) throw unavailable();
      return user;
    },
    async remove(user) {
      const result = await dependencies.remove(user);
      return { ...result, receipt_version: receiptVersion, owner_id: user.id };
    },
  });
}
