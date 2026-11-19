# Stripe Checkout admission before account deletion

The optional Checkout guard closes an Auth UUID's ability to start new
checkout before the staged deletion finishes. The database records one
exact dispatch before calling Stripe and requires the matching Stripe
session receipt before the writer returns its URL. A closure that wins
while Stripe is responding preserves the receipt for cleanup and withholds
the URL. Unacknowledged dispatches remain pending across timeouts and
request retries. A later successful request cannot retire an earlier dispatch.

Checkout and its resulting subscription carry the verified Auth UUID,
account email, and a server-generated dispatch UUID. The guarded writer
verifies the immutable owner of any reused Stripe customer. It also requires
a configured app base URL. Request-supplied origins remain available only in
the existing unguarded configuration. A same-email replacement account is
held while the earlier billing projection identity remains fenced.

The staged deletion checks each exact known Stripe session before attempting
any expiration. Stripe can expire an open session. An already expired session
must have no subscription and must lack enabled recovery. If expiry fails
after the customer completes Checkout, the candidate reads the exact session
again. A complete session contributes a subscription only when Stripe reports
it paid or requiring no payment and returns its exact subscription ID.
Unsettled, invalid, unacknowledged, or independently recoverable sessions
keep account deletion pending. [Stripe Checkout Session lifecycle](https://docs.stripe.com/api/checkout/sessions/object)

A subscription discovered from Stripe may precede its local webhook row. The
staged process requires a fresh provider ownership check for that subscription.
The exact preflight projection snapshot must still be valid when fenced.
Cancellation runs against the combined account inventory after the fence
closes. Once the provider and data steps succeed, an exact ledger acknowledgement
allows hard Auth removal. Admission remains closed across a retry after a lost
Auth removal response. A checkout record's restrictive Auth foreign key
protects the record until this acknowledgement.
[Stripe session expiry API](https://docs.stripe.com/api/checkout/sessions/expire)

## Isolated rollout prerequisites

1. Use an explicitly approved disposable project and Stripe Sandbox fixture.
   Inventory every route that can create Checkout Sessions or subscriptions,
   including legacy deployments, Payment Links, Billing Portal changes, and
   provider-side access. Identify and drain all pre-existing provider sessions
   and in-flight requests before relying on the new ledger. This guard tracks
   only checkout through its writer and covers the staged Stripe-only route.
2. Install the E69 billing projection fence before
   `stripe-checkout-admission.sql`. Deploy the updated checkout writer and
   separately allowlisted deletion rehearsal with the existing staged billing,
   retirement and upload settings. Enable `EXECUTE_STRIPE_CHECKOUT_GUARD=1`
   for the writer and staged deletion together. Verify which deployment handles
   each prior checkout request. Keep the legacy destructive endpoint outside
   this exercise.
3. Before a broader rollout, exercise exact provider expiration, a completion
   race with a delayed projection, timeout recovery, separate billing
   providers and unrelated owners. Verify the account's email and customer
   binding against Stripe. Email or provider changes require independently
   verified reassociation. The ledger currently fails closed at 100 retained
   dispatches per owner. Reconcile archive and history retention before broader
   activation.
4. For an unknown dispatch, verify the Stripe response and its exact
   owner/dispatch metadata independently before acknowledging its session in
   the ledger. A missing event, a timed-out request, or an expired idempotency
   key is insufficient evidence to drop a dispatch. The candidate contains no
   automatic recovery that replays an old Stripe creation.
   [Stripe idempotency semantics](https://docs.stripe.com/api/idempotent_requests)
5. Close the test with the deletion and guarded writer withdrawn and every
   checkout dispatch reconciled. `reverse-stripe-checkout-admission.sql` refuses
   reversal while any checkout dispatch or closure remains. Apply it before
   reversing the billing projection fence. Reopen checkout only after the
   coordinated rollback is verified.

## Local verification

`stripe-checkout-admission-test.sql` checks narrowly scoped grants, the
close/acknowledgement sequence, exact inventory completion, hard Auth removal,
the same-email fence, and unrelated admission. Run it in the disposable
PostgreSQL fixture after `bootstrap.sql`, all baseline migrations, the
retirement guard, the billing projection fence, and checkout admission.
E72 passed against PostgreSQL 16, including two real overlapping transaction
orders and a clean rollback with a matching pre-install schema dump. Rollback
with an unresolved dispatch returned an error and preserved the candidate
schema. The combined Deno tests cover provider response handling with fakes.
No live Stripe API, deployed writer or production delete is covered by these
tests.
