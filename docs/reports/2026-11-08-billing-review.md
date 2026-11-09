# Native billing and integration handoff — 2026-11-08

This is the current repository progress record, linked from the root README.
Detailed run evidence remains in the private setup workspace referenced below.
The Google Drive progress sheet has not been updated by this chat.

## Status at this checkpoint

| Area | Completed | Still open |
| --- | --- | --- |
| Billing implementation | Local commit `51332a8`; all six reproduced issues fixed; 50 focused tests, both type-checks and scoped lint/format pass | Real provider scenario acceptance |
| Isolated database | New empty test project bootstrapped with billing table, own-email read-only client RLS, unique index and unchanged service-role-only atomic RPC; actual grants/RLS verified | Provider-created subscription rows and authenticated native gates |
| Test deployment | Both reviewed webhook functions active in the isolated project; `verify_jwt=false` with bearer/signature checks retained; latest metadata v6 | Downloaded deployed-source equivalence: CLI multipart/octet-stream mismatch; Dashboard Code/Download route pending |
| RevenueCat setup | Separate project, exact entitlement, user-entered V1 key and webhook token; Sandbox-only connection active; configured synthetic TEST HTTP 200; missing/invalid bearer HTTP 401 | Test Store product/purchase, current-customer lookup and event/database acceptance |
| Stripe setup | Existing sandbox explicitly approved for Execute-prefixed disposable objects; restricted receiver key prepared with only Subscriptions Read; all four custom secret names verified | User reports exact-version endpoint created/signing secret saved; independent endpoint metadata, signature and delivery checks next |
| Recovery | Focused retry fix `c301f6c` on separate branch; five new regressions and all 27 isolated model methods pass | Draft PR readiness, native/live acceptance, review/integration |
| StoreKit/native | Runtime state and work saved; restart checkpoint and verified Git bundles prepared | Coordinate restart, fix platform recognition, cancellation control then existing four-case suite |

## What changed in billing

Both provider event paths read current Stripe/RevenueCat state and apply shared
email-keyed effective access through the existing revision-checked transaction.
Stripe deletion or a failed invoice cannot remove a currently valid RC grant.
Checkout/paid invoice events cannot revive a currently canceled subscription;
provider-read failures retry; delayed payloads cannot replay obsolete access.
Exact RC entitlement, grace/lifetime behavior, Stripe active/trialing eligibility,
identity and authentication contracts are preserved. Known Stripe links are
bounded to 20 and terminal history is pruned. No new refund-only revocation policy.

The 15 embedded PostgreSQL/handler report groups and 50 tests are controlled
fixture/local evidence. The billing-only bootstrap adds 11 local security/SQL
validation groups and actual remote ACL/RLS checks. None establishes Apple
purchase/refund/reversal/grace or native interrupted-purchase acceptance.

## Environments and boundaries

| Service | Existing shared environment — unchanged | Approved test environment |
| --- | --- | --- |
| Supabase | Executev2 `shoflbdwlmvttidoolvd`; existing RC v8 | Execute Billing Integration `zpnvnsdtbtdyhvipctpa`, us-west-2 |
| RevenueCat | Execute Performance `7415d2f3`; original apps/mappings/webhook retained | Execute Billing Integration `5414e2b1`; entitlement `Execute Performance Premium` |
| Stripe | No live-account setup or unrelated Star Learning objects changed | Star Learning sandbox `acct_1TAfBREiWRJocTMe`; new Execute-prefixed test objects only |

The user created the test database password privately. All four configured custom
names have been verified without reading values: `REVENUECAT_SECRET_API_KEY`,
`REVENUECAT_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`.
The receiver API key and endpoint signing secret are separate credentials.

The Stripe destination UI offered only 2026 versions. A documented Workbench
Shell command was prepared with body `api_version=2024-04-10`, the exact test URL
and six supported events; the user executed it and saved the creation-only
signing secret privately. That completion is user-reported until the next
independent endpoint/delivery check. No creation response was read by the agent.

Deployment verification caught the CLI enabling gateway JWT verification despite
local config; explicit `--no-verify-jwt` corrected this on the test project only.
Stripe GET HTTP 405 confirms runtime/method guard. RevenueCat TEST 200 confirms
transport/authentication only; its synthetic route skips provider/database work.

## Recovery and native work

Lachlan's `feature/native-recovery` was not edited. PR #2 reviewed head remains
`cba84fea`, draft/unmerged. Its reproduced personalization-invalidation retry
failure is fixed in separate branch `codex/recovery-invalidation-retry`, commit
`c301f6c`. Retry repeats the failed invalidation without repeating acknowledged
check-in/limitation saves, with identity/generation guards and same-user reload
support. The old model fails the new regression; the fixed isolated macOS runner
passes all 27 methods. This is not simulator/XCTest/live RLS/AI acceptance.
Integrate the Recovery feature first, then review/cherry-pick its dependent fix.

The reference Customize toggle only changes its own label/icon/color; it does not
change or save Recovery layout. Concrete source-rendered states are saved for
parity review. Building working customization would be a new feature decision.

Xcode 26.6 plus installed iOS 26.1/26.5 still reports missing 26.5/no eligible native
destination at the latest observed check. No restart or StoreKit repair/pass is
claimed. Save private browser work before coordinating restart. Cancellation must
work before the original four StoreKit cases are run.

## Safety, preservation and next action

Billing source is unchanged from `51332a8`; legal submodule selection and untracked agreement
PDF are preserved. Local commits have not been pushed; no production deployment,
provider mapping/restore-policy change or production data mutation occurred.

An existing standard Stripe test key was accidentally exposed in accessibility
output while locating controls. The user was informed and private rotation was
recommended; the value was not reused or included in this handoff/artifacts.
Subsequent key work uses user-only creation/reveal/copy/paste and narrowly scoped
nonsecret controls. Rotation of that older key remains user-handled.

Next: independently verify the new endpoint is sandbox, version 2024-04-10, exact
URL and six events; verify signing rejection and configured delivery; finish
controlled Test Store/Stripe sandbox scenarios; inspect deployed source via
Dashboard Code/Download; then coordinate restart/native acceptance. Keep synthetic
TEST, fixtures, real test-provider events and physical/native results distinct.

## Detailed evidence

Private workspace:
`/Users/evanlycos/Documents/Codex/2026-11-08/continue-execute-s-native-migration-in/`

- `work/billing-setup-20261108/setup-state.json`: current setup and private-step status.
- `work/billing-setup-20261108/`: bootstrap, remote RLS/ACL checks, deployment logs,
  function/secret-name metadata, auth/transport checks and provider-check plan.
- `outputs/billing-reconciliation-package.zip`: reviewed billing sources/tests,
  original rollback package and isolated scenario evidence.
- `outputs/recovery-retry-review.zip`: focused patch, baseline/fixed model results
  and source-derived regression runner.
- `outputs/recovery-customize-reference.html`: concrete inert-toggle comparison.
- `outputs/RESUME-setup-20261108.txt`: restart and exact continuation checkpoint.

No secret values belong in repository notes, evidence or commands. Use the
selected test project explicitly; never run an unreviewed broad `db push`.
