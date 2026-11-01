# Native billing acceptance

This is the remaining acceptance runbook for `com.executelabs.execute.native-dev`.
The dated evidence in [the parity audit](native-parity-audit.md) remains the record
of completed physical tests. A fixture pass does not establish a sandbox pass.

## Test boundaries

- Use the standalone `ios-native/ExecuteNative.xcodeproj`, ordinary `ExecuteNative`
  scheme, StoreKit Configuration **None**, and no mock/preview launch arguments.
- Preserve the original Execute app, existing tester purchase history, RevenueCat
  restore policy and provider mappings. Do not clear purchase history to simulate
  a clean customer or write subscription rows to manufacture an outcome.
- Record Execute identity, sandbox tester label, native product, before/after
  entitlement, backend row count/state, event ID and delivery status privately.
  Published evidence uses account labels rather than email addresses.
- Authentication, new passwords and Apple authorization are handled by the user.
  Stop any transaction that is not explicitly identified as Sandbox/testing.

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
| Pending approval | Use a working supported StoreKit testing environment. | Pending does not grant access; approval/rejection resolves correctly. Local Code 3 currently prevents treating SKTestSession controls as accepted. |

## Server and release follow-up

- Delayed/repeated events and retained independent purchases have fixture coverage;
  controlled integration acceptance is still open. Do not blindly replay historical
  production events or infer delivery success from a synthetic TEST.
- `STRIPE_SECRET_KEY` was absent at the last verified deployment. Stripe-linked
  reconciliation intentionally retries rather than guessing access. A later Stripe
  webhook can still overwrite shared effective status: mixed-provider acceptance
  and any shared production fix require a separately reviewed rollout.
- Local StoreKit Code 3 remains an independent unresolved issue. Rerun only its
  isolated scheme when investigating it; ordinary billing mocks and real Apple
  sandbox tests do not establish a fix.
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
| Refund reversal | Fix deployed as v8; 20 local tests pass; source/auth/configured TEST smoke verified | Supported real Sandbox refund/reversal integration acceptance |
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
