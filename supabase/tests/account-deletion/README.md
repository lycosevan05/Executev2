# W09 · Account-deletion race

## Candidate for UUID-owned entities

`owned-entity-auth-guard.sql` adds an immediate `ON DELETE RESTRICT` foreign key
from `owner_id` to `auth.users(id)` on all 19 Execute entity tables. When an
owned write commits first, the database preserves Auth so cleanup can be
retried. When hard Auth removal commits first, the write cannot create an
orphan. This uses the database's referential locks at the actual Auth boundary
instead of relying on the Edge Function to win the interval between requests.

The transaction installs the constraints with a bounded lock wait. `NOT VALID`
preserves historical rows and enforces new references. Collect aggregate orphan
counts before a staged rollout and decide how to handle any historical orphans.
Review the effect on admin-side user removal because these constraints require
explicit cleanup first. Each entity already has an `owner_id` index in the
baseline. No constraint cascades into application records.

Run against a local PostgreSQL 17 distribution that includes `pgcrypto`:

```sh
python3 supabase/tests/account-deletion/test_owned_entity_auth_guard.py \
  --postgres-bin /path/to/postgresql/bin
```

The runner creates and shuts down its own disposable cluster, connects over its
private Unix socket, applies the six repository migrations, and then applies the
candidate SQL. Its Auth and Storage schemas are synthetic. The two
transaction-order cases wait for the expected database lock before committing
the first transaction. The fixture also checks that pre-existing rows, an
unrelated authenticated write and the legacy billing projection keep their
current behavior. PostgreSQL error `23503` is the intended loser in each
transaction order.

All four groups passed locally on PostgreSQL 17.12 with the full six-migration
E59 chain. The candidate installed 19 constraints alongside the 19 existing
restrictive ownership policies. The existing 35 Deno deletion fixtures also
passed.

## Extension for authenticated writes to legacy entities

