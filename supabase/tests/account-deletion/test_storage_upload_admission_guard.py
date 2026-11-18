#!/usr/bin/env python3
"""Exercise the opt-in admission guard against the disposable W04 API and DB."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import select
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID, uuid4

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "native-auth"))
from run import LOCAL_API, PROJECT_ID, local_credentials

BUCKET = "/storage/v1/object/uploads"
BODY = b"Execute W09 disposable upload admission fixture"
PSQL = [
    "docker", "exec", "-i", f"supabase_db_{PROJECT_ID}", "psql", "-XqAt",
    "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
]


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise AssertionError("The isolated Storage test received a redirect.")


def request(public_key, bearer, method, path, body=None, expected=(200,)):
    headers = {"apikey": public_key, "Authorization": f"Bearer {bearer}"}
    if isinstance(body, dict):
        body = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif body is not None:
        headers["Content-Type"] = "text/plain"
    req = Request(LOCAL_API + path, method=method, data=body, headers=headers)
    try:
        with build_opener(RejectRedirects).open(req, timeout=10) as response:
            status, content = response.status, response.read()
    except HTTPError as error:
        status, content = error.code, error.read()
    if status not in expected:
        raise AssertionError(f"Unexpected local {method} response HTTP {status}.")
    return content


def sql(command):
    result = subprocess.run(PSQL, input=command, capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        raise AssertionError(f"Fixture database command failed: {result.stderr.strip()}")
    return result.stdout.strip()


def wait_for_storage_admission_lock(closer_pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if sql(
            "select exists (select from pg_stat_activity "
            f"where {closer_pid} = any(pg_blocking_pids(pid)) "
            "and query ilike '%insert into%objects%');"
        ) == "t":
            return
        time.sleep(0.05)
    raise AssertionError("The real Storage request did not reach the guarded transaction.")


def expect_access_denial(raw):
    result = json.loads(raw)
    if str(result.get("statusCode")) != "403" or "row-level security" not in result.get("message", ""):
        raise AssertionError("Storage returned an error other than a policy denial.")


def run(credentials):
    key = credentials["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"]
    admin = credentials["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"]
    owners = {}
    paths = []

    def call(bearer, method, path, body=None, expected=(200,)):
        return request(key if bearer != admin else admin, bearer, method, path, body, expected)

    def create_owner(email):
        password = str(uuid4())
        owner = json.loads(call(admin, "POST", "/auth/v1/admin/users", {
            "email": email, "password": password, "email_confirm": True,
        }, expected=(200, 201)))
        owner_id = str(UUID(owner["id"]))
        owners[owner_id] = email
        session = json.loads(call(key, "POST", "/auth/v1/token?grant_type=password", {
            "email": email, "password": password,
        }))
        assert session["user"]["id"] == owner_id
        return owner_id, session["access_token"]

    def upload(bearer, object_name):
        paths.append(object_name)
        call(bearer, "POST", BUCKET + "/" + object_name, BODY, expected=(200, 201))
        assert call(admin, "GET", BUCKET + "/" + object_name) == BODY

    def denied_upload(bearer, object_name, method="POST"):
        paths.append(object_name)
        raw = call(bearer, method, BUCKET + "/" + object_name, b"Blocked fixture write", expected=(400, 403))
        expect_access_denial(raw)

    def delete_owner(owner_id):
        call(admin, "DELETE", "/auth/v1/admin/users/" + owner_id, expected=(200, 204))
        owners.pop(owner_id)

    try:
        email = f"w09-admission-{uuid4()}@example.com"
        owner_id, owner = create_owner(email)
        other_id, other = create_owner(f"w09-admission-{uuid4()}@example.com")
        before, pending = f"{owner_id}/before.txt", f"{owner_id}/pending.txt"
        other_path = f"{other_id}/unrelated.txt"
        upload(owner, before)

        function = "/rest/v1/rpc/close_account_upload_admission"
        call(owner, "POST", function, {"p_owner_id": owner_id}, expected=(401, 403, 404))
        with (
            subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as closer,
            ThreadPoolExecutor(max_workers=1) as executor,
        ):
            try:
                closer.stdin.write(
                    "select pg_backend_pid();\n"
                    "begin; set local role service_role;\n"
                    f"do $$ begin perform public.close_account_upload_admission('{owner_id}'); end $$;\n"
                    "\\echo closure_ready\n"
                )
                closer.stdin.flush()
                if not select.select([closer.stdout], [], [], 5)[0]:
                    raise AssertionError("The fixture did not acknowledge the closure transaction.")
                closer_pid = int(closer.stdout.readline())
                if closer.stdout.readline().strip() != "closure_ready":
                    raise AssertionError("The fixture closure transaction did not begin.")
                pending_attempt = executor.submit(denied_upload, owner, pending)
                wait_for_storage_admission_lock(closer_pid)
                upload(other, other_path)
                assert not pending_attempt.done()
                closer.communicate("commit;\n\\q\n", timeout=5)
                assert closer.returncode == 0
                pending_attempt.result(timeout=5)
            finally:
                if closer.poll() is None:
                    closer.kill()

        call(admin, "GET", "/auth/v1/admin/users/" + owner_id)
        call(admin, "POST", function, {"p_owner_id": owner_id}, expected=(200, 204))
        denied_upload(owner, before, method="PUT")
        assert call(admin, "GET", BUCKET + "/" + before) == BODY
        call(admin, "GET", BUCKET + "/" + pending, expected=(400, 404))
        call(admin, "DELETE", BUCKET, {"prefixes": [before]})
        delete_owner(owner_id)
        call(admin, "GET", "/auth/v1/admin/users/" + owner_id, expected=(404,))
        assert sql(
            "select count(*) from execute_storage_deletion_guard.closed_upload_admission "
            f"where owner_id = '{owner_id}';"
        ) == "0"
        denied_upload(owner, f"{owner_id}/after-auth-removal.txt")

        replacement_id, replacement = create_owner(email)
        assert replacement_id != owner_id
        upload(replacement, f"{replacement_id}/before.txt")
        assert call(admin, "GET", BUCKET + "/" + other_path) == BODY
    finally:
        if paths:
            call(admin, "DELETE", BUCKET, {"prefixes": list(set(paths))})
        for owner_id in tuple(owners):
            delete_owner(owner_id)
    print(
        "W09 Storage guard passed. Closure-first admission was denied, unrelated traffic "
        "continued, and the same-email replacement uploaded."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", type=Path, required=True)
    parser.add_argument("--cli", default="supabase-go")
    args = parser.parse_args()
    credentials = local_credentials(args.cli, args.stack_dir.resolve())
    run(credentials)


if __name__ == "__main__":
    main()
