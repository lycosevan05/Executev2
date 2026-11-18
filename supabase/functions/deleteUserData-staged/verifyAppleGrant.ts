import { verifyStagedAppleGrant } from "./appleRevocation.ts";

if (import.meta.main) {
  try {
    await verifyStagedAppleGrant({
      ownerId: Deno.env.get("EXECUTE_STAGED_DELETION_OWNER_UUID") ?? "",
      subject: Deno.env.get("EXECUTE_STAGED_APPLE_AUTH_SUBJECT") ?? "",
      clientId: Deno.env.get("EXECUTE_STAGED_APPLE_CLIENT_ID") ?? "",
    }, Deno.env.get("EXECUTE_STAGED_APPLE_GRANT") ?? "");
    console.log("Verified Apple grant for the staged Auth owner.");
  } catch {
    console.error(
      "Could not verify the Apple grant for the staged Auth owner.",
    );
    Deno.exitCode = 1;
  }
}
