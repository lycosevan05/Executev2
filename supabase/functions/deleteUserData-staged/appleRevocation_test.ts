import { deepEqual, equal, rejects } from "node:assert/strict";
import {
  type AppleDeletionUser,
  revokeStagedAppleAuthorization,
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

const forbiddenRequest: typeof fetch = () => {
  throw new Error("Unexpected provider operation");
};

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

Deno.test("trusted Apple refresh token is sent only to the fixed revocation endpoint", async () => {
  const request = (url: string, init: RequestInit) => {
    equal(url, "https://appleid.apple.com/auth/revoke");
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
  equal(
    await revokeStagedAppleAuthorization(appleUser, lookup, request),
    "revoked",
  );
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

Deno.test("unknown provider outcomes fail closed without leaking provider details", async () => {
  for (
    const request of [
      () =>
        Promise.resolve(
          new Response("synthetic-private-detail", {
            status: 400,
          }),
        ),
      () => Promise.reject(new Error("synthetic-private-detail")),
    ]
  ) {
    await rejects(
      () => revokeStagedAppleAuthorization(appleUser, lookup, request),
      { message: "Apple authorization revocation could not be confirmed." },
    );
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
