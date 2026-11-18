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

## Native rollout barrier and acknowledgement — E18

The current production AppEnvironment explicitly selects
awaitingServerVerification. SupabaseAccountService refuses BEFORE invoking the
function; Profile shows a temporary-unavailability message and disables both
confirmation entry and permanent deletion. No live capability probe is sent: the
legacy deployed handler does not restrict the request method/body, so probing it
could itself delete records. This temporary barrier is an open release blocker,
not removal of required account deletion.

After separately authorized deployment and independent revision/config readback,
an explicitly reviewed acceptance build can select verifiedServerRollout for a
newly authorized disposable account. The service then requires success true, no
error, results.authentication exactly deleted, a storage status and valid
nonnegative deleted-count statuses for every other result. Bare legacy success,
missing/malformed/partial/error acknowledgements and all
transport/decoding/provider failures remain unconfirmed; raw backend details are
not echoed. These client checks do not independently prove server-side cleanup,
and cannot replace database/storage/auth acceptance. Failed/unavailable requests
retain session, cache, navigation and draft permission. Enablement remains an
explicit source change; there is no user-supplied runtime bypass or implicit
flag defaulting to enabled.

33 unique native methods pass (8new contract regressions plus25affected existing
session/billing/Profile methods), distinct from unchanged E17's26server
fixtures. Normal simulator UI verifies the unavailable message, disabled
controls and Cancel/back to Home; no confirmation text or permanent action was
entered. Fresh independent14group SELECT before/after all UI preserves every
count and RAWhash. Generic normal signed iOS Debug build/strict-deep codesign
pass; no physical deletion test. The initial32native run overlaps the final33;
do not sum.

Rollback ZIP verification was deferred by the user. Two normal download controls
produced no observable download event or error; no archive/version binding was
obtained. Browser policy blocked chrome://downloads (HTTP/HTTPS only), and no
alternate-surface/filesystem/API workaround was attempted. Deployment is still
unapproved and not ready. Continue independent required native workflows while
this gate is outstanding.

## E41 source ZIP and E52 deployment verification

An existing Supabase-origin `deleteUserData.zip` was found in the earlier
workspace. All three members exactly match the independently captured E17 source
hashes. The archive SHA-256 is
`f3d53503a70affeac88a1ad30255a9a53937dcf13619ab6a2a0ec0e913aa87e7`. It contains
the source closure, including a major-version-only Supabase JS import. It
carries no resolved dependency lock or deployed revision.

The November 17 authorized CLI readback confirms that the current deployment is
version 6 with legacy JWT verification enabled. Its provider bundle digest is
`b3f05b26de612852a9a7778cf1f9453b71e243ac8e084f0725b7597f67d9d297`, which
matches the November 13 Management API snapshots. A fresh single-function source
download matches all three E41 ZIP members byte for byte. A usable compiled
archive with that digest or a resolved dependency lock remains outstanding for
reproducible rollback.

## Local entity ownership policy migration

`20261117000000_guard_entity_ownership.sql` adds one restrictive policy to each
of the 19 public entity tables. The restrictive policy intersects the existing
permissions for SELECT, INSERT, UPDATE and DELETE, including both sides of an
update. A populated owner UUID must match the caller. Rows without a UUID must
have at least one exact matching legacy email field and no conflicting populated
email fields. Subscription rows also check the legacy JSON user ID for
disagreement. Blank legacy fields are treated as unset.

The migration leaves legacy data, existing permissive policies, service-role
behavior and storage policies in place. Removing the named restrictive policy
from the same 19 tables reverses this schema change and restores the original
ownership rules. That schema rollback is independent of the compiled Edge
Function rollback artifact. The policy applies as a local migration candidate.
Live legacy-data compatibility and concurrent writes during deletion still
require acceptance.

## Exact change and ownership contract

`index.ts` authenticates through the existing shared helper and accepts POST
only (OPTIONS remains CORS). The request body cannot select an identity.
`handler.ts` redacts unexpected failures. The existing success envelope remains
`{ success: true, results }`. The native service now requires explicit
authentication removal and nonnegative storage/record deletion counts, rather
than trusting a success boolean. The real app remains unavailable for deletion
until the server rollout is independently verified.

`store.ts` gives a nonnull owner UUID authority over secondary email metadata.
It discovers legacy candidates across all ENTITY_TABLES with separate exact
email predicates restricted to `owner_id IS NULL`. At least one identity field
must match the authenticated email, and every other populated identity field
must agree. Empty strings and SQL null both leave a field unset and remain
distinct in conditional DELETEs. Subscription JSON `user_id` participates in
legacy attribution. A conflicting or malformed candidate stops the account
operation before any mutation. Email-less accounts use UUID ownership only. No
user email is interpolated into PostgREST `.or` syntax.

Legacy candidates and all UUID- or legacy-owned subscription rows are
inventoried in ordered pages of 100, bounded at 10,000 distinct candidates per
table. Overlapping scopes must observe the same attribution and Stripe
references for a given row ID. Legacy and subscription DELETEs batch IDs with
identical snapshot predicates and require the exact affected count. The
predicates include the current owner UUID or null, the inspected legacy identity
fields, and the singular and plural Stripe link fields for subscription rows.
The plural list is matched as JSONB, with separate predicates for a missing
field and explicit JSON null. A snapshot that changes before its DELETE is
preserved by the database predicates and a count mismatch stops cleanup before
authentication removal. Ordinary UUID-owned rows use the direct authoritative
UUID predicate. Subscription rows created after preflight remain for review and
block authentication removal when observed in the final absence check. Provider
references absent from all database rows cannot be discovered by this patch.

