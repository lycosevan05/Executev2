import type {
  AppleRevocationOutcome,
  DeletionUser,
} from "../deleteUserData/deletion.ts";

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

interface StagedAppleGrant {
  ownerId: string;
  subject: string;
  clientId: string;
  clientSecret: string;
  refreshToken: string;
}

const revokeEndpoint = "https://appleid.apple.com/auth/revoke";

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

/** Consume only trusted server provisioning for the exact staged identity. */
export async function revokeStagedAppleAuthorization(
  user: AppleDeletionUser,
  readTrustedGrant: () => string | undefined,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<AppleRevocationOutcome | undefined> {
  const appleIdentities =
    user.identities?.filter((identity) => identity.provider === "apple") ?? [];
  const hasAppleIdentity = appleIdentities.length > 0 ||
    user.app_metadata?.provider === "apple" ||
    (Array.isArray(user.app_metadata?.providers) &&
      user.app_metadata.providers.includes("apple"));
  if (!hasAppleIdentity) return;

  // Apple TN3194 permits deletion when no credential exists. Give the user
  // manual revocation guidance after the deletion receipt is validated.
  const raw = readTrustedGrant();
  if (!raw) return "manual_required";

  const grant = loadGrant(raw);
  const [identity] = appleIdentities;
  if (
    appleIdentities.length !== 1 || identity.user_id !== user.id ||
    identity.identity_data?.sub !== grant.subject || grant.ownerId !== user.id
  ) {
    throw new Error("Apple deletion credentials could not be verified.");
  }

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
