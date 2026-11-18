import { deepEqual, equal, rejects } from "node:assert/strict";
import {
  type AppleDeletionUser,
  revokeStagedAppleAuthorization,
  verifyStagedAppleGrant,
} from "./appleRevocation.ts";
import { deleteAccount } from "../deleteUserData/deletion.ts";

const ownerId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const appleUser: AppleDeletionUser = {
  id: ownerId,
  identities: [
    {
      provider: "apple",
      user_id: ownerId,
      identity_data: { sub: "apple-synthetic-subject" },
    },
  ],
};
const fixtureGrant = {
  ownerId,
  subject: "apple-synthetic-subject",
  clientId: "invalid.example.staged-fixture",
  clientSecret: "synthetic-secret",
  refreshToken: "synthetic-refresh-token",
};
const lookup = () => JSON.stringify(fixtureGrant);
const trustedOwner = {
  ownerId,
  subject: fixtureGrant.subject,
  clientId: fixtureGrant.clientId,
};

const forbiddenRequest: typeof fetch = () => {
  throw new Error("Unexpected provider operation");
};

const signatureAlgorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
const issuer = "https://appleid.apple.com";
const keyPair = crypto.subtle.generateKey(
  {
    ...signatureAlgorithm,
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
  },
  true,
  ["sign", "verify"],
);

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(
    /\//g,
    "_",
  ).replace(/=+$/, "");
}

async function appleFixture(overrides: Record<string, unknown> = {}) {
  const { publicKey, privateKey } = await keyPair;
  const key = {
    ...await crypto.subtle.exportKey("jwk", publicKey),
    kid: "fixture-key",
    use: "sig",
  };
  const encoder = new TextEncoder();
  const claims = {
    iss: issuer,
    aud: fixtureGrant.clientId,
    sub: fixtureGrant.subject,
    exp: Math.floor(Date.now() / 1_000) + 60,
    ...overrides,
  };
  const header = base64Url(
    encoder.encode(JSON.stringify({ alg: key.alg, kid: key.kid })),
  );
  const payload = base64Url(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    signatureAlgorithm,
    privateKey,
    encoder.encode(signingInput),
  );

  return {
    jwks: { keys: [key] },
    token: {
      id_token: `${signingInput}.${base64Url(new Uint8Array(signature))}`,
    },
  };
}

Deno.test("unrelated identities do not read fixture credentials or call Apple", async () => {
  equal(
    await revokeStagedAppleAuthorization(
      { id: ownerId, app_metadata: { provider: "google" } },
      () => {
        throw new Error("Unexpected credential read");
      },
      forbiddenRequest,
    ),
    undefined,
  );
});

Deno.test("Apple-backed accounts missing credentials receive manual guidance", async () => {
  for (
    const user of [appleUser, {
      id: ownerId,
      app_metadata: { providers: ["email", "apple"] },
    }]
  ) {
    equal(
      await revokeStagedAppleAuthorization(
        user,
        () => undefined,
        forbiddenRequest,
      ),
      "manual_required",
    );
  }
});

Deno.test("provisioning verifies a signed exact-owner grant without revoking it", async () => {
  const { jwks, token } = await appleFixture();
  const requests: string[] = [];
  const request = (url: string, init: RequestInit) => {
    requests.push(url);
    equal(init.redirect, "error");
    equal(init.signal instanceof AbortSignal, true);
    if (url === `${issuer}/auth/token`) {
      equal(init.method, "POST");
      deepEqual(Object.fromEntries(init.body as URLSearchParams), {
        client_id: fixtureGrant.clientId,
        client_secret: fixtureGrant.clientSecret,
        grant_type: "refresh_token",
        refresh_token: fixtureGrant.refreshToken,
      });
      return Promise.resolve(Response.json(token));
    }
    if (url === `${issuer}/auth/keys`) {
      equal(init.method, "GET");
      equal(init.body, undefined);
      return Promise.resolve(Response.json(jwks));
    }
    throw new Error("Unexpected provider operation");
  };
  await verifyStagedAppleGrant(trustedOwner, lookup(), request);
  deepEqual(requests, [`${issuer}/auth/token`, `${issuer}/auth/keys`]);
});

Deno.test("staged deletion can retry revocation after a partial delete", async () => {
  let attempts = 0;
  const request = (url: string, init: RequestInit) => {
    attempts += 1;
    equal(url, `${issuer}/auth/revoke`);
    equal(init.method, "POST");
    equal(init.redirect, "error");
    equal(init.signal instanceof AbortSignal, true);
    deepEqual(Object.fromEntries(init.body as URLSearchParams), {
      client_id: fixtureGrant.clientId,
      client_secret: fixtureGrant.clientSecret,
      token: fixtureGrant.refreshToken,
      token_type_hint: "refresh_token",
    });
    return Promise.resolve(new Response(null, { status: 200 }));
  };
  for (let index = 0; index < 2; index += 1) {
    equal(
      await revokeStagedAppleAuthorization(appleUser, lookup, request),
      "revoked",
    );
  }
  equal(attempts, 2);
});

