import { handleCors, json } from "../_shared/cors.ts";

const bucket = "uploads";
const maxUploadBytes = 50 * 1024 * 1024;
const allowedTypes = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
  "application/pdf",
  "text/plain",
]);
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type Begin = { kind: "registered"; id: string; path: string } | {
  kind: "closed";
};
type Outcome = "stored" | "already-exists" | "unverified";

interface UploadWriter {
  begin(owner: string, path: string): Promise<Begin>;
  send(path: string, bytes: Uint8Array, contentType: string): Promise<Outcome>;
  finish(owner: string, id: string): Promise<void>;
}

interface Dependencies {
  getUser(req: Request): Promise<{ id: string }>;
  createWriter(): UploadWriter;
}

class UploadTooLarge extends Error {}

async function readUpload(req: Request, limit: number) {
  const contentLength = req.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > limit) {
    throw new UploadTooLarge();
  }
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel().catch(() => {});
        throw new UploadTooLarge();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (chunks.length === 1) return chunks[0];
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export function createGuardedUploadHandler(
  dependencies: Dependencies,
  limit = maxUploadBytes,
) {
  return async (req: Request): Promise<Response> => {
    const preflight = handleCors(req);
    if (preflight) return preflight;
    if (req.method !== "POST") {
      return json({ error: "Method not allowed." }, 405);
    }
    if (!/^Bearer [^\s,]+$/i.test(req.headers.get("authorization") ?? "")) {
      return json({ error: "Unauthorized." }, 401);
    }

    const query = new URL(req.url).searchParams;
    const buckets = query.getAll("bucket");
    const paths = query.getAll("path");
    const [requestedOwner, filename, ...extra] = paths[0]?.split("/") ?? [];
    if (
      buckets.length !== 1 || buckets[0] !== bucket || paths.length !== 1 ||
      extra.length || !requestedOwner || !filename || filename.length > 255 ||
      /[^A-Za-z0-9._-]/.test(filename) || filename === "." || filename === ".."
    ) {
      return json({ error: "Invalid upload destination." }, 400);
    }
    const contentType = req.headers.get("content-type")?.split(";")[0].trim()
      .toLowerCase();
    if (!contentType || !allowedTypes.has(contentType)) {
      return json({ error: "Unsupported upload type." }, 415);
    }

    let owner: string;
    try {
      owner = (await dependencies.getUser(req)).id.toLowerCase();
    } catch (error) {
      if (error instanceof Response && error.status === 401) {
        return json({ error: "Unauthorized." }, 401);
      }
      return json({ error: "Upload authentication unavailable." }, 503);
    }
    if (!uuidPattern.test(owner) || requestedOwner.toLowerCase() !== owner) {
      return json(
        { error: "Upload destination is outside your account." },
        403,
      );
    }
    const path = `${owner}/${filename}`;

    let bytes: Uint8Array;
    try {
      bytes = await readUpload(req, limit);
    } catch (error) {
      if (error instanceof UploadTooLarge) {
        return json({ error: "Upload exceeds the size limit." }, 413);
      }
      return json({ error: "Upload body could not be read." }, 400);
    }
    if (!bytes.byteLength) return json({ error: "Upload body is empty." }, 400);

    try {
      const writer = dependencies.createWriter();
      const admission = await writer.begin(owner, path);
      if (admission.kind === "closed") {
        return json({ error: "Upload admission is closed." }, 409);
      }
      if (admission.path !== path || !uuidPattern.test(admission.id)) {
        return json({ error: "Upload admission could not be verified." }, 503);
      }

      const outcome = await writer.send(path, bytes, contentType);
      if (outcome === "unverified") {
        // No durable proof the Storage request finished. The marker must remain.
        return json({ error: "Upload outcome could not be verified." }, 503);
      }
      await writer.finish(owner, admission.id);
      if (outcome === "already-exists") {
        return json({ error: "An upload already exists at that path." }, 409);
      }
      return json({ path }, 201);
    } catch {
      return json({ error: "Upload could not be confirmed." }, 503);
    }
  };
}
