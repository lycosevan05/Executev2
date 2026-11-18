"""Rehearse reversal of the five E63 optional deletion guards in a fresh local DB."""

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
)
STRIPE_ID = "sub_fixture_rollback"
UNRELATED_EMAIL = "unrelated@example.invalid"

# Fixture-only structural reversal. Hosted rollout must coordinate stopped
# writers and unresolved external work before any objects can be removed.
REVERSE = """
begin;
do $$
declare
  entity regclass;
begin
  if exists (select from execute_storage_deletion_guard.closed_upload_admission)
    or exists (select from execute_deletion_private.retired_stripe_subscription) then
    raise exception 'pending deletion state requires reconciliation';
  end if;
  for entity in select conrelid::regclass from pg_catalog.pg_constraint
    where conname = 'account_deletion_live_owner'
  loop
    execute format('drop policy "live auth for legacy entities" on %s', entity);
    execute format('drop trigger pin_authenticated_legacy_owner on %s', entity);
    execute format('alter table %s drop constraint account_deletion_live_owner', entity);
  end loop;
end;
$$;
drop function public.pin_authenticated_legacy_entity_owner();
drop function execute_deletion_guard.current_auth_owner_exists();
drop schema execute_deletion_guard;
drop trigger reject_retired_stripe_subscription_insert on public.user_subscriptions;
drop trigger reject_retired_stripe_subscription_update on public.user_subscriptions;
drop function public.retire_account_stripe_subscription_rows(uuid, text, jsonb);
drop function execute_deletion_private.reject_retired_stripe_subscription();
drop function execute_deletion_private.stripe_subscription_fingerprints(jsonb);
drop table execute_deletion_private.retired_stripe_subscription;
drop schema execute_deletion_private;
drop policy "account deletion uploads insert guard" on storage.objects;
drop policy "account deletion uploads update guard" on storage.objects;
drop function public.close_account_upload_admission(uuid);
drop function execute_storage_deletion_guard.current_owner_can_upload();
drop table execute_storage_deletion_guard.closed_upload_admission;
drop schema execute_storage_deletion_guard;
commit;
"""


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


def reject_pending_reversal(db):
    before = schema(db)
    try:
        db.sql(REVERSE)
    except AssertionError as error:
        assert "pending deletion state requires reconciliation" in str(error), error
    else:
        raise AssertionError("Structural reversal opened a pending deletion")
    assert schema(db) == before


def rehearse(db):
    db.file(HERE / "bootstrap.sql")
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        db.file(migration)
    db.sql(
        f"insert into public.goals(owner_id, owner_email) values ('{UNRELATED}', '{UNRELATED_EMAIL}');"
    )
    existing_rows = db.sql("select row_to_json(g) from public.goals g;")
    baseline = schema(db)
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)

    install(db)
    assert schema(db) != baseline
    assert db.sql(
        "select count(*) from pg_constraint where conname = 'account_deletion_live_owner'"
    ) == "19"
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)
    db.sql(REVERSE)
    assert schema(db) == baseline
    assert db.sql("select row_to_json(g) from public.goals g;") == existing_rows
    probe_existing_authenticated_client(db)
    probe_existing_provider(db)
    print("PASS clean reversal restores the baseline schema and preserves existing client/provider behavior")

    install(db)
    db.sql(f"set role service_role; select public.close_account_upload_admission('{WRITER_FIRST}');")
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
