// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ENTITY_TABLES } from "../../functions/_shared/records.ts";
import {
  collectUploads,
  deleteAccount,
  validateUser,
} from "../../functions/deleteUserData/deletion.ts";
import {
  createDeletionStore,
  type DeletionClient,
} from "../../functions/deleteUserData/store.ts";

const endpoint = "http://127.0.0.1:55421";
const bucket = "uploads";
const body = "Execute W09 disposable Storage fixture";

function requireFixtureKey(name: string): string {
  const key = Deno.env.get(name);
  if (!key) throw new Error("Run through run_storage_lifecycle.py.");
  return key;
}

function client(key: string) {
  return createClient(endpoint, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      fetch(input, init) {
        const url = new URL(input instanceof Request ? input.url : input);
        if (url.origin !== endpoint) {
          throw new Error(
            "Only the verified local fixture may receive requests.",
          );
        }
        return fetch(input, { ...init, redirect: "error" });
      },
    },
  });
}
type Client = ReturnType<typeof client>;

function requireValue<T>(
  result: { data: T; error: unknown },
  operation: string,
): NonNullable<T> {
  if (result.error || result.data == null) throw new Error(operation);
  return result.data;
}

interface Owner {
  id: string;
  email: string;
  password: string;
  paths: string[];
}

async function run() {
  if (
    Deno.env.get("EXECUTE_ISOLATED_AUTH") !== "1" ||
    Deno.env.get("EXECUTE_ISOLATED_AUTH_URL") !== endpoint
  ) throw new Error("The dedicated local fixture is required.");

  const service = client(requireFixtureKey("EXECUTE_ISOLATED_AUTH_ADMIN_KEY"));
  const publicKey = requireFixtureKey("EXECUTE_ISOLATED_AUTH_PUBLIC_KEY");
  const files = service.storage.from(bucket);
  const store = createDeletionStore(
    service as unknown as DeletionClient,
    bucket,
  );
  const owners = new Map<string, Owner>();
  const testEmail = () => `w09-${crypto.randomUUID()}@example.com`;

  async function createOwner(email: string): Promise<Owner> {
    const password = crypto.randomUUID();
    const { data, error } = await service.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (error || !data.user) {
      throw new Error("Synthetic Auth owner could not be created.");
    }
    const { user } = data;
    validateUser(user);
    const owner = { id: user.id, email, password, paths: [] };
    owners.set(owner.id, owner);
    return owner;
  }

  async function upload(actor: Client, owner: Owner, name: string) {
    const path = `${owner.id}/${name}`;
    // Track paths before requesting upload so cleanup covers a lost response.
    owner.paths.push(path);
    requireValue(
      await actor.storage.from(bucket).upload(
        path,
        new Blob([body], { type: "text/plain" }),
        {
          contentType: "text/plain",
        },
      ),
      "Fixture Storage upload failed.",
    );
    const readback = requireValue(
      await files.download(path),
      "Uploaded bytes could not be read.",
    );
    if (await readback.text() !== body) {
      throw new Error("Storage returned unexpected bytes.");
    }
  }

  async function uploadAsOwner(owner: Owner, name: string) {
    const browser = client(publicKey);
    const { data, error } = await browser.auth.signInWithPassword({
      email: owner.email,
      password: owner.password,
    });
    if (error || data.user?.id !== owner.id) {
      throw new Error(
        "Synthetic owner could not sign in with its expected UUID.",
      );
    }
    await upload(browser, owner, name);
  }

  let failure: unknown;
  try {
    const target = await createOwner(testEmail());
    const unrelated = await createOwner(testEmail());
    await uploadAsOwner(target, "owner.txt");
    await upload(service, target, "nested/service.txt");
    await uploadAsOwner(unrelated, "untouched.txt");
    const inventory = await collectUploads(store, target.id);
    if (
      inventory.length !== target.paths.length ||
      !target.paths.every((path) => inventory.includes(path))
    ) {
      throw new Error(
        "Exact UUID inventory did not match the two fixture uploads.",
      );
    }

    const result = await deleteAccount(target, ENTITY_TABLES, store, {
      verifyOwner() {
        throw new Error(
          "Disposable deletion unexpectedly found billing references.",
        );
      },
      cancel() {
        throw new Error(
          "The Storage fixture must never call a billing provider.",
        );
      },
    });
    if (result.results.storage !== "deleted 2") {
      throw new Error("Deletion did not report removing both Storage objects.");
    }

    const auth = await service.auth.admin.getUserById(target.id);
    if (auth.error?.status !== 404 || auth.data.user) {
      throw new Error("Auth did not confirm the synthetic owner was removed.");
    }
    if ((await collectUploads(store, target.id)).length !== 0) {
      throw new Error("Storage still lists objects under the deleted owner.");
    }
    for (const path of target.paths) {
      if ((await files.exists(path)).data !== false) {
        throw new Error("Storage did not confirm an exact path was absent.");
      }
    }

    owners.delete(target.id);

    const otherFile = requireValue(
      await files.download(unrelated.paths[0]),
      "Unrelated owner's file was not readable after cleanup.",
    );
    if (await otherFile.text() !== body) {
      throw new Error("Unrelated bytes changed.");
    }
    const returning = await createOwner(target.email);
    if (returning.id === target.id) {
      throw new Error("Auth reused the deleted UUID.");
    }
    await uploadAsOwner(returning, "owner.txt");
  } catch (error) {
    failure = error;
  }

  let cleanupFailed = false;
  for (const owner of owners.values()) {
    try {
      if (owner.paths.length) {
        requireValue(
          await files.remove(owner.paths),
          "Fixture file cleanup failed.",
        );
      }
      const { error } = await service.auth.admin.deleteUser(owner.id);
      if (error && error.status !== 404) {
        throw new Error("Fixture Auth cleanup failed.");
      }
    } catch {
      cleanupFailed = true;
    }
  }
  if (cleanupFailed) {
    console.error(
      "Synthetic fixture cleanup was incomplete. Stop and purge the verified fixture.",
    );
  }
  if (failure) throw failure;
  if (cleanupFailed) throw new Error("Fixture cleanup was incomplete.");
  console.log(
    "W09 local lifecycle passed: owner and service uploads removed, Auth user removed, " +
      "unrelated bytes preserved, same-email replacement uploaded under its new UUID.",
  );
}

if (import.meta.main) {
  try {
    await run();
    // The SDK may keep background transport handles open after fixture cleanup.
    Deno.exit(0);
  } catch (error) {
    console.error(
      error instanceof Error ? error.message : "Storage fixture failed.",
    );
    Deno.exit(1);
  }
}
