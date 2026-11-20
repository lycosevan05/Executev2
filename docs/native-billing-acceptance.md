# Native billing acceptance

Current scope/status is authoritative in [the native completion checklist](native-parity-audit.md), W11–W15/G06. This file retains dated billing evidence and case procedures for `com.executelabs.execute.native-dev`; older blocker statements are historical. Local StoreKit Code3 was resolved by the four-case November9 pass below. Physical alternate-device provisioning is a separate current G02 gate; do not restart the closed Code3 investigation.
The dated evidence in [the parity audit](native-parity-audit.md) remains the record
of completed physical tests. A fixture pass does not establish a sandbox pass.

## Test boundaries

- Use the standalone `ios-native/ExecuteNative.xcodeproj`, ordinary `ExecuteNative`
  scheme, StoreKit Configuration **None**, and no mock/preview launch arguments.
- Use normal Xcode signing for live sign-in. A `CODE_SIGNING_ALLOWED=NO` fixture artifact can run local tests while lacking Keychain access; it must not be reused for live authenticated acceptance.
- Preserve the original Execute app, existing tester purchase history, RevenueCat
  restore policy and provider mappings. Do not clear purchase history to simulate
  a clean customer or write subscription rows to manufacture an outcome.
- Record Execute identity, sandbox tester label, native product, before/after
  entitlement, backend row count/state, event ID and delivery status privately.
  Published evidence uses account labels rather than email addresses.
- Authentication, new passwords and Apple authorization are handled by the user.
  Stop any transaction that is not explicitly identified as Sandbox/testing.

## Isolated Stripe and RevenueCat acceptance

E60 verified the Stripe destination and previously successful deliveries. E61
passed the Stripe-only trial and cancellation against the matching backend row
and authenticated native state. Use only the Star Learning Stripe sandbox
(`acct_1TAfBREiWRJocTMe`), Execute Billing Integration Supabase
(`zpnvnsdtbtdyhvipctpa`) and the isolated RevenueCat project (`5414e2b1`).

### Read-only preflight

1. Verify the active Stripe destination is Sandbox, is set to API version
   `2024-04-10` and points to
   `https://zpnvnsdtbtdyhvipctpa.supabase.co/functions/v1/stripeWebhook`. Its
   six events are `checkout.session.completed`, the
   `customer.subscription.created` / `updated` / `deleted` events and the
   `invoice.payment_succeeded` / `failed` events. Confirm the isolated
   RevenueCat destination is Sandbox-only and points to the isolated project's
   `revenuecatWebhook`. Check credential names and runtime evidence by presence
   only. Even a Stripe-only delivery needs the isolated RevenueCat v1 lookup.
2. Use a fresh confirmed Auth user with a controlled email and no earlier
   purchase, entitlement or subscription row. The Auth email, RevenueCat App
   User ID and Stripe **subscription** `metadata.user_id` must match exactly.
   Customer email alone has no effect on row ownership.
3. For a normal signed-app run, verify a signed Debug build points to the
   isolated project and can sign in and reach Profile, Premium & Billing and
   Nutrition. The billing-only Supabase bootstrap and the isolated monthly-only
   offering support the XCTest below. Full app screens also need compatible
   feature tables and a current offering with both native plans. The ordinary
   billing screen checks both product identifiers and their durations.

### First provider run

Approve the exact new Execute-prefixed test customer and subscription, and
their immediate cancellation after the active readback. Reuse only a recurring
price confirmed to belong to the isolated Execute fixture. If one is missing,
include creation of one Execute-prefixed sandbox product and recurring price
in the approval. A brief free trial with the subscription configured to cancel
if no payment method is present provides a deterministic eligible `trialing`
state without a test payment method. Skip trial invoice payment, email sending,
receipt transfers and historical event replay.

| Checkpoint | Current provider and delivery | Row and matching native app |
| --- | --- | --- |
| Before creation | New identity, no Stripe subscription and no active RevenueCat entitlement | Zero matching rows. Billing and Nutrition show free access. |
| Trial starts | The new test subscription is `trialing`, its exact `metadata.user_id` is present and a matching `customer.subscription.created` delivery succeeds | Exactly one matching row with `premium/trialing`, `store=stripe`, the matching Stripe ID and the most recent correlated event ID. After Billing refresh, app shows Trial active, the web-management explanation and an unlocked Nutrition Premium gate. |
| Immediate cancellation | Cancel only the new test subscription without any additional invoice or refund. Stripe confirms `canceled` and a matching `customer.subscription.deleted` delivery succeeds | The same row remains, with `free/canceled` and Stripe canceled. After refresh and relaunch of the same account, Billing and Nutrition agree on free access. |

Capture the delivery response and the current provider snapshot before each
readback. Concurrent legitimate events can change `stripe_last_event_id`
before the read. Reconcile the newer event to the same exact Stripe subscription
and current stage, or record the stage as inconclusive. A transport-only test
event, a historical delivery and a successful cancel request do not establish
the row or app result.

Use an isolated dashboard with read-only access for the exact private identity.
This query does not change the fixture or disclose the email in its result.

```sql
with identity as (select '<exact disposable Auth email>'::text as email)
select s.id, s.updated_date,
       s.data->>'plan' as effective_plan,
       s.data->>'status' as effective_status,
       s.data->>'store' as effective_store,
       s.data->>'stripe_subscription_id' as stripe_subscription_id,
       s.data->>'stripe_price_id' as stripe_price_id,
       s.data->>'stripe_plan' as stripe_plan,
       s.data->>'stripe_status' as stripe_status,
       s.data->>'stripe_current_period_end' as stripe_period_end,
       s.data->>'stripe_last_event_type' as stripe_event_type,
       s.data->>'stripe_last_event_id' as stripe_event_id,
       s.data->>'revenuecat_product_id' as revenuecat_product_id,
       s.data->>'revenuecat_environment' as revenuecat_environment,
       s.data->>'revenuecat_plan' as revenuecat_plan,
       s.data->>'revenuecat_status' as revenuecat_status,
       s.data->>'revenuecat_last_event_type' as revenuecat_event_type,
       s.data->>'revenuecat_last_event_id' as revenuecat_event_id,
       s.data->>'current_period_end' as effective_period_end
from public.user_subscriptions s, identity
where s.data->>'user_id' = identity.email;
```

