# W09 production rollout

## Recorded baseline

E71 installed the three upload preparation SQL files on Executev2 and deployed
JWT-verified `guardedStorageUpload` revision 1. A signed synthetic fixture
wrote, read and removed both a direct Storage upload and a canonical upload.
Independent readback found zero fixture objects, pending dispatches and closed
admissions. The direct-writer cutover was absent, and legacy deletion v6 was
active. E70 rehearsed Stripe-linked deletion and Apple revocation in isolated
environments. See the [upload preparation record](../supabase/tests/account-deletion/README.md#canonical-upload-route-and-writer-cutover)
and [staged deletion runbook](../supabase/functions/deleteUserData-staged/README.md).

## Verify the deployed writers

Start with a read-only inventory from the release owner. For each supported
client, record its environment, serving host or distribution channel, app
version, build or deployment revision, reachable upload actions, and observed
Storage route. Mark artifacts that lack a deployment record as local evidence.

| Writer | Evidence and next check |
| --- | --- |
| Browser | The E72 local production build routes food photo and barcode uploads through `guardedStorageUpload`. The retained Developer Vite bundle calls the direct Storage SDK. The owner recalls browser prototypes and has no confirmed live origin. GitHub returned an empty deployments list and no accessible Pages record. If a deployment is found, identify its owner, hosting configuration and client activity before replacing or retiring it. Compare the served `UploadFile` implementation and exercise the candidate's photo and barcode actions with a synthetic account in the isolated environment. The `executelabs.ca` legal and support site is a separate repository. |
| Capacitor | The retained Developer app resource bundle calls the direct Storage SDK. Installed Capacitor apps receive their packaged web assets with a new app build. Inspect the history of the original Execute app in App Store Connect and TestFlight, and trace each still-supported build to its packaged bundle or an approved synthetic-device test. |
| Native Swift | The E71 Native Dev candidate configures the guarded Storage service. Keep its exact signed bundle and release backend paired in acceptance. Check whether any other build or feature uses Storage separately. |
| Managed Storage | On the exact hosted project, inventory direct upload requests, signed-upload issuance and redemption, resumable sessions and in-flight writes. Use read-only Storage settings and route-level aggregate logs where available. Record the coverage interval, then establish provider-backed expiry or explicit retirement of older capabilities and sessions. An empty canonical ledger covers only requests registered by the canonical path. |
| Privileged writers | Inventory job, Edge Function, integration and S3 writer owners against the actual project. Verify which uses of service or S3 access can write the `uploads` bucket. Move relevant writers onto coordinated admission or explicitly retire them. Record status and scope without exporting key values. |

E72 checked the original Execute Performance record in App Store Connect. Its
iOS 1.0 version is in Prepare for Submission. The separate TestFlight list
showed original bundle `com.executelabs.execute`, build 17, in internal
Testing. Apple recorded upload on August 28, before the canonical writer was
added to this migration. Builds 16 and 18 remained Ready to Submit. Keep
direct writes open for supported legacy clients until the team verifies their
replacement or retirement.

The 24-hour Executev2 API gateway count included both known E71 Storage
write fixtures. It returned zero other writes matching the direct uploads,
signed, resumable or S3 route prefixes. The sample establishes recent
observations only. It does not identify every deployed client, prove
capability expiry or cover unlogged privileged requests. The Edge Function
inventory showed only the guarded upload, legacy deletion, RevenueCat webhook
and AI invocation. The web Stripe functions in source were absent from this
project's deployed list.

The next deployable phase is the guarded browser and Capacitor client builds
while direct writes remain available. Rebuild and exercise both against an
isolated hosted project first, including upload error handling and owner
switching. Obtain separate release approval for the confirmed client channels.
Retain E71 preparation until supported old writers have migrated or have an
approved retirement plan, and the last admitted write is accounted for.

## Billing-linked owners

The E72 read-only subscription inventory found eight RevenueCat-linked stored
rows and zero Stripe-linked rows. All eight reported email customer IDs
and lacked a stored Auth UUID owner. Each email currently matches one Auth
record. That match alone gives no evidence of historic ownership or provider
authorization. [Aggregate inventory SQL](../supabase/tests/account-deletion/revenuecat-owner-inventory.sql)

A stored row is historical projection data and cannot establish active
subscription status. Keep RevenueCat projection rows out of the staged
Stripe-only rehearsal.

Native Premium currently combines server state with the RevenueCat SDK and
uses the owner's email as the RevenueCat customer ID. Before broad deletion,
prove that delayed renewal and transfer events cannot recreate the retired
owner and that a new Auth UUID reusing the email cannot inherit the old
customer's purchases implicitly. Preserve legitimate transfers to verified
active recipients. Require a verified owner-bound identity or explicit
reassociation and rehearse the active App Store, late webhook, same-email
registration, and unrelated subscriber cases in Sandbox. A RevenueCat customer
deletion cannot cancel a StoreKit subscription.
Follow the [subscriber deletion and UUID migration runbook](w09-revenuecat-subscriber-deletion.md)
for the rehearsal and rollout gates.

The native confirmation explains that Apple billing continues until canceled
and links directly to Apple's subscription management. The link is available
independently of the in-app account deletion confirmation.
[Apple account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion)

## Sign in with Apple

An Apple-linked owner with an authenticated Execute session and no usable
Apple credential can complete account deletion and receive manual Apple
revocation instructions. Detect that case from the verified Auth identity and
a healthy credential lookup. Retain the generic instructions locally through
relaunch until dismissed, with no account identifier. Provider errors and
unreadable custody records cannot serve as revocation evidence.
[Apple token revocation guidance](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)

Keep automatic custody gated until a signed hosted callback proves that the
refresh grant arrives, and an Apple-only owner can resume partial deletion
after their Execute session expires. Reconcile a newly issued grant through
that retry and verify which provider authorization the receipt covers.

## Cutover and recovery

1. Capture the production preparation catalog and exact endpoint revisions.
   Rehearse the fourth upload SQL file on an isolated clone. Verify successful
   canonical writes and ordinary reads, rejection of direct writes, and absence
   of orphaned test bytes. Include a synthetic witness account. Obtain separate
   production cutover approval after the writer inventory and drain are verified.
2. Keep production deletion behind its gate until entity ownership, checkout
   drain, billing identity and Apple grant handling are verified together.
   Include the existing v6 route in compatibility and retirement planning. Old
   web and Capacitor clients still call that route, and replacing it requires a
   separately verified recovery plan. The captured v6 source and provider
   digest establish the legacy baseline. Keep v6 in place while rehearsing the
   new endpoint. Test deletion only with an approved disposable account and
   independent readback.
3. To restore E71 upload preparation, disable deletion, independently confirm
   the route is unavailable and admitted work is terminal, and reconcile
   dispatches. Apply [`reverse-storage-upload-writer-cutover.sql`](../supabase/tests/account-deletion/reverse-storage-upload-writer-cutover.sql)
   against the exact catalog. It removes only the cutover RPC and two restrictive
   direct-writer policies. Verify that both write paths work and compare the
   restored catalog to the preparation snapshot. Review any surviving billing
   or deletion state separately. This reversal changes write admission and
   preserves the canonical route.

The E72 isolated PostgreSQL rehearsal restored the preparation catalog and
confirmed both write paths at the SQL boundary. The cutover rollback refused a
changed policy, a pending dispatch, and an active upload closure. The fixture
uses synthetic Auth and Storage schemas. Hosted Storage byte and endpoint
verification remain part of the next isolated rollout rehearsal.

## Restore the E71 catalog after a deletion rollout

Capture the E71 preparation catalog and endpoint revisions before changes.
Withdraw the new deletion, Checkout and Apple-grant capture routes and wait for
admitted work to reach verified outcomes. Preserve any active billing or Apple
records for reconciliation. If enabled, reverse
[Stripe Checkout admission](../supabase/tests/account-deletion/reverse-stripe-checkout-admission.sql),
[Apple grant custody](../supabase/tests/account-deletion/reverse-apple-grant-custody.sql)
and the [billing projection fence](../supabase/tests/account-deletion/reverse-billing-projection-fence.sql).
Reverse the writer cutover and confirm the direct and canonical upload paths
are available. Schedule a brief window without new canonical dispatches for the
remaining schema reversal.

Apply the [scoped deletion guard reversal](../supabase/tests/account-deletion/reverse-deletion-guards-to-upload-preparation.sql)
when Stripe retirement markers, upload closures and pending upload dispatches
have been reconciled. It removes the four entity and Stripe retirement guards
while retaining the three E71 upload preparation files. A nonempty ledger or
unexpected database dependency stops the transaction. Keep closed identities
and retirement markers in place if a provider event can still recreate a
retired projection. Obtain an approved reconciliation plan in that case.

Compare the resulting catalog and endpoint revisions to the captured baseline.
Verify both upload routes and ordinary entity and billing writes with approved
synthetic fixtures. The [local rollback fixture](../supabase/tests/account-deletion/test_staged_schema_reversal.py)
compares the schema before and after both supported reversal sequences. Any
prior data changes require their own recovery assessment.
