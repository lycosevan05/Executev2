import { getUser } from "../_shared/records.ts";
import { removeAccount } from "../deleteUserData/service.ts";
import { createStagedDeletionHandler } from "./handler.ts";
import { revokeStagedAppleAuthorization } from "./appleRevocation.ts";
import {
  readAppleGrantSettings,
  revokeCapturedAppleAuthorization,
} from "../appleGrantCapture/custody.ts";
import { createAppleGrantVault } from "../appleGrantCapture/vault.ts";

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
  remove: (user) => {
    const settings = readAppleGrantSettings((name) => Deno.env.get(name));
    return removeAccount(user, {
      allowStripe: false,
      requireUploadDrain: true,
      enableStagedBilling:
        Deno.env.get("EXECUTE_STAGED_BILLING_LINKED_DELETION") ===
          "1",
      stagedAppStoreProject:
        Deno.env.get("EXECUTE_STAGED_APP_STORE_LINKED_DELETION") === "1"
          ? Deno.env.get("EXECUTE_VERIFIED_BILLING_PROJECT") ?? ""
          : undefined,
      revokeAppleAuthorization: () => {
        if (settings) {
          return revokeCapturedAppleAuthorization(
            user,
            settings,
            createAppleGrantVault(),
          );
        }
        return revokeStagedAppleAuthorization(
          user,
          () => Deno.env.get("EXECUTE_STAGED_APPLE_GRANT"),
        );
      },
    });
  },
}));
