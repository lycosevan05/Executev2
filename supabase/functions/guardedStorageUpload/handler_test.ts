import { createGuardedUploadHandler } from "./handler.ts";

const owner = "faebea21-5e53-4eaa-8cef-ddb863c6a54a";
const otherOwner = "4ef89ed6-2bbc-487f-8f13-87a3bd6c71cc";
const dispatch = "e30fc3e3-03c7-4c60-9b18-fb6584c2f567";
const destination = `${owner}/receipt.jpg`;

function assertEquals(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

function request(path = destination, options: RequestInit = {}) {
  const url = new URL("https://example.invalid/guardedStorageUpload");
  url.searchParams.set("bucket", "uploads");
  url.searchParams.set("path", path);
  return new Request(url, {
    method: "POST",
    body: new Uint8Array([7, 8, 9]),
    headers: {
      "content-type": "image/jpeg",
      authorization: "Bearer disposable",
    },
    ...options,
  });
}

function setup(
  outcome: "stored" | "already-exists" | "unverified" | "throw" = "stored",
) {
  const calls: unknown[][] = [];
  const deps: Parameters<typeof createGuardedUploadHandler>[0] = {
    getUser: () => {
      calls.push(["authenticate"]);
      return Promise.resolve({ id: owner });
    },
    createWriter: () => ({
      begin: (uuid, path) => {
        calls.push(["begin", uuid, path]);
        return Promise.resolve({ kind: "registered", id: dispatch, path });
      },
      send: (path, bytes, type) => {
        calls.push(["send", path, Array.from(bytes), type]);
        if (outcome === "throw") return Promise.reject(new Error("timeout"));
        return Promise.resolve(outcome);
      },
      finish: (uuid, id) => {
        calls.push(["finish", uuid, id]);
        return Promise.resolve();
      },
    }),
  };
  return { calls, deps, handler: createGuardedUploadHandler(deps, 4) };
}

Deno.test("browser preflight and unsupported HTTP methods never create uploads", async () => {
  const { calls, handler } = setup();
  const preflight = await handler(
    request(destination, { method: "OPTIONS", body: undefined }),
  );
  assertEquals(preflight.status, 200);
  assertEquals(
    preflight.headers.get("Access-Control-Allow-Headers")?.includes("apikey"),
    true,
  );
  assertEquals(
    (await handler(request(destination, { method: "PUT" }))).status,
    405,
  );
  assertEquals(calls, []);
});

Deno.test("Authorization, exact owner, destination and MIME are enforced", async () => {
  const { calls, handler } = setup();
  assertEquals(
    (await handler(request(destination, { headers: {} }))).status,
    401,
  );
  assertEquals(
    (await handler(request(`${otherOwner}/receipt.jpg`))).status,
    403,
  );
  assertEquals(
    (await handler(request(`${owner}/nested/already.jpg`))).status,
    400,
  );
  assertEquals((await handler(request(`${owner}/..`))).status, 400);
  assertEquals((await handler(request(`${owner}/receipt.gif\n`))).status, 400);
  assertEquals(
    (await handler(request(destination, {
      headers: {
        authorization: "Bearer disposable",
        "content-type": "application/json",
      },
    }))).status,
    415,
  );
  assertEquals(calls, [["authenticate"]]);
});

Deno.test("binary upload is written once after exact path registration and acknowledges completion", async () => {
  const { calls, handler } = setup();
  const reply = await handler(request(`${owner.toUpperCase()}/receipt.jpg`));
  assertEquals(reply.status, 201);
  assertEquals(await reply.json(), { path: destination });
  assertEquals(calls, [
    ["authenticate"],
    ["begin", owner, destination],
    ["send", destination, [7, 8, 9], "image/jpeg"],
    ["finish", owner, dispatch],
  ]);
});

Deno.test("oversized, empty and interrupted request bodies never register dispatches", async () => {
  const { calls, handler } = setup();
  assertEquals(
    (await handler(request(destination, { body: new Uint8Array(5) }))).status,
    413,
  );
  assertEquals(
    (await handler(request(destination, { body: new Uint8Array() }))).status,
    400,
  );
  const broken = new ReadableStream<Uint8Array>({
    pull(c) {
      c.error(new Error("interrupted"));
    },
  });
  assertEquals(
    (await handler(request(destination, { body: broken }))).status,
    400,
  );
  assertEquals(calls, [["authenticate"], ["authenticate"], ["authenticate"]]);
});

Deno.test("closed or unverifiable dispatch registration prevents Storage writes", async () => {
  const { calls, deps } = setup();
  const writer = deps.createWriter();
  const closed = createGuardedUploadHandler({
    ...deps,
    createWriter: () => ({
      ...writer,
      begin: () => Promise.resolve({ kind: "closed" }),
    }),
  });
  const invalid = createGuardedUploadHandler({
    ...deps,
    createWriter: () => ({
      ...writer,
      begin: () =>
        Promise.resolve({ kind: "registered", id: dispatch, path: otherOwner }),
    }),
  });
  assertEquals((await closed(request())).status, 409);
  assertEquals((await invalid(request())).status, 503);
  assertEquals(calls, [["authenticate"], ["authenticate"]]);
});

Deno.test("verifiable duplicate clears its dispatch while uncertain outcomes remain pending", async () => {
  const duplicate = setup("already-exists");
  assertEquals((await duplicate.handler(request())).status, 409);
  assertEquals(duplicate.calls.at(-1), ["finish", owner, dispatch]);
  for (const outcome of ["unverified", "throw"] as const) {
    const unknown = setup(outcome);
    assertEquals((await unknown.handler(request())).status, 503);
    assertEquals(unknown.calls.at(-1), [
      "send",
      destination,
      [7, 8, 9],
      "image/jpeg",
    ]);
  }
});

Deno.test("a known write with uncertain ledger acknowledgment does not return a success URL", async () => {
  const { calls, deps } = setup();
  const writer = deps.createWriter();
  const handler = createGuardedUploadHandler({
    ...deps,
    createWriter: () => ({
      ...writer,
      finish: () => Promise.reject(new Error("connection lost")),
    }),
  });
  assertEquals((await handler(request())).status, 503);
  assertEquals(calls.at(-1), ["send", destination, [7, 8, 9], "image/jpeg"]);
});
