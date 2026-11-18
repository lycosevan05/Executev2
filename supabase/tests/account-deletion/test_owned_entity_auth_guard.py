"""Exercise the isolated deletion guard candidate using a fresh local PostgreSQL."""

import argparse
import json
import os
import select
import subprocess
import tempfile
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
MIGRATIONS = HERE.parent.parent / "migrations"
WRITER_FIRST = "11111111-1111-1111-1111-111111111111"
DELETION_FIRST = "22222222-2222-2222-2222-222222222222"
UNRELATED = "33333333-3333-3333-3333-333333333333"
HISTORICAL_ORPHAN = "44444444-4444-4444-4444-444444444444"
LEGACY_WRITER_FIRST = "55555555-5555-5555-5555-555555555555"
LEGACY_DELETION_FIRST = "66666666-6666-6666-6666-666666666666"
RETURNING_EMAIL_OWNER = "77777777-7777-7777-7777-777777777777"
LEGACY_PATCH_ID = "88888888-8888-8888-8888-888888888888"
LEGACY_WRITER_ROW = "99999999-9999-9999-9999-999999999999"


class Fixture:
    def __init__(self, root, binaries):
        self.root = root
        self.binaries = binaries
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
        self.psql = [
            binaries / "psql", "-XqAt", "-h", root, "-p", "55433", "-U", "postgres",
            "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose",
        ]

    def __enter__(self):
        self.command(
            [self.binaries / "initdb", "-D", self.root / "data", "-U", "postgres",
             "--auth-local=trust", "--auth-host=reject", "--no-locale", "-E", "UTF8"],
        )
        self.command([
            self.binaries / "pg_ctl", "-D", self.root / "data", "-w", "-t", "10",
            "-l", self.root / "postgres.log", "-o",
            f"-k {self.root} -p 55433 -c listen_addresses='' -c unix_socket_permissions=0700 "
            "-c statement_timeout=10000",
            "start",
        ])
        return self

    def __exit__(self, error_type, *_):
        self.command([
            self.binaries / "pg_ctl", "-D", self.root / "data", "-w", "-t", "10",
            "-m", "fast", "stop",
        ])
        if error_type is not None:
            print((self.root / "postgres.log").read_text(), flush=True)

    def command(self, args, sql_input=None):
        result = subprocess.run(
            args, input=sql_input, capture_output=True, text=True, timeout=25,
            env={**self.env, "PGAPPNAME": "w09_observer"}, check=False,
        )
        if result.returncode:
            raise AssertionError(result.stderr or result.stdout)
        return result

    def sql(self, value):
        return self.command([*self.psql, "-c", value]).stdout.strip()

    def file(self, path):
        self.command([*self.psql, "-f", "-"], sql_input=path.read_text())

    def session(self, name):
        return subprocess.Popen(
            self.psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env={**self.env, "PGAPPNAME": name},
        )

    def wait_until_blocked(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            blockers = self.sql(
                "select coalesce(max(cardinality(pg_blocking_pids(pid))), 0) "
                "from pg_stat_activity where application_name = 'w09_waiter'"
            )
            if blockers == "1":
                return
            time.sleep(0.05)
        raise AssertionError("Competing transaction did not reach the expected FK lock")


def send_and_acknowledge(client, sql):
    client.stdin.write(f"{sql}\n\\echo transaction_ready\n")
    client.stdin.flush()
    if not select.select([client.stdout], [], [], 10)[0]:
        raise AssertionError("PostgreSQL fixture did not acknowledge its transaction")
    if client.stdout.readline().strip() != "transaction_ready":
        raise AssertionError("PostgreSQL fixture stopped before the transaction barrier")


def write_entity(owner_id):
    return f"set role service_role; insert into public.goals(owner_id) values ('{owner_id}');"


def remove_auth(owner_id):
    return f"delete from auth.users where id = '{owner_id}';"


def authenticated_as(owner_id, email):
    claims = json.dumps({"role": "authenticated", "sub": owner_id, "email": email})
    return f"set role authenticated; set request.jwt.claims = '{claims}'; "


def write_legacy_entity(owner_id, email):
    return (
        authenticated_as(owner_id, email)
        + "insert into public.goals(owner_id, data) values (null, '{}');"
    )


def expect_ownership_rejection(db, statement):
    try:
        db.sql(statement)
    except AssertionError as error:
        assert "42501" in str(error), error
    else:
        raise AssertionError("Expected inconsistent legacy ownership to be rejected")


def check_transaction_order(db, first, second):
    with db.session("w09_first") as first_client, db.session("w09_waiter") as waiter:
        try:
            send_and_acknowledge(first_client, f"begin; {first}")
            waiter.stdin.write(second + "\n\\q\n")
            waiter.stdin.flush()
            db.wait_until_blocked()
            first_client.stdin.write("commit;\n\\q\n")
            first_client.stdin.flush()
            first_client.communicate(timeout=5)
            assert first_client.returncode == 0
            _, error = waiter.communicate(timeout=5)
            assert waiter.returncode != 0 and "23503" in error, error
        finally:
            for client in (first_client, waiter):
                if client.poll() is None:
                    client.kill()


def test_guard(db):
    db.file(HERE / "bootstrap.sql")
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        db.file(migration)
    db.sql(f"insert into public.goals(owner_id) values ('{HISTORICAL_ORPHAN}');")
    db.file(HERE / "owned-entity-auth-guard.sql")

    assert db.sql(
        "select count(*) from pg_constraint where conname = 'account_deletion_live_owner' "
        "and confrelid = 'auth.users'::regclass and contype = 'f' and confdeltype = 'r' "
        "and not convalidated"
    ) == "19"
    assert db.sql(
        "select count(*) from pg_policies where schemaname = 'public' "
        "and policyname = 'entity ownership guard' and permissive = 'RESTRICTIVE'"
    ) == "19"
    assert db.sql(f"select count(*) from public.goals where owner_id = '{HISTORICAL_ORPHAN}'") == "1"
    print("PASS all 19 constraints installed without changing historical rows")

    check_transaction_order(db, write_entity(WRITER_FIRST), remove_auth(WRITER_FIRST))
    assert db.sql(f"select count(*) from auth.users where id = '{WRITER_FIRST}'") == "1"
    assert db.sql(f"select count(*) from public.goals where owner_id = '{WRITER_FIRST}'") == "1"
    db.sql(f"delete from public.goals where owner_id = '{WRITER_FIRST}'")
    db.sql(remove_auth(WRITER_FIRST))
    assert db.sql(f"select count(*) from auth.users where id = '{WRITER_FIRST}'") == "0"
    print("PASS an in-flight owned write keeps Auth available until explicit cleanup and retry")

    check_transaction_order(db, remove_auth(DELETION_FIRST), write_entity(DELETION_FIRST))
    assert db.sql(f"select count(*) from auth.users where id = '{DELETION_FIRST}'") == "0"
    assert db.sql(f"select count(*) from public.goals where owner_id = '{DELETION_FIRST}'") == "0"
    print("PASS an owned write waiting on Auth removal cannot create an orphan")

    claims = json.dumps({"role": "authenticated", "sub": UNRELATED, "email": "unrelated@example.invalid"})
    db.sql(
        f"set role authenticated; select set_config('request.jwt.claims', '{claims}', false); "
        "insert into public.goals(data) values ('{}'); "
        "insert into public.goals(owner_id, data) values (null, '{}');"
    )
    assert db.sql(f"select count(*) from public.goals where owner_id = '{UNRELATED}'") == "1"
    assert db.sql(
        "select count(*) from public.goals where owner_id is null and owner_email = 'unrelated@example.invalid'"
    ) == "1"
    db.sql(
        "set role service_role; select public.reconcile_revenuecat_subscriptions("
        "'[{\"user_id\":\"legacy@example.invalid\",\"expected_updated_date\":null,"
        "\"data\":{\"status\":\"active\"}}]'::jsonb);"
    )
    assert db.sql(
        "select count(*) from public.user_subscriptions "
        "where data->>'user_id' = 'legacy@example.invalid' and owner_id is null"
    ) == "1"
    print("PASS unrelated authenticated UUID and legacy writes and existing billing projection still work")


def test_authenticated_legacy_guard(db):
    writer_email = "legacy-writer-first@example.invalid"
    deletion_email = "legacy-deletion-first@example.invalid"
    db.sql(
        "insert into auth.users (id, email) values "
        f"('{LEGACY_WRITER_FIRST}', '{writer_email}'), "
        f"('{LEGACY_DELETION_FIRST}', '{deletion_email}');"
    )
    db.file(HERE / "authenticated-legacy-owner-guard.sql")
    assert db.sql(
        "select count(*) from pg_trigger where tgname = 'pin_authenticated_legacy_owner' "
        "and not tgisinternal"
    ) == "19"
    assert db.sql(
        "select count(*) from public.goals where owner_id is null "
        "and owner_email = 'unrelated@example.invalid'"
    ) == "1"
    print("PASS all 19 write triggers installed without backfilling legacy rows")

    db.sql(
        f"insert into public.goals(id, owner_id, owner_email) values ('{LEGACY_WRITER_ROW}', null, '{writer_email}');"
    )
    legacy_update = authenticated_as(LEGACY_WRITER_FIRST, writer_email) + (
        f"""update public.goals set data = '{{"updated":true}}' where id = '{LEGACY_WRITER_ROW}';"""
    )
    check_transaction_order(db, legacy_update, remove_auth(LEGACY_WRITER_FIRST))
    assert db.sql(f"select count(*) from auth.users where id = '{LEGACY_WRITER_FIRST}'") == "1"
    assert db.sql(
        f"select count(*) from public.goals where owner_id = '{LEGACY_WRITER_FIRST}' "
        f"and owner_email = '{writer_email}'"
    ) == "1"
    db.sql(f"delete from public.goals where owner_id = '{LEGACY_WRITER_FIRST}';")
    db.sql(remove_auth(LEGACY_WRITER_FIRST))
    assert db.sql(f"select count(*) from auth.users where id = '{LEGACY_WRITER_FIRST}'") == "0"
    assert db.sql(f"select count(*) from public.goals where id = '{LEGACY_WRITER_ROW}'") == "0"
    print("PASS a committed authenticated legacy update is now included in explicit cleanup")

    check_transaction_order(
        db, remove_auth(LEGACY_DELETION_FIRST), write_legacy_entity(LEGACY_DELETION_FIRST, deletion_email)
    )
    assert db.sql(f"select count(*) from public.goals where owner_email = '{deletion_email}'") == "0"
    db.sql(
        f"insert into auth.users (id, email) values ('{RETURNING_EMAIL_OWNER}', '{deletion_email}');"
    )
    db.sql(write_legacy_entity(RETURNING_EMAIL_OWNER, deletion_email))
    assert db.sql(
        f"select owner_id from public.goals where owner_email = '{deletion_email}'"
    ) == RETURNING_EMAIL_OWNER
    print("PASS Auth removal prevents an orphan and a returning email binds to its new UUID")

    unrelated = authenticated_as(UNRELATED, "unrelated@example.invalid")
    expect_ownership_rejection(
        db, unrelated
        + "insert into public.goals(owner_id, owner_email) values (null, 'different@example.invalid');"
    )
    expect_ownership_rejection(
        db, unrelated + "insert into public.goals(owner_id, owner_email, created_by, user_email) "
        + "values (null, null, null, null);"
    )
    expect_ownership_rejection(
        db, unrelated + "insert into public.user_subscriptions(owner_id, data) "
        + """values (null, '{"user_id":"different@example.invalid"}');"""
    )
    db.sql(
        f"insert into public.goals(id, owner_id, owner_email, created_by) "
        f"values ('{LEGACY_PATCH_ID}', null, 'unrelated@example.invalid', '');"
    )
    assert db.sql(
        unrelated + f"select item->>'owner_id' from public.patch_record("
        f"'goals', '{LEGACY_PATCH_ID}', '{{\"confirmed\":true}}') as item;"
    ) == UNRELATED
    assert db.sql(
        f"select data->>'confirmed' from public.goals where id = '{LEGACY_PATCH_ID}'"
    ) == "true"
    assert db.sql(
        f"select count(*) from public.goals where owner_id = '{UNRELATED}'"
    ) == "2"
    print("PASS existing legacy attribution checks and native patch semantics are preserved")

    db.sql(
        "set role service_role; select public.reconcile_revenuecat_subscriptions("
        "'[{\"user_id\":\"unbound@example.invalid\",\"expected_updated_date\":null,"
        "\"data\":{\"status\":\"active\"}}]'::jsonb);"
    )
    assert db.sql(
        "select count(*) from public.user_subscriptions "
        "where data->>'user_id' = 'unbound@example.invalid' and owner_id is null"
    ) == "1"
    print("PASS email-only provider reconciliation remains compatible and outside the guard")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-bin", required=True, type=Path)
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="w09-guard-", dir="/tmp") as directory:
        with Fixture(Path(directory), options.postgres_bin.resolve()) as database:
            test_guard(database)
            test_authenticated_legacy_guard(database)
