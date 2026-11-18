import { getUser } from "../_shared/records.ts";
import { removeAccount } from "../deleteUserData/service.ts";
import { createStagedDeletionHandler } from "./handler.ts";
import { revokeStagedAppleAuthorization } from "./appleRevocation.ts";

Deno.serve(createStagedDeletionHandler({
  readSettings() {
    return {
      mode: Deno.env.get("EXECUTE_STAGED_DELETION_MODE"),
      actualProjectUrl: Deno.env.get("SUPABASE_URL"),
      approvedProjectUrl: Deno.env.get("EXECUTE_STAGED_DELETION_PROJECT_URL"),
      disposableOwnerId: Deno.env.get("EXECUTE_STAGED_DELETION_OWNER_UUID"),
    };
  },
  getUser,
  remove: (user) =>
    removeAccount(user, {
      allowStripe: false,
      requireUploadDrain: true,
      revokeAppleAuthorization: () =>
        revokeStagedAppleAuthorization(
          user,
          () => Deno.env.get("EXECUTE_STAGED_APPLE_GRANT"),
        ),
    }),
}));
