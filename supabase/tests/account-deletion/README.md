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

## Remaining boundaries

- Auth hard-deletion prevents issuing refreshed tokens. An already-issued access
  token can remain valid until expiry. E58's restrictive entity policy preserves
  the matched legacy email branch for a null `owner_id`. It compares JWT claims
  and row fields without checking the existence of an Auth row. The nullable
  foreign key leaves that branch in place. Coordinate legacy writers with
  cleanup and enforce live Auth ownership across applicable access paths before
  declaring the account isolated. A liveness check alone would still leave the
  final-check race for transactions that observed the active account earlier.
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

## Staged acceptance

1. Establish the exact v6 rollback artifact or provider-confirmed bytes. Review
   the isolated schema rollout and rollback. Apply the candidate only to a
   separately authorized isolated project after checking historical ownership
   counts and every path that deletes Auth users. A schema rollback drops
   `account_deletion_live_owner` on the same 19 reviewed tables in one
   transaction. It does not reverse a provider cancellation or account deletion.
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