`deletion.ts` finishes legacy, subscription, and recursive upload inventory
before any mutation. It uses the billing projection's bounded link parser to
combine legacy single links with all known linked Stripe subscriptions. It
verifies every known subscription's metadata.user_id against the authenticated
UUID or email before canceling any. `billing.ts` permits only a genuine
resource_missing response or already-canceled status to skip cancellation; it no
longer treats arbitrary text containing “canceled subscription” as success.
Missing/mismatched legacy provider ownership metadata blocks cleanup for
reconciliation. It does not guess ownership from a customer email or cancel App
Store subscriptions. Stripe API version14.21.0/2024-04-10 is retained from the
local pre-change function; the observed deployed function has no Stripe path, so
adding cancellation requires separate billing/deployment authorization.

Uploads are traversed under the exact UUID prefix, paginated by stable name
order, with depth32 and total-entry10000 safety bounds,
invalid-path/unknown-entry/repeated-page rejection. File placeholders with real
IDs are removed too. Inventory completes before deleting objects; removal uses
batches of100. A fresh upload inventory must be empty before row deletion and
again after all row checks, immediately before auth removal. The final check
catches files left by a writer during row cleanup and preserves the ability to
retry. Limit/shape/failure conditions stop instead of silently reporting
success. Bucket-not-found is ignored only for the exact404/Bucket not found
shape; other storage errors fail closed.

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

### Concurrency acceptance still required

The
[isolated UUID ownership guard candidate](../../tests/account-deletion/README.md)
coordinates authoritative entity writes and hard Auth removal at the database
boundary. Its opt-in extension binds qualifying authenticated legacy writes
to the request's UUID before the FK check. Both are separate from automatic
migrations. Storage, untouched legacy records and delayed provider events
still need staged coordination.

E58 verified the ownership migration through isolated PostgREST and the full
local migration chain. Supabase Support accepted the request for the exact v6
compiled rollback artifact. The reply and digest-matching bytes are pending.

Before enabling account deletion, a staged design needs to coordinate the same
owner's authenticated entity and upload writes, in-flight database writes and
subscription provider projections during deletion. A durable deletion state with
retry access is a candidate. Any schema proposal must account for legacy email
rows and existing providers that project by email, define how delayed provider
events are handled after final deletion, and avoid suppressing a new UUID
account that legitimately uses the same email. Application checks alone cannot
coordinate database and provider writes. Keep provider cancellation and external
object cleanup retryable with Auth removal as the final step.

Prove this on a disposable isolated backend first. Hold a same-owner write in
flight while starting deletion, cover uploads and a delayed provider projection,
verify unrelated-owner writes still succeed, and check whether the app can retry
after a controlled partial failure. After all app and writer actions,
independently verify no deleted-owner records or objects returned, the old
session cannot read or write, and fresh sign-in follows the intended account
contract without inheriting old private data. Isolated proof, rollback
readiness, rollout approval and final disposable-account acceptance are separate
milestones.

## Reproducible local checks

Run from repository root with Deno2.8.1:

```sh
deno test --no-config --node-modules-dir=none --no-lock --deny-net --deny-env --deny-read --deny-write --deny-run supabase/functions/deleteUserData/deletion_test.ts supabase/functions/deleteUserData/sdk_test.ts supabase/functions/deleteUserData/handler_test.ts
deno check --no-config --node-modules-dir=none supabase/functions/deleteUserData/index.ts
deno fmt --check supabase/functions/deleteUserData
```

35 unique methods cover 30 in-memory orchestration/adapter/provider cases, four
HTTP boundary cases, and one actual Supabase SDK serialization case with
injected fetch. The six added cases cover conflicting ordinary and subscription
legacy identity, UUID authority, overlap instability, changed preconditions, and
a late subscription. Later regressions cover a late upload, multiple known
Stripe links and changed plural links. The late-upload retry removes only the
new owned file and reaches Auth exactly once. The SDK fixture verifies exact
quoted email, conditional DELETE by batched ID and owner scope, null and blank
predicates, JSON-path predicates, pagination/count, Storage payload and Auth
route. Dependencies can be resolved from the public package cache during module
loading. Runtime network, environment, file and process access are denied. These
are local fixtures. A separate loopback test used the actual deletion store and
SDK with PostgreSQL 17.12 and PostgREST 14.18 against the full local migration
chain. A missing list, explicit JSON null and an empty list matched their
snapshots. A changed list retained its row, then a fresh snapshot deleted that
row and preserved the foreign owner. Hosted PostgREST, realistic-account timing,
live providers and the native deletion lifecycle still require acceptance.
Earlier fixture counts overlap this run.

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
5. Read back the deployed revision/config before any destructive action. Keep
   the native rollout barrier active until this verification. Any acceptance
   build enabling verifiedServerRollout must be reviewed against the exact
   approved backend revision, and final release must include successful
   lifecycle acceptance; the disabled state cannot satisfy W09. Request separate
   destructive acceptance authorization for a **new, explicitly disposable
   account without preserved migration activity**. Start without any paid
   subscription. Capture owner/source/count/storage baseline for that account
   and foreign-owner sentinels through SELECT only; verify native
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
