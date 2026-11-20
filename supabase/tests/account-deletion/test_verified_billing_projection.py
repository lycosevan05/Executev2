"""Verify the opted-in billing readers, writers and rollback on local PostgreSQL."""

import argparse
import json
import tempfile
from pathlib import Path

from test_owned_entity_auth_guard import DELETION_FIRST, Fixture, HERE, MIGRATIONS, UNRELATED, WRITER_FIRST
from test_revenuecat_identity_ledger import PROJECT, attach, close, ensure, expect_failure, overlap, request, retire

ENVIRONMENT = "SANDBOX"
INSTALL = HERE / "verified-revenuecat-billing.sql"
REVERSE = HERE / "reverse-verified-revenuecat-billing.sql"
EMAILS = {
    WRITER_FIRST: "writer-first@example.invalid",
    DELETION_FIRST: "deletion-first@example.invalid",
    UNRELATED: "unrelated@example.invalid",
}


def activate(owner, environment=ENVIRONMENT):
    return f"public.activate_verified_billing_owner('{PROJECT}', '{owner}', '{environment}')"


def subject(db, *, owner=None, identifier=None):
    if owner is not None:
        target = f"p_owner_id => '{owner}'"
    else:
        target = f"p_identifier => '{identifier}'"
    return json.loads(request(db, f"public.read_verified_billing_subject('{PROJECT}', {target})"))


def change(owner, customer, revision=None, *, plan="premium", **extra):
    return {
        "owner_id": owner,
        "customer_id": customer,
        "expected_email": EMAILS[owner],
        "expected_updated_date": revision,
        "data": {"plan": plan, "status": "active", "store": "app_store", **extra},
    }


def apply(changes, environment=ENVIRONMENT):
    data = json.dumps(changes).replace("'", "''")
    return f"public.apply_verified_billing_projections('{PROJECT}', '{environment}', '{data}'::jsonb)"


