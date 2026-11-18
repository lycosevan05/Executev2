#!/usr/bin/env python3
"""Verify the opt-in dispatch barrier on the dedicated local Storage API."""

import argparse
from http.client import HTTPConnection
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
from uuid import UUID, uuid4

sys.dont_write_bytecode = True
from test_storage_upload_admission_guard import BUCKET, LOCAL_API, local_credentials, request, sql

RPC = "/rest/v1/rpc/"
BODY = b"Execute W09 disposable in-flight upload"
DENIED = (401, 403, 404)


def run(credentials):
    public = credentials["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"]
    service = credentials["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"]
    auth_users = "/auth/v1/admin/users"

    def call(method, path, body=None, *, bearer=service, expected=(200,)):
        key = service if bearer == service else public
        return request(key, bearer, method, path, body, expected)

    def rpc(name, args, *, bearer=service, expected=(200, 204)):
        body = call("POST", RPC + name, args, bearer=bearer, expected=expected)
        return json.loads(body) if body else None

    def create_owner(email):
        password = str(uuid4())
        result = json.loads(call("POST", auth_users, {
            "email": email, "password": password, "email_confirm": True,
        }, expected=(200, 201)))
        owner = str(UUID(result["id"]))
        session = json.loads(call("POST", "/auth/v1/token?grant_type=password", {
            "email": email, "password": password,
        }, bearer=public))
        assert session["user"]["id"] == owner
        return owner, session["access_token"]

    def begin(owner, filename, **options):
        return rpc("begin_account_upload_dispatch", {"p_owner_id": owner, "p_filename": filename}, **options)

    def finish(owner, dispatch, **options):
        return rpc("finish_account_upload_dispatch", {"p_owner_id": owner, "p_dispatch_id": dispatch}, **options)

    def close(owner, **options):
        return rpc("close_and_list_account_upload_dispatches", {"p_owner_id": owner}, **options)

    def inventory(owner):
        return json.loads(call("POST", "/storage/v1/object/list/uploads", {"prefix": owner}))

    def upload_and_remove(owner, filename):
        [dispatch] = begin(owner, filename)
        name = dispatch["object_name"]
        call("POST", f"{BUCKET}/{name}", BODY, expected=(200, 201))
        assert call("GET", f"{BUCKET}/{name}") == BODY
        finish(owner, dispatch["dispatch_id"])
        call("DELETE", BUCKET, {"prefixes": [name]})

    email = f"w09-dispatch-{uuid4()}@example.com"
    owner, owner_token = create_owner(email)
    other, _ = create_owner(f"w09-dispatch-{uuid4()}@example.com")
    begin(owner, "private.txt", bearer=owner_token, expected=DENIED)
    close(owner, bearer=owner_token, expected=DENIED)
    invalid = begin(owner, "../invalid.txt", expected=(400,))
    assert invalid["code"] == "22023"

    [pending] = begin(owner, "held.txt")
    dispatch_id = pending["dispatch_id"]
    name = pending["object_name"]
    assert name == f"{owner}/{dispatch_id}-held.txt"
    finish(owner, dispatch_id, bearer=owner_token, expected=DENIED)
    finish(other, dispatch_id)

    # Send a genuine standard upload with a controlled delay inside the HTTP
    # request body. The dispatch already exists before sending the first byte.
    endpoint = urlsplit(LOCAL_API)
    connection = HTTPConnection(endpoint.hostname, endpoint.port, timeout=15)
    try:
        connection.putrequest("POST", f"{BUCKET}/{name}")
        connection.putheader("apikey", service)
        connection.putheader("Authorization", f"Bearer {service}")
        connection.putheader("Content-Type", "text/plain")
        connection.putheader("Content-Length", str(len(BODY)))
        connection.endheaders(BODY[:1])

        assert inventory(owner) == []
        assert close(owner) == [pending]
        rejected = begin(owner, "closed.txt", expected=(400, 409, 500))
        assert rejected["code"] == "55000"
        # The existing file inventory is empty. The pending dispatch itself
        # must prevent Auth deletion through the supported Auth API.
        call("DELETE", f"{auth_users}/{owner}", expected=(400, 409, 500))
        assert json.loads(call("GET", f"{auth_users}/{owner}"))["id"] == owner
        upload_and_remove(other, "unrelated.txt")

        connection.send(BODY[1:])
        response = connection.getresponse()
        receipt = json.loads(response.read())
        assert response.status in (200, 201) and receipt["Key"] == f"uploads/{name}"
    finally:
        connection.close()

    # A delayed reply or worker restart leaves the record pending. A file
    # listing, even with the object present, is not the dispatch receipt.
    assert close(owner) == [pending]
    assert call("GET", f"{BUCKET}/{name}") == BODY
    finish(owner, dispatch_id)
    finish(owner, dispatch_id)
    assert close(owner) == []
    assert [item["name"] for item in inventory(owner)] == [f"{dispatch_id}-held.txt"]
    call("DELETE", BUCKET, {"prefixes": [name]})
    assert inventory(owner) == []
    call("DELETE", f"{auth_users}/{owner}", expected=(200, 204))
    call("GET", f"{auth_users}/{owner}", expected=(404,))

    replacement, _ = create_owner(email)
    assert replacement != owner
    upload_and_remove(replacement, "replacement.txt")
    for remaining in (other, replacement):
        call("DELETE", f"{auth_users}/{remaining}", expected=(200, 204))
    assert sql("select count(*) from execute_storage_deletion_guard.pending_upload_dispatch;") == "0"
    print("Storage dispatch guard passed: partial-body upload drained before cleanup; unrelated and replacement uploads succeeded.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", type=Path, required=True)
    parser.add_argument("--cli", default="supabase-go")
    args = parser.parse_args()
    run(local_credentials(args.cli, args.stack_dir.resolve()))


if __name__ == "__main__":
    main()