Deno.test("malformed and mismatched grants never reach Apple", async () => {
  for (
    const raw of [
      "{",
      "null",
      "{}",
      JSON.stringify({ ...fixtureGrant, subject: "different-subject" }),
      JSON.stringify({ ...fixtureGrant, ownerId: "different-owner" }),
    ]
  ) {
    await rejects(
      () =>
        revokeStagedAppleAuthorization(appleUser, () => raw, forbiddenRequest),
      /^Error: Apple deletion credentials/,
    );
  }

  await rejects(() =>
    revokeStagedAppleAuthorization(
      {
        ...appleUser,
        identities: appleUser.identities?.map((identity) => ({
          ...identity,
          user_id: "different-owner",
        })),
      },
      lookup,
      forbiddenRequest,
    ), /could not be verified/);
});

Deno.test("operator labels must match the independently verified owner and client", async () => {
  for (
    const override of [
      { ownerId: "11111111-2222-3333-4444-555555555555" },
      { subject: "different-subject" },
      { clientId: "invalid.example.unrelated-service" },
    ]
  ) {
    await rejects(
      () =>
        verifyStagedAppleGrant(
          trustedOwner,
          JSON.stringify({ ...fixtureGrant, ...override }),
          forbiddenRequest,
        ),
      { message: "Apple deletion credentials could not be verified." },
    );
  }
});

Deno.test("provisioning rejects Apple grants for a different subject, audience or issuer", async () => {
  const claimOverrides = [
    { sub: "different-subject" },
    { aud: "invalid.example.unrelated-service" },
    { iss: "https://invalid.example" },
    { exp: 1 },
  ];
  for (const override of claimOverrides) {
    const { jwks, token } = await appleFixture(override);
    const requests: string[] = [];
    await rejects(
      () =>
        verifyStagedAppleGrant(trustedOwner, lookup(), (url) => {
          requests.push(url);
          return Promise.resolve(
            Response.json(url === `${issuer}/auth/token` ? token : jwks),
          );
        }),
      { message: "Apple deletion credentials could not be verified." },
    );
    deepEqual(requests, [`${issuer}/auth/token`, `${issuer}/auth/keys`]);
  }
});

Deno.test("provisioning rejects a modified identity signature", async () => {
  const { jwks, token } = await appleFixture();
  const [header, payload, signature] = token.id_token.split(".");
  const altered = `${signature[0] === "A" ? "B" : "A"}${signature.slice(1)}`;
  const requests: string[] = [];
  await rejects(
    () =>
      verifyStagedAppleGrant(trustedOwner, lookup(), (url) => {
        requests.push(url);
        return Promise.resolve(Response.json(
          url === `${issuer}/auth/token`
            ? { id_token: `${header}.${payload}.${altered}` }
            : jwks,
        ));
      }),
    { message: "Apple deletion credentials could not be verified." },
  );
  deepEqual(requests, [`${issuer}/auth/token`, `${issuer}/auth/keys`]);
});

Deno.test("unknown provider outcomes fail closed without leaking provider details", async () => {
  const { jwks, token } = await appleFixture();
  for (const failure of ["/auth/token", "/auth/keys", "/auth/revoke"]) {
    for (const networkError of [true, false]) {
      const requests: string[] = [];
      const request = (url: string) => {
        requests.push(url);
        if (url === `${issuer}${failure}`) {
          return networkError
            ? Promise.reject(new Error("synthetic-private-detail"))
            : Promise.resolve(
              new Response("synthetic-private-detail", {
                status: 400,
              }),
            );
        }
        return Promise.resolve(
          Response.json(url === `${issuer}/auth/token` ? token : jwks),
        );
      };
      await rejects(
        () =>
          failure === "/auth/revoke"
            ? revokeStagedAppleAuthorization(appleUser, lookup, request)
            : verifyStagedAppleGrant(trustedOwner, lookup(), request),
        {
          message: failure === "/auth/revoke"
            ? "Apple authorization revocation could not be confirmed."
            : "Apple deletion credentials could not be verified.",
        },
      );
      equal(requests.at(-1), `${issuer}${failure}`);
    }
  }
});

Deno.test("deletion closes billing projections before Apple and keeps data on failed revocation", async () => {
  const steps: string[] = [];
  const result = () =>
    deleteAccount(
      appleUser,
      ["profile"],
      {
        prepareRows: () =>
          Promise.resolve({
            subscriptionIds: ["sub_fixture"],
            closeBillingProjection: () => {
              steps.push("billing fence");
              return Promise.resolve();
            },
            deleteRows: () => {
              steps.push("rows");
              return Promise.resolve(1);
            },
          }),
        listUploads: () => Promise.resolve([]),
        removeUploads: () =>
          Promise.reject(new Error("Unexpected upload removal")),
        assertRowsAbsent: () => Promise.resolve(),
        deleteAuthentication: () => {
          steps.push("auth");
          return Promise.resolve();
        },
      },
      {
        verifyOwner: () => {
          steps.push("verify billing");
          return Promise.resolve();
        },
        cancel: () => {
          steps.push("cancel billing");
          return Promise.resolve();
        },
      },
      () => {
        steps.push("drain");
        return Promise.resolve();
      },
      () => {
        steps.push("Apple");
        if (steps.length === 4) return Promise.reject(new Error("Apple retry"));
        return Promise.resolve("manual_required");
      },
    );

  await rejects(result, /Apple retry/);
  deepEqual(steps, ["verify billing", "drain", "billing fence", "Apple"]);
  equal((await result()).apple_revocation, "manual_required");
  deepEqual(steps.slice(4), [
    "verify billing",
    "drain",
    "billing fence",
    "Apple",
    "cancel billing",
    "rows",
    "auth",
  ]);
});
