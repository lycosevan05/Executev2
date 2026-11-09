# Atomic entity patch regression checks

Run `npm ci` then `npm test` in this directory. This separate test package does not add a dependency to the web or native application. Node20 or later is required.

The20 groups use PGlite0.3.14 (PostgreSQL) with local roles, owner policies and synthetic records. They apply the old helper before the new migration to check both creation and ACL hardening. They verify invoker/RLS behavior, attribution preservation, denied billing updates and anonymous calls, invalid inputs, atomic merges, returned envelopes and rollback. No provider credentials or remote database connection is used.

`PGLITE_MODULE_PATH` optionally points to an already-installed PGlite module; `PATCH_RECORD_RESULTS_PATH` optionally selects the JSON result path. These are test-runner options only. A local pass does not establish remote PostgREST, authenticated native update or live guidance acceptance; verify those after the separately approved deployment.
