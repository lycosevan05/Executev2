# RevenueCat subscription reconciliation

The handler refreshes current customer state for both `transferred_from` and
`transferred_to` before acknowledging a transfer. Only email identities are
stored; RC anonymous IDs are not application users. Other supported subscription
events also refresh current state, so delayed pre-transfer events cannot replay
an obsolete grant or revoke a newer purchase. Only the exact entitlement
`Execute Performance Premium` grants RevenueCat access. Expiry, billing grace,
trials and lifetime grants use RevenueCat's observation time.

All participant rows commit through one PostgreSQL RPC. Every row must still have
the revision read before the provider requests. Concurrent changes, provider
errors or malformed snapshots abort the batch and return 503 for retry. Existing
Stripe IDs and unrelated metadata are preserved; rows with a Stripe subscription
are checked against Stripe before deciding effective access. A source with another
active RevenueCat purchase or an active/trialing Stripe subscription stays paid.

## Deployment gate

**Scoped rollout completed on 2026-10-21 (2026-10-22 UTC):** the additive migration
and only this function were deployed after approval. That rollout produced **v7**,
bundle SHA-256 `7ac44932bac5ff55ee6d0a493d0e90dd8fe9495b80560396e174e8ceabc69c61`,
`verify_jwt=false`. The V1 project secret was configured privately. Preflight found
5 subscription rows, zero duplicates and zero Stripe-linked rows; the new index,
service-role-only security-invoker RPC and retained RLS were verified. The migration
history records only this approved migration. No `db push` was used.

RevenueCat TEST `81273CE2-68B6-4606-9637-08D90EFBA4D7` returned 200/skipped TEST;
missing and invalid bearer credentials returned 401 Unauthorized. **The runtime provider lookup, database writeback and scoped physical A → B transfer acceptance passed.** The initial annual purchase passed on October 21. On October 31, native-dev Sandbox TRANSFER `AB8C4C09-0CAC-4F93-841A-079BDACBF0A6` reached this endpoint with HTTP 200/`{"received":true}`; read-only SQL verified exactly one row per account, A free/canceled and B premium/active. Repeating Restore as B preserved rows and ownership. Destination Premium/Nutrition access and source Premium/Nutrition gating were confirmed on the phone by the user; the source sign-in left backend ownership unchanged. No manual row writes, dashboard Transfer action or restore-policy change was used. Historical event replay, retained independent-purchase cases and the other sandbox cases remain open; local StoreKit Code=3 is independent and unresolved.
The attempted manual replay was never sent: successful deliveries have no Retry
control in RevenueCat's dashboard and the saved authentication value is masked.
Fresh annual INITIAL_PURCHASE `2B106B21-763C-430F-837A-36FB35EB7A60` returned HTTP 200; read-only SQL verified one premium/active A row with matching native-dev product, Sandbox environment, period and event ID. This verifies the deployed V1 lookup and atomic RPC/writeback path. No manual row write or historical replay was used.
`STRIPE_SECRET_KEY` is not configured; future Stripe-linked rows must fail/retry
until that credential is privately configured. Existing stale rows are not backfilled.

The existing shared endpoint receives both apps and both environments. Retain its
bearer secret, gateway setting, restore policy, Apple credentials and product mappings.
The following steps document rollout requirements and remaining acceptance:

1. Obtain approval for this migration and the `revenuecatWebhook` deployment.
2. In Supabase project `shoflbdwlmvttidoolvd`, privately configure
   `REVENUECAT_SECRET_API_KEY` with a REST API **v1** project secret key for RevenueCat
   project `7415d2f3`. A project key is used to reconcile purchases across the shared
   project's apps. Do not copy it into chat, mobile configuration, source or logs.
   `REVENUECAT_WEBHOOK_SECRET` remains the existing inbound authentication secret.
   Keep `SUPABASE_URL` and the existing `SERVICE_ROLE_KEY` /
   `SUPABASE_SERVICE_ROLE_KEY` configuration. `STRIPE_SECRET_KEY` is required when
   reconciling any existing row with `stripe_subscription_id`; a failed/missing
   Stripe lookup causes retry, never a guessed downgrade.
3. Preflight the unique email index and duplicate rows. Apply **only**
   `supabase/migrations/20261021000000_reconcile_revenuecat_subscriptions.sql`.
   Its index creation fails on duplicates and deletes no rows. Do not use an
   unreviewed `db push` that also applies unrelated pending migrations. The new
   RPC is service-role-only and security-invoker; table RLS is retained.
4. Deploy **only** `revenuecatWebhook`, retaining `verify_jwt=false`. Existing
   Stripe webhook code is unchanged; no legacy Stripe upsert RPC was installed by this rollout. Run the synthetic TEST,
   missing/invalid bearer checks and a known-customer provider read before a real
   transfer. TEST does not prove customer reconciliation or transfer correctness.
