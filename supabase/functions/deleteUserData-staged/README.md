# W09 staged endpoint and rollback

The separate `deleteUserData-staged` endpoint is an opt-in rehearsal candidate.
Keep the hosted `deleteUserData` v6 route and its gateway configuration in place.
The native rollout barrier remains disabled. This endpoint has no production
activation mode.

## Artifact verification

The captured v6 provider bundle SHA-256 is
`b3f05b26de612852a9a7778cf1f9453b71e243ac8e084f0725b7597f67d9d297`.
The independently captured source ZIP has SHA-256
`f3d53503a70affeac88a1ad30255a9a53937dcf13619ab6a2a0ec0e913aa87e7`.
The ZIP contains three verified source members. The Supabase JS import specifies
only its major version, and the ZIP supplies neither a resolved dependency lock
nor a deployment revision. Supabase also documents that its CLI download omits
dependency configuration. [Supabase download and restore guidance](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)

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
   compatibility gates are ready, enable only the exact disposable account.
   Set `EXECUTE_STAGED_DELETION_MODE` to `disposable-account`, set
   `EXECUTE_STAGED_DELETION_PROJECT_URL` to the exact approved project origin
   matching `SUPABASE_URL`, and set `EXECUTE_STAGED_DELETION_OWNER_UUID`
   to the exact synthetic Auth UUID. The staged endpoint refuses access to
   Stripe. An inventoried Stripe reference stops deletion before any writes.
   A billing-linked rehearsal needs separately reviewed code and authorization.
4. Preserve Auth, Storage byte and database snapshots for the target and an
   unrelated synthetic owner. Rehearse rejection for a matching email on a
   different UUID, successful target cleanup, and an injected partial failure
   with the original UUID able to retry. Run the upload coordination and
   delayed-provider checks in the same environment and use independent Auth,
   Storage API, and SQL readback. A normal success response cannot close the gate.
5. Exercise the shutoff while the original release and its v6 route are intact.
   Remove the affirmative acceptance mode from the staged runtime. Verify all
   reachable staged instances again reject the disposable identity before Auth
   lookup or service work. An environment request is evidence only after that
   rejection has been read back. If instances can retain old settings, rehearse
   blocking the staged route at its entry point before using this design for
   release. Unset the UUID and project approval after shutoff. A request already
   admitted can still complete. Determine its actual phase before further tests.

## Rehearse database compatibility and rollback independently

Side-by-side Edge Function routing shares the same database in any one project.
An endpoint switch cannot reverse constraints, triggers, policies or ledger
entries. Review exact proposed SQL and its reverse steps against a disposable
baseline before approval. Keep the database objects additive during mixed-version
operation. Prove metadata and fixture-row differences before and after each
phase, including normal existing-client ownership reads and writes, account
reuse, ordinary provider reconciliation, and Storage through its supported API.

Rehearse the following states on an approved disposable database:

- Baseline schema and current clients with the staged route off.
- Additive schema with existing clients, synthetic ownership and provider
  fixtures, and the staged route off.
- Staged-only execution with a controlled failure before Auth removal.
- Staged route shut off. Preserve pending deletion state and record completed
  provider, Storage and Auth phases.
- Approved reversal of the exact candidate schema changes, followed by
  independent schema and surviving-record readback. Repeat with an incomplete
  deletion in the fixture so reversal cannot silently reopen writes or restore
  a retired provider association.

Do not drop closure or retirement state while a partially completed cleanup or
a pending provider retry still depends on it. If preserving those markers is
necessary, keep the matching compatibility mechanism until their safety window
is independently verified. Endpoint rollback stops admitting new requests.
Restoration of canceled subscriptions or deleted bytes, rows and Auth accounts
requires a separate recovery decision.

The tests in this directory exercise the local HTTP admission and shutoff
contract. Hosted deployment, provider replay, destructive lifecycle, native
route change and combined database reversal remain pending.
