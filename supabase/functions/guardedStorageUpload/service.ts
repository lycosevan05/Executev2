import { createServiceClient, getUser } from "../_shared/records.ts";
import { createGuardedUploadHandler } from "./handler.ts";

export const guardedStorageUpload = createGuardedUploadHandler({
  getUser,
  createWriter() {
    const service = createServiceClient();
    const uploads = service.storage.from("uploads");
    return {
      async begin(owner, path) {
        const { data, error } = await service.rpc(
          "begin_exact_account_upload_dispatch",
          { p_owner_id: owner, p_object_name: path },
        );
        if (error?.code === "55000") return { kind: "closed" };
        if (error || !Array.isArray(data) || data.length !== 1) {
          throw new Error("Upload registration was not confirmed");
        }
        return {
          kind: "registered",
          id: data[0].dispatch_id,
          path: data[0].object_name,
        };
      },
      async send(path, bytes, contentType) {
        const { data, error } = await uploads.upload(path, bytes, {
          contentType,
          upsert: false,
        });
        if (!error && data?.path === path) return "stored";
        if (error?.name === "StorageApiError") {
          const { statusCode, message } = error;
          if (
            statusCode === "KeyAlreadyExists" ||
            (statusCode === "409" && message === "The resource already exists")
          ) return "already-exists";
          if (
            statusCode === "InvalidMimeType" ||
            (statusCode === "415" &&
              message === `mime type ${contentType} is not supported`)
          ) return { rejected: 415 };
          if (
            statusCode === "EntityTooLarge" ||
            (statusCode === "413" &&
              message === "The object exceeded the maximum allowed size")
          ) return { rejected: 413 };
        }
        return "unverified";
      },
      async finish(owner, id) {
        const { error } = await service.rpc(
          "finish_account_upload_dispatch",
          { p_owner_id: owner, p_dispatch_id: id },
        );
        if (error) throw new Error("Upload completion was not confirmed");
      },
    };
  },
});
