# Billing/backend reconciliation handoff — 2026-11-08

## Implemented and locally verified

All six reproduced Stripe issues are fixed: deletion and failed invoices preserve
current RevenueCat access; checkout and paid invoices cannot revive a canceled
current subscription; failed provider reads request retry; delayed updates use
current snapshots. Both webhook paths use shared current-provider projections
and the existing revision-checked atomic RPC. No migration is newly required.

50 focused tests pass, including real local Stripe SDK signature checks.
Both entrypoints type-check; scoped lint, formatting and whitespace pass.
Controlled provider fixtures through embedded PostgreSQL pass 15 groups (the
existing six-case SQL suite plus 14 combined handler/RPC groups). These are
isolated integration checks, not live provider/Sandbox/native acceptance.

Preserved exact email identity, exact RC entitlement, either-provider access,
service-role-only writes and existing authentication/API version. Current Stripe
active/trialing takes display precedence when both providers grant. Known Stripe
links are bounded to 20; terminal history is pruned. Stripe past_due gains no
new grace; charge refund/dispute policy is unchanged. Provider faults retry
without guessed downgrades or partial writes. No live purchase/data write.

## Deployment review and external dependencies

Not deployed or pushed. Fresh inventory: RC v8 is active; no Stripe endpoint,
STRIPE_SECRET_KEY or STRIPE_WEBHOOK_SECRET exists in this project. Downloaded RC
v8 rollback source matches baseline 44b3663 exactly. New rollout requires scope and
environment approval, private Stripe configuration, SELECT-only RPC/RLS/index
preflight, source-drift check and live disposable integration acceptance. No
checkout/portal deployment is bundled. Code rollback cannot undo projected rows;
RC v8 rollback also loses additive multi-link reconciliation.

Recovery PR #2 head cba84fea is still draft/DIRTY, with no checks/reviews. Source
merge preview conflicts only in the audit history. Reproduced P2: failed
personalization invalidation after a saved limitation is not retried; Retry can
clear the error with stale context still fresh. Lachlan retains ownership; no
branch/source change or merge. Combined native acceptance is blocked by draft
readiness, this defect and live Recovery persistence/RLS/AI acceptance. Explicit
review decision on the inert Customize omission remains open.

StoreKit is separate: restart outstanding, both runtimes Ready, no eligible
native destination; Xcode still says iOS 26.5 missing. No new runtime repair or
test was attempted in this continuation. Coordinate restart with open work,
then resolve platform recognition and run cancellation before the existing four
StoreKit cases. Original legal/PDF work is preserved; disk 24 GiB free.

## Detailed evidence

Private setup workspace:
`/Users/evanlycos/Documents/Codex/2026-11-08/continue-execute-s-native-migration-in/`

- `outputs/billing-reconciliation-review.txt`: six-issue disposition, exact
  verification boundaries, Recovery finding and required user actions.
- `outputs/billing-deployment-review.txt`: exact scope, deployment sequence,
  preflight and known-good rollback reference.
- `outputs/billing-reconciliation-package.zip`: candidate runtime/tests,
  rollback sources, manifests and detailed controlled scenario evidence.
- Scratch: `work/billing-integration-20261108/` and `work/recovery-review/`.

Next owner action: review the concrete package and select the intended Stripe
integration environment; configure secrets privately only after that decision.
Live provider/native acceptance remains open and must record the exact deployed
version, actual event/delivery, backend state and device result separately.
