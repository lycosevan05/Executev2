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
REVERSE_CUTOVER = (HERE / "reverse-storage-upload-writer-cutover.sql").read_text()
REVERSE_TO_E71 = (HERE / "reverse-deletion-guards-to-upload-preparation.sql").read_text()
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


def direct_upload(path):
    # The synthetic Storage schema lacks the platform grants on the hosted table.
    return (
        "begin; grant usage on schema storage to authenticated; "
        "grant insert, select on storage.objects to authenticated; "
        + authenticated_as(UNRELATED, UNRELATED_EMAIL)
        + f"insert into storage.objects(bucket_id, name) values ('uploads', '{path}') returning name; "
        "rollback;"
    )


def rehearse_upload_cutover(db):
    preparation_schema = schema(db)
    preparation_catalog = db.sql(CATALOG)
    direct_path = f"{UNRELATED}/direct-preparation.txt"
    direct_write = direct_upload(direct_path)
    assert db.sql(direct_write) == direct_path
    db.file(HERE / "storage-upload-writer-cutover.sql")
    try:
        db.sql(direct_write)
    except AssertionError as error:
        assert "violates row-level security policy" in str(error), error
    else:
        raise AssertionError("Cutover accepted an ordinary direct upload")

    db.sql('alter policy "uploads require canonical writer for update" on storage.objects using (true);')
    reject_reversal(db, REVERSE_CUTOVER, "canonical upload cutover schema changed")
    db.sql('alter policy "uploads require canonical writer for update" on storage.objects using (bucket_id <> \'uploads\');')

    canonical_path = f"{WRITER_FIRST}/cutover.txt"
    begin_upload = (
        "set role service_role; select dispatch_id "
        f"from public.begin_exact_account_upload_dispatch('{WRITER_FIRST}', '{canonical_path}');"
    )
    dispatch = db.sql(begin_upload)
    reject_reversal(db, REVERSE_CUTOVER, "pending upload state requires reconciliation")
    # The fixture registered a dispatch but sent no bytes.
    db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch}');")
    db.sql(f"set role service_role; select public.close_account_upload_admission('{WRITER_FIRST}');")
    reject_reversal(db, REVERSE_CUTOVER, "pending upload state requires reconciliation")
    db.sql(f"delete from auth.users where id = '{WRITER_FIRST}';"
           f"insert into auth.users (id,email) values ('{WRITER_FIRST}', '{WRITER_EMAIL}');")

    db.sql(REVERSE_CUTOVER)
    assert schema(db) == preparation_schema
    assert db.sql(CATALOG) == preparation_catalog
    assert db.sql(direct_write) == direct_path
    dispatch = db.sql(begin_upload)
    assert db.sql("select object_name from execute_storage_deletion_guard.pending_upload_dispatch") == canonical_path
    db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch}');")
    print("PASS cutover reversal restores the preparation catalog, direct writes and canonical registrations")


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
    rehearse_upload_cutover(db)
    db.sql(REVERSE_UPLOAD)
    assert schema(db) == baseline
    assert db.sql(CATALOG) == baseline_catalog
    print("PASS upload preparation reverses before cutover and retains pending dispatches and admission closures")