### Mixed-provider follow-up

Run the Stripe-ends-first path on one fresh disposable identity. This exercises
both real webhook handlers and both provider grants on the same row. Reserve
about 30 minutes after the purchase. Test Store's accelerated monthly schedule
is about 25 minutes to expiry. Use observed provider state and delivery as the
gate. [RevenueCat Test Store](https://www.revenuecat.com/docs/test-and-launch/sandbox/test-store)

**Before starting**

1. Scope approval to creating one new confirmed password Auth identity, one
   new Execute-prefixed no-payment-method test Stripe customer and one trial
   on the existing monthly fixture price, identifying one disposable RevenueCat
   customer and purchasing the single Test Store monthly package on that same
   identity, and immediately canceling only that Stripe trial. Include early
   cancellation if the run stalls. Use a synthetic email unchanged in Auth,
   Stripe subscription metadata and RevenueCat App User ID.
2. Repeat the endpoint preflight. In the Stripe sandbox confirm
   `price_1UZjtiEiWRJocTMeRkmJCpTg` is active, `livemode=false` and is the CAD 1
   monthly price of `Execute Billing Integration 20261108`. In RevenueCat verify
   offering `execute_billing_integration` contains `$rc_monthly` mapped to
   `execute_billing_integration_monthly`, a one-month Test Store product
   attached to `Execute Performance Premium` with no free trial. Verify Sandbox
   Testing Access allows the disposable identity and the Sandbox-only destination accepts
   `INITIAL_PURCHASE`, `RENEWAL`, `CANCELLATION` and `EXPIRATION`. Pause if the
   setup differs or any other webhook destination could expose the test events
   to a shared or production app. [RevenueCat Sandbox Testing Access](https://www.revenuecat.com/docs/projects/sandbox-access)
3. Use a dedicated clean iOS simulator, a Debug `ExecuteNative` test host with
   StoreKit Configuration **None**, and select only
   `ExecuteNativeTests/HostedIsolatedMixedBillingTests/testAuthenticatedMixedProviderPremium`.
   Build for testing from `ios-native/ExecuteNative.xcodeproj`. Launch a fresh
   host process for each stage with parallel testing disabled. The XCTest uses
   the pinned RevenueCat SDK and the exact monthly package by offering ID. It
   restores an isolated Supabase password session in memory and reads the live
   RevenueCat entitlement, the real native Supabase reader and AppState access.
   The purchase sheet is part of the XCTest. Normal app navigation and plan
   screen acceptance need their own run.

Set these private inputs in `ExecuteNativeTests.EnvironmentVariables` of a
temporary `.xctestrun` copy beside the build products, with permissions `0600`.
Keep the inputs out of ordinary native-dev settings. Omit
`EXECUTE_HOSTED_BILLING`, the Stripe-only opt-in. With the test simulator
visible for the purchase step, use the same command for each stage.

```sh
xcodebuild test-without-building -xctestrun "$billing_xctestrun" \
  -destination "platform=iOS Simulator,id=$billing_simulator_id" \
  -parallel-testing-enabled NO \
  -only-testing:ExecuteNativeTests/HostedIsolatedMixedBillingTests/testAuthenticatedMixedProviderPremium
```

| Variable | Value |
| --- | --- |
| `EXECUTE_HOSTED_MIXED_BILLING` | `1` |
| `EXECUTE_HOSTED_BILLING_URL` | `https://zpnvnsdtbtdyhvipctpa.supabase.co` |
| `EXECUTE_HOSTED_BILLING_PUBLIC_KEY` | Isolated Supabase publishable/anon key |
| `EXECUTE_HOSTED_MIXED_TEST_STORE_KEY` | The isolated RevenueCat project's `test_` SDK key verified in its dashboard |
| `EXECUTE_HOSTED_BILLING_EMAIL`, `EXECUTE_HOSTED_BILLING_PASSWORD`, `EXECUTE_HOSTED_BILLING_USER_ID` | Disposable Auth login and exact owner UUID |
| `EXECUTE_HOSTED_BILLING_STRIPE_ID` | Omit for `absent`, then supply the exact new sandbox `sub_` ID |
| `EXECUTE_HOSTED_MIXED_STAGE` | `absent`, `stripeTrial`, `both`, `revenueCatOnly` or `ended` |
| `EXECUTE_HOSTED_MIXED_PURCHASE` | Omit for every readback. Set `1` only at `stripeTrial` to open the approved monthly Test Store purchase sheet. |

**Transaction and evidence sequence**

| Stage | Provider action or evidence | Subscription row and native access |
| --- | --- | --- |
| `absent` | Verify no Stripe subscription, no RevenueCat receipt/entitlement and no earlier row. | Zero rows for the exact identity. The fresh authenticated XCTest is Free. |
| `stripeTrial` | Create the approved three-day Stripe trial without a payment method, with automatic cancel on missing method. Put the exact identity in subscription `metadata.user_id`. Observe the new `trialing` subscription and successful isolated `customer.subscription.created` delivery. Verify no payment. | One `premium/trialing` row, effective `stripe`, with the exact subscription and Stripe event IDs. RevenueCat is inactive. The native XCTest is Premium. |
| `both` | Run the XCTest once at `stripeTrial` with purchase enabled. On **Test Store Purchase**, confirm the exact monthly product ID and select **Test valid purchase**. Capture the `SANDBOX`/`TEST_STORE` `INITIAL_PURCHASE` delivery, active monthly entitlement and Stripe still trialing. | Same row ID, both provider plans Premium, `stripe_status=trialing`, `revenuecat_status=active`, monthly product and `revenuecat_environment=SANDBOX`. Effective state is still `premium/trialing`, store `stripe`. The native XCTest is Premium. |
| `revenueCatOnly` | While RevenueCat shows the active monthly entitlement, immediately cancel only the new Stripe trial with `invoice_now=false` and `prorate=false`. Check the actual `canceled` subscription and successful `customer.subscription.deleted` delivery. | Same row ID, Stripe free/canceled, RevenueCat premium/active. Effective state is `premium/active` with the RevenueCat provider snapshot's Test Store value. The native XCTest is Premium. |
| `ended` | Let Test Store renew and expire naturally. Capture an inactive RevenueCat entitlement, successful `EXPIRATION` delivery and Stripe still canceled. | Same row ID, both provider plans Free and both statuses canceled. Effective state is `free/canceled`, store `stripe`. Refresh the native XCTest in a fresh process and confirm Free. |

Record UTC timestamps, the exact Stripe subscription and correlated event IDs,
RevenueCat transaction and correlated event IDs, webhook responses, and row
count and ID in private evidence. A renewal can race a read and legitimately
become the latest RevenueCat event. Collect the initial purchase delivery and
reconcile any newer row event ID to a successful delivery for the same monthly
transaction lineage. The authenticated reader selects one row. Use the SQL
query above to independently verify uniqueness, historical row continuity and
both projections. If a webhook says it delivered but a provider or row state
disagrees, capture the discrepancy before any retry. Keep the Auth identity
available until the final readback. End with both provider grants inactive,
remove the temporary `.xctestrun`, and retain the isolated historical records.
If the purchase was interrupted or the result is unclear, read RevenueCat's
transaction history before considering another sheet. Do not clear histories
or force the backend state.

The combined offline fixture already exercises both provider-loss orders and
both final event IDs. Run it with
`deno test --no-config --deny-net supabase/functions/stripeWebhook/reconcile_test.ts`.
A second live sequence, if approved, can let RevenueCat expire while a fresh
Stripe trial is still active, confirm `premium/trialing` through Stripe, then
cancel that trial and confirm `free/canceled`. Apple pending purchase,
interruption, refund, refund reversal and grace have their own acceptance cases.
Use account labels in shared progress notes.
[Stripe subscription trials](https://docs.stripe.com/billing/subscriptions/trials)
· [Stripe cancellation](https://docs.stripe.com/billing/subscriptions/cancel)
· [RevenueCat webhook event fields](https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields)

## Account matrix

| Label | Execute account | Sandbox Apple Account | Purpose |
| --- | --- | --- | --- |
| A | Existing source from accepted transfer | Existing purchaser tester | Historical source-gating evidence; Restore can transfer ownership back |
| B | Existing destination from accepted transfer | Same purchaser tester | Same-owner reinstall/restore after checking current entitlement |
| C | Fresh disposable identity with no prior paid access | Separate Canadian tester with no purchase history in either app | Empty restore, canceled purchase and network/error checks |

Confirm C has no RevenueCat entitlement and no paid backend row before testing.
A different sandbox tester alone does not guarantee a clean Execute customer.
Check current state immediately before each run: accelerated sandbox expiry means
an old Premium screenshot is insufficient proof that B is still entitled.

## Verified device cases — 2026-11-01

- **No-purchase restore passed:** empty result, no Premium, Nutrition AI gated,
  no RevenueCat entitlement, zero backend subscription/paid rows, and free state
  plus C's email session preserved after process relaunch.
- **Canceled purchase passed:** closed Apple's native-dev monthly CAD 15 testing
  sheet before Subscribe; cancellation message, responsive plan controls, no
  RevenueCat entitlement and zero backend subscription/paid rows.
- **Offline Restore / online recovery scoped pass:** user reported an offline
  warning and no unlock on either attempt; completed online empty result,
  responsive controls, no RevenueCat entitlement and zero subscription rows were
  directly verified. Exact offline wording/timing was not captured; interrupted
  purchases and measured offline timeouts remain unverified.
- **Purchaser uninstall/reinstall passed:** native-dev was removed and reinstalled;
  B session/Premium recovered automatically before manual Restore, which then
  succeeded. Nutrition AI opened; one paid backend row and provider ownership
  remained stable. Keychain erasure/receipt-only recovery was not established.

- **Auto-renewal cancellation and expiry passed:** Apple Sandbox cancellation,
  paid-period retention, actual EXPIRATION delivery200, one free/canceled B row,
  and refreshed Billing/Profile/Nutrition gates were directly verified. The screen
  retained its prior state until explicit Billing refresh; passive immediate
  revocation was not established.

## Device case procedures

| Case | Actions | Required outcome/evidence |
| --- | --- | --- |
| No-purchase restore | Sign into Execute C and the unused sandbox tester. Open billing; tap Restore once; handle only sandbox authentication. | Clear no-active-purchase result; no Premium activation; Nutrition remains gated; no new paid backend row or transferred receipt. Relaunch and confirm it stays free. |
| Cancel purchase | While C is free, start a native monthly purchase and cancel Apple's sheet. | Cancellation message; no entitlement, transaction grant or paid backend row; controls become usable again. |
| Restore network failure/retry | On C, interrupt connectivity before Restore; record any cached response separately. Restore connectivity and retry once. | Error/retry or accurate cached state; no accidental unlock; no stuck spinner; retry completes and remains free. |
| Reinstall/restore | Return to purchaser tester and B; verify current entitlement and back up evidence before removing only the native-dev test app. Reinstall a verified ordinary-scheme build, sign into B, record access before Restore, then Restore once. | The same customer's valid purchase recovers; if auto-refresh already recovered it, record that separately. No extra purchase or ownership transfer; exactly one backend row; Premium and Nutrition agree. If entitlement expired, this is an expired-restore case, not active recovery. |
| Slow account switch | Start a delayed billing read/operation on one disposable identity, then switch accounts. | Previous result cannot unlock the new account or display its success message; provider/backend ownership remains explainable. Mock race tests are separate from device evidence. |
| Cancellation/expiry/refund | Use the intended native-dev Sandbox subscription in Apple management; observe each supported lifecycle separately. | Cancellation preserves access through its paid period; expiry/refund follows actual provider truth and matching webhook/backend state. Previous expiry evidence does not prove cancellation/refund. |
| Pending approval | Use Xcode StoreKit Testing with Ask to Buy enabled. Resolve the request using the test transaction controls. | Pending leaves access Free. Approval unlocks the entitlement, and decline keeps access Free. |

### Hosted App Store exception cases

Use one approved disposable Execute identity and a designated Sandbox Apple
Account on the development-signed native-dev app with StoreKit Configuration
set to **None**. Confirm the exact Apple sandbox product and Apple's notification
destination, the RevenueCat App Store app and environment, and the intended
Supabase project before making a purchase or changing tester settings. Record
the exact account, transaction lineage, provider event, delivery response and
readback privately. Get separate approval for any app-wide configuration change.

- **Interruption.** Use the tester's interruption setting. Verify that the
  purchase attempt leaves the disposable identity Free, and privately resolve
  any Apple-required action. Restore the tester's original setting. After the
  purchase resolves, match the actual sandbox transaction, entitlement and
  backend row to the same owner. [Testing an interrupted purchase](https://developer.apple.com/documentation/storekit/testing-an-interrupted-purchase)
- **Billing grace.** Confirm the app already has Sandbox billing grace enabled,
  or obtain approval for a Sandbox-only change before proceeding. Allow the
  setting to propagate before inducing a failure. Apple says configuration
  edits can take up to 24 hours and apply to upcoming renewals.
  [Apple's grace configuration](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions/)
  Buy the approved monthly subscription, then turn off **Allow Purchases & Renewals**
  for the designated tester. Check paid access during grace. Re-enable the
  setting for a recovery test or wait for grace and retry to end for an expiry
  test. Match the provider events, row and native access before resetting the
  tester setting. The signed, read-only
  `HostedAppleSandboxRefundTests/testReadGraceOfVerifiedSandboxPurchase`
  uses the same private transaction and customer fields as the refund fixture,
  with `EXECUTE_HOSTED_APPLE_SANDBOX_GRACE=1` as the opt-in. It requires
  Apple's verified grace state and a future expiration after the paid period,
  and checks that the RevenueCat App Store Sandbox entitlement remains active.
  [Apple's failing-renewal testing procedure](https://developer.apple.com/documentation/storekit/testing-failing-subscription-renewals-and-in-app-purchases)
- **Refund.** Use the dedicated Debug XCTest on a signed native-dev host with
  the approved Execute account already restored. Capture the exact current
  transaction and original transaction IDs from the authorized purchase. Build
  the ordinary `ExecuteNative` scheme for testing. Select only
  `ExecuteNativeTests/HostedAppleSandboxRefundTests/testPresentRefundSheetForVerifiedSandboxPurchase`.
  Set `EXECUTE_HOSTED_APPLE_SANDBOX_REFUND=1`,
  `EXECUTE_HOSTED_APPLE_REFUND_PRODUCT_ID`,
  `EXECUTE_HOSTED_APPLE_REFUND_TRANSACTION_ID`,
  `EXECUTE_HOSTED_APPLE_REFUND_ORIGINAL_TRANSACTION_ID`, and
  `EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER` in the test target's private temporary
  `.xctestrun` environment. Remove the file after the test. The test compares
  the active RevenueCat customer and exact App Store Sandbox transaction with
  the verified StoreKit purchase. It opens Apple's sheet for the operator to
  submit after specific refund approval. A renewal can change the current
  transaction ID. Stop and reverify the approved scope if any guard rejects
  the request. A submitted sheet still requires separate Apple revocation,
  RevenueCat delivery, database and native access evidence. Use the same private
  environment and select only
  `ExecuteNativeTests/HostedAppleSandboxRefundTests/testReadRevocationOfVerifiedSandboxPurchase`
  after the refund. This read-only test checks the exact verified StoreKit
  transaction in history and fresh RevenueCat access. It opens no Apple sheet.
  [Testing refund requests](https://developer.apple.com/documentation/storekit/testing-refund-requests)
- **Refund reversal.** Apple documents `REFUND_REVERSED` for a reversed refund
  after a customer dispute. Its test-notification API sends `TEST`. Keep the
  webhook fixture result and actual reversal acceptance distinct.
  [Apple notification types](https://developer.apple.com/documentation/appstoreservernotifications/notificationtype)

## Server and release follow-up

- Delayed/repeated events and retained independent purchases have fixture coverage;
  controlled integration acceptance is still open. Do not blindly replay historical
  production events or infer delivery success from a synthetic TEST.
- `STRIPE_SECRET_KEY` was absent at the last verified deployment. Stripe-linked
  reconciliation intentionally retries rather than guessing access. A later Stripe
  webhook can still overwrite shared effective status: mixed-provider acceptance
  and any shared production fix require a separately reviewed rollout.
- Local StoreKit Code 3 remains independently reproduced on Xcode26.6/iOS26.5.
  The installed26.1 fallback has not reached a test. Approved storage cleanup has
  recovered approximately33GiB; a Mac restart and required platform setup remain
  before retesting. Follow the [controlled repair resume
  procedure](native-parity-audit.md#storekit-toolchain-and-runtime-repair--2026-11-01)
  before another probe. Run only the bounded cancellation case first, then all
  four fixture tests if controls work. Existing pending coverage stops at no grant;
  approval/rejection transitions still need acceptance. Ordinary billing mocks and
  real Apple sandbox tests do not establish a local test-session fix.
- Account deletion deployment/device acceptance, App Store submission and broader
  native migration release gates remain separate.

Apple setup reference: [Create a Sandbox Apple Account](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account).

## Lifecycle review and expiry checkpoint — 2026-11-01

A new isolated seven-case fixture review of the unchanged webhook matched six
expected outcomes: paid-period cancellation retention, refund with an expired
provider entitlement, billing issue during grace, billing issue after grace,
expiry, and a delayed expiry event after a newer active purchase. These exercise
current provider snapshots; they are not live refund or billing-retry acceptance.

**Discovered gap (fix deployed as v8; live acceptance pending):** the original handler omitted `REFUND_REVERSED` from `handledTypes`.
The reproduction returned HTTP 200 / `skipped: REFUND_REVERSED`, with zero provider
reads and zero reconciliation writes despite an active current entitlement fixture.
The omitted event could leave backend access stale until another handled event
reconciled it. The approved version 8 fix now refreshes current provider state;
its deployment and acceptance limits are recorded below.
RevenueCat documents this as an App Store event in its
[event reference](https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields).

| Remaining case | Current evidence | Next required evidence |
| --- | --- | --- |
| Cancellation followed by expiry | Passed: actual cancellation and EXPIRATION delivery200, one B free/canceled row and refreshed device gates | Complete for this run; passive immediate revocation without refresh is not established |
| Refund/revocation | Expired provider snapshot fixture revokes; no live pass | Supported Sandbox refund with actual provider entitlement, event/delivery, backend and device checks |
| Refund reversal | Fix deployed as v8; 20 local tests pass; source/auth/configured TEST smoke verified | Release owner accepted fixture coverage for reversal on Nov 19; live Sandbox refund passed in E66 |
| Billing retry/grace | Current grace and expired grace fixtures behave as expected; Swift grace-resolution unit coverage exists | Actual Apple Sandbox billing-failure/grace transition, recovery or grace expiry, matching server/device state |
| Delayed/repeated events | Existing idempotency/current-truth fixtures; repeated same-owner physical restore passed | Controlled integration delivery without replaying unrelated production history |

The fix adds `REFUND_REVERSED` to the existing current-state reconciliation
route, with three regressions for active access, a delayed reversal after expiry,
and provider failure/retry. All three new tests failed against the original
handler while its 17 existing tests passed; the fixed handler passes all 20 tests,
lint and type-check. The reviewed source is deployed as version 8. Gateway and
bearer authentication remain unchanged.

### B expiry observation procedure

Keep Execute B and its purchaser Sandbox tester signed in. Do not Renew,
Subscribe, Restore, clear tester history or manually change a subscription row.
The recorded annual end is **2026-11-01T07:42:08Z**, equivalent to **November 1,
12:42:08 a.m. America/Vancouver** (before that morning's clock change).

1. After that time, inspect B in RevenueCat and record inactive/expired entitlement
   plus native-dev annual EXPIRATION event ID, event time and actual integration
   response. Allow transport delay; a calendar timestamp alone is not a pass.
2. Run the existing SELECT-only B query: require exactly one row, `free/canceled`,
   matching `revenuecat_last_event_type/id`, provider observation time and period.
   If it remains paid, distinguish delayed delivery from handler failure.
3. Refresh/foreground the existing native-dev app as B. Check Profile/Billing and
   Nutrition's Premium AI gate without submitting AI work. Record both gates.
4. Record each layer separately. If device access differs from provider/backend,
   capture that mismatch before relaunch or further diagnosis. Do not manufacture
   a passing result by writing rows or buying/restoring.

The device build is unchanged; the later webhook-only rollout is recorded below. Pending approval,
interrupted purchase, mixed-provider Stripe status, StoreKit Code3, account deletion
and broader native release acceptance remain separate open items.

## Completed B cancellation-to-expiry result — 2026-11-01

The annual period ended at `2026-11-01T07:42:08Z`. RevenueCat emitted native-dev
Sandbox `EXPIRATION`, reason `UNSUBSCRIBE`, event
`D37D18A5-DD0E-4799-93BE-05928B426BA2`. The actual integration returned **HTTP200**,
`{"received":true}`. RevenueCat showed **Inactive · expired**. A fresh SELECT-only
query returned exactly **one B subscription row**, `free/canceled`, with that event
ID/type, period end unchanged, `cancel_at_period_end=false`, provider observation
`07:42:22Z` and backend update `07:42:23.01489Z`.

The physical phone was confirmed signed into B before expiry and stayed on that
identity. Its already-open screen retained the earlier active state until Billing
was explicitly reopened. The completed **Checking subscription** refresh then
showed the free paywall. Profile showed **Upgrade to Premium**, and tapping
Nutrition's **Describe your meal with AI** opened the Premium paywall. No estimate
was submitted. No Restore, Subscribe, Renew, process restart or manual database
write was used. This accepts post-refresh gates; passive immediate expiry while
leaving the old view open is not established.

Private evidence in the setup workspace: `outputs/cancellation-expired-revenuecat.png`,
`outputs/cancellation-expiry-{webhook200,backend,billing-gated,profile-gated,nutrition-gated}.png`
and the acceptance status JSON. Refund/reversal and billing-grace integration,
pending approval, interrupted purchase, mixed-provider Stripe and local StoreKit
Code3 remain open. The refund-reversal fix was subsequently deployed as version 8, as recorded below.

## Refund-reversal fix applied locally — 2026-11-01

The reviewed event-route change and three regression tests are now in the active
`codex/native-billing` checkout. All 20 handler tests, lint, entrypoint type-check,
changed-file formatting and whitespace checks passed. Read-only deployed-source
comparison confirms version7 differs by only the added event route; rollback and
staged source are prepared. See the [function rollout guide](../supabase/functions/revenuecatWebhook/README.md#refund-reversal-follow-up--2026-11-01).
The scoped rollout subsequently passed as recorded below; real refund/reversal
acceptance remains pending. No migration, secrets, provider setting, restore
policy or Recovery branch changed.

## Refund-reversal v8 rollout verified — 2026-11-01

After scoped approval, deployed only revenuecatWebhook. Management API confirms
active v8, original gateway setting, and no changes to other functions. Downloaded
source matches the exact reviewed stage; the sole runtime difference from v7 is
REFUND_REVERSED routing. Missing/invalid bearer requests returned 401 on both
endpoint forms. Configured RevenueCat TEST `6F475DD8-ED66-4EE7-9302-F995BE75EB9D`
returned 200 with `{"received":true,"skipped":"TEST"}`. No migration, private-key,
provider/restore-policy or native-build change occurred. Full bundle hash and
rollback details are in the function README and private rollout manifest.
This is source/authentication/transport smoke plus local regression coverage;
real Apple refund/reversal acceptance remains unverified. No historical replay
or manual subscription edit was used.

## Restart continuation — 2026-11-08

The six Stripe reconciliation issues are implemented locally. All 50 focused
checks and 15 controlled PostgreSQL/handler groups pass; both webhook entrypoints
type-check and scoped lint/formatting pass. No live provider, deployment or native
acceptance is claimed. Fresh inventory shows RC v8 but no Stripe endpoint/secrets.
Recovery PR #2 remains draft with a reproduced invalidation-retry defect; StoreKit
platform recognition/restart remains blocked independently. Preserve legal/PDF
work. See the single [current handoff and detailed evidence](reports/2026-11-08-billing-review.md).

## Native acceptance after support installation — 2026-11-09

This checkpoint supersedes the platform-blocked status above. The completed official Xcode support installation restored eligible destinations in Xcode26.6. On dedicated simulator `E26EF6EE-DDA9-48A4-92E5-6CBE29B75CDE` (iPhone17/iOS26.1, build23B86), the unchanged `ExecuteNative-StoreKit` acceptance definition passed:

| Case | Observed result | Duration |
| --- | --- | --- |
| Cancellation, run first | `.userCancelled`; zero current entitlements | 2.258s |
| Monthly/annual metadata | Two products, nonempty localized display prices, one month/year periods | 0.051s |
| Purchase and App Store sync | Verified local purchase; entitlement recovered after sync | 0.742s |
| Ask to Buy | `.pending`; zero current entitlements | 0.803s |

Cancellation used a30-second execution allowance and finished with xcodebuild exit0. The remaining three cases reused the compiled build with `test-without-building`, exit0. Independent xcresult summaries contain1+3 passed, zero failed/skipped; no `SKInternalErrorDomain Code=3` appeared. These are local Apple StoreKit fixtures, not App Store Connect/RevenueCat receipt or real-provider acceptance. Later Ask to Buy approval/rejection remains separate.

Ordinary fixture-free `ExecuteNative` also compiled successfully. Native XCTest passed all28 Recovery and13 Plan refinement methods (41/41, zero failed/skipped). Existing UI tests passed Billing3 + Recovery6 (9/9), covering navigation, mock purchase/restore membership UI, legal destinations, Recovery tasks/limitations/guidance failure and large text. UI services are fixtures; these results do not establish live RLS/AI persistence or authenticated cross-provider gates. The two isolated provider/server cross-provider scenarios are independently verified in the Execute workbook, with native matching-session access still open.

The standalone signed Debug iPhone artifact builds through the generic iOS destination and passes strict codesign verification for team `58GZDC8UKY`, native-dev bundle and existing native-dev monthly/annual IDs. A device-specific build could not mount the connected iPhone's developer disk image; no installation or physical-device launch is claimed. No distribution, production deployment, PR push or merge occurred.

Evidence is retained under the current chat workspace `work/post-restart-native`: four xcresult bundles, extracted summaries, logs, exported UI attachments and the public device-build manifest. The normal app is open at sign-in on the dedicated simulator with no fixture arguments. Live Recovery/Plan checks await private sign-in using a disposable Execute account. Plan saving additionally needs legitimate Premium access and an existing active plan; no manual entitlement grants are authorized.

The Code3 investigation closed within the original30-minute total limit: prior1383s plus resumed235s =1618s (26m58s), leaving182s unused. Do not restart an unrestricted diagnostic loop. Canonical progress remains the Execute Document on Google Drive, maintained by the separate writer.

## Live Recovery guidance verified — 2026-11-09

The user approved the single reviewed `patch_record` helper on the shared app backend. The first native retry committed its update but failed response decoding; the helper was rolled back immediately. The client now accepts a single default RPC result, verifies the requested UUID, and uses the SDK timestamp decoder. Six actual-SDK/local HTTP regressions pass, including alternate envelopes and rejected empty/multiple/wrong-ID acknowledgments.

After redeploying the identical approved SQL, the normally signed app successfully re-saved the existing synthetic QA check-in/DailyLog and persisted generated guidance. Termination/relaunch restored the complete guidance without regeneration. Independent read-only database checks confirm the same one check-in and one DailyLog, unchanged IDs and identical guidance SHA256. The re-save retained energy8; a changed-input edit is not claimed. No manual row writes, entitlement grants or RLS changes were used.

The approved helper is active and final verification passed; another rollback is not required. Only this SQL was applied, without registering migration history or applying unrelated migrations. This supersedes the missing-helper blocker above. Live limitations/tasks/date-switch, initial Plan generation/refinement persistence, remaining destinations, account deletion, physical-device parity and TestFlight readiness remain separate gates. PR #2 stays draft and unmerged. Evidence: the chat workspace's `work/live-native-20261109/patch-record-review/native-persistence-result.json`, transport test summary and `outputs/native-live-guidance-restored.png`; canonical progress remains the Execute Document maintained by the separate writer.

### Live limitation and date follow-up — 2026-11-09
The normal authenticated app created one explicitly synthetic QA limitation, then archived it using the app control. Switching Nov9 → Nov8 showed an unsaved default check-in rather than the saved day's guidance; returning to Nov9 restored saved guidance and the archived limitation. Independent SELECT confirms one limitation record with is_active=false and the synthetic note. This is date reload coverage, not another full relaunch test. Planned task completion still requires a real saved plan; changed-input editing and full Plan/device/release acceptance remain open. Evidence: chat workspace work/live-native-20261109/limitation-date-result.json and limitation-after-date-reload-db.json. Canonical Execute Progress Log is verified through row95.

## E72 signed Sandbox grace — 2026-11-19

The owner confirmed one no-charge Native Dev monthly Sandbox purchase after
the 24-hour setting window, then turned renewals off on the disposable Apple
tester. The purchase renewed the approved existing Sandbox lineage. Receipt
times below are UTC.

- The ordinary period ended at 08:47:53. RevenueCat recorded the billing issue
  at 08:48:02 and reported a grace expiration of 08:52:53. The exact
  Executev2 projection remained Premium and active after ordinary expiry.
- After reconnecting by USB and unlocking the paired iPhone, the signed
  read-only XCTest passed at 08:50:42. Verified Apple transaction and renewal
  information reported `.inGracePeriod`, a past ordinary expiry, and the same
  future grace expiration. The exact RevenueCat SDK entitlement remained active
  for the monthly App Store Sandbox product. The owner's Billing screen
  showed Premium during grace.
- The owner turned Allow Purchases & Renewals back on. Apple issued a new
  signed transaction on the same lineage, and RevenueCat briefly cleared the
  billing issue. The next cycle entered billing retry again, with no new
  grace expiration and a Free/canceled Executev2 projection at final readback.
  The signed pass applies to the first grace retention case. Repeat-renewal
  recovery and live refund reversal remain open.
- The signed E71 Release app was reinstalled and launched on the test iPhone.
  With the owner's explicit approval for Apple's combined switch, the
  temporary Sandbox grace setting was turned off. App Store Connect returned
  to Set Up Billing Grace Period.

### Read-only follow-up for later renewals

Use `HostedAppleSandboxRefundTests/testReadApprovedSandboxRenewalHistory`
on the approved signed Native Dev QA device running iOS 17 or later. Set
`EXECUTE_SANDBOX_RENEWAL_HISTORY=1`, `EXECUTE_SANDBOX_RENEWAL_ORIGINAL_ID`, and
`EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER` in the private test target environment.
Set `EXECUTE_SANDBOX_RENEWAL_AFTER_UTC` and
`EXECUTE_SANDBOX_RENEWAL_THROUGH_UTC` to ISO 8601 timestamps bounding the
approved historical window. The upper bound must be in the past and within
24 hours of the lower bound. For E72, the lower bound is
`2026-11-19T08:52:54Z`, when the second billing issue appeared.

The probe requires two consecutive Apple-verified monthly Sandbox renewal
transactions on the same lineage, each with a five-minute period and with
the second beginning at the first expiration, within two seconds. It reads
StoreKit history and the app's existing customer identity. It prints
period timestamps only. Match those timestamps independently against the
provider and the projected billing row. [StoreKit transaction history](https://developer.apple.com/documentation/storekit/transaction/all)

## E73 recovered Sandbox renewals and expiry delivery — 2026-11-19

RevenueCat's exact Native Dev monthly Sandbox history showed successful
renewal 19 at 08:58:15 UTC after the E72 retry, followed by renewal 20 at
09:03:15 UTC. Both retained the original transaction lineage and delivered
their webhooks with HTTP 200. Regular renewal continued through 09:45:42 UTC.
The Executev2 QA row recorded a later successful renewal. A bounded,
read-only signed StoreKit history probe is ready for the next USB session.
The QA iPhone was unavailable for independent receipt history verification.

The subscription expired at 09:50:42 UTC after auto-renew was disabled.
RevenueCat showed the expiration webhook failed all six automatic attempts
with no response. The one owner-approved retry still showed failure.
Executev2's sampled function logs showed successful billing invocations up
to 09:44:57 UTC and no matching later invocation. The exact QA subscription
row still projected App Store Premium even though its period had elapsed.
The cause of the delivery failure remains unconfirmed.

On refresh, the native candidate now stops treating an elapsed dated
App Store projection as current access. A current live RevenueCat
entitlement can still grant access through grace. The date guard is scoped to the
App Store projection. Twenty-nine focused Release simulator tests passed,
including the stale projection and active live grace cases.

Apple documents approved, declined, and prorated Sandbox refunds. The
Apple-origin refund reversal event follows reversal of an earlier refund
after a dispute. No supported Sandbox control to trigger that event was
identified. The staged reconciliation fixtures cover refund reversal.
[Sandbox refund testing](https://developer.apple.com/documentation/storekit/testing-refund-requests.md)
· [Apple notification types](https://developer.apple.com/documentation/appstoreservernotifications/notificationtype.md)

## E74 Sandbox expiry follow-up — 2026-11-19

The existing Executev2 webhook URL returned HTTP 200 to a preflight with
no credentials or event body. This checks the route's reachability from the
test client. The previously observed RevenueCat expiration delivery gap
remains unresolved.

The verified-only RevenueCat writer independently checks the app, product,
provider environment, immutable owner and expected row revision. The
offline expiry cases confirm that replaying an expiration while fresh
provider data shows a later paid period keeps Premium, and an actually
elapsed current period projects Free. The E73 native guard continues to
apply on refresh for an elapsed App Store projection. The historical
physical receipt probe remains pending.
[RevenueCat delivery and retry behavior](https://www.revenuecat.com/docs/integrations/webhooks)

## E75 refund reversal acceptance — 2026-11-19

The release owner approved using the staged reconciliation fixtures for
Apple refund reversal. The fixtures cover restoring eligibility on fresh
provider evidence after a reversal. No live Apple reversal was observed.
This resolves the refund-reversal acceptance item.

The read-only StoreKit test passed on the signed physical QA iPhone. It
found ten verified Sandbox renewals and seven contiguous five-minute
pairs for the exact approved monthly lineage. The final pair covered
09:40:42–09:45:42 UTC and 09:45:42–09:50:42 UTC. The normal signed app was
reinstalled and launched after the test.

An independent read of the exact Executev2 QA row still showed
`premium/active` after the 09:50:42 UTC period ended. The last projected
event was a renewal observed at 09:44:57 UTC. This closes the signed
renewal-history check. Delivery of the Sandbox expiration and backend
reconciliation remain open.

### Automatic recovery when an expiration event is missing

The isolated job runs every five minutes and reads only overdue, verified
Sandbox App Store owners. It reconciles from the current RevenueCat
subscriber and any linked Stripe subscription. The existing owner and
revision checks protect against concurrent writers and retirement. A failed
provider read leaves the row eligible for a later job run. Successful runs
retain recorded webhook metadata so recovery does not imply delivery.

Use the provider-specific App Store deadline even when Stripe is the
effective source. Record the last signed App Store end time, confirm that
the isolated expiration was withheld, and read the backend before opening
the app. The acceptance target is Free within 15 minutes when neither
provider still grants access. Valid grace, renewed App Store, active Stripe,
and retired-owner fixtures cover the other branches. Hosted timing still
requires independent provider and database evidence.

#### Hosted results, November 19 Vancouver time

The original RevenueCat destination was the Executev2 function endpoint.
A matching renewal around 09:39:58 UTC returned HTTP 200 and had both a
request and an execution ID in the retained function logs. The latest
matching invocation before expiry was another HTTP 200 at 09:44:57 UTC.
The gateway and function search found no matching invocation for the
09:50:42 UTC expiration through 10:10 UTC. RevenueCat reported no response.
The logs do not establish where the delivery stopped.

In the isolated rehearsal the actual App Store cancellation projected
Premium while the last paid period was still active. The later expiration
was withheld from the isolated webhook. The period ended at
01:41:51 UTC on November 20. The scheduled request returned HTTP 200 and
updated exactly one row. The persisted row became Free at 01:45:05.965 UTC,
3 minutes 15 seconds after expiry. Its last webhook remained CANCELLATION.
No app launch or direct row edit was part of this measurement.

The separate mixed control used one real card-free Stripe Sandbox trial.
After the untouched Free result was recorded, the verified fixture was
staged with the expired App Store deadline and the actual Stripe trial.
At 01:50:04.456 UTC the scheduled worker wrote App Store Free and preserved
effective Premium from the Stripe trial. After cancellation, a verified
read returned both sources to Free. The temporary restricted key was
revoked and its next request returned HTTP 401.

The signed Free-gate probe is prepared. The device was released before
that follow-up. The hosted evidence covers the verified Sandbox cohort.
The legacy web reader still filters by email and needs a compatible
path before rollout to owner-bound rows.

### Prepare the production rollout

The [production aggregate](../supabase/tests/account-deletion/production-rollout-readback.sql)
found eight legacy RevenueCat rows, zero verified projections, zero linked
Stripe rows and no billing fence or scheduled job. The existing RevenueCat
webhook remains the legacy writer. A matching email does not establish an
owner binding. Prepare provider and Auth evidence for any candidate, including
the app, environment, product, known transfer aliases and exact Auth UUID.

Build 19 understands the authenticated, owner-scoped compatibility RPC.
On older databases it falls back to the existing email read when PostgREST
reports the RPC missing. After the RPC is present it uses that fallback only
for a legacy decision. A verified Free or empty result is authoritative.
Sandbox and unavailable results cannot fall back to email. The RPC returns
only display fields, after a server-side production cohort lookup. The
Capacitor RevenueCat SDK still signs in by email for its independent
entitlement and purchase flow. Keep build 19 on legacy billing. Before any
verified cohort can use that client, update and verify SDK ownership and
access gating, including logout and same-email re-registration.

| Phase | Forward step | Stop or rollback |
| --- | --- | --- |
| Prepare schema | Capture current catalog and restore artifact. Review the billing projection fence, owner ledger, verified projection SQL and the compatibility RPC in dependency order. Obtain production approval before applying SQL. | Keep legacy webhook admission available. Remove the compatibility RPC before any dependency reversal. Stop structural reversal if it would remove a live fence, enrolled owner or retirement evidence. |
| Observe one owner | Establish a verified production binding independently. Capture the verified owner’s current App Store and applicable Stripe state. After explicit approval, deploy `revenuecatExpiryObserve` with gateway JWT verification off and its separate strong bearer, explicit enable flag, one exact UUID, approved project and product list. Invoke manually during the observation window. | The candidate performs only reads, reports one decision, and has no schedule or write path. Remove the observer enable flag and withdraw the endpoint to stop it. Its settings are separate from the shared webhook configuration. |
| Verify coexistence | Replay approved, isolated legacy and verified scenarios before enabling dual routing. Verify the authenticated production client read against the exact canary, keep unverified historical owners on the legacy route, and reject ambiguous aliases for review. | Never switch the shared webhook to verified-only while unresolved legacy rows remain. Keep both writer revisions available until source, owner, and delivery evidence match. |
| Schedule production writes | After the observer is verified, review the writable allowlist, compare-and-set ownership, 15-minute target, alerting, and retry/rollback behavior. Start with a separately authorized canary and compare provider and readback evidence before expanding. | Disable the scheduler and withdraw the write endpoint before changing schema. Preserve verified-owner bindings and retirement markers. Do not issue a speculative provider retry or rewrite an unverified legacy row. |

W15's hosted rehearsal passed for verified Sandbox owners. The original
delivery failure remains uncorrelated, and the legacy QA row still showed
expired App Store Premium at the last readback. Production observation has
no enrolled owner yet.
