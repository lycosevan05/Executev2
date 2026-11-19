import { deepEqual, equal, rejects } from "node:assert/strict";
import type { AppleDeletionUser } from "../deleteUserData-staged/appleRevocation.ts";
import {
  type AppleGrantSettings,
  type AppleGrantVault,
  captureAppleGrant,
  readAppleGrantSettings,
  revokeCapturedAppleAuthorization,
  type StoredAppleGrant,
} from "./custody.ts";
import { createAppleGrantCaptureHandler } from "./handler.ts";

const ownerId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const subject = "apple-fixture";
const settings: AppleGrantSettings = {
  origin: "https://appleqa.supabase.co",
  clientId: "invalid.example.apple-qa",
  clientSecret: "synthetic-client-secret",
  activeKeyId: "v1",
  keys: new Map([["v1", "2a".repeat(32)]]),
};
const user: AppleDeletionUser = {
  id: ownerId,
  identities: [{
    provider: "apple",
    user_id: ownerId,
    identity_data: { sub: subject },
  }],
};

function memoryVault() {
  let closing = false;
  let revoked = false;
  let acknowledgmentFails = false;
  const grants: StoredAppleGrant[] = [];
  const closes: [string, string | null, string][] = [];
  const vault: AppleGrantVault = {
    knows: (identity, fingerprints) => {
      if (closing) throw new Error("closed");
      equal(identity.ownerId, ownerId);
      equal(identity.subject, subject);
      return Promise.resolve(
        grants.some((grant) => fingerprints.includes(grant.fingerprint)),
      );
    },
    save: (id, grant) => {
      if (closing) throw new Error("closed");
      equal(id, ownerId);
      grants.push(grant);
      return Promise.resolve();
    },
    close: (id, sub, client) => {
      closes.push([id, sub, client]);
      closing = true;
      return Promise.resolve({ revoked, grants: grants.slice() });
    },
    confirmRevoked: (id, grantId) => {
      equal(id, ownerId);
      if (acknowledgmentFails) {
        throw new Error("DB failed after Apple response");
      }
      const idx = grants.findIndex((grant) => grant.id === grantId);
      if (idx >= 0) {
        grants.splice(idx, 1);
        revoked = grants.length === 0;
      }
      return Promise.resolve();
    },
  };
  return {
    grants,
    closes,
    vault,
    setAcknowledgmentFailure: (value: boolean) => acknowledgmentFails = value,
  };
}

const signatureAlgorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
const keyPair = crypto.subtle.generateKey(
  {
    ...signatureAlgorithm,
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
  },
  true,
  ["sign", "verify"],
);

function encode(input: Uint8Array) {
  return btoa(String.fromCharCode(...input)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replace(/=+$/, "");
}

async function providerFixture(sub = subject) {
  const { publicKey, privateKey } = await keyPair;
  const encoder = new TextEncoder();
  const key = {
    ...await crypto.subtle.exportKey("jwk", publicKey),
    kid: "key",
    use: "sig",
  };
  const payload = {
    sub,
    aud: settings.clientId,
    iss: "https://appleid.apple.com",
    exp: Math.floor(Date.now() / 1_000) + 60,
  };
  const input = [
    encode(encoder.encode(JSON.stringify({ alg: "RS256", kid: key.kid }))),
    encode(encoder.encode(JSON.stringify(payload))),
  ].join(".");
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      signatureAlgorithm,
      privateKey,
      encoder.encode(input),
    ),
  );
  const requests: string[] = [];
  const revoked: string[] = [];
  let failToken: string | undefined;
  const request = (url: string, init: RequestInit) => {
    equal(new URL(url).origin, "https://appleid.apple.com");
    equal(init.redirect, "error");
    requests.push(new URL(url).pathname);
    if (url.endsWith("/auth/keys")) {
      return Promise.resolve(Response.json({ keys: [key] }));
    }
    const body = init.body as URLSearchParams;
    equal(body.get("client_id"), settings.clientId);
    equal(body.get("client_secret"), settings.clientSecret);
    if (url.endsWith("/auth/token")) {
      return Promise.resolve(
        Response.json({ id_token: `${input}.${encode(signature)}` }),
      );
    }
    equal(new URL(url).pathname, "/auth/revoke");
    const token = body.get("token")!;
    revoked.push(token);
    return Promise.resolve(
      new Response(null, { status: token === failToken ? 503 : 200 }),
    );
  };
  return {
    request,
    requests,
    revoked,
    failOn: (token?: string) => failToken = token,
  };
}

