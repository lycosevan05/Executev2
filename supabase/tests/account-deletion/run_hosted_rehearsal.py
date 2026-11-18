"""Exercise the staged deletion endpoint on a newly isolated Supabase project."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID, uuid4


RESTRICTED_PROJECTS = {
    "https://shoflbdwlmvttidoolvd.supabase.co",  # Executev2
    "https://zpnvnsdtbtdyhvipctpa.supabase.co",  # Execute Billing Integration
}
STAGED_ROUTE = "/functions/v1/deleteUserData-staged"
BUCKET = "uploads"


class Stop(Exception):
    """An unsuccessful or unverified operation."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class HostedFixture:
    def __init__(self, origin, state):
        self.origin = origin
        self.state = state
        self.run = state["run"]
        self.public = os.environ.get("EXECUTE_W09_PUBLIC_KEY", "")
        self.admin = os.environ.get("EXECUTE_W09_SERVICE_ROLE_KEY", "")
        self.opener = build_opener(NoRedirects())

    def request(self, method, path, expected, *, token=None, admin=False,
                payload=None, blob=None, headers=None):
        key = self.admin if admin else self.public
        if not key or not path.startswith("/") or path.startswith("//"):
            raise Stop("A valid API key and first-party API path are required.")
        combined = {"apikey": key}
        if admin or token:
            combined["Authorization"] = f"Bearer {token or key}"
        if payload is not None:
            blob = json.dumps(payload).encode()
            combined["Content-Type"] = "application/json"
        combined.update(headers or {})
        req = Request(self.origin + path, data=blob, headers=combined, method=method)
        try:
            response = self.opener.open(req, timeout=45)
        except HTTPError as error:
            response = error
        except (TimeoutError, URLError, OSError) as error:
            raise Stop("An API response was lost. Inspect the isolated fixture before retrying.") from error
        with response:
            status, body = response.code, response.read()
        if status not in expected:
            # Provider error bodies may contain private values.
            raise Stop(f"{method} {path.split('?')[0].split('/')[1]} returned HTTP {status}, expected {expected}.")
        return status, body

    def json(self, method, path, expected, **kwargs):
        statuses = (expected,) if isinstance(expected, int) else expected
        _, body = self.request(method, path, statuses, **kwargs)
        return json.loads(body)

    def auth_user(self, actor, missing=False):
        status, body = self.request("GET", f"/auth/v1/admin/users/{actor['id']}",
                                    (404,) if missing else (200,), admin=True)
        if status == 200:
            user = json.loads(body)
            if not self.matches(actor, user):
                raise Stop("The Auth UUID, email or administrator fixture marker did not match.")

    def matches(self, actor, user):
        return (user.get("id") == actor["id"] and user.get("email") == actor["email"]
                and user.get("app_metadata", {}).get("w09_fixture") == actor["marker"])

    def sign_in(self, actor):
        self.auth_user(actor)
        session = self.json("POST", "/auth/v1/token?grant_type=password", 200,
                            payload={"email": actor["email"], "password": actor["password"]})
        if not self.matches(actor, session.get("user", {})) or not session.get("access_token"):
            raise Stop("The new session did not match the disposable actor.")
        return session["access_token"]

    def create_actor(self, role, save):
        if role in self.state["actors"]:
            raise Stop("The fixture actor was already created.")
        email_role = "target" if role == "replacement" else role
        actor = {"email": f"w09-{self.run}-{email_role}@example.invalid",
                 "password": secrets.token_urlsafe(36), "marker": f"{self.run}:{role}",
                 "goal": str(uuid4())}
        user = self.json("POST", "/auth/v1/admin/users", (200, 201), admin=True, payload={
            "email": actor["email"], "password": actor["password"], "email_confirm": True,
            "app_metadata": {"w09_fixture": actor["marker"]},
        })
        actor["id"] = canonical_uuid(user.get("id"))
        self.state["actors"][role] = actor
        save()
        if not self.matches(actor, user):
            raise Stop("Auth created a user with an unexpected fixture marker.")
        return actor

    def path(self, actor, name="canonical"):
        return f"{actor['id']}/w09-{self.run}-{name}.txt"

    def contents(self, actor, name="canonical"):
        return f"Execute W09 {actor['marker']} {name}\n".encode()

    def seed(self, actor):
        token = self.sign_in(actor)
        self.request("POST", "/rest/v1/goals", (201,), token=token, payload={
            "id": actor["goal"], "owner_id": actor["id"],
            "data": {"w09_fixture": actor["marker"]},
        })
        path = self.path(actor)
        uploaded = self.json(
            "POST", "/functions/v1/guardedStorageUpload?" + urlencode({"bucket": BUCKET, "path": path}),
            201, token=token, blob=self.contents(actor), headers={"Content-Type": "text/plain"},
        )
        if uploaded != {"path": path}:
            raise Stop("The canonical upload receipt did not match the fixture path.")
        self.readback(actor)

    def readback(self, actor, missing=False, name="canonical"):
        self.auth_user(actor, missing=missing)
        query = urlencode({"select": "id,owner_id,data", "id": f"eq.{actor['goal']}",
                           "owner_id": f"eq.{actor['id']}"})
        goals = self.json("GET", "/rest/v1/goals?" + query, 200, admin=True)
        expected = [] if missing else [{
            "id": actor["goal"], "owner_id": actor["id"], "data": {"w09_fixture": actor["marker"]},
        }]
        if goals != expected:
            raise Stop("The independent database row did not match the expected result.")
        self.readback_storage(actor, missing, name)

    def readback_storage(self, actor, missing, name):
        path = self.path(actor, name)
        files = self.json("POST", f"/storage/v1/object/list/{BUCKET}", 200, admin=True,
                          payload={"prefix": actor["id"], "search": path.split("/")[1]})
        if missing:
            if files:
                raise Stop("Storage still lists the target file.")
            self.request("GET", f"/storage/v1/object/{BUCKET}/{path}",
                         (400, 404), admin=True)
            return
        if len(files) != 1 or files[0]["name"] != path.split("/")[1]:
            raise Stop("Storage inventory did not contain the exact expected file.")
        _, data = self.request("GET", f"/storage/v1/object/{BUCKET}/{path}",
                               (200,), admin=True)
        if data != self.contents(actor, name):
            raise Stop("Storage bytes did not match the fixture.")

    def check_off(self, withdrawn=False):
        token = self.sign_in(self.state["actors"]["witness"])
        if not withdrawn:
            self.request("POST", STAGED_ROUTE, (503,), token=token, payload={})
            return
        for path in (STAGED_ROUTE, "/functions/v1/guardedStorageUpload"):
            result = self.json("POST", path, 404, token=token, payload={})
            if result.get("code") != "NOT_FOUND" or result.get("message") != "Requested function was not found":
                raise Stop("The provider did not confirm withdrawal of the exact function.")

    def check_cutover(self):
        self.check_off()
        witness = self.state["actors"]["witness"]
        token = self.sign_in(witness)
        path = self.path(witness, "cutover")
        _, body = self.request(
            "POST", f"/storage/v1/object/{BUCKET}/{path}", (400, 403), token=token,
            blob=self.contents(witness, "cutover"),
            headers={"Content-Type": "text/plain", "x-upsert": "false"},
        )
        if b"row-level security" not in body.lower():
            raise Stop("The Storage response did not establish direct-write policy denial.")
        self.readback_storage(witness, missing=True, name="cutover")
        self.readback(witness)

    def hold(self, save):
        target = self.state["actors"]["target"]
        witness = self.state["actors"]["witness"]
        if self.state.get("held_dispatch"):
            raise Stop("The disposable dispatch is already recorded.")
        for actor in (target, witness):
            self.readback(actor)
        target_token, witness_token = self.sign_in(target), self.sign_in(witness)
        self.request("POST", STAGED_ROUTE, (401,), payload={})
        self.request("POST", STAGED_ROUTE, (403,), token=witness_token, payload={})

        # This disposable dispatch is intentionally never sent to Storage.
        # The staged route must keep Auth and bytes while the ledger blocks deletion.
        held_path = self.path(target, "held")
        registration = self.json("POST", "/rest/v1/rpc/begin_exact_account_upload_dispatch", 200,
                                 admin=True, payload={"p_owner_id": target["id"], "p_object_name": held_path})
        if len(registration) != 1 or registration[0]["object_name"] != held_path:
            raise Stop("The held test dispatch was not verified.")
        dispatch = canonical_uuid(registration[0]["dispatch_id"])
        self.state["held_dispatch"] = dispatch
        save()
        self.request("POST", STAGED_ROUTE, (500,), token=target_token, payload={})
        self.readback(target)
        self.readback(witness)

    def exercise(self, save):
        target = self.state["actors"]["target"]
        witness = self.state["actors"]["witness"]
        if not self.state.get("held_dispatch"):
            raise Stop("First hold and independently verify the disposable dispatch.")
        dispatch = canonical_uuid(self.state["held_dispatch"])
        target_token = self.sign_in(target)
        self.request("POST", "/rest/v1/rpc/finish_account_upload_dispatch", (200, 204),
                     admin=True, payload={"p_owner_id": target["id"], "p_dispatch_id": dispatch})
        del self.state["held_dispatch"]
        save()

        result = self.json("POST", STAGED_ROUTE, 200, token=target_token, payload={})
        if result.get("results", {}).get("storage") != "deleted 1":
            raise Stop("No confirmed deletion receipt for the exact target file.")
        self.readback(target, missing=True)
        self.readback(witness)
        replacement = self.create_actor("replacement", save)
        if replacement["id"] in {target["id"], witness["id"]}:
            raise Stop("Auth did not assign a fresh UUID to the replacement.")
        self.seed(replacement)

    def check_restored(self, withdrawn):
        self.check_off(withdrawn)
        self.readback(self.state["actors"]["target"], missing=True)
        self.readback(self.state["actors"]["replacement"])
        witness = self.state["actors"]["witness"]
        self.readback(witness)
        # Ordinary Storage writer works again after the temporary cutover is reversed.
        path = self.path(witness, "restored")
        self.request("POST", f"/storage/v1/object/{BUCKET}/{path}", (200,),
                     token=self.sign_in(witness), blob=self.contents(witness, "restored"),
                     headers={"Content-Type": "text/plain", "x-upsert": "false"})
        self.readback(witness, name="restored")

    def cleanup(self, withdrawn):
        # Keep any unresolved request or marker available for independent review.
        if self.state.get("held_dispatch"):
            raise Stop("A held dispatch needs independent reconciliation before cleanup.")
        self.check_off(withdrawn)
        actors = self.state["actors"]
        for role in ("target", "replacement", "witness"):
            if role not in actors:
                continue
            actor = actors[role]
            status, body = self.request("GET", f"/auth/v1/admin/users/{actor['id']}",
                                        (200, 404), admin=True)
            if status == 404:
                self.readback(actor, missing=True)
            else:
                if not self.matches(actor, json.loads(body)):
                    raise Stop("Cleanup refused an account without its matching fixture marker.")
                self.request("DELETE", f"/storage/v1/object/{BUCKET}", (200,), admin=True,
                             payload={"prefixes": [self.path(actor), self.path(actor, "restored"),
                                                  self.path(actor, "cutover")]})
                query = urlencode({"id": f"eq.{actor['goal']}", "owner_id": f"eq.{actor['id']}",
                                   "data->>w09_fixture": f"eq.{actor['marker']}"})
                self.request("DELETE", "/rest/v1/goals?" + query, (204,), admin=True)
                self.request("DELETE", f"/auth/v1/admin/users/{actor['id']}", (200, 204),
                             admin=True, payload={"should_soft_delete": False})
                self.readback(actor, missing=True)
            if role == "witness":
                self.readback_storage(actor, missing=True, name="restored")
                self.readback_storage(actor, missing=True, name="cutover")

    def sql_readback(self, include_guard_state):
        if not self.state["actors"]:
            raise Stop("The fixture has no verified actor IDs to inspect.")
        rows = ",\n  ".join(
            f"('{role}', '{actor['id']}'::uuid, '{actor['goal']}'::uuid, '{self.path(actor)}')"
            for role, actor in self.state["actors"].items()
        )
        guard_columns = """
       ,exists(select from execute_storage_deletion_guard.closed_upload_admission where owner_id = fixture.owner_id) as upload_closed
       ,(select count(*) from execute_storage_deletion_guard.pending_upload_dispatch where owner_id = fixture.owner_id) as pending_dispatches""" if include_guard_state else ""
        print(f"""with fixture(actor, owner_id, goal_id, object_path) as (values
  {rows}
)
select actor,
       exists(select from auth.users where id = fixture.owner_id) as auth_exists,
       exists(select from public.goals where id = fixture.goal_id and owner_id = fixture.owner_id) as goal_exists,
       exists(select from storage.objects where bucket_id = 'uploads' and name = fixture.object_path) as object_exists{guard_columns}
from fixture order by actor;""")


