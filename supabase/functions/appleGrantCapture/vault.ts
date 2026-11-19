import { createServiceClient } from "../_shared/records.ts";
import { validateUser } from "../deleteUserData/deletion.ts";
import type { AppleGrantVault, StoredAppleGrant } from "./custody.ts";

function storedGrant(raw: unknown): StoredAppleGrant {
  if (!raw || typeof raw !== "object") {
    throw new Error("Invalid Apple grant record.");
  }
  const grant = raw as Partial<StoredAppleGrant>;
  if (
    !grant.id || !grant.subject || !grant.clientId || !grant.keyId ||
    typeof grant.fingerprint !== "string" ||
    !/^[a-f0-9]{64}$/.test(grant.fingerprint) ||
    typeof grant.nonce !== "string" || !/^[a-f0-9]{24}$/.test(grant.nonce) ||
    typeof grant.ciphertext !== "string" || grant.ciphertext.length > 16_416 ||
    !/^(?:[a-f0-9]{2}){17,}$/.test(grant.ciphertext)
  ) {
    throw new Error("Invalid Apple grant record.");
  }
  validateUser({ id: grant.id });
  return grant as StoredAppleGrant;
}

export function createAppleGrantVault(): AppleGrantVault {
  const service = createServiceClient();
  return {
    async knows(identity, fingerprints) {
      const { data, error } = await service.rpc("execute_has_apple_grant", {
        p_owner: identity.ownerId,
        p_subject: identity.subject,
        p_client: identity.clientId,
        p_fingerprints: fingerprints,
      });
      if (error || typeof data !== "boolean") {
        throw new Error("Apple grant lookup failed.");
      }
      return data;
    },
    async save(ownerId, grant) {
      const { data, error } = await service.rpc("execute_capture_apple_grant", {
        p_owner: ownerId,
        p_subject: grant.subject,
        p_client: grant.clientId,
        p_id: grant.id,
        p_key: grant.keyId,
        p_fingerprint: grant.fingerprint,
        p_nonce: grant.nonce,
        p_ciphertext: grant.ciphertext,
      });
      if (error || data !== true) {
        throw new Error("Apple grant storage failed.");
      }
    },
    async close(ownerId, subject, clientId) {
      const { data, error } = await service.rpc("execute_close_apple_grants", {
        p_owner: ownerId,
        p_subject: subject,
        p_client: clientId,
      });
      if (
        error || typeof data?.revoked !== "boolean" ||
        !Array.isArray(data?.grants)
      ) {
        throw new Error("Apple grant closure failed.");
      }
      return { revoked: data.revoked, grants: data.grants.map(storedGrant) };
    },
    async confirmRevoked(ownerId, grantId) {
      const { data, error } = await service.rpc(
        "execute_confirm_apple_grant_revoked",
        {
          p_owner: ownerId,
          p_id: grantId,
        },
      );
      if (error || data !== true) {
        throw new Error("Apple revocation could not be recorded.");
      }
    },
  };
}
