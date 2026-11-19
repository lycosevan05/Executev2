"""Rehearse reversal of the optional deletion guards in a fresh local DB."""

import argparse
import tempfile
from pathlib import Path

from test_owned_entity_auth_guard import (
    Fixture,
    HERE,
    MIGRATIONS,
    UNRELATED,
    authenticated_as,
)
from test_retired_stripe_subscription_guard import (
    WRITER_EMAIL,
    WRITER_FIRST,
    WRITER_ROW,
    reconcile,
    retirement,
    seed_subscription,
)

GUARDS = (
    "owned-entity-auth-guard.sql",
    "authenticated-legacy-owner-guard.sql",
    "live-auth-legacy-policy.sql",
    "retired-stripe-subscription-guard.sql",
    "storage-upload-admission-guard.sql",
    "storage-upload-dispatch-guard.sql",
    "storage-upload-exact-dispatch.sql",
    "storage-upload-writer-cutover.sql",
)
STRIPE_ID = "sub_fixture_rollback"
UNRELATED_EMAIL = "unrelated@example.invalid"

REVERSE = (HERE / "reverse-staged-guards.sql").read_text()
REVERSE_UPLOAD = (HERE / "reverse-storage-upload-preparation.sql").read_text()
CATALOG = (HERE / "staged-guard-schema.sql").read_text()


def schema(db):
    dump = db.command([
        db.binaries / "pg_dump", "--schema-only", "-h", db.root, "-p", "55433",
        "-U", "postgres", "-d", "postgres",
    ]).stdout
    # pg_dump generates a fresh safety token on every export.
    return "\n".join(
        line for line in dump.splitlines()
        if not line.startswith(("\\restrict ", "\\unrestrict "))
    )


def install(db):
    for name in GUARDS:
        db.file(HERE / name)


def probe_existing_authenticated_client(db):
    assert db.sql(
        "begin;" + authenticated_as(UNRELATED, UNRELATED_EMAIL)
        + f"insert into public.goals(owner_id, owner_email) values ('{UNRELATED}', '{UNRELATED_EMAIL}');"
        + f"select count(*) from public.goals where owner_id = '{UNRELATED}'; rollback;"
    ) == "2"


def probe_existing_provider(db):
    assert db.sql(
        "begin; set role service_role;"
        + reconcile(UNRELATED_EMAIL, None, "sub_fixture_unrelated")
        + "select count(*) from public.user_subscriptions "
        + "where data->>'stripe_subscription_id' = 'sub_fixture_unrelated'; rollback;"
    ) == "1\n1"


def reject_reversal(db, sql, message):
    before = schema(db)
    try:
        db.sql(sql)
    except AssertionError as error:
        assert message in str(error), error
    else:
        raise AssertionError("Unsafe structural reversal succeeded")
    assert schema(db) == before


def reject_pending_reversal(db):
    reject_reversal(db, REVERSE, "pending deletion state requires reconciliation")


def rehearse_upload_preparation(db, baseline, baseline_catalog):
    for name in GUARDS[4:7]:
        db.file(HERE / name)
    dispatch = db.sql(
        "set role service_role; select dispatch_id "
        f"from public.begin_exact_account_upload_dispatch('{WRITER_FIRST}', '{WRITER_FIRST}/preparation.txt');"
    )
    reject_reversal(db, REVERSE_UPLOAD, "pending upload state requires reconciliation")
    db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch}');")
    db.sql(f"set role service_role; select public.close_account_upload_admission('{WRITER_FIRST}');")
    reject_reversal(db, REVERSE_UPLOAD, "pending upload state requires reconciliation")
    db.sql(f"delete from auth.users where id = '{WRITER_FIRST}';"
           f"insert into auth.users (id,email) values ('{WRITER_FIRST}', '{WRITER_EMAIL}');")
    db.sql(REVERSE_UPLOAD)
    assert schema(db) == baseline
    assert db.sql(CATALOG) == baseline_catalog
    print("PASS upload preparation reverses before cutover and retains pending dispatches and admission closures")


def rehearse(db):
    db.file(HERE / "bootstrap.sql")
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        db.file(migration)
    db.sql(
        f"insert into public.goals(owner_id, owner_email) values ('{UNRELATED}', '{UNRELATED_EMAIL}');"
    )
    existing_rows = db.sql("select row_to_json(g) from public.goals g;")
    baseline = schema(db)
    baseline_catalog = db.sql(CATALOG)
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)
    rehearse_upload_preparation(db, baseline, baseline_catalog)

    install(db)
    assert schema(db) != baseline
    assert db.sql(CATALOG) != baseline_catalog
    assert db.sql(
        "select count(*) from pg_constraint where conname = 'account_deletion_live_owner'"
    ) == "19"
    assert db.sql(
        "select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' "
        "and policyname like 'uploads require canonical writer for %' and permissive = 'RESTRICTIVE'"
    ) == "2"
    reject_reversal(db, REVERSE_UPLOAD, "writer cutover requires the full staged reversal")
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)
    db.sql(REVERSE)
    assert schema(db) == baseline
    assert db.sql(CATALOG) == baseline_catalog
    assert db.sql("select row_to_json(g) from public.goals g;") == existing_rows
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)
    print("PASS clean reversal restores the baseline schema and preserves existing client/provider behavior")

    install(db)
    pending_path = f"{WRITER_FIRST}/in-flight.txt"
    dispatch_id = db.sql(
        f"set role service_role; select dispatch_id "
        f"from public.begin_exact_account_upload_dispatch('{WRITER_FIRST}', '{pending_path}');"
    )
    assert db.sql("select count(*) from execute_storage_deletion_guard.closed_upload_admission;") == "0"
    reject_pending_reversal(db)
    assert db.sql(
        "select object_name from execute_storage_deletion_guard.pending_upload_dispatch;"
    ) == pending_path
    print("PASS a pending exact-path upload dispatch independently prevents structural reversal")
    # In this SQL-only fixture no bytes were sent, so the outcome is known.
    db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch_id}');")

    assert db.sql(
        "set role service_role; select count(*) "
        f"from public.close_and_list_guarded_account_upload_dispatches('{WRITER_FIRST}');"
    ) == "0"
    reject_pending_reversal(db)
    assert db.sql("select count(*) from execute_storage_deletion_guard.closed_upload_admission;") == "1"
    print("PASS an existing upload closure prevents structural reversal")

    # Reconcile the upload fixture before isolating the independent Stripe case.
    assert db.sql(f"delete from auth.users where id = '{WRITER_FIRST}';"
                  "select count(*) from execute_storage_deletion_guard.closed_upload_admission;") == "0"
    db.sql(f"insert into auth.users (id,email) values ('{WRITER_FIRST}', '{WRITER_EMAIL}');")
    seed_subscription(db, WRITER_ROW, WRITER_EMAIL, STRIPE_ID)
    assert db.sql("set role service_role; " + retirement(
        WRITER_FIRST, WRITER_ROW, WRITER_EMAIL, STRIPE_ID
    )) == "1"
    reject_pending_reversal(db)
    assert db.sql("select count(*) from execute_deletion_private.retired_stripe_subscription;") == "1"
    assert db.sql("select row_to_json(g) from public.goals g;") == existing_rows
    print("PASS an existing Stripe retirement marker prevents structural reversal")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-bin", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ex-w09-roll-") as root:
        with Fixture(Path(root), args.postgres_bin.resolve()) as db:
            rehearse(db)


if __name__ == "__main__":
    main()