def canonical_uuid(value):
    if not isinstance(value, str) or str(UUID(value)) != value:
        raise Stop("The fixture identity is not a canonical UUID.")
    return value


def private_state(path, origin, prepare):
    if prepare:
        with path.open("x") as stream:
            state = {"origin": origin, "run": uuid4().hex, "actors": {}}
            json.dump(state, stream)
    else:
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode) or path.stat().st_mode & 0o077:
            raise Stop("The fixture state must be a private regular file.")
        state = json.loads(path.read_text())
    if state["origin"] != origin or not re.fullmatch(r"[a-f0-9]{32}", state["run"]):
        raise Stop("The recorded fixture belongs to another project or has an invalid run tag.")
    for role, actor in state["actors"].items():
        if role not in ("target", "witness", "replacement"):
            raise Stop("The recorded actor is outside the fixture.")
        email_role = "target" if role == "replacement" else role
        if (actor["email"] != f"w09-{state['run']}-{email_role}@example.invalid"
                or actor["marker"] != f"{state['run']}:{role}"):
            raise Stop("The recorded account does not match its fixture.")
        canonical_uuid(actor["id"])
        canonical_uuid(actor["goal"])
    if len({actor["id"] for actor in state["actors"].values()}) != len(state["actors"]):
        raise Stop("The recorded fixture contains duplicate Auth UUIDs.")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "seed", "check-off", "check-cutover", "hold", "rehearse",
                                          "readback-sql", "check-withdrawn", "check-restored", "cleanup"))
    parser.add_argument("--approved-origin", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--writers-isolated", action="store_true",
                        help="Confirm the project has no issued capabilities or untracked writers.")
    parser.add_argument("--include-guard-state", action="store_true",
                        help="Include ledger and upload-closure readback while the guards are installed.")
    parser.add_argument("--staged-withdrawn", action="store_true",
                        help="Require provider NOT_FOUND for both withdrawn functions in post-rollback phases.")
    args = parser.parse_args()
    if args.staged_withdrawn and args.phase not in ("check-restored", "cleanup"):
        parser.error("--staged-withdrawn applies only to the post-rollback phases")
    origin = args.approved_origin
    if (not re.fullmatch(r"https://[a-z]{20}\.supabase\.co", origin)
            or origin in RESTRICTED_PROJECTS
            or origin != os.environ.get("EXECUTE_W09_APPROVED_ORIGIN")):
        raise Stop("Use the exact HTTPS origin of the approved dedicated deletion project.")
    if args.phase != "readback-sql" and not args.writers_isolated:
        raise Stop("Confirm writer isolation for the dedicated project before contacting it.")
    os.umask(0o077)
    state = private_state(args.state, origin, args.phase == "prepare")

    def save():
        with tempfile.NamedTemporaryFile(mode="w", dir=args.state.parent, delete=False) as stream:
            json.dump(state, stream)
        os.replace(stream.name, args.state)

    fixture = HostedFixture(origin, state)
    if args.phase == "prepare":
        target = fixture.create_actor("target", save)
        fixture.create_actor("witness", save)
        print(f"Exact staged deletion target UUID: {target['id']}")
    elif args.phase == "seed":
        for actor in state["actors"].values():
            fixture.seed(actor)
    elif args.phase == "check-off":
        fixture.check_off()
    elif args.phase == "check-cutover":
        fixture.check_cutover()
    elif args.phase == "hold":
        fixture.hold(save)
    elif args.phase == "rehearse":
        fixture.exercise(save)
    elif args.phase == "readback-sql":
        fixture.sql_readback(args.include_guard_state)
        return
    elif args.phase == "check-withdrawn":
        fixture.check_off(withdrawn=True)
    elif args.phase == "check-restored":
        fixture.check_restored(args.staged_withdrawn)
    else:
        fixture.cleanup(args.staged_withdrawn)
    print(f"Hosted fixture phase complete: {args.phase}.")


if __name__ == "__main__":
    try:
        main()
    except Stop as error:
        raise SystemExit(str(error)) from None
    except (KeyError, ValueError, OSError):
        raise SystemExit("The fixture response or private state could not be verified.") from None
