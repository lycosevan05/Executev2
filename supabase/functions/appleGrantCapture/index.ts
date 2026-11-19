import { getUser } from "../_shared/records.ts";
import { readAppleGrantSettings } from "./custody.ts";
import { createAppleGrantCaptureHandler } from "./handler.ts";
import { createAppleGrantVault } from "./vault.ts";

Deno.serve(createAppleGrantCaptureHandler({
  settings: () => readAppleGrantSettings((name) => Deno.env.get(name)),
  getUser,
  vault: createAppleGrantVault,
}));