5. With two fresh disposable Execute accounts and a sandbox tester without
   original-app purchase history, buy native-dev Premium as A, then restore as B
   using the same sandbox Apple account. Verify A loses RevenueCat-derived backend
   access, B gains it, exactly one row exists per email, and both Profile/Nutrition
   gates refresh. Preserve legitimate independent purchases. Repeat delivery and
   verify no duplicate rows or reversed ownership. Do not test on the historical
   customer alias used for the earlier monthly/annual checks.
6. Monitor non-2xx deliveries. RevenueCat retries only for a finite window; failed
   deliveries may need manual redelivery after configuration/outage repair.
   Existing stale rows are not automatically backfilled: review/replay relevant
   transfer events after rollout and verify current provider state.

Rollback: redeploy the prior handler first; the additive RPC/index may remain
unused. Rolling back code does not undo already reconciled subscription rows.

## Validation

```sh
deno test --config supabase/functions/revenuecatWebhook/deno.json supabase/functions/revenuecatWebhook/reconcile_test.ts
deno lint --config supabase/functions/revenuecatWebhook/deno.json supabase/functions/revenuecatWebhook
deno check --config supabase/functions/revenuecatWebhook/deno.json supabase/functions/revenuecatWebhook/index.ts
```

`reconcile_test.sql` must run only in a local disposable PostgreSQL database after
the schema and migrations. It tests a complete transfer, metadata preservation,
all-or-nothing rollback on a destination conflict, insert races, retry idempotency,
anonymous-ID rejection and RPC privileges. Fixture writes roll back.

The six SQL scenarios were run with PGlite in an isolated temporary directory;
this checks PostgreSQL function/transaction behavior, not concurrent connections
to deployed Supabase. The handler suite now has 20 tests using provider fixtures, not live writes.
Neither test suite establishes sandbox transfer acceptance.

Scope limit: the existing Stripe webhook can still overwrite the shared effective
status when a later Stripe lifecycle event arrives. This change preserves Stripe
access during RevenueCat reconciliation; it does not redesign both payment
providers' long-term status projection. Review that separately for dual-purchase
accounts. No project-wide restore-policy change is included.

References: [RevenueCat webhooks](https://www.revenuecat.com/docs/integrations/webhooks),
[transfer fields](https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields),
[customer lookup](https://www.revenuecat.com/docs/api-v1/customers).

## Refund-reversal follow-up — 2026-11-01

**Deployed and verified as version 8 after explicit approval.** Previously
`REFUND_REVERSED` returned 200/skipped without refreshing customer state. It now
uses the same current RevenueCat snapshot, optional Stripe check and atomic RPC
as the existing events. It does not grant access from the event payload. Three
regressions cover current active access, a delayed reversal after expiry, and
provider failure returning 503 without writes. All 20 tests, lint, entrypoint type-check,
changed-file formatting and whitespace checks passed. The three new tests failed
against the prior source. These fixtures do not establish real Apple reversal
acceptance.

Preflight reconfirmed deployed v7 and its original bundle SHA above. Only
`revenuecatWebhook` was deployed from a reviewed four-file stage to project
`shoflbdwlmvttidoolvd`. At **2026-11-01 07:50 UTC / 12:50 a.m. Vancouver**, the
management API reported active **v8**, bundle SHA-256
`5c74136c9ab166cceea0c9763509b785fb62f7a74424c83ca745e5d81fc05c24`,
retaining `verify_jwt=false`. A fresh source download matched all four reviewed
file hashes. Compared with v7, index/config/shared CORS are identical and the only
runtime change is the added event type. Other functions' versions/hashes stayed
unchanged. No migration, credentials, provider configuration, restore policy,
backfill or native app deployment changed.

**Authentication and configured transport smoke passed.** Missing and invalid
bearer requests returned 401/Unauthorized on both the canonical function URL and
the exact existing URL saved in RevenueCat. RevenueCat's configured synthetic
TEST `6F475DD8-ED66-4EE7-9302-F995BE75EB9D` at **07:51:09 UTC** returned 200,
`{"received":true,"skipped":"TEST"}`. The saved bearer value was not read or changed.
TEST skips customer/provider/database reconciliation; it proves configured
transport/authentication, not the new refund-reversal route or a real refund.
The new route has source verification and regression coverage; supported Sandbox
refund/reversal with provider, actual event, backend and device evidence remains
open. Previously skipped events were not replayed and no subscription row was
manually edited.

The downloaded v7 source remains in the private rollback folder recorded in the
setup workspace rollout manifest. Roll back only this function while retaining
its gateway setting. Rollback does not undo reconciliations already performed.