def rehearse_deletion_reversal_to_preparation(db, existing_rows):
    for name in GUARDS[4:7]:
        db.file(HERE / name)
    preparation_schema = schema(db)
    preparation_catalog = db.sql(CATALOG)
    direct_path = f"{UNRELATED}/direct-restored.txt"
    canonical_path = f"{WRITER_FIRST}/canonical-restored.txt"
    begin_upload = (
        "set role service_role; select dispatch_id "
        f"from public.begin_exact_account_upload_dispatch('{WRITER_FIRST}', '{canonical_path}');"
    )

    for with_e72_guards in (False, True):
        for name in GUARDS[:4]:
            db.file(HERE / name)
        db.file(HERE / GUARDS[7])
        reject_reversal(db, REVERSE_TO_E71, "reverse the writer cutover first")
        db.sql(REVERSE_CUTOVER)

        if with_e72_guards:
            db.file(HERE / "billing-projection-fence.sql")
            reject_reversal(db, REVERSE_TO_E71, "reverse the billing projection fence first")
            db.file(HERE / "stripe-checkout-admission.sql")
            db.file(HERE / "apple-grant-custody.sql")
            reject_reversal(db, REVERSE_TO_E71, "reverse Stripe Checkout admission first")
            db.file(HERE / "reverse-stripe-checkout-admission.sql")
            reject_reversal(db, REVERSE_TO_E71, "reverse Apple grant custody first")
            db.file(HERE / "reverse-apple-grant-custody.sql")
            db.file(HERE / "reverse-billing-projection-fence.sql")
        else:
            db.sql('alter policy "account deletion uploads insert guard" on storage.objects rename to "fixture renamed guard";')
            reject_reversal(db, REVERSE_TO_E71, "E71 upload preparation is incomplete")
            db.sql('alter policy "fixture renamed guard" on storage.objects rename to "account deletion uploads insert guard";')
            dispatch = db.sql(begin_upload)
            reject_reversal(db, REVERSE_TO_E71, "pending upload state requires reconciliation")
            # The fixture registered an upload without sending bytes.
            db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch}');")
            db.sql(f"set role service_role; select public.close_account_upload_admission('{WRITER_FIRST}');")
            reject_reversal(db, REVERSE_TO_E71, "pending upload state requires reconciliation")
            db.sql(f"delete from auth.users where id = '{WRITER_FIRST}';"
                   f"insert into auth.users (id,email) values ('{WRITER_FIRST}', '{WRITER_EMAIL}');")
            seed_subscription(db, WRITER_ROW, WRITER_EMAIL, STRIPE_ID)
            assert db.sql("set role service_role; " + retirement(
                WRITER_FIRST, WRITER_ROW, WRITER_EMAIL, STRIPE_ID
            )) == "1"
            reject_reversal(db, REVERSE_TO_E71, "Stripe retirement markers require reconciliation")
            assert db.sql("select count(*) from execute_deletion_private.retired_stripe_subscription;") == "1"
            # The synthetic subscription has no real provider events to reconcile.
            db.sql("delete from execute_deletion_private.retired_stripe_subscription;")
            db.sql("create table execute_deletion_private.unexpected_fixture_dependency (id integer);")
            reject_reversal(db, REVERSE_TO_E71, "other objects depend on it")
            db.sql("drop table execute_deletion_private.unexpected_fixture_dependency;")

        db.sql(REVERSE_TO_E71)
        assert schema(db) == preparation_schema
        assert db.sql(CATALOG) == preparation_catalog
        assert db.sql("select row_to_json(g) from public.goals g;") == existing_rows
        assert db.sql(direct_upload(direct_path)) == direct_path
        dispatch = db.sql(begin_upload)
        assert db.sql("select object_name from execute_storage_deletion_guard.pending_upload_dispatch") == canonical_path
        db.sql(f"set role service_role; select public.finish_account_upload_dispatch('{WRITER_FIRST}', '{dispatch}');")
        probe_existing_authenticated_client(db)
        probe_existing_provider(db)
        suffix = " after reversing E72 guards" if with_e72_guards else " with baseline guards only"
        print("PASS deletion reversal restores the exact E71 catalog and both upload paths" + suffix)

    db.sql(REVERSE_UPLOAD)


def rehearse(db):
    db.file(HERE / "bootstrap.sql")
    # The staged Apple custody functions resolve the managed Auth identity table.
    db.sql("create table auth.identities (user_id uuid not null references auth.users(id) on delete cascade, "
           "provider text not null, identity_data jsonb not null);")
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
    rehearse_deletion_reversal_to_preparation(db, existing_rows)
    assert schema(db) == baseline

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
    reject_reversal(db, REVERSE_UPLOAD, "reverse the writer cutover before upload preparation")
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
