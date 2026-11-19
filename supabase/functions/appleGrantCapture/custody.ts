import {
  appleAuthorizationSubject,
  type AppleDeletionUser,
  hasAppleAuthorization,
  revokeVerifiedAppleGrant,
  verifyStagedAppleGrant,
} from "../deleteUserData-staged/appleRevocation.ts";
import {
  type AppleRevocationOutcome,
  validateUser,
} from "../deleteUserData/deletion.ts";

type ReadSetting = (name: string) => string | undefined;
export type ProviderRequest = (
  url: string,
  init: RequestInit,
) => Promise<Response>;
const keyIDPattern = /^[a-z0-9_-]{1,32}$/;
const keyPattern = /^[a-f0-9]{64}$/i;
const encoder = new TextEncoder();
export const maxAppleRefreshTokenLength = 8192;

export interface AppleGrantSettings {
  origin: string;
  clientId: string;
  clientSecret: string;
  activeKeyId: string;
  keys: ReadonlyMap<string, string>;
}

export function readAppleGrantSettings(
  read: ReadSetting,
): AppleGrantSettings | undefined {
  const mode = read("EXECUTE_APPLE_GRANT_MODE");
  if (!mode || mode === "disabled") return;
  try {
    const origin = read("SUPABASE_URL") ?? "";
    const approved = read("EXECUTE_APPLE_GRANT_PROJECT_URL");
    const clientId = read("EXECUTE_APPLE_GRANT_CLIENT_ID") ?? "";
    const clientSecret = read("EXECUTE_APPLE_GRANT_CLIENT_SECRET") ?? "";
    const activeKeyId = read("EXECUTE_APPLE_GRANT_KEY_ID") ?? "";
    const keyData: unknown = JSON.parse(read("EXECUTE_APPLE_GRANT_KEYS") ?? "");
    const url = new URL(origin);
    if (
      mode !== "enabled" || approved !== origin || url.origin !== origin ||
      url.protocol !== "https:" || url.port ||
      !/^[a-z0-9]+\.supabase\.co$/.test(url.hostname) ||
      !/^[A-Za-z0-9.-]{1,255}$/.test(clientId) ||
      !clientSecret || clientSecret.length > 4096 ||
      !keyIDPattern.test(activeKeyId) ||
      !keyData || typeof keyData !== "object" || Array.isArray(keyData)
    ) throw new Error();
    const keys = new Map<string, string>();
    for (const [id, value] of Object.entries(keyData)) {
      if (
        !keyIDPattern.test(id) || typeof value !== "string" ||
        !keyPattern.test(value)
      ) throw new Error();
      keys.set(id, value);
    }
    if (!keys.has(activeKeyId)) throw new Error();
    return { origin, clientId, clientSecret, activeKeyId, keys };
  } catch {
    throw new Error("Apple grant custody is unavailable.");
  }
}

export interface StoredAppleGrant {
  id: string;
  subject: string;
  clientId: string;
  keyId: string;
  fingerprint: string;
  nonce: string;
  ciphertext: string;
}

interface GrantIdentity {
  ownerId: string;
  subject: string;
  clientId: string;
}

export interface AppleGrantVault {
  knows(
    identity: GrantIdentity,
    fingerprints: readonly string[],
  ): Promise<boolean>;
  save(ownerId: string, grant: StoredAppleGrant): Promise<void>;
  close(
    ownerId: string,
    subject: string | null,
    clientId: string,
  ): Promise<{ revoked: boolean; grants: StoredAppleGrant[] }>;
  confirmRevoked(ownerId: string, grantId: string): Promise<void>;
}

