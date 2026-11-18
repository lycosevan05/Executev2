#!/usr/bin/env python3
"""Apply the optional upload cutover and exercise it on the disposable W04 stack."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener
from uuid import UUID, uuid4

sys.dont_write_bytecode = True
from test_storage_upload_admission_guard import (
    BUCKET, LOCAL_API, RejectRedirects, local_credentials, request, sql,
)

HERE = Path(__file__).resolve().parent
UPLOAD = "http://127.0.0.1:55423/guardedStorageUpload"
AUTH_USERS = "/auth/v1/admin/users"
RPC = "/rest/v1/rpc/"
CLOSE = RPC + "close_and_list_guarded_account_upload_dispatches"
PAYLOAD = b"Execute disposable canonical upload fixture"


def run(credentials):
    public = credentials["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"]
    service = credentials["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"]

    def rest(method, path, body=None, *, token=service, expected=(200,)):
        return request(service if token == service else public, token, method, path, body, expected)

    def create_owner(email):
        password = str(uuid4())
        user = json.loads(rest("POST", AUTH_USERS, {
            "email": email, "password": password, "email_confirm": True,
        }, expected=(200, 201)))
        owner = str(UUID(user["id"]))
        session = json.loads(rest("POST", "/auth/v1/token?grant_type=password", {
            "email": email, "password": password,
        }, token=public))
        assert session["user"]["id"] == owner
        return owner, session["access_token"]

    def upload(path, token, expected, body=PAYLOAD, *, method="POST"):
        dest = UPLOAD + "?" + urlencode({"bucket": "uploads", "path": path})
        headers = {"Authorization": f"Bearer {token}", "apikey": public,
                   "Content-Type": "text/plain;charset=UTF-8"}
        req = Request(dest, data=body, method=method, headers=headers)
        try:
            with build_opener(RejectRedirects).open(req, timeout=10) as response:
                result, status = response.read(), response.status
        except HTTPError as error:
            result, status = error.read(), error.code
        assert status == expected, f"Unexpected canonical upload result {status} (wanted {expected})."
        return json.loads(result) if method != "OPTIONS" else result

    def close(owner):
        return json.loads(rest("POST", CLOSE, {
            "p_owner_id": owner,
        }))

    def pending_count():
        return sql("select count(*) from execute_storage_deletion_guard.pending_upload_dispatch;")

    email = f"e65-upload-{uuid4()}@example.com"
    owner, owner_token = create_owner(email)
    other, other_token = create_owner(f"e65-upload-{uuid4()}@example.com")
    target = f"{owner}/target.txt"
    unrelated = f"{other}/unrelated.txt"

    upload(target, owner_token, 200, body=None, method="OPTIONS")
    upload(target, "not-a-user-token", 401)
    upload(target, other_token, 403)
    assert pending_count() == "0"

    # Supabase's direct Storage writer can no longer admit these operations.
    rest("POST", f"{BUCKET}/{target}", PAYLOAD, token=owner_token, expected=(400, 403))
    rest("PUT", f"{BUCKET}/{target}", PAYLOAD, token=owner_token, expected=(400, 403))

    # An ordinary logged-in client keeps using the supported public object URL
    # and can delete its own file, even though the real service writer owns it.
    assert upload(f"{owner.upper()}/target.txt", owner_token, 201) == {"path": target}
    assert upload(unrelated, other_token, 201) == {"path": unrelated}
    assert rest("GET", f"/storage/v1/object/public/uploads/{target}", token=public) == PAYLOAD
    assert rest("GET", f"{BUCKET}/{target}", token=owner_token) == PAYLOAD
    assert sql(f"select owner_id is null from storage.objects where bucket_id='uploads' and name='{target}';") == "t"
    rest("PUT", f"{BUCKET}/{target}", b"blocked", token=owner_token, expected=(400, 403))
    upload(target, owner_token, 409, body=b"duplicate must not overwrite")
    assert rest("GET", f"{BUCKET}/{target}", token=owner_token) == PAYLOAD
    assert pending_count() == "0"

    # Neither an ordinary caller nor a wrong prefix may create a dispatch.
    exact_args = {"p_owner_id": owner, "p_object_name": target}
    rest("POST", RPC + "begin_exact_account_upload_dispatch", exact_args, token=owner_token,
         expected=(401, 403, 404))
    rest("POST", RPC + "begin_exact_account_upload_dispatch",
         {**exact_args, "p_object_name": unrelated}, expected=(400,))

    rest("POST", CLOSE, {"p_owner_id": owner}, token=owner_token, expected=(401, 403, 404))
    sql('alter policy "uploads require canonical writer for insert" on storage.objects with check (true);')
    bad_cutover = json.loads(rest("POST", CLOSE, {"p_owner_id": owner}, expected=(400, 409, 500)))
    assert bad_cutover["code"] == "55000"
    assert sql("select count(*) from execute_storage_deletion_guard.closed_upload_admission;") == "0"
    sql("""alter policy "uploads require canonical writer for insert" on storage.objects
           with check (bucket_id <> 'uploads');""")
    assert close(owner) == []
    upload(f"{owner}/closed.txt", owner_token, 409)
    rest("DELETE", BUCKET, {"prefixes": [target]}, token=owner_token)
    rest("GET", f"{BUCKET}/{target}", token=service, expected=(400, 404))
    rest("DELETE", f"{AUTH_USERS}/{owner}", expected=(200, 204))
    assert rest("GET", f"{BUCKET}/{unrelated}", token=other_token) == PAYLOAD

    replacement, replacement_token = create_owner(email)
    assert replacement != owner
    fresh_path = f"{replacement}/fresh.txt"
    assert upload(fresh_path, replacement_token, 201) == {"path": fresh_path}
    rest("DELETE", BUCKET, {"prefixes": [unrelated, fresh_path]})
    for remaining in (other, replacement):
        rest("DELETE", f"{AUTH_USERS}/{remaining}", expected=(200, 204))
    assert pending_count() == "0"

    print("Canonical route, duplicate handling, direct-write denial, existing reads/deletes and UUID reuse passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", type=Path, required=True)
    parser.add_argument("--cli", default="supabase-go")
    parser.add_argument("--deno", default="deno")
    args = parser.parse_args()
    credentials = local_credentials(args.cli, args.stack_dir.resolve())
    for filename in ("storage-upload-admission-guard.sql", "storage-upload-dispatch-guard.sql",
                     "storage-upload-exact-dispatch.sql", "storage-upload-writer-cutover.sql"):
        sql((HERE / filename).read_text())

    env = {key: value for key, value in os.environ.items() if key != "SERVICE_ROLE_KEY"}
    env.update(SUPABASE_URL=LOCAL_API,
               SUPABASE_ANON_KEY=credentials["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"],
               SUPABASE_SERVICE_ROLE_KEY=credentials["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"])
    command = [args.deno, "run", "--cached-only", "--no-lock", "--node-modules-dir=none",
               "--allow-net=127.0.0.1:55421,127.0.0.1:55423",
               "--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,SERVICE_ROLE_KEY",
               str(HERE / "serve-guarded-upload.ts")]
    with subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as server:
        try:
            for _ in range(50):
                try:
                    req = Request(UPLOAD, method="OPTIONS")
                    with build_opener(RejectRedirects).open(req, timeout=0.25) as response:
                        assert response.status == 200
                        break
                except (OSError, URLError):
                    if server.poll() is not None:
                        raise AssertionError("The local canonical upload handler stopped during startup.")
                    time.sleep(0.1)
            else:
                raise AssertionError("The local canonical upload handler did not start.")
            run(credentials)
        finally:
            if server.poll() is None:
                server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    main()
