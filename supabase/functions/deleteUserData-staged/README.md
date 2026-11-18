# W09 staged endpoint and rollback

The separate `deleteUserData-staged` endpoint is an opt-in rehearsal candidate.
Keep the hosted `deleteUserData` v6 route and its gateway configuration in
place. The native rollout barrier remains disabled. This endpoint has no
production activation mode.

## Artifact verification

The captured v6 provider bundle SHA-256 is
`b3f05b26de612852a9a7778cf1f9453b71e243ac8e084f0725b7597f67d9d297`. The
independently captured source ZIP has SHA-256
`f3d53503a70affeac88a1ad30255a9a53937dcf13619ab6a2a0ec0e913aa87e7`. The ZIP
contains three verified source members. The Supabase JS import specifies only
its major version, and the ZIP supplies neither a resolved dependency lock nor a
deployment revision. Supabase also documents that its CLI download omits
dependency configuration.
[Supabase download and restore guidance](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)

E64 independently rehashed the three dashboard-captured files in the archived
deletion evidence. All three matched their recorded per-file digests.

If a compiled candidate becomes available, compare the bytes to the recorded v6
digest before describing it as the deployed artifact:

```sh
test "$(shasum -a 256 "$v6_bundle" | awk '{print $1}')" = \
  b3f05b26de612852a9a7778cf1f9453b71e243ac8e084f0725b7597f67d9d297
```

Retain the confirmed revision, JWT configuration, and toolchain/dependency
manifest alongside any future deployable artifact. The source ZIP remains useful
for compatibility review. Preserving v6 in place makes byte-identical
replacement of v6 unnecessary for this staged route.

## Rehearse activation and shutdown

1. Use a separately approved disposable project and Auth identity. Capture the
   complete candidate source/dependency manifest, intended project, current
   gateway and API authentication settings, bucket, and exact staged database
   policy definitions. Verify the released clients keep using their existing
   route and that the native deletion gate is disabled.
2. After separate authorization, deploy only `deleteUserData-staged` to the
   approved project. Confirm gateway JWT verification is enabled and capture the
   staged revision. Leave acceptance settings unset and probe only the staged
   route. A valid POST to the staged route must receive `503` before the handler
   looks up Auth or creates a service client. Never send a probe to v6. Its
   deployed handler can mutate records without a POST method check.
3. Prove failure for an unauthenticated session and a different Auth UUID.
   Separately authorize any destructive trial. Once the write-coordination and
   compatibility gates are ready, enable only the exact disposable account. Set
   `EXECUTE_STAGED_DELETION_MODE` to `disposable-account`, set
   `EXECUTE_STAGED_DELETION_PROJECT_URL` to the exact approved project origin
   matching `SUPABASE_URL`, and set `EXECUTE_STAGED_DELETION_OWNER_UUID` to the
   exact synthetic Auth UUID. The staged endpoint refuses access to Stripe. An
   inventoried Stripe reference stops deletion before any writes. A
   billing-linked rehearsal needs separately reviewed code and authorization.
   The staged handler requires the canonical-writer cutover for the `uploads`
   bucket. The guarded RPC verifies the database policies and closes admission
   for the approved UUID in one transaction. The handler stops before cleanup if
   any dispatch remains pending or the response is unverified. After a verified
   drain it takes a fresh Storage inventory. Account for legacy clients,
   pre-cutover uploads, signed capabilities, resumable uploads and external
   privileged writers before hosted acceptance.
4. Preserve Auth, Storage byte and database snapshots for the target and an
   unrelated synthetic owner. Rehearse rejection for a matching email on a
   different UUID, successful target cleanup, and an injected partial failure
   with the original UUID able to retry. Run the upload coordination and
   delayed-provider checks in the same environment and use independent Auth,
   Storage API, and SQL readback. A normal success response cannot close the
   gate.
5. Exercise the shutoff while the original release and its v6 route are intact.
   Remove the affirmative acceptance mode from the staged runtime. Verify all
   reachable staged instances again reject the disposable identity before Auth
   lookup or service work. An environment request is evidence only after that
   rejection has been read back. If instances can retain old settings, rehearse
   blocking the staged route at its entry point before using this design for
   release. Unset the UUID and project approval after shutoff. A request already
   admitted can still complete. Determine its actual phase before further tests.

## Run the isolated hosted rehearsal

Use a fresh disposable project with its own project ref, database and Storage
bucket. Verify the ref for every linked CLI operation. Record the exact ref and
source revision privately. Apply the six tracked baseline migrations first.
Supabase provisions Auth and Storage in hosted projects, so omit the local
`bootstrap.sql` fixture. Capture the managed functions list, the baseline
`uploads` bucket configuration, and the following read-only catalog snapshot.
Use the same role and project for each catalog read.