`authenticated-legacy-owner-guard.sql` is an opt-in extension to the UUID
deletion guard. Installation rolls back if the expected immediate FK is
missing on any of the 19 tables. On an authenticated insert or
update that would leave `owner_id` null, the trigger verifies the complete
E58 legacy email predicate, including the subscription JSON owner when present.
It then makes the request's verified Auth UUID authoritative for that row.
PostgreSQL checks the modified row against RLS after the trigger runs. The
separate email check keeps a newly assigned UUID from bypassing the legacy
ownership checks. [PostgreSQL policy and trigger ordering](https://www.postgresql.org/docs/17/sql-createpolicy.html)

The FK handles both transaction orders once the UUID is set. If the write
commits first, it blocks Auth removal until explicit cleanup retries. If Auth
removal commits first, it rejects the write. A returning email can use a new
Auth UUID because the fence is keyed to the account, and writes on existing
UUID-owned rows continue through the existing policy. A legacy PATCH may
return a newly authoritative `owner_id`. Existing null-owner rows are promoted
only when an authenticated write qualifies, so review historical ownership
and verify client compatibility before staging the extension.

The same native PostgreSQL 17.12 runner passed five additional groups. It
checked all 19 triggers, both lock orders, using the same email with a new UUID,
unchanged historical rows, matching and conflicting legacy fields, the real
`patch_record` RPC, and compatibility with an email-only provider projection.
These use synthetic Auth and Storage schemas and the full six-migration chain.
They do not verify either hosted API.

## Extension for Auth liveness on unbound entities

`live-auth-legacy-policy.sql` adds a restrictive policy for the authenticated
role to all 19 tables. Unbound rows must satisfy both the existing exact-email
ownership rules and a check that the caller's UUID still exists in Auth. The
policy applies to existing and proposed rows across SELECT, DELETE, INSERT, and
UPDATE. UUID-bound rows continue through current ownership rules and the UUID FK.
The private lookup accepts no caller-supplied ID and returns only whether the
current UUID exists. Keep its schema outside the exposed API schema list and
verify the installing role can read Auth. The service role and provider write
contracts are unaffected.

The staged fixture checks all 19 policy definitions, normal authorized legacy
reads and deletes, a missing subject's predicate result, and service-role and
UUID-bound reads. This is a statement-level Auth lookup. The write-side FK
still coordinates row writes and Auth removal. Legacy rows awaiting cleanup
can remain visible to a matching current account, so prove account reuse and
cleanup before rollout.

## Local Auth and Storage lifecycle

The [W04 disposable stack](../native-auth/README.md#start-the-dedicated-stack)
also runs the official Storage service. From a repository checkout with the
Supabase JS dependencies in Deno's module cache, run the W09 lifecycle against
that unlinked stack after verifying its loopback bindings.

```sh
python3 supabase/tests/account-deletion/run_storage_lifecycle.py --stack-dir "$fixture"
```

On a fresh checkout with an empty module cache, first run
`deno check --no-lock supabase/tests/account-deletion/storage-lifecycle.ts`
to cache the repository's Supabase JS imports. The lifecycle runner separately
checks the stack identity and published ports before obtaining credentials.
During the lifecycle, Deno can only connect to the exact local API endpoint.
No hosted project, Stripe API, or Edge Function deployment is involved.

The fixture signs in a fresh owner and uploads a file. It also uploads a nested
file under that owner's prefix through the service client. It reads the bytes
back, then invokes Execute's deletion orchestration and its production Storage,
PostgREST and Auth adapters against the local APIs. The run must verify recursive
inventory scoped to the target UUID, absence by listing and exact object path
after deletion, and hard Auth removal. An unrelated owner's file must remain
readable. A new Auth user reusing the deleted account's email must receive a
different UUID and upload normally. The runner cleans up the synthetic paths
and users it created. Purge the disposable stack after use if cleanup fails.

The E62 run passed against local Supabase CLI v2.101.0, Auth v2.188.1,
Storage v1.54.1, PostgREST v14.10 and the PostgreSQL image 17.6.1.106.
It passed with the six baseline migrations and again after installing all
three opt-in entity guards on the same disposable stack. The 35 offline
deletion fixtures passed independently.

This covers the sequential API lifecycle. The staged acceptance below still
requires verification of coordinated in-flight uploads, provider projections
and retry behavior. Use the Storage API for uploads and deletion. Supabase
stores file metadata in PostgreSQL and object bytes in the Storage backend.
Keep the managed Storage schema read-only. Bucket policies can use PostgreSQL
RLS for supported access control. [Supabase Storage schema](https://supabase.com/docs/guides/storage/schema/design) · [Supabase Storage ownership](https://supabase.com/docs/guides/storage/security/ownership)

## Authenticated upload admission during deletion

`storage-upload-admission-guard.sql` is an opt-in policy candidate for the
`uploads` bucket. It uses the verified Auth UUID and lasts across cleanup
retries. The service-only `close_account_upload_admission(uuid)` RPC locks
that owner's Auth row and records a private marker. The restrictive insert
and update policies require a live Auth row and open admission. A concurrent
permission check waits for an earlier closure transaction, then evaluates the
committed marker. A hard Auth delete removes the marker in the same database
transaction. A replacement owner using the same email receives a different
UUID and starts with open admission.

Apply the candidate only to a verified isolated fixture. From the repository
root, after starting the dedicated loopback W04 stack described above, run

```sh
docker exec -i supabase_db_execute-w04-e59 psql -X -U postgres -d postgres \
  -v ON_ERROR_STOP=1 < supabase/tests/account-deletion/storage-upload-admission-guard.sql
python3 supabase/tests/account-deletion/test_storage_upload_admission_guard.py \
  --stack-dir "$fixture"
```

Against Storage v1.54.1 and PostgreSQL 17.6.1.106, the test held a closure
transaction open and observed the ordinary authenticated Storage upload waiting
on it in PostgreSQL. After the closure committed, the API refused the upload.
An unrelated owner's upload succeeded while the target request waited. The test
also verified denial of overwrites, the original bytes, the service-only RPC,
idempotent retry with Auth intact, API cleanup, and hard Auth deletion. An upload
using the old session was still denied after the private marker was removed.
The replacement UUID could upload successfully. The runner uses actual
synthetic Auth sessions and performs all file reads and writes through Storage
APIs.

The exact uploader version checks RLS in a preliminary permission transaction.
Its later metadata commit runs under the Storage service's elevated role after
the byte upload. An upload already admitted can therefore complete after a
closure. This candidate controls new standard uploads and overwrites made by
authenticated users. A deployment design still needs to coordinate earlier
requests and verify other write channels, including service uploads, signed
uploads and resumable uploads. Keep deletion disabled until those paths, the
supported object cleanup, and staged retries are verified. [Pinned Storage uploader source](https://github.com/supabase/storage/blob/v1.54.1/src/storage/uploader.ts)

### Track outstanding upload requests

`storage-upload-dispatch-guard.sql` adds a service-only ledger for the writer
boundary. It requires the admission guard above. Before each actual Storage
send, the trusted writer registers the verified Auth UUID and obtains a fresh
dispatch ID and an exact, canonical object name in `uploads`. The writer uses
that name for a single request and acknowledges the dispatch only after it has
a definitive terminal result. An acknowledgment can be retried. A missing
or ambiguous result keeps the dispatch pending, including after a process
restart. A timeout, a missing file, or a file listing alone cannot establish
that the request has finished. Each new send must have a separate registration.

The deletion service closes admission and queries pending dispatches together.
The existing Auth row lock orders closure and registration. A nonempty result
stops cleanup and preserves Auth for a retry. The ledger's foreign key also
prevents hard Auth removal while a dispatch is pending. Once the result is empty,
the service can take its fresh Storage inventory before cleanup. Each retry
checks the same Auth UUID. A new UUID can upload after reusing a deleted email.

```sh
docker exec -i supabase_db_execute-w04-e59 psql -XqAt -U postgres -d postgres \
  -v ON_ERROR_STOP=1 < supabase/tests/account-deletion/storage-upload-dispatch-guard.sql
python3 supabase/tests/account-deletion/test_storage_upload_dispatch_guard.py \
  --stack-dir "$fixture"
```

The fixture sends part of a real Storage request body and pauses before
completing the transfer. It checks that closure reports the pending dispatch
even with an empty inventory, rejects a new target registration, keeps the
target Auth account, and permits an unrelated owner to upload. After Storage
acknowledges the transfer, the test withholds the writer acknowledgment to
model a lost reply. The barrier stays closed until that acknowledgment arrives.
The final Storage inventory, cleanup, hard Auth deletion, and a same-email
replacement upload all use the real local APIs. Both this check and the
original upload admission check passed on Storage v1.54.1 and PostgreSQL
17.6.1.106 with the baseline migrations. They also passed with the three E61
entity guards and the E63 Stripe retirement guard installed. The sequential
E62 Storage lifecycle passed with those guards installed.

### Route app uploads through the ledger

The native Storage service and web and Capacitor photo and barcode flows use
`guardedStorageUpload`. The endpoint verifies the current Auth UUID and routes
new raw uploads to the canonical `uploads/<owner>/<filename>` path. It preserves
the bucket's MIME and size limits and refuses overwrites. A stored object,
verified duplicate or definite provider MIME or size rejection is terminal.
An unknown Storage outcome or lost final acknowledgment keeps the dispatch
pending until it can be independently reconciled.

For an approved isolated rollout, install
`storage-upload-exact-dispatch.sql` after the existing admission and dispatch
guards. Deploy and verify the canonical writer before distributing rebuilt
clients that depend on it. Retire pre-cutover clients and establish that
previously admitted direct, signed and resumable requests have finished. Account
for any external service-role or S3 writers before relying on the ledger.
Once ready, `storage-upload-writer-cutover.sql` blocks direct actor inserts and
updates in `uploads`, while retaining the existing read and delete policies.
The staged deletion route checks that this exact cutover is active in the same
database transaction in which it closes admission and inventories dispatches.
Hosted rollout and unknown-outcome reconciliation still need acceptance.

To roll back this candidate in a staged environment, stop dispatching new
writes and reconcile outstanding dispatches with their terminal results. Once
the ledger is empty, remove the three dispatch RPCs and the pending table in one
transaction. Preserve the earlier admission guard and account retry state
until every pending deletion has a reviewed outcome.

A future authorized Edge rollout must close admission and then take a fresh
inventory before removing objects. Keep the admission marker when cleanup
returns a retryable error. If rollout is rolled back, reconcile all existing
markers and incomplete deletions before removing the optional policies, RPC,
and private schema. The current Edge path and automatic migrations are
unchanged by this fixture.

## Remaining boundaries

- Auth hard-deletion prevents issuing refreshed tokens. An already-issued access
  token can remain valid until expiry. E58's legacy email branch compares JWT
  claims and row fields. The two extensions supply UUID binding for
  authenticated writes and Auth liveness for untouched legacy rows in the
  fixture. Validate both through real Auth and PostgREST, including transaction
  ordering and account reuse.
- Supabase documents Auth removal failing for Auth-owned Storage objects.
  Execute's cleanup contract is the configured bucket and its exact UUID prefix,
  which can also contain an object written with service credentials. Prove the
  configured Storage API's authorization, metadata and object-write ordering in
  staging. Use supported Storage APIs for physical cleanup.
- Stripe Checkout currently writes email attribution into provider metadata.
  Stripe and RevenueCat reconciliation use email keys, and the database RPC can
  create a row without a UUID. A permanent email block would suppress a new
  account using that address. Removing a temporary email block could admit an
  old delayed event. An immutable account UUID or explicit durable
  provider-to-owner binding is required where provider operations can outlive
  the deleted account. A legacy event without a trusted binding needs a separate
  reconciliation path and cannot be safely assigned by looking up the email
  alone.

## Retirement of known Stripe subscriptions

The opt-in `retired-stripe-subscription-guard.sql` candidate keeps late
projections from bringing back Stripe subscription IDs that account deletion
already verified and removed. The service-only RPC checks the same account and
row snapshot used by deletion. It removes matching rows and records a SHA-256
fingerprint for each of their Stripe references in one transaction. The private
ledger contains fingerprints only. A later projection containing one of those
references fails without recreating or overwriting the subscription row. A new
UUID using the same email can reconcile a different Stripe subscription ID.

The short retirement transaction takes an exclusive lock on the subscription
table. It waits for a writer already holding a row lock and then rechecks the
snapshot. Plain reads can continue. A writer that arrives after retirement
waits for the transaction to finish and then checks the committed fingerprints.
Lock acquisition times out after five seconds. Stripe-reference writes require
PostgreSQL's read-committed semantics so a fixed older snapshot cannot miss a
fingerprint. Measure contention and check isolation with the staged provider
paths before rollout.

```sh
python3 supabase/tests/account-deletion/test_retired_stripe_subscription_guard.py \
  --postgres-bin /path/to/postgresql/bin
```

The test uses the six baseline migrations, synthetic users and the existing
provider reconciliation RPC. It verifies exact snapshot checks, rollback of a
mixed-owner batch, a new UUID with the original email, both transaction orders,
and rejection through the legacy upsert path. Deno separately covers the
adapter's exact snapshots and stopping before provider cancellation when the
staged RPC is unavailable.

For a separately approved staging run, apply the candidate before setting
`EXECUTE_STAGED_STRIPE_RETIREMENT=1` on the candidate deletion function. Before
cleanup, the adapter checks that an empty RPC call works. During cleanup the
RPC must return exactly the expected row count. Keep the native deletion gate
closed through staged verification. To undo the candidate, clear the opt-in
setting first. Review removing the two `reject_retired_stripe_subscription_*`
triggers and the public retirement RPC in one transaction. Keep the private
fingerprints for rollback review because dropping enforcement permits previously
retired references again. Review retention separately.

The guard covers IDs present in the verified deletion snapshot. An unseen
Stripe ID, a projection that carries no retired ID, or an email-only RevenueCat
projection still needs durable provider attribution. The guard does not
coordinate Storage writes or supply the exact deployed v6 rollback artifact.

## Staged acceptance

1. Establish the exact v6 rollback artifact or provider-confirmed bytes. Review
   the isolated schema rollout and rollback. Apply the candidate only to a
   separately authorized isolated project after checking historical ownership
   counts and every path that deletes Auth users. If installed, remove the
   `live auth for legacy entities` policies before dropping their private
   function and schema. Then remove the
   `pin_authenticated_legacy_owner` triggers and their trigger function before
   dropping `account_deletion_live_owner` on the same 19 reviewed tables. Use
   one transaction for the reviewed schema rollback. Keep assigned UUIDs and
   review their attribution separately. The rollback cannot restore provider
   subscriptions or deleted accounts.
2. Design the durable deletion state around the old UUID. Acquire it before
   enumerating cleanup inputs, let existing transactions finish, and reject new
   writes under that owner while deletion is pending. Preserve narrowly scoped
   retry access after partial cleanup. Coordinate UUID and legacy entity writes,
   Storage, Stripe checkout and provider reconciliation. Retain a way to
   identify retired provider associations after Auth removal without suppressing
   a new UUID account.
3. In the isolated project, verify the writer-first and deletion-first outcomes
   through actual Auth, entity and Storage APIs. Exercise legacy writes, uploads
   under the owner prefix, a delayed provider event, an unrelated active
   account, a partial failure followed by retry, and a new UUID using the same
   email. Verify owner-scoped data plus the actual storage object state after
   the final attempt. Exercise a previously issued session under the intended
   lifetime and revocation contract.
4. Keep the native capability gated until staged results and the intended exact
   rollout both have independent acceptance. Deployment, provider events, and
   destructive hosted QA remain separately scoped.

References:
[Supabase Auth user management](https://supabase.com/docs/guides/auth/managing-user-data)
and
[PostgreSQL foreign-key constraints](https://www.postgresql.org/docs/17/ddl-constraints.html).

### Canonical upload route and writer cutover

The `guardedStorageUpload` Edge Function accepts an authenticated POST with
raw bytes, the `uploads` bucket, and a single `<Auth UUID>/<filename>` path.
The response supplies the canonical lowercase UUID path. Supported file types
and the 50 MiB ceiling match the bucket migration. The route registers the
exact destination through the service-only `begin_exact_account_upload_dispatch`
RPC before issuing a single non-overwriting Storage request. A matching Storage
receipt, verified duplicate, or explicit Storage MIME/size rejection completes
that dispatch. A transport loss,
unexpected Storage response, or uncertain database acknowledgment requires
operator reconciliation. A subsequent upload cannot acknowledge an earlier
dispatch. When the file is absent from a listing, its dispatch can still be
pending.

Install `storage-upload-exact-dispatch.sql` after the E64 admission and dispatch
candidates. Move supported clients onto the route before applying
`storage-upload-writer-cutover.sql` to the approved project. The service-only
`close_and_list_guarded_account_upload_dispatches` RPC verifies RLS and the
exact insert/update cutover policies in the same transaction as closing
admission and listing pending dispatches. A missing policy or a changed
predicate prevents closure. The cutover blocks ordinary
authenticated or anonymous Storage insert and update for `uploads`, and keeps
public reads and same-prefix authenticated deletes compatible with existing
policies. The guarded request uses the service credential. Its Storage
`owner_id` can be null, so the authenticated UUID prefix remains authoritative
for object lookup and cleanup. [Supabase Storage ownership](https://supabase.com/docs/guides/storage/security/ownership)

Before enabling staged deletion, inventory all deployed clients, provider-side
writers, signed-upload capabilities and resumable sessions for this bucket.
Keep deletion admission disabled while pre-cutover writes are still unresolved.
Verify that no outside service or S3 credential can send untracked writes and
that previously issued capabilities and sessions are expired or retired.
The pinned Storage implementation redeems existing signed upload capabilities
under its service role. [Supabase Storage signed upload handler](https://github.com/supabase/storage/blob/v1.54.1/src/http/routes/object/uploadSignedObject.ts)
Rehearse the exact project gateway and hosted Storage versions before relying
on the policy cutover. A client rollback that restores a direct writer requires
turning staged deletion off and resolving any outstanding dispatches before
reopening direct writes.

From a fresh verified W04 loopback stack, the following fixture installs the
four optional Storage candidates and exercises the production handler through
a loopback Deno HTTP listener with real Auth, PostgREST and Storage.

```sh
deno check --no-lock --node-modules-dir=none supabase/functions/guardedStorageUpload/index.ts
python3 supabase/tests/account-deletion/test_canonical_storage_upload.py --stack-dir "$fixture"
```

The E65 fixture passed normal upload, exact-path and unauthorized checks,
duplicate preservation, a terminal provider MIME rejection, direct insert and
update denial, denial of new authenticated signed-upload URLs, public and
owner reads, prefix-based owner deletion, admission closure, an unrelated
account, and a same-email replacement UUID. On local Storage v1.54.1, an
ordinary authenticated TUS creation returned HTTP 201 before cutover and was
canceled. After cutover, a new authenticated creation returned HTTP 403 from
RLS with no upload session or object. The E64 in-flight upload fixture also
passed with the canonical writer and cutover SQL installed. The seven offline handler tests separately
exercise uncertain storage and acknowledgment outcomes.
