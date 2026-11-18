import { getUser } from "../_shared/records.ts";
import { createDeletionHandler } from "./handler.ts";
import { removeAccount } from "./service.ts";

// This local handler does not replace the retained hosted legacy function.
Deno.serve(createDeletionHandler({ getUser, remove: removeAccount }));
