# W09 RevenueCat subscriber deletion and UUID migration

The [production rollout](w09-production-rollout.md#billing-linked-owners) keeps
staged billing-linked deletion Stripe-only. Use this runbook to qualify App Store subscribers
with a separately approved Sandbox rehearsal. Keep Executev2, the original
app, existing customers and production restore settings out of the rehearsal.

## 1. Inventory the exact environment and identities

- Pair an isolated Supabase project and signed Native Dev build with the exact
  RevenueCat project, Apple app and Sandbox webhook. Use a dedicated Apple
  Sandbox tester and disposable Execute owners. Verify bundle, product,
  entitlement, webhook revisions and environment with read-only checks before
  purchase. Use read-only credentials for inventory. Record the project-wide restore behavior and any Sandbox override.
  [Signed device procedure](native-billing-acceptance.md#test-boundaries)
  · [Restore settings](https://www.revenuecat.com/docs/projects/restore-behavior)
- Inventory `user_subscriptions` by Auth UUID and every legacy identity field,
  including row ownership, JSON email fields, RevenueCat IDs and Stripe IDs.
  Inspect both [RevenueCat](../supabase/functions/revenuecatWebhook/index.ts)
  and [Stripe](../supabase/functions/stripeWebhook/index.ts) webhook writers,
  their [shared reconciliation RPC](../supabase/migrations/20261021000000_reconcile_revenuecat_subscriptions.sql),
  and any deployed legacy `upsert_user_subscription` caller. Include
  [Checkout](../supabase/functions/stripeCreateCheckout/index.ts) and
  [portal](../supabase/functions/stripeCreatePortal/index.ts), which use billing
  links, and the [native](../ios-native/ExecuteNative/Core/RevenueCat/BillingStore.swift)
  and [web](../src/lib/subscription.js) Premium readers, including live SDK
  state, cache and legacy Capacitor sign-in.
- For each disposable owner, read the exact case-sensitive candidate ID from
  RevenueCat v2 and paginate aliases, subscriptions, purchases and active
  entitlements. Match app, store, environment and store transaction lineage.
  Inspect Sandbox and Production data in the same customer because customer
  IDs are project-wide. A merged projection or its effective `store` field
  can hide a second billing provider. Put partial inventories, unexpected
  purchases, shared aliases and conflicting owners on hold. Use v2 for absence
  checks. The v1 customer GET can create a customer and return HTTP 201.
  [v2 customers and aliases](https://www.revenuecat.com/docs/api-v2/customer)
  · [v2 customer resources](https://www.revenuecat.com/docs/api-v2/customer/resources)
  · [v1 customer lookup](https://www.revenuecat.com/docs/api-v1/customers)

## 2. Stage UUID ownership before changing client identity

1. Add a service-owned mapping from the immutable Auth UUID to a single
   canonical RevenueCat ID in the exact project. Generate an opaque UUID for
   new customers. Keep a separate, verified binding for each existing email or
   alias and a durable retirement marker that survives Auth deletion. Check
   case-sensitive provider IDs and email normalization for collisions. Require
   durable owner evidence such as historical UUID binding and verified
   purchase history. Current control of an email or an email-only legacy row
   does not prove ownership of past purchases. Hold ambiguous groups for
   support resolution.
2. Ship dual-ID resolution with the existing client identity unchanged first.
   Resolve webhook aliases and both sides of `TRANSFER` to active, retired,
   or unresolved owners. Recheck that decision under the billing fence in the
   same RPC that commits the live owners' revisions. Fetch fresh provider
   state for verified live participants. An explicitly retired participant
   can be skipped without blocking a verified live recipient. A conflicting
   or unresolved entitlement holder must not grant access or acknowledge
   partial work. An anonymous alias can be covered by its verified customer
   group. Retired-only events can be acknowledged after the durable marker is
   confirmed. Route both provider writers through the same checks, including
   legacy entry points, and skip provider lookups of known retired IDs.
   [Webhook event fields](https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields)
3. Switch the first-purchase cohort to UUID-backed billing after both webhooks
   and the server reader accept UUIDs. Bind native and Capacitor SDK
   configuration, listeners, restores and cache to the verified active owner.
   Roll old clients forward or retire their billing path before changing
   existing subscribers. Verify server RLS, Stripe references and the
   server/live Premium merge during account switching and offline relaunch.
4. Migrate one verified existing subscriber before widening the cohort.
   Changing custom IDs with SDK `logIn` neither merges nor transfers those
   customers. Keep the proven legacy binding until its migration is confirmed
   from both endpoints. RevenueCat v2 transfer moves subscriptions and
   one-time purchases and filters by app IDs, with no environment filter in
   the request schema. For this isolated case only, evaluate it after both
   profiles and all matching assets have been verified, with explicit
   approval for the exact app and a disposable source and target. Capture
   before and after inventories and confirm a single entitlement holder.
   Treat an uncertain result as pending and reconcile both endpoints before
   retrying. Keep existing subscribers on their verified binding if the move
   or its recovery cannot be scoped.
   [SDK identification](https://www.revenuecat.com/docs/customers/identifying-customers)
   · [v2 transfer contract](https://www.revenuecat.com/docs/api-v2/customer)

### Optional identity ledger foundation

The isolated [ledger SQL](../supabase/tests/account-deletion/revenuecat-identity-ledger.sql)
requires the existing billing projection fence. Service code can register a new
opaque RevenueCat UUID for one Auth UUID, attach an alias after independent
ownership verification, look up the binding, and retire it after the fence
closes. The exact canonical ID and all aliases share one case-sensitive
namespace per RevenueCat project. Retirement keeps salted fingerprints and
removes the stored raw UUIDs. Auth removal preserves the fingerprints.

A lookup is a snapshot. The future projection writer must recheck ownership
under the admission locks in the same database transaction as the write.
Install this foundation before connecting providers, changing client
identities or enabling linked deletion. Historical email identities still
require independent ownership verification before enrollment.

Run the local fixture over its private Unix socket.

```sh
python3 supabase/tests/account-deletion/test_revenuecat_identity_ledger.py --pg-bin /path/to/postgres/bin
```

Withdraw all ledger consumers first. The [empty-ledger reversal](../supabase/tests/account-deletion/reverse-revenuecat-identity-ledger.sql)
refuses to remove active or retired bindings. Reverse the empty ledger before
attempting to reverse the billing fence.

## 3. Rehearse deletion with a signed Sandbox build

1. Capture an unrelated active subscriber as a witness. Verify a clean UUID
   first purchase and one existing email-backed subscriber migrated to a
   UUID. Check the signed app, RevenueCat v2 and the exact server row for
   each. Before deleting the target, verify the Apple billing warning, direct
   Manage Apple Subscription link and immediate deletion option.
   [Apple account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion)
2. Use the approved staged route for one disposable App Store-only owner.
   Verify the expected Apple app, product, Sandbox subscription and exact
   owner, with no linked Stripe or other store assets. Confirm the projection
   fence closes admission before destructive work. Independently read back the
   deletion receipt, Auth denial, missing rows and objects, cleared device
   data and durable billing markers. Keep Apple auto-renewal and the
   RevenueCat customer intact during this verification. Observe the next
   renewal or confirmed current StoreKit subscription plus corresponding
   RevenueCat Sandbox transaction. A subscription's natural expiry is not
   evidence of cancellation. Customer deletion in RevenueCat does not cancel
   Apple and can affect other stores or environments.
   [RevenueCat customer deletion behavior](https://www.revenuecat.com/docs/dashboard-and-metrics/customer-profile)
3. In fixtures, pause a reconciliation between provider read and database
   commit while deletion closes the owner. Deliver duplicate and out-of-order
   renewal, retry, expiration and transfer events. On the hosted Sandbox,
   record an actual post-deletion event and a verified transfer with a retired
   side and a live recipient. The retired side must remain absent, the live
   side must reflect current provider state, and the witness must stay
   unchanged. Compare independent database readback with provider state and
   webhook delivery status. Record a fixture-only result if a live event has
   not arrived.
4. Re-register the disposable email under a new Auth UUID. Verify free access
   in the SDK, server and UI on clean install and account switch, with no
   automatic legacy login, restore or alias binding. Exercise a deliberate
   restore under the configured policy separately and confirm the authorized
   owner receives it only after verified reassociation. Repeat the ordinary
   first-purchase and existing-subscriber read checks before widening.

## 4. Stop, recover and approve expansion

Pause the affected cohort on ambiguous ownership, a lost or duplicate grant,
a late event that recreates a row, or a changed witness. Disable staged
deletion and new UUID migrations, drain and reconcile in-flight events, and
restore the last verified client and webhook revisions only where they preserve
the verified bindings. Keep retirement markers and compatible dual-ID readers
for moved owners. Switching an SDK ID back does not undo a provider transfer.
Any scoped reverse transfer requires fresh ownership and asset checks and
separate approval. Deleted Auth users and app records require a separate
recovery assessment. [Production recovery sequence](w09-production-rollout.md#cutover-and-recovery)

Record the build, project and function revisions, fixture labels, transaction
and event references in private evidence, outcome matrix, and rollback state.
Before a production expansion, confirm any RevenueCat records that remain
associated with deleted owners have an approved retention or erasure
disposition. Keep the rehearsal and production gates separate.