def test_verified_billing(db):
    db.file(HERE / "bootstrap.sql")
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        db.file(migration)
    db.file(HERE / "billing-projection-fence.sql")
    db.file(HERE / "revenuecat-identity-ledger.sql")
    catalog = (HERE / "staged-guard-schema.sql").read_text()
    baseline = db.sql(catalog)
    db.file(INSTALL)
    db.file(REVERSE)
    assert db.sql(catalog) == baseline
    db.file(INSTALL)

    first = request(db, ensure(WRITER_FIRST))
    second = request(db, ensure(DELETION_FIRST))
    old = request(db, ensure(UNRELATED))
    assert subject(db, owner=WRITER_FIRST) == {"state": "blocked"}
    assert subject(db, identifier="untrusted-email@example.invalid") == {"state": "unresolved"}
    expect_failure(lambda: db.sql(f"set role authenticated; select {activate(WRITER_FIRST)}"), "42501")
    expect_failure(lambda: db.sql(f"set role authenticated; select public.read_verified_billing_subject('{PROJECT}', '{first}')"), "42501")
    expect_failure(lambda: db.sql(f"set role authenticated; select {apply([change(WRITER_FIRST, first)])}"), "42501")

    legacy = "insert into public.user_subscriptions (owner_email, data) values " \
        "('unrelated@example.invalid', '{\"user_id\":\"unrelated@example.invalid\",\"plan\":\"premium\"}')"
    db.sql("set role service_role; " + legacy)
    expect_failure(lambda: request(db, activate(UNRELATED)), "23514")
    assert subject(db, identifier=old) == {"state": "blocked"}
    assert request(db, activate(WRITER_FIRST)) == "t"
    assert request(db, activate(DELETION_FIRST)) == "t"
    expect_failure(lambda: request(db, activate(WRITER_FIRST, "PRODUCTION")), "23514")
    expect_failure(lambda: db.file(REVERSE), "55000")
    request(db, attach(WRITER_FIRST, "verified-old-alias"))
    assert subject(db, identifier="verified-old-alias") == {
        "state": "active", "owner_id": WRITER_FIRST, "customer_id": first,
        "environment": ENVIRONMENT, "email": EMAILS[WRITER_FIRST], "subscription": None,
    }
    print("PASS gated activation, service-only lookup, occupied rollback refusal, and untouched legacy reads")

    initial = change(WRITER_FIRST, first, revenuecat_app_user_id=first, owner_email="untrusted@example.invalid")
    expect_failure(lambda: request(db, apply([initial], "PRODUCTION")), "40001")
    expect_failure(lambda: request(db, apply([change(WRITER_FIRST, first, revenuecat_environment="PRODUCTION")])), "23514")
    expect_failure(lambda: request(db, apply([change(WRITER_FIRST, second)])), "40001")
    wrong_email = {**initial, "expected_email": EMAILS[UNRELATED]}
    expect_failure(lambda: request(db, apply([wrong_email])), "40001")
    assert request(db, apply([initial])) == "1"
    observed = subject(db, owner=WRITER_FIRST)["subscription"]
    assert observed["data"] == {
        "plan": "premium", "status": "active", "store": "app_store", "user_id": WRITER_FIRST,
        "verified_billing_project": PROJECT, "verified_billing_environment": ENVIRONMENT,
    }
    expect_failure(lambda: db.sql("set role service_role; " + legacy.replace("unrelated", "writer-first")), "23514")

    authenticated = f"""set request.jwt.claims = '{{"sub":"{WRITER_FIRST}","role":"authenticated"}}'; set role authenticated; """
    assert db.sql(authenticated + f"select count(*) from public.user_subscriptions where owner_id='{WRITER_FIRST}'") == "1"
    db.sql(authenticated + f"update public.user_subscriptions set data=data || '{{\"plan\":\"free\"}}' where owner_id='{WRITER_FIRST}';")
    db.sql(authenticated + f"delete from public.user_subscriptions where owner_id='{WRITER_FIRST}';")
    assert subject(db, owner=WRITER_FIRST)["subscription"] == observed
    print("PASS scoped UUID write, provider and environment matching, and authenticated write protection")

    paired = [change(WRITER_FIRST, first, observed["updated_date"], plan="free"), change(DELETION_FIRST, second)]
    expect_failure(lambda: request(db, apply([paired[0], {**paired[1], "customer_id": first}])), "40001")
    assert subject(db, owner=WRITER_FIRST)["subscription"] == observed
    assert subject(db, owner=DELETION_FIRST)["subscription"] is None
    assert request(db, apply(paired)) == "2"
    expect_failure(lambda: request(db, apply(paired)), "40001")
    assert subject(db, owner=WRITER_FIRST)["subscription"]["data"]["plan"] == "free"
    assert subject(db, owner=DELETION_FIRST)["subscription"]["data"]["plan"] == "premium"
    print("PASS atomic multi-owner projections and stale revision refusal")


    due_file = HERE / "sandbox-expiry-reconciliation.sql"
    db.file(due_file)
    inventory = f"public.list_due_verified_sandbox_app_store_owners('{PROJECT}')"
    expect_failure(lambda: db.sql("set role authenticated; select " + inventory), "42501")
    assert db.sql("select count(*) from " + inventory) == "0"
    current = subject(db, owner=DELETION_FIRST)["subscription"]
    preserved_stripe = change(
        DELETION_FIRST, second, current["updated_date"], store="stripe",
        revenuecat_environment="SANDBOX", revenuecat_plan="premium",
        revenuecat_current_period_end="2001-01-01T00:00:00Z",
        current_period_end="2099-01-01T00:00:00Z",
    )
    assert request(db, apply([preserved_stripe])) == "1"
    assert db.sql("select value->>'owner_id' from " + inventory + " as due(value)") == DELETION_FIRST
    current = subject(db, owner=DELETION_FIRST)["subscription"]
    refreshed = change(
        DELETION_FIRST, second, current["updated_date"], revenuecat_environment=None,
        revenuecat_plan=None, revenuecat_current_period_end=None,
    )
    assert request(db, apply([refreshed])) == "1"
    assert db.sql("select count(*) from " + inventory) == "0"
    db.sql("drop function public.list_due_verified_sandbox_app_store_owners(text)")
    print("PASS service-only due-owner inventory uses the App Store deadline for mixed billing")
    # A provider read can finish before closure, while its transaction starts
    # afterwards. Closure uses the exact UUID-backed row as its snapshot.
    snapshot = db.sql(f"""select jsonb_build_array(jsonb_build_object(
      'id', s.id, 'owner_id', s.owner_id, 'owner_email', s.owner_email,
      'created_by', s.created_by, 'user_email', s.user_email, 'data', s.data
    )) from public.user_subscriptions s where s.owner_id='{WRITER_FIRST}'""").replace("'", "''")
    fenced = close(WRITER_FIRST, EMAILS[WRITER_FIRST]).replace("'[]'", f"'{snapshot}'")
    current = subject(db, owner=WRITER_FIRST)["subscription"]
    overlap(db, fenced, apply([change(WRITER_FIRST, first, current["updated_date"])]), "40001")
    assert subject(db, identifier=first) == {"state": "blocked"}
    assert request(db, retire(WRITER_FIRST)) == "t"
    assert subject(db, identifier=first) == {"state": "retired"}
    assert subject(db, owner=WRITER_FIRST) == {"state": "retired"}
    assert subject(db, owner=DELETION_FIRST)["subscription"]["data"]["plan"] == "premium"
    print("PASS deletion fence invalidates an in-flight write and retains unrelated access")

    def app_store_deletion(snapshot, *, close_fence=False, project=PROJECT):
        snapshot_sql = json.dumps(snapshot).replace("'", "''")
        return (
            f"public.check_staged_app_store_account_deletion('{project}', '{DELETION_FIRST}', "
            f"'{EMAILS[DELETION_FIRST]}', '{snapshot_sql}'::jsonb, {str(close_fence).lower()})"
        )

    def app_store_rows():
        return json.loads(db.sql(f"""select jsonb_agg(jsonb_build_object(
          'id', s.id, 'owner_id', s.owner_id, 'owner_email', s.owner_email,
          'created_by', s.created_by, 'user_email', s.user_email, 'data', s.data
        )) from public.user_subscriptions s where s.owner_id='{DELETION_FIRST}'"""))

    snapshot = app_store_rows()
    assert request(db, app_store_deletion(snapshot)) == "f"
    current = subject(db, owner=DELETION_FIRST)["subscription"]
    mixed = change(DELETION_FIRST, second, current["updated_date"],
                   revenuecat_environment="SANDBOX", stripe_customer_id="cus_fixture")
    assert request(db, apply([mixed])) == "1"
    assert request(db, app_store_deletion(app_store_rows(), close_fence=True)) == "f"
    current = subject(db, owner=DELETION_FIRST)["subscription"]
    clean = change(DELETION_FIRST, second, current["updated_date"],
                   revenuecat_environment="SANDBOX", stripe_customer_id=None)
    assert request(db, apply([clean])) == "1"
    snapshot = app_store_rows()
    assert request(db, app_store_deletion(snapshot, project="wrong-project")) == "f"
    expect_failure(lambda: db.sql("set role authenticated; select " + app_store_deletion(snapshot)), "42501")
    assert request(db, app_store_deletion(snapshot)) == "t"
    assert subject(db, identifier=second)["state"] == "active"
    expect_failure(
        lambda: request(db, app_store_deletion([{**snapshot[0], "id": UNRELATED}], close_fence=True)),
        "40001",
    )
    assert subject(db, identifier=second)["state"] == "active"
    current = subject(db, owner=DELETION_FIRST)["subscription"]
    overlap(db, app_store_deletion(snapshot, close_fence=True),
            apply([change(DELETION_FIRST, second, current["updated_date"])]), "40001")
    assert subject(db, identifier=second) == {"state": "retired"}
    assert request(db, app_store_deletion(snapshot, close_fence=True)) == "t"
    db.sql(f"delete from public.user_subscriptions where owner_id='{DELETION_FIRST}'")
    assert request(db, app_store_deletion([], close_fence=True)) == "t"
    expect_failure(lambda: request(db, apply([clean])), "40001")
    print("PASS exact App Store Sandbox admission, atomic retirement, stale writer refusal and partial retry")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="w09-bound-billing-", dir="/tmp") as temporary:
        with Fixture(Path(temporary), args.pg_bin) as isolated:
            test_verified_billing(isolated)
