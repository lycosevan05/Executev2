# Account deletion — prepared local safety change

**Not deployed. No live billing cancellation, storage/row deletion or auth
deletion has been run.** W09/G05 stay open. The existing preserved migration QA
account must never be used for destructive acceptance.

## Observed deployed baseline — read only

The signed-in dashboard Code view was independently inspected. Its three-file
source closure (index.ts, ../_shared/records.ts, ../_shared/cors.ts) was copied
through the editor UI and hashed in the private E17 evidence. Gateway Verify JWT
with legacy secret is ON and was not changed. No Test, Deploy or deletion
control was used.

The deployed entry point differs from the pre-change local Git source: it has
the unrestricted legacy email OR and returns success after table errors, but has
**no upload cleanup, Stripe cancellation or auth removal at all**. Its shared
table list includes all19entities including goal progress. The deployed cors
source matches local; shared records differs. Thus rolling back to local ef4ed0c
would not restore the observed deployed behavior. Use the captured deployed
closure as the source baseline, not that Git commit.

Deployment revision ID and packaged/dependency artifact were not exposed in the
inspected Code/Settings surfaces. The stock CLI help failed in the sandbox while
trying to write home telemetry, before any metadata query; no credential
automation or retry followed. Exact revision/dependency/config binding remains a
prerequisite to deployment approval. This is a review package, not an assertion
that a byte-reproducible deployment rollback is ready. Unknown legacy email
associations and concurrent writers remain acceptance limits.

## Exact change and ownership contract

`index.ts` authenticates through the existing shared helper and accepts POST
only (OPTIONS remains CORS). The request body cannot select an identity.
`handler.ts` redacts unexpected failures. The existing success envelope remains
`{ success: true, results }`, compatible with the standalone Swift
AccountService. No Swift code changed.

`store.ts` deletes UUID-owned rows plus separately encoded legacy email matches
**only where owner_id IS NULL**. A nonnull foreign owner always wins over
matching email metadata. No user email is interpolated into PostgREST `.or`
syntax. All existing ENTITY_TABLES, including goal progress, are supplied by the
shared constant. Email-less accounts use UUID ownership only. Subscription
enumeration includes UUID ownership and null-owner legacy email
columns/data.user_id, ordered and paginated in pages of100, with
duplicate-page/no-progress checks and ID deduplication. It replaces the
old10-record cutoff. Provider references absent from all database rows cannot be
discovered by this patch; do not claim a complete provider-account audit.

`deletion.ts` finishes subscription and recursive upload inventory before any
mutation, then verifies every referenced Stripe subscription's metadata.user_id
against the authenticated UUID or email before canceling any. `billing.ts`
permits only a genuine resource_missing response or already-canceled status to
skip cancellation; it no longer treats arbitrary text containing “canceled
subscription” as success. Missing/mismatched legacy provider ownership metadata
blocks cleanup for reconciliation. It does not guess ownership from a customer
email or cancel App Store subscriptions. Stripe API version14.21.0/2024-04-10 is
retained from the local pre-change function; the observed deployed function has
no Stripe path, so adding cancellation requires separate billing/deployment
authorization.

Uploads are traversed under the exact UUID prefix, paginated by stable name
order, with depth32 and total-entry10000 safety bounds,
invalid-path/unknown-entry/repeated-page rejection. File placeholders with real
IDs are removed too. Inventory completes before deleting objects; removal uses
batches of100. A fresh inventory must be empty before row deletion, and fresh
row checks must be empty before auth removal. Limit/shape/failure conditions
stop instead of silently reporting success. Bucket-not-found is ignored only for
the exact404/Bucket not found shape; other storage errors fail closed.

`_shared/records.ts` has four **type-only** parameter corrections: use
ReturnType of the concrete createServiceClient factory rather than generic
createClient, preventing SDK generic inference from collapsing writes to never.
No shared-helper executable expression changed. The baseline independently
reproduced2existing helper errors; the final complete deletion entry point
checks successfully against the actual cached SDK.

## Failure and concurrency limits

This is not a transaction across Stripe, Storage, Postgres and Auth. A
cancellation may succeed before a later cancellation fails. Storage or some
tables may be deleted before a later table fails. Authentication is removed
last; failures retain sign-in where possible to allow retry. A retry skips
subscriptions already canceled or gone and resumes cleanup. No automatic refund,
subscription recreation or data restoration is attempted.

Fresh absence checks detect records/uploads appearing before those checks.
Another device or provider webhook can still write between a final check and
auth deletion. There is no server deletion fence, cross-resource lock or
atomicity guarantee in this patch. Offset pagination can fail safely on repeated
pages but cannot establish a consistent snapshot under arbitrary concurrent
writes. Existing broad legacy RLS policies are not changed or certified by this
function-local owner guard. Concurrent-write, active-session/re-login and legacy
ownership release gates therefore remain open. A stronger fence/ownership
migration would require a separately reviewed schema/function proposal and
authorization.

