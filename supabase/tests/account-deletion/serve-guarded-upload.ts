import { guardedStorageUpload } from "../../functions/guardedStorageUpload/service.ts";

if (Deno.env.get("SUPABASE_URL") !== "http://127.0.0.1:55421") {
  throw new Error("Expected the local Execute Auth fixture");
}

Deno.serve({ hostname: "127.0.0.1", port: 55423 }, guardedStorageUpload);
