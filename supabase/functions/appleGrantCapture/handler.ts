import type { AppleDeletionUser } from "../deleteUserData-staged/appleRevocation.ts";
import { appleAuthorizationSubject } from "../deleteUserData-staged/appleRevocation.ts";
import {
  type AppleGrantSettings,
  type AppleGrantVault,
  captureAppleGrant,
  maxAppleRefreshTokenLength,
  type ProviderRequest,
  validRefreshToken,
} from "./custody.ts";

const unavailable = () =>
  Response.json(
    { error: "Apple grant custody is unavailable." },
    { status: 503, headers: { "Cache-Control": "no-store" } },
  );

async function readRefreshToken(request: Request): Promise<string> {
  if (
    !request.body ||
    request.headers.get("content-type")?.split(";")[0].trim() !==
      "application/json"
  ) {
    throw new Error();
  }
  const maxBody = maxAppleRefreshTokenLength * 2 + 64; // JSON escaping may double a character.
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let json = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBody) {
        await reader.cancel();
        throw new Error();
      }
      json += decoder.decode(value, { stream: true });
    }
    const payload = JSON.parse(json + decoder.decode());
    if (
      !payload || Object.keys(payload).length !== 1 ||
      !validRefreshToken(payload.refreshToken)
    ) {
      throw new Error();
    }
    return payload.refreshToken;
  } finally {
    reader.releaseLock();
  }
}

export function createAppleGrantCaptureHandler(dependencies: {
  settings(): AppleGrantSettings | undefined;
  getUser(request: Request): Promise<AppleDeletionUser>;
  vault(): AppleGrantVault;
  providerRequest?: ProviderRequest;
}) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return new Response(null, { status: 405, headers: { Allow: "POST" } });
    }
    let settings;
    try {
      settings = dependencies.settings();
      if (!settings) return unavailable();
    } catch {
      return unavailable();
    }
    let user;
    try {
      user = await dependencies.getUser(request);
    } catch {
      return new Response(null, { status: 401 });
    }
    if (!appleAuthorizationSubject(user)) {
      return new Response(null, { status: 403 });
    }

    let refreshToken;
    try {
      refreshToken = await readRefreshToken(request);
    } catch {
      return new Response(null, { status: 400 });
    }

    try {
      await captureAppleGrant(
        user,
        refreshToken,
        settings,
        dependencies.vault(),
        dependencies.providerRequest,
      );
      return new Response(null, {
        status: 204,
        headers: { "Cache-Control": "no-store" },
      });
    } catch {
      return unavailable();
    }
  };
}