Deno.test("capture is disabled by default and rejects malformed or cross-project enablement", () => {
  const config: Record<string, string> = {
    EXECUTE_APPLE_GRANT_MODE: "enabled",
    SUPABASE_URL: settings.origin,
    EXECUTE_APPLE_GRANT_PROJECT_URL: settings.origin,
    EXECUTE_APPLE_GRANT_CLIENT_ID: settings.clientId,
    EXECUTE_APPLE_GRANT_CLIENT_SECRET: settings.clientSecret,
    EXECUTE_APPLE_GRANT_KEY_ID: "v1",
    EXECUTE_APPLE_GRANT_KEYS: JSON.stringify(Object.fromEntries(settings.keys)),
  };
  equal(readAppleGrantSettings(() => undefined), undefined);
  deepEqual(readAppleGrantSettings((name) => config[name]), settings);
  for (
    const bad of [
      { EXECUTE_APPLE_GRANT_PROJECT_URL: "https://other.supabase.co" },
      {
        SUPABASE_URL: "https://other.example",
        EXECUTE_APPLE_GRANT_PROJECT_URL: "https://other.example",
      },
      { EXECUTE_APPLE_GRANT_KEYS: '{"v2":"invalid-secret"}' },
    ]
  ) {
    const fixture: Record<string, string | undefined> = { ...config, ...bad };
    try {
      readAppleGrantSettings((name) => fixture[name]);
      throw new Error("Unexpected enablement.");
    } catch (error) {
      equal((error as Error).message, "Apple grant custody is unavailable.");
    }
  }
});

