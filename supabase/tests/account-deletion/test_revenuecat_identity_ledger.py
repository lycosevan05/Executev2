"""Verify the optional RevenueCat identity primitives in a disposable PostgreSQL."""

import argparse
import tempfile
from pathlib import Path

from test_owned_entity_auth_guard import (
    DELETION_FIRST,
    Fixture,
    HERE,
    MIGRATIONS,
    MISSING_AUTH_OWNER,
    RETURNING_EMAIL_OWNER,
    UNRELATED,
    WRITER_FIRST,
    send_and_acknowledge,
)


INSTALL = HERE / "revenuecat-identity-ledger.sql"
REVERSE = HERE / "reverse-revenuecat-identity-ledger.sql"
PROJECT = "fixture-project"


def ensure(owner, project=PROJECT):
    return f"public.ensure_revenuecat_customer_id('{project}', '{owner}')"


def attach(owner, alias, project=PROJECT):
    return f"public.attach_verified_revenuecat_alias('{project}', '{owner}', '{alias}')"


def resolve(identifier, project=PROJECT):
    return f"public.resolve_revenuecat_identity('{project}', '{identifier}')"


def retire(owner):
    return f"public.retire_revenuecat_identity('{PROJECT}', '{owner}')"


def close(owner, email):
    return f"public.close_account_billing_projection('{owner}', '{email}', '[]'::jsonb)"


def request(db, expression):
    return db.sql(f"set role service_role; select {expression};")


def expect_failure(action, code):
    try:
        action()
    except AssertionError as error:
        assert code in str(error), error
    else:
        raise AssertionError(f"Expected SQLSTATE {code}")


def overlap(db, first, second, expected_error=None):
    with db.session("w09_first") as holder, db.session("w09_waiter") as waiter:
        try:
            send_and_acknowledge(holder, f"begin; set local role service_role; "
                                  f"do $$ begin perform {first}; end $$;")
            waiter.stdin.write(f"set role service_role; select {second};\n\\q\n")
            waiter.stdin.flush()
            db.wait_until_blocked()
            holder.stdin.write("commit;\n\\q\n")
            holder.stdin.flush()
            _, holder_error = holder.communicate(timeout=5)
            assert holder.returncode == 0, holder_error
            output, error = waiter.communicate(timeout=5)
            if expected_error is None:
                assert waiter.returncode == 0, error
                return output.strip()
            assert waiter.returncode != 0 and expected_error in error, error
        finally:
            for client in (holder, waiter):
                if client.poll() is None:
                    client.kill()


def test_ledger(db):
    db.file(HERE / "bootstrap.sql")
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        db.file(migration)
    db.file(HERE / "billing-projection-fence.sql")
    db.file(INSTALL)
    expect_failure(lambda: db.file(HERE / "reverse-billing-projection-fence.sql"), "2BP01")
    db.file(REVERSE)
    assert db.sql("select to_regnamespace('execute_revenuecat_private') is null") == "t"
    assert db.sql("select to_regprocedure('public.close_account_billing_projection(uuid,text,jsonb)') is not null") == "t"
    db.file(INSTALL)
    print("PASS empty ledger reversal preserves the original fence and guards its dependency")

    for role in ("anon", "authenticated"):
        for operation in (ensure(DELETION_FIRST), attach(DELETION_FIRST, "Example"),
                          resolve("Example"), retire(DELETION_FIRST)):
            expect_failure(lambda: db.sql(f"set role {role}; select {operation}"), "42501")
    expect_failure(lambda: db.sql("set role service_role; select * from execute_revenuecat_private.identity_key"),
                   "42501")
    expect_failure(lambda: request(db, ensure(MISSING_AUTH_OWNER)), "55000")
    expect_failure(lambda: request(db, resolve("invalid/id")), "22023")
    assert db.sql(f"set role service_role; select * from {resolve('Unknown')}") == "unresolved||"
    print("PASS only named service RPCs can access the ledger")

    first_customer = overlap(db, ensure(WRITER_FIRST), ensure(WRITER_FIRST))
    assert first_customer != WRITER_FIRST
    assert request(db, ensure(WRITER_FIRST)) == first_customer
    second_customer = request(db, ensure(UNRELATED))
    assert second_customer != first_customer
    assert request(db, ensure(WRITER_FIRST, "other-project")) != first_customer
    overlap(db, attach(WRITER_FIRST, "Shared"), attach(UNRELATED, "Shared"), "23505")
    request(db, attach(WRITER_FIRST, "Shared"))
    request(db, attach(UNRELATED, "shared"))
    other_customer = request(db, ensure(UNRELATED, "other-project"))
    request(db, attach(UNRELATED, "Shared", "other-project"))
    assert db.sql(f"set role service_role; select * from {resolve('Shared', 'other-project')}") == (
        f"active|{UNRELATED}|{other_customer}"
    )
    expect_failure(lambda: request(db, attach(UNRELATED, first_customer)), "23505")
    assert db.sql(f"set role service_role; select * from {resolve('Shared')}") == f"active|{WRITER_FIRST}|{first_customer}"
    assert db.sql(f"set role service_role; select * from {resolve('shared')}") == f"active|{UNRELATED}|{second_customer}"
    print("PASS concurrent enrollment, exact aliases, and canonical collisions share one project namespace")

    request(db, attach(WRITER_FIRST, "writer-first@example.invalid"))
    expect_failure(lambda: request(db, retire(WRITER_FIRST)), "55000")
    assert overlap(db, attach(WRITER_FIRST, "BeforeClosure"),
                   close(WRITER_FIRST, "writer-first@example.invalid")) == "t"
    overlap(db, close(DELETION_FIRST, "deletion-first@example.invalid"), ensure(DELETION_FIRST), "55000")
    for identifier in ("BeforeClosure", first_customer):
        assert db.sql(f"set role service_role; select * from {resolve(identifier)}") == "blocked||"
    expect_failure(lambda: request(db, attach(WRITER_FIRST, "AfterClosure")), "55000")
    assert overlap(db, retire(WRITER_FIRST), retire(WRITER_FIRST)) == "t"
    db.sql(f"delete from auth.users where id = '{WRITER_FIRST}'; "
           f"insert into auth.users (id,email) values ('{RETURNING_EMAIL_OWNER}', 'writer-first@example.invalid')")
    assert request(db, retire(WRITER_FIRST)) == "t"
    assert request(db, ensure(RETURNING_EMAIL_OWNER)) != first_customer
    for identifier in (first_customer, "Shared", "BeforeClosure", "writer-first@example.invalid"):
        assert db.sql(f"set role service_role; select * from {resolve(identifier)}") == "retired||"
        expect_failure(lambda: request(db, attach(RETURNING_EMAIL_OWNER, identifier)), "23505")
    assert db.sql(f"set role service_role; select * from {resolve('shared')}") == f"active|{UNRELATED}|{second_customer}"
    assert db.sql("select count(*) from execute_revenuecat_private.accounts where retired_at is not null "
                  "and customer_id is null and owner_id is null") == "1"
    expect_failure(lambda: db.file(REVERSE), "55000")
    print("PASS closure and retirement order, same-email recreation, active witness, and nonempty rollback refusal")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="w09-revenuecat-", dir="/tmp") as temporary:
        with Fixture(Path(temporary), args.pg_bin) as isolated:
            test_ledger(isolated)
