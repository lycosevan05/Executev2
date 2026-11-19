import type {
  AppleRevocationOutcome,
  DeletionUser,
} from "../deleteUserData/deletion.ts";
import { validateUser } from "../deleteUserData/deletion.ts";

interface AuthIdentity {
  provider: string;
  user_id: string;
  identity_data?: Record<string, unknown>;
}

export interface AppleDeletionUser extends DeletionUser {
  identities?: AuthIdentity[];
  app_metadata?: {
    provider?: string;
    providers?: string[];
  };
}

export interface StagedAppleGrant {
  ownerId: string;
  subject: string;
  clientId: string;
  clientSecret: string;
  refreshToken: string;
}

const appleIssuer = "https://appleid.apple.com";
const keysEndpoint = `${appleIssuer}/auth/keys`;
const tokenEndpoint = `${appleIssuer}/auth/token`;
const revokeEndpoint = `${appleIssuer}/auth/revoke`;
const signatureAlgorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

function loadGrant(raw: string): StagedAppleGrant {
  let grant: Partial<StagedAppleGrant> | null;
  try {
    grant = JSON.parse(raw);
  } catch {
    throw new Error("Apple deletion credentials are unavailable.");
  }
  if (!grant || typeof grant !== "object" || Array.isArray(grant)) {
    throw new Error("Apple deletion credentials are unavailable.");
  }
  const { ownerId, subject, clientId, clientSecret, refreshToken } = grant;
  if (
    typeof ownerId !== "string" || !ownerId ||
    typeof subject !== "string" || !subject ||
    typeof clientId !== "string" || !clientId ||
    typeof clientSecret !== "string" || !clientSecret ||
    typeof refreshToken !== "string" || !refreshToken
  ) {
    throw new Error("Apple deletion credentials are unavailable.");
  }
  return { ownerId, subject, clientId, clientSecret, refreshToken };
}

function decodeBase64Url(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Invalid Apple token encoding.");
  }
  return Uint8Array.from(
    atob(value.replace(/-/g, "+").replace(/_/g, "/")),
    (byte) => byte.charCodeAt(0),
  );
}

async function verifyGrantSubject(
  grant: StagedAppleGrant,
  request: (url: string, init: RequestInit) => Promise<Response>,
): Promise<boolean> {
  const token = await request(tokenEndpoint, {
    method: "POST",
    body: new URLSearchParams({
      client_id: grant.clientId,
      client_secret: grant.clientSecret,
      grant_type: "refresh_token",
      refresh_token: grant.refreshToken,
    }),
    redirect: "error",
    signal: AbortSignal.timeout(8_000),
  });
  if (!token.ok) return false;

  const { id_token: idToken } = await token.json();
  if (typeof idToken !== "string") return false;
  const [header, payload, signature, trailing] = idToken.split(".");
  if (!header || !payload || !signature || trailing !== undefined) return false;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const { alg, kid } = JSON.parse(decoder.decode(decodeBase64Url(header)));
  if (alg !== "RS256" || typeof kid !== "string" || !kid) return false;

  const jwks = await request(keysEndpoint, {
    method: "GET",
    redirect: "error",
    signal: AbortSignal.timeout(8_000),
  });
  if (!jwks.ok) return false;
  const { keys }: { keys: (JsonWebKey & { kid?: string })[] } = await jwks
    .json();
  const matches = keys.filter((key) =>
    key.kid === kid && key.kty === "RSA" && key.use === "sig" &&
    key.alg === "RS256"
  );
  if (matches.length !== 1) return false;
  const signingKey = await crypto.subtle.importKey(
    "jwk",
    matches[0],
    signatureAlgorithm,
    false,
    ["verify"],
  );
  const signed = await crypto.subtle.verify(
    signatureAlgorithm,
    signingKey,
    decodeBase64Url(signature),
    new TextEncoder().encode(`${header}.${payload}`),
  );
  if (!signed) return false;

  const { iss, aud, sub, exp } = JSON.parse(
    decoder.decode(decodeBase64Url(payload)),
  );
  return iss === appleIssuer && aud === grant.clientId &&
    sub === grant.subject && Number.isSafeInteger(exp) &&
    exp > Date.now() / 1_000;
}

/** Verify a candidate secret once, before staging it for revocation. */
export async function verifyStagedAppleGrant(
  trustedOwner: { ownerId: string; subject: string; clientId: string },
  rawGrant: string,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<void> {
  validateUser({ id: trustedOwner.ownerId });
  const grant = loadGrant(rawGrant);
  if (
    trustedOwner.ownerId !== grant.ownerId ||
    trustedOwner.subject !== grant.subject ||
    trustedOwner.clientId !== grant.clientId ||
    !await verifyGrantSubject(grant, request).catch(() => false)
  ) {
    throw new Error("Apple deletion credentials could not be verified.");
  }
}

/** Consume only trusted server provisioning for the exact staged identity. */
export async function revokeStagedAppleAuthorization(
  user: AppleDeletionUser,
  readTrustedGrant: () => string | undefined,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<AppleRevocationOutcome | undefined> {
  if (!hasAppleAuthorization(user)) return;

  // Apple TN3194 permits deletion when no credential exists. Give the user
  // manual revocation guidance after the deletion receipt is validated.
  const raw = readTrustedGrant();
  if (!raw) return "manual_required";

  const grant = loadGrant(raw);
  if (
    appleAuthorizationSubject(user) !== grant.subject ||
    grant.ownerId !== user.id
  ) {
    throw new Error("Apple deletion credentials could not be verified.");
  }
  return await revokeVerifiedAppleGrant(grant, request);
}

export function hasAppleAuthorization(user: AppleDeletionUser): boolean {
  return user.identities?.some((identity) => identity.provider === "apple") ||
    user.app_metadata?.provider === "apple" ||
    (Array.isArray(user.app_metadata?.providers) &&
      user.app_metadata.providers.includes("apple"));
}

export function appleAuthorizationSubject(
  user: AppleDeletionUser,
): string | undefined {
  const identities =
    user.identities?.filter((identity) => identity.provider === "apple") ?? [];
  const [identity] = identities;
  const subject = identity?.identity_data?.sub;
  if (
    identities.length === 1 && identity.user_id === user.id &&
    typeof subject === "string" && subject.length && subject.length <= 512
  ) return subject;
}

/** Send only a grant already bound to its verified Auth owner. */
export async function revokeVerifiedAppleGrant(
  grant: StagedAppleGrant,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<"revoked"> {
  let response: Response;
  try {
    response = await request(revokeEndpoint, {
      method: "POST",
      body: new URLSearchParams({
        client_id: grant.clientId,
        client_secret: grant.clientSecret,
        token: grant.refreshToken,
        token_type_hint: "refresh_token",
      }),
      redirect: "error",
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    throw new Error("Apple authorization revocation could not be confirmed.");
  }
  if (response.status !== 200) {
    throw new Error("Apple authorization revocation could not be confirmed.");
  }
  return "revoked";
}