Deno.test("only an authenticated Apple owner can send one bounded token", async () => {
  const { vault, grants } = memoryVault();
  const provider = await providerFixture();
  let authorized = true;
  let identity = user;
  const handler = createAppleGrantCaptureHandler({
    settings: () => settings,
    getUser: () =>
      authorized
        ? Promise.resolve(identity)
        : Promise.reject(new Error("secret")),
    vault: () => vault,
    providerRequest: provider.request,
  });
  function request(body: unknown) {
    return new Request(settings.origin + "/functions/v1/appleGrantCapture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  }
  authorized = false;
  equal((await handler(request({ refreshToken: "token" }))).status, 401);
  authorized = true;
  identity = { id: ownerId, app_metadata: { provider: "apple" } };
  equal((await handler(request({ refreshToken: "token" }))).status, 403);
  identity = user;
  equal(
    (await handler(request({ refreshToken: "x".repeat(16400) }))).status,
    400,
  );
  equal(
    (await handler(request({ refreshToken: "token", subject: "untrusted" })))
      .status,
    400,
  );
  equal(provider.requests.length, 0);
  equal(
    (await handler(request({ refreshToken: "fixture-refresh-token" }))).status,
    204,
  );
  equal(grants.length, 1);
  equal(JSON.stringify(grants).includes("fixture-refresh-token"), false);
  equal(JSON.stringify(grants).includes(settings.clientSecret), false);
});

Deno.test("signed subject must match and repeated tokens reuse their existing proof after rotation", async () => {
  const { vault, grants } = memoryVault();
  const token = "synthetic-refresh-private";
  const foreign = await providerFixture("someone-else");
  await rejects(
    () => captureAppleGrant(user, token, settings, vault, foreign.request),
    /custody could not be confirmed/,
  );
  equal(grants.length, 0);
  const provider = await providerFixture();
  await captureAppleGrant(user, token, settings, vault, provider.request);
  await captureAppleGrant(
    user,
    token,
    {
      ...settings,
      activeKeyId: "v2",
      keys: new Map([...settings.keys, ["v2", "b3".repeat(32)]]),
    },
    vault,
    provider.request,
  );
  equal(grants.length, 1);
  deepEqual(provider.requests, ["/auth/token", "/auth/keys"]);
});

Deno.test("tampering with ciphertext or moving to another Auth owner stops revocation", async () => {
  const { vault, grants } = memoryVault();
  const provider = await providerFixture();
  await captureAppleGrant(
    user,
    "synthetic-token-a",
    settings,
    vault,
    provider.request,
  );
  const foreignOwner = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef";
  const unrelated: AppleDeletionUser = {
    id: foreignOwner,
    identities: [{
      provider: "apple",
      user_id: foreignOwner,
      identity_data: { sub: subject },
    }],
  };
  await rejects(
    () =>
      revokeCapturedAppleAuthorization(
        unrelated,
        settings,
        vault,
        provider.request,
      ),
    /revocation could not be confirmed/,
  );
  grants[0].ciphertext = (grants[0].ciphertext.startsWith("a") ? "b" : "a") +
    grants[0].ciphertext.slice(1);
  await rejects(
    () =>
      revokeCapturedAppleAuthorization(user, settings, vault, provider.request),
    /revocation could not be confirmed/,
  );
  equal(provider.revoked.length, 0);
});

Deno.test("provider failures keep undischarged ciphertext and retries keep the revocation receipt", async () => {
  const { vault, grants } = memoryVault();
  const provider = await providerFixture();
  await captureAppleGrant(
    user,
    "synthetic-token-a",
    settings,
    vault,
    provider.request,
  );
  await captureAppleGrant(
    user,
    "synthetic-token-b",
    settings,
    vault,
    provider.request,
  );
  provider.failOn("synthetic-token-b");
  await rejects(
    () =>
      revokeCapturedAppleAuthorization(user, settings, vault, provider.request),
    /revocation could not be confirmed/,
  );
  equal(grants.length, 1);
  await rejects(
    () =>
      captureAppleGrant(
        user,
        "synthetic-token-c",
        settings,
        vault,
        provider.request,
      ),
    /custody could not be confirmed/,
  );
  provider.failOn();
  equal(
    await revokeCapturedAppleAuthorization(
      user,
      settings,
      vault,
      provider.request,
    ),
    "revoked",
  );
  equal(
    await revokeCapturedAppleAuthorization(
      user,
      settings,
      vault,
      provider.request,
    ),
    "revoked",
  );
  deepEqual(provider.revoked, [
    "synthetic-token-a",
    "synthetic-token-b",
    "synthetic-token-b",
  ]);
  equal(grants.length, 0);
});

Deno.test("a lost database acknowledgment retries the same Apple revoke without revalidating the token", async () => {
  const { vault, grants, setAcknowledgmentFailure } = memoryVault();
  const provider = await providerFixture();
  await captureAppleGrant(
    user,
    "synthetic-refresh-token",
    settings,
    vault,
    provider.request,
  );
  setAcknowledgmentFailure(true);
  await rejects(() =>
    revokeCapturedAppleAuthorization(user, settings, vault, provider.request)
  );
  equal(grants.length, 1);
  setAcknowledgmentFailure(false);
  equal(
    await revokeCapturedAppleAuthorization(
      user,
      settings,
      vault,
      provider.request,
    ),
    "revoked",
  );
  deepEqual(provider.requests, [
    "/auth/token",
    "/auth/keys",
    "/auth/revoke",
    "/auth/revoke",
  ]);
});

Deno.test("legacy Apple and other Auth accounts receive the appropriate outcome without a provider request", async () => {
  const provider = await providerFixture();
  const legacy = memoryVault();
  equal(
    await revokeCapturedAppleAuthorization(
      user,
      settings,
      legacy.vault,
      provider.request,
    ),
    "manual_required",
  );
  equal(
    await revokeCapturedAppleAuthorization(
      { id: ownerId },
      settings,
      memoryVault().vault,
      provider.request,
    ),
    undefined,
  );
  equal(provider.requests.length, 0);
});