function hex(bytes: ArrayBuffer | Uint8Array): string {
  return Array.from(
    new Uint8Array(bytes),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

function decodeHex(value: string): Uint8Array<ArrayBuffer> {
  if (!/^(?:[a-f0-9]{2})+$/i.test(value)) throw new Error();
  return Uint8Array.from(
    value.match(/../g)!,
    (byte) => Number.parseInt(byte, 16),
  );
}

async function deriveKey(
  settings: AppleGrantSettings,
  keyId: string,
  purpose: "seal" | "fingerprint",
) {
  const secret = settings.keys.get(keyId);
  if (!secret) throw new Error();
  const master = await crypto.subtle.importKey(
    "raw",
    decodeHex(secret),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: encoder.encode(settings.origin),
      info: encoder.encode(`execute-apple-grant-v1:${purpose}`),
    },
    master,
    purpose === "seal"
      ? { name: "AES-GCM", length: 256 }
      : { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    purpose === "seal" ? ["encrypt", "decrypt"] : ["sign"],
  );
}

function context(
  settings: AppleGrantSettings,
  ownerId: string,
  grant: Omit<StoredAppleGrant, "ciphertext">,
) {
  return encoder.encode(JSON.stringify([
    "execute-apple-grant-v1",
    settings.origin,
    ownerId,
    grant.subject,
    grant.clientId,
    grant.id,
    grant.keyId,
    grant.fingerprint,
  ]));
}

async function fingerprint(
  settings: AppleGrantSettings,
  keyId: string,
  identity: GrantIdentity,
  token: string,
) {
  const key = await deriveKey(settings, keyId, "fingerprint");
  return hex(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(
        JSON.stringify([
          identity.ownerId,
          identity.subject,
          identity.clientId,
          token,
        ]),
      ),
    ),
  );
}

async function seal(
  settings: AppleGrantSettings,
  identity: GrantIdentity,
  token: string,
  digest: string,
): Promise<StoredAppleGrant> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const grant = {
    id: crypto.randomUUID(),
    subject: identity.subject,
    clientId: identity.clientId,
    keyId: settings.activeKeyId,
    fingerprint: digest,
    nonce: hex(nonce),
  };
  const key = await deriveKey(settings, grant.keyId, "seal");
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      additionalData: context(settings, identity.ownerId, grant),
    },
    key,
    encoder.encode(token),
  );
  return { ...grant, ciphertext: hex(ciphertext) };
}

async function open(
  settings: AppleGrantSettings,
  ownerId: string,
  grant: StoredAppleGrant,
): Promise<string> {
  const key = await deriveKey(settings, grant.keyId, "seal");
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: decodeHex(grant.nonce),
      additionalData: context(settings, ownerId, grant),
    },
    key,
    decodeHex(grant.ciphertext),
  );
  return new TextDecoder("utf-8", { fatal: true }).decode(plaintext);
}

export async function captureAppleGrant(
  user: AppleDeletionUser,
  token: string,
  settings: AppleGrantSettings,
  vault: AppleGrantVault,
  request: ProviderRequest = fetch,
): Promise<void> {
  try {
    validateUser(user);
    const subject = appleAuthorizationSubject(user);
    if (!subject || !validRefreshToken(token)) throw new Error();
    const identity = { ownerId: user.id, subject, clientId: settings.clientId };
    const ids = [
      settings.activeKeyId,
      ...Array.from(settings.keys.keys()).filter((id) =>
        id !== settings.activeKeyId
      ),
    ];
    const digests = await Promise.all(
      ids.map((id) => fingerprint(settings, id, identity, token)),
    );
    if (await vault.knows(identity, digests)) return;
    await verifyStagedAppleGrant(
      identity,
      JSON.stringify({
        ...identity,
        clientSecret: settings.clientSecret,
        refreshToken: token,
      }),
      request,
    );
    await vault.save(
      user.id,
      await seal(settings, identity, token, digests[0]),
    );
  } catch {
    throw new Error("Apple grant custody could not be confirmed.");
  }
}

export function validRefreshToken(token: unknown): token is string {
  return typeof token === "string" && token.length > 0 &&
    token.length <= maxAppleRefreshTokenLength && /^[\x21-\x7E]+$/.test(token);
}

/** Preserve every unacknowledged grant until the provider confirms revocation. */
export async function revokeCapturedAppleAuthorization(
  user: AppleDeletionUser,
  settings: AppleGrantSettings,
  vault: AppleGrantVault,
  request: ProviderRequest = fetch,
): Promise<AppleRevocationOutcome | undefined> {
  try {
    validateUser(user);
    const subject = appleAuthorizationSubject(user);
    const state = await vault.close(
      user.id,
      subject ?? null,
      settings.clientId,
    );
    if (state.revoked && state.grants.length === 0) return "revoked";
    if (!state.grants.length) {
      return hasAppleAuthorization(user) ? "manual_required" : undefined;
    }

    // Authenticate every encrypted record before the first provider mutation.
    const grants = await Promise.all(state.grants.map(async (grant) => {
      if (
        state.revoked || !subject || grant.subject !== subject ||
        grant.clientId !== settings.clientId
      ) throw new Error();
      const refreshToken = await open(settings, user.id, grant);
      if (!validRefreshToken(refreshToken)) throw new Error();
      return { id: grant.id, refreshToken };
    }));
    for (const { id, refreshToken } of grants) {
      await revokeVerifiedAppleGrant({
        ownerId: user.id,
        subject: subject!,
        clientId: settings.clientId,
        clientSecret: settings.clientSecret,
        refreshToken,
      }, request);
      await vault.confirmRevoked(user.id, id);
    }
    return "revoked";
  } catch {
    throw new Error("Apple authorization revocation could not be confirmed.");
  }
}