```sh
guard_sql=supabase/tests/account-deletion
supabase db query --linked --workdir "$isolated_link" --file "$guard_sql/staged-guard-schema.sql"
```

Apply the first seven optional files listed in `GUARDS` in
`test_staged_schema_reversal.py` in order. Verify the canonical writer on the
isolated project before applying `storage-upload-writer-cutover.sql` as the
eighth file. Keep staged deletion off during these steps. Verify no deployed
client or external privileged writer targets this project. Use newly created
synthetic accounts for both the target and the unrelated control. Record the
control's exact Auth UUID, row and canonical Storage object hash immediately
before the deletion checks. Keep that control intact through structural
rollback. Read file bytes through the Storage API.
[Supabase Storage deletion guidance](https://supabase.com/docs/guides/storage/management/delete-objects)

After the lifecycle and any retries reach known terminal states, unset
`EXECUTE_STAGED_DELETION_MODE`. Use a valid fixture JWT to verify the staged
route responds `503` while shut off. Then remove both staged endpoints if they
were newly deployed for this rehearsal and verify that neither route remains
deployed. Remove only the rehearsal settings. Drain all admitted invocations and
maintain the isolated writer freeze through rollback.
[Supabase secrets](https://supabase.com/docs/guides/functions/secrets) ·
[Supabase Function deletion](https://supabase.com/docs/reference/cli/supabase-functions-delete)

With all eight optional SQL files installed, read counts from
`execute_storage_deletion_guard.closed_upload_admission`,
`execute_storage_deletion_guard.pending_upload_dispatch`, and
`execute_deletion_private.retired_stripe_subscription`. If all counts are zero
and admitted requests are terminal, apply `reverse-staged-guards.sql` as one
transaction against the same verified disposable project. The script takes
bounded locks and checks the three tables again before dropping any objects. It
has no conditional drops and aborts as a unit on an unexpected schema or busy
lock. Record exact forward files after any partial installation and reverse only
their reviewed changes.

Read `staged-guard-schema.sql` again and compare the `guard_schema` value to the
baseline. Verify the unrelated account, record and bytes independently,
including an ordinary authenticated read. Verify a disposable post-rollback
standard upload through Storage and remove only the exact synthetic object.
After recording the comparison, clean up the remaining synthetic objects, rows
and Auth user through their respective APIs. Schema, surviving data and endpoint
state are independent rollback evidence.

## Rehearse database compatibility and rollback independently

Side-by-side Edge Function routing shares the same database in any one project.
An endpoint switch cannot reverse constraints, triggers, policies or ledger
entries. Review exact proposed SQL and its reverse steps against a disposable
baseline before approval. Keep the database objects additive during
mixed-version operation. Prove metadata and fixture-row differences before and
after each phase, including normal existing-client ownership reads and writes,
account reuse, ordinary provider reconciliation, and Storage through its
supported API.

Rehearse the following states on an approved disposable database:

- Baseline schema and current clients with the staged route off.
- Additive schema with existing clients, synthetic ownership and provider
  fixtures, and the staged route off.
- Staged-only execution with a controlled failure before Auth removal.
- Staged route shut off. Preserve pending deletion state and record completed
  provider, Storage and Auth phases.
- Approved reversal of the exact candidate schema changes, followed by
  independent schema and surviving-record readback. Repeat with an incomplete
  deletion in the fixture so reversal cannot silently reopen writes or restore a
  retired provider association.

Do not drop closure or retirement state while a partially completed cleanup or a
pending provider retry still depends on it. If preserving those markers is
necessary, keep the matching compatibility mechanism until their safety window
is independently verified. Endpoint rollback stops admitting new requests.
Restoration of canceled subscriptions or deleted bytes, rows and Auth accounts
requires a separate recovery decision.

The tests in this directory exercise the local HTTP admission and shutoff
contract. The structural reversal rehearsal uses a fresh PostgreSQL fixture with
the six baseline migrations, the five E63 optional guards, the E64 dispatch
guard, and the E65 exact dispatch and canonical writer cutover.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 supabase/tests/account-deletion/test_staged_schema_reversal.py \
  --postgres-bin /path/to/postgresql/bin
```

It passed on PostgreSQL 17.12. The clean fixture recovered the exact baseline
schema export and preserved the existing unrelated row. Authenticated entity
writes and the billing reconciliation RPC worked before, during and after
installation. An unresolved upload dispatch, an upload closure, and a Stripe
retirement fingerprint each independently blocked reversal and preserved the
staged schema. The dispatch check also preserved the exact object path.

The rehearsal uses synthetic Auth and Storage schemas, with no Storage byte
operations or provider calls. Hosted deployment, provider replay, destructive
lifecycle, native route change and full hosted rollback remain pending.
