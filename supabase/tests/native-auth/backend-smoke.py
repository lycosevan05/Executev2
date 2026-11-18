#!/usr/bin/env python3
"""Check the W04 fixture's real Auth timebox and owner-scoped PostgREST reads."""
import argparse
import json
from pathlib import Path
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4

sys.dont_write_bytecode = True
from run import local_credentials


class LocalFixture:
    def __init__(self, cli, stack_dir):
        keys = local_credentials(cli, stack_dir)
        self.url = keys["EXECUTE_ISOLATED_AUTH_URL"]
        self.public = keys["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"]
        self.admin = keys["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"]

    def request(self, path, *, body=None, token=None, admin=False, expected=(200,)):
        key = self.admin if admin else self.public
        headers = {
            "Content-Type": "application/json",
            "apikey": key,
            "Authorization": "Bearer " + (token or key),
            "Prefer": "return=representation",
        }
        raw_body = None if body is None else json.dumps(body).encode()
        request = Request(self.url + path, data=raw_body, headers=headers)
        try:
            with urlopen(request, timeout=10) as response:
                status, result = response.status, json.load(response)
        except HTTPError as error:
            status, result = error.code, json.load(error)
        if status not in expected:
            code = result.get("error_code") if isinstance(result, dict) else None
            raise SystemExit(f"Local fixture request failed: HTTP {status}, code {code}.")
        return result

    def new_owner(self):
        email = f"w04-{uuid4().hex}@example.com"
        result = self.request("/auth/v1/admin/users",
                              body={"email": email, "password": uuid4().hex, "email_confirm": True},
                              admin=True, expected=(200, 201))
        return email, result["id"]

    def sign_in(self, owner):
        email, owner_id = owner
        link = self.request("/auth/v1/admin/generate_link",
                            body={"type": "magiclink", "email": email}, admin=True)
        otp = link.get("email_otp") or link.get("properties", {}).get("email_otp")
        if not otp:
            raise SystemExit("The isolated Auth server did not generate an email code.")
        session = self.request("/auth/v1/verify", body={"email": email, "token": otp, "type": "email"})
        if session["user"]["id"] != owner_id:
            raise SystemExit("Local email-code sign-in returned an unexpected owner.")
        return session

    def refresh(self, session, expected=(200,)):
        return self.request("/auth/v1/token?grant_type=refresh_token",
                            body={"refresh_token": session["refresh_token"]}, expected=expected)


def verify_timebox(fixture):
    owner = fixture.new_owner()
    refreshed = fixture.refresh(fixture.sign_in(owner))
    if refreshed["user"]["id"] != owner[1]:
        raise SystemExit("Pre-expiry refresh returned an unexpected owner.")
    time.sleep(17)
    expired = fixture.refresh(refreshed, expected=(400, 401, 403))
    if expired.get("error_code") != "session_expired":
        raise SystemExit("Terminal expiry did not return session_expired.")
    fixture.sign_in(owner)


def verify_readback(fixture):
    expected_rows = []
    for label in ("A", "B"):
        email, owner_id = fixture.new_owner()
        token = fixture.sign_in((email, owner_id))["access_token"]
        body = {
            "owner_id": owner_id, "owner_email": email, "created_by": email, "user_email": email,
            "data": {"title": f"W04 fixture {label}"},
        }
        inserted = fixture.request("/rest/v1/goals", body=body, token=token, expected=(201,))
        expected_rows.append((token, [{"id": inserted[0]["id"], "owner_id": owner_id}]))
    for token, expected in expected_rows:
        observed = fixture.request("/rest/v1/goals?select=id,owner_id", token=token)
        if observed != expected:
            raise SystemExit("The authenticated owner did not receive exactly their fixture goal.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", type=Path, required=True)
    parser.add_argument("--cli", default="supabase-go")
    args = parser.parse_args()
    fixture = LocalFixture(args.cli, args.stack_dir.resolve())
    verify_timebox(fixture)
    verify_readback(fixture)
    print(json.dumps({"terminal_refresh_error": "session_expired", "fresh_sign_in_same_owner": True,
                      "owner_scoped_PostgREST_readbacks": 2}))


if __name__ == "__main__":
    main()
