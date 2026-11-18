import { guardedStorageUpload } from "../../functions/guardedStorageUpload/service.ts";
import { createStagedDeletionHandler } from "../../functions/deleteUserData-staged/handler.ts";
import { removeAccount } from "../../functions/deleteUserData/service.ts";
import { getUser } from "../../functions/_shared/records.ts";

const staged = createStagedDeletionHandler({
  readSettings: () => ({
    mode: "disposable-account",
    actualProjectUrl: Deno.env.get("SUPABASE_URL"),
    approvedProjectUrl: "http://127.0.0.1:55471",
    disposableOwnerId: Deno.env.get("EXECUTE_STAGED_DELETION_OWNER_UUID"),
  }),
  getUser,
  remove: (user) =>
    removeAccount(user, { allowStripe: false, requireUploadDrain: true }),
});

Deno.serve({ hostname: "127.0.0.1", port: 55473 }, (request) => {
  const path = new URL(request.url).pathname;
  if (path === "/health") return new Response("ready");
  if (path === "/functions/v1/guardedStorageUpload") {
    return guardedStorageUpload(request);
  }
  if (path === "/functions/v1/deleteUserData-staged") return staged(request);
  return new Response(null, { status: 404 });
});