Missing provider metadata, historical changed email, excessive storage
depth/count, stale provider references or incomplete inventory require operator
review. An error is preferable to canceling another account's subscription or
deleting its data.

## Reproducible local checks

Run from repository root with Deno2.8.1:

```sh
deno test --no-config --node-modules-dir=none --no-lock --deny-net --deny-env --deny-read --deny-write --deny-run supabase/functions/deleteUserData/deletion_test.ts supabase/functions/deleteUserData/sdk_test.ts supabase/functions/deleteUserData/handler_test.ts
deno check --no-config --node-modules-dir=none supabase/functions/deleteUserData/index.ts
deno fmt --check supabase/functions/deleteUserData
```

26 unique methods:21in-memory orchestration/adapter/provider cases,4HTTP
boundary cases,1actual Supabase SDK serialization case with injected fetch.
Dependencies can be resolved from the public package cache during module
loading; runtime network, environment, file and process access are denied. No
real credentials or auth storage are used. The SDK fixture checks exact quoted
email, null-owner AND conditions, pagination/count, Storage payload and Auth
route against a fake endpoint. It is not a live database, Stripe, Supabase
deployment, native deletion UI or physical test. Earlier20/21/25method runs
overlap the final26; do not sum them.

## Proposed rollout — review before execution

1. Review the committed diff/manifest, provider-metadata behavior, bounds,
   residual race and shared type-only correction. Keep this function unavailable
   for acceptance if any prerequisite fails. No schema migration or global
   function deploy is part of the change.
2. With separately authorized read-only access, confirm the intended project's
   existing function revision, shared dependencies, API gateway JWT settings and
   configured bucket/provider environment by **presence**, never export secrets.
   Capture the currently deployed source/config privately as the real rollback
   artifact. The local pre-change Git source is only a candidate rollback until
   it is compared to the deployed revision.
3. Resolve any deployed-source divergence. Freeze the exact approved candidate
   hash and the exact verified previous deployed artifact. Keep gateway
   authentication enabled. Do not rotate credentials, alter other providers or
   settings, or bundle unrelated pending functions/migrations.
4. Request distinct deployment authorization naming only deleteUserData and its
   listed shared dependencies. After approval, deploy only that function with
   normal tooling to the verified intended project; preserve current JWT
   verification. Do not execute deployment from this document without that
   approval. This document provides no authorization.
5. Read back the deployed revision/config before any destructive action. Request
   separate destructive acceptance authorization for a **new, explicitly
   disposable account without preserved migration activity**. Start without any
   paid subscription. Capture owner/source/count/storage baseline for that
   account and foreign-owner sentinels through SELECT only; verify native
   confirmation/cancel before any actual deletion.
6. Only after explicit destructive approval, exercise deletion,
   partial-failure/retry, local purge and private re-login behavior;
   independently verify that only designated rows/objects/auth identity were
   removed and foreign/unrelated records remain. Never query/output credentials,
   tokens or authentication storage. Existing migration QA must be untouched.
7. Any test that cancels or changes a subscription needs its own explicit
   billing-mutation scope and approved test provider/account. Fixture coverage
   does not authorize Sandbox or live cancellation. App Store cancellation
   remains a manual subscription-management step, separately confirmed.
8. User performs changed-flow physical acceptance after normal signing/install
   readiness; simulator/database/fixture/physical results stay separate. Record
   exact outcomes before advancing W09/G05. Concurrent-write/fence/RLS gates
   need explicit evidence/proposal, not a success toast.

## Rollback — separately authorized, not executed

Before deployment, archive the verified previous **deployed** entry point and
shared closure, environment-name inventory (no values), JWT config and revision
identifiers. Abort if unavailable. Prepared source can be dropped/reverted
locally without touching deployed state. The pre-change local function and
shared helper are available at ef4ed0c162dd3b641415109b44358c30be5bd65c; they
are not proof of the deployed revision.

After deployment, stop further deletion tests on any unexpected
ownership/provider/storage outcome. With separate approval, deploy the captured
previous function closure only to the same verified project, preserving
JWT/config. Read back that revision. Do not globally revert shared
files/functions or apply migrations. Restoring the old function also restores
its known unsafe legacy email behavior, so do not resume destructive acceptance
until an approved safer candidate is available.

**Code rollback cannot undo canceled subscriptions, removed objects/rows or auth
deletion.** Recover data only from pre-approved backup/restoration procedures
under separate authorization; never recreate billing or real accounts
automatically. A post-partial-failure rollback may prevent forward retry
behavior, so inspect exact completed phases first. Do not promise transactional
recovery. Deployment, billing mutation and destructive acceptance remain
unapproved here.
