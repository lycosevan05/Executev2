"""Exercise the Stripe retirement candidate using a new isolated PostgreSQL."""
import argparse
import json
import tempfile
from pathlib import Path

from test_owned_entity_auth_guard import (
    DELETION_FIRST,
    Fixture,
    HERE,
    MIGRATIONS,
    WRITER_FIRST,
    send_and_acknowledge,
)

WRITER_ROW = "9ba61823-107d-45ba-8a01-78351d081397"
DELETION_ROW = "d4ee4d32-2428-40e4-9174-5586aa47c347"
WRITER_EMAIL = "writer-first@example.invalid"
DELETION_EMAIL = "deletion-first@example.invalid"


def json_sql(value):
    return "'" + json.dumps(value).replace("'", "''") + "'::jsonb"


def seed_subscription(db, row, email, stripe_id):
    data = json_sql({
        "user_id": email,
        "stripe_subscription_id": stripe_id,
        "stripe_subscription_ids": [stripe_id],
    })
    db.sql(f"""
      insert into public.user_subscriptions (id, owner_email, data)
      values ('{row}', '{email}', {data});
    """)
    return db.sql(f"select updated_date from public.user_subscriptions where id = '{row}';")


def retirement(owner, row, email, stripe_id):
    snapshot = json_sql([{
        "id": row,
        "owner_id": None,
        "owner_email": email,
        "created_by": None,
        "user_email": None,
        "legacy_user_id": email,
        "stripe_id": stripe_id,
        "stripe_ids_json": json.dumps([stripe_id]),
    }])
    return f"select public.retire_account_stripe_subscription_rows('{owner}', '{email}', {snapshot});"


def reconcile(email, revision, stripe_id):
    changes = json_sql([{
        "user_id": email,
        "expected_updated_date": revision,
        "data": {"stripe_subscription_id": stripe_id, "stripe_subscription_ids": [stripe_id]},
    }])
    return f"select public.reconcile_revenuecat_subscriptions({changes});"


def check_order(db, first, second, error_code):
    with db.session("w09_first") as writer, db.session("w09_waiter") as waiter:
        try:
            send_and_acknowledge(writer, f"begin; set local role service_role;\n\\o /dev/null\n{first}\n\\o")
            waiter.stdin.write(f"begin; set local role service_role; {second}\ncommit;\n\\q\n")
            waiter.stdin.flush()
            db.wait_until_blocked()
            writer.stdin.write("commit;\n\\q\n")
            writer.stdin.flush()
            _, writer_error = writer.communicate(timeout=5)
            assert writer.returncode == 0, writer_error
            _, waiter_error = waiter.communicate(timeout=5)
            assert waiter.returncode != 0 and error_code in waiter_error, waiter_error
        finally:
            for client in (writer, waiter):
                if client.poll() is None:
                    client.kill()


def check_retirement(db):
    db.file(HERE / "retired-stripe-subscription-guard-test.sql")
    print("PASS exact service-role privilege, atomicity, legacy revalidation and email reuse")

    revision = seed_subscription(db, WRITER_ROW, WRITER_EMAIL, "sub_writer_initial")
    check_order(
        db,
        reconcile(WRITER_EMAIL, revision, "sub_writer_recent"),
        retirement(WRITER_FIRST, WRITER_ROW, WRITER_EMAIL, "sub_writer_initial"),
        "40001",
    )
    assert db.sql(f"""
      select data->>'stripe_subscription_id' from public.user_subscriptions
      where id = '{WRITER_ROW}';
    """) == "sub_writer_recent"
    assert db.sql("select count(*) from execute_deletion_private.retired_stripe_subscription;") == "0"
    print("PASS provider-first transaction retains new references and invalidates the old deletion snapshot")

    seed_subscription(db, DELETION_ROW, DELETION_EMAIL, "sub_delete_first")
    check_order(
        db,
        retirement(DELETION_FIRST, DELETION_ROW, DELETION_EMAIL, "sub_delete_first"),
        reconcile(DELETION_EMAIL, None, "sub_delete_first"),
        "23514",
    )
    assert db.sql(f"""
      select count(*) from public.user_subscriptions where data->>'user_id' = '{DELETION_EMAIL}';
    """) == "0"
    assert db.sql("select count(*) from execute_deletion_private.retired_stripe_subscription;") == "1"
    print("PASS deletion-first transaction durably rejects the queued retired provider reference")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-bin", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="w09-retire-") as tmp:
        with Fixture(Path(tmp), args.postgres_bin.resolve()) as db:
            db.file(HERE / "bootstrap.sql")
            for migration in sorted(MIGRATIONS.glob("*.sql")):
                db.file(migration)
            db.file(HERE / "retired-stripe-subscription-guard.sql")
            check_retirement(db)


if __name__ == "__main__":
    main()
