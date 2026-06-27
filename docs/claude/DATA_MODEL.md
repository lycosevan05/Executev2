# DATA_MODEL.md — Execute (Executev3) Database Schema Reference

Structure-only reference for the Supabase/Postgres schema behind Execute. This
doc describes **tables, columns, types, constraints, RLS, and relationships**.
Runtime/flow behavior (Realtime self-echo, optimistic writes, SWR, cache
hydration) lives in `KEY_FLOWS.md`, not here.

> **Authoritative sources.** Table *names* come from the `TABLES` map in
> `src/api/backendClient.js` and the `entity_tables` array in the base
> migration. Column *definitions* are quoted verbatim from the migration SQL in
> `supabase/migrations/`. Nothing here is inferred from a table name.

---

## 1. The single most important fact: the generic JSONB-bag schema

There are **two kinds of tables** in this database:

1. **19 "entity" tables** — all created by one templated `do $$ ... $$` loop in
   `20260526000000_supabase_backend.sql`. Every one of them has the **exact same
   8 columns**. They are *not* relationally modeled. All entity-specific
   fields (a plan's days, a food log's macros, a profile's goals, …) live
   untyped inside a single `data jsonb` column.
2. **1 standalone table** — `house_listings`, created with real, named,
   typed columns in `20260622000000_house_board.sql`. This is the only table
   with a domain-specific column layout.

This means: **for the 19 entity tables, you cannot learn an entity's fields from
the database schema.** The DB only knows about the wrapper columns. The real
shape of each entity lives in application code (the JS that reads/writes
`data`), and is therefore *unverified at the schema level*. Wherever this doc
would otherwise list entity-specific columns, it marks them **UNVERIFIED (lives
in `data` JSONB)**.

---

## 2. The entity-table template (applies to all 19 entity tables)

Every entity table is created with this exact definition (verbatim from
`supabase/migrations/20260526000000_supabase_backend.sql`, lines 40–49, with
`%I` resolving to each table name):

```sql
create table if not exists public.<table> (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid default auth.uid(),
  owner_email text default (auth.jwt() ->> 'email'),
  created_by text default (auth.jwt() ->> 'email'),
  user_email text default (auth.jwt() ->> 'email'),
  data jsonb not null default '{}'::jsonb,
  created_date timestamptz not null default now(),
  updated_date timestamptz not null default now()
)
```

### Column reference (identical for all 19 entity tables)

| Column         | Type          | Null?    | Default                       | Notes |
|----------------|---------------|----------|-------------------------------|-------|
| `id`           | `uuid`        | not null | `gen_random_uuid()`           | Primary key. Requires `pgcrypto` (created at top of migration). |
| `owner_id`     | `uuid`        | nullable | `auth.uid()`                  | The Supabase auth user id. Set automatically from the JWT on insert. No FK to `auth.users` is declared. |
| `owner_email`  | `text`        | nullable | `auth.jwt() ->> 'email'`      | Email from the JWT at insert time. |
| `created_by`   | `text`        | nullable | `auth.jwt() ->> 'email'`      | Email from the JWT at insert time. Used as an ownership key in RLS and as a query filter. |
| `user_email`   | `text`        | nullable | `auth.jwt() ->> 'email'`      | Email from the JWT at insert time. Redundant with `created_by`; both exist as alternate ownership keys. |
| `data`         | `jsonb`       | not null | `'{}'::jsonb`                 | **The entity payload.** All entity-specific fields live here. GIN-indexed. |
| `created_date` | `timestamptz` | not null | `now()`                       | Row creation time. |
| `updated_date` | `timestamptz` | not null | `now()`                       | Maintained by a `before update` trigger (see below). |

### Indexes (created per entity table)

For every entity table, the loop creates (lines 119–124):

- `<table>_owner_id_idx` on `(owner_id)`
- `<table>_owner_email_idx` on `(owner_email)`
- `<table>_created_by_idx` on `(created_by)`
- `<table>_created_date_idx` on `(created_date desc)`
- `<table>_updated_date_idx` on `(updated_date desc)`
- `<table>_data_gin_idx` — **GIN index on `(data)`** (enables JSONB containment / `data->>key` filtering)

### `updated_date` trigger

A `before update` row trigger named `touch_backend_record` fires on every entity
table and runs `public.touch_backend_record()`, which sets
`new.updated_date = now()` (lines 3–11, 126–132). So `updated_date` is
**server-maintained on update** — application-supplied values are overwritten.

> Note: `created_date`/`updated_date` are also set client-side in
> `recordPayload`/`mergeUpdate` in `backendClient.js`, but the trigger is the
> authority for `updated_date` on updates.

### Realtime

Each entity table is added to the `supabase_realtime` publication (lines
134–139, guarded against duplicate/undefined-object errors). So all 19 entity
tables emit Realtime `postgres_changes` events. (Behavior of those events is
covered in `KEY_FLOWS.md`.)

---

## 3. The 19 entity tables (name mapping)

All share the template above. The app refers to them by an **entity name**; the
DB knows them by their **table name**. Mapping is the `TABLES` map in
`src/api/backendClient.js` (lines 50–70), cross-checked against `entity_tables`
in the migration (lines 16–36):

| Entity name (app)      | Table name (DB)            | Purpose (from app usage; payload UNVERIFIED) |
|------------------------|----------------------------|----------------------------------------------|
| `AIPlan`               | `ai_plans`                 | Master AI-generated plan (7-day overview). One canonical "master plan" per user. |
| `CustomChecklistItem`  | `custom_checklist_items`   | User-defined checklist/habit items. |
| `DailyLog`             | `daily_logs`               | Per-day log (steps, sleep, water, mood, energy, weight, etc.). Keyed by date inside `data`. |
| `FoodLog`              | `food_logs`                | Logged food entries (per day). |
| `Goal`                 | `goals`                    | User goals. |
| `GoalProgressEntry`    | `goal_progress_entries`    | Progress entries against a goal. |
| `InjuryProfile`        | `injury_profiles`          | Injury/limitation data feeding workout generation. |
| `MealPlan`             | `meal_plans`               | Per-day generated meal plan. |
| `NutritionProfile`     | `nutrition_profiles`       | Nutrition invariant (targets, macros, preferences). |
| `ReadinessCheckIn`     | `readiness_check_ins`      | Daily readiness check-ins. |
| `SavedRecipe`          | `saved_recipes`            | Saved recipes. |
| `User`                 | `app_users`                | App-level user record (distinct from Supabase `auth.users`). |
| `UserAIContext`        | `user_ai_contexts`         | Cached AI context for a user (invalidated on vitals logging). |
| `UserPageLayout`       | `user_page_layouts`        | Per-user page/widget layout customization. |
| `UserProfile`          | `user_profiles`            | User invariant profile (demographics, training level). |
| `UserSubscription`     | `user_subscriptions`       | Subscription/entitlement row. **Sole writer is the `revenuecatWebhook` edge function** (device never writes it — see CLAUDE.md). |
| `WorkoutLog`           | `workout_logs`             | Logged workout sessions. |
| `WorkoutPlan`          | `workout_plans`            | Per-day generated workout plan. |
| `WorkoutProfile`       | `workout_profiles`         | Workout invariant (equipment, schedule, preferences). |

> **Every "Purpose" / payload description above is UNVERIFIED at the schema
> level.** The DB stores all of it as opaque `data jsonb`. Treat these as
> app-intent annotations, not column guarantees. To verify a payload's real
> shape, read the JS that writes that entity (e.g. `generateInitialPlanBundle.js`,
> `vitalsLog.js`, `subscription.js`), not the migrations.

---

## 4. Application-level record shape (`flattenRecord`) — schema vs. app drift

The DB row shape (8 columns) is **not** what application code sees. The
`EntityClient` in `backendClient.js` reshapes every row on read via
`flattenRecord` (lines 102–113):

```js
function flattenRecord(row) {
  const data = row.data && typeof row.data === 'object' ? row.data : {};
  return {
    ...data,                       // JSONB payload spread to the top level
    id: row.id,
    created_by: row.created_by || data.created_by || row.owner_email || data.user_email || '',
    user_email: data.user_email || row.user_email || row.owner_email || '',
    created_date: row.created_date,
    updated_date: row.updated_date,
  };
}
```

So the **in-app record** = `data`'s keys spread flat, plus `id`, `created_by`,
`user_email`, `created_date`, `updated_date`. Notably:

- `owner_id` and `owner_email` are **dropped** from the flattened view (they
  exist in the DB but never surface to most app code).
- `created_by` / `user_email` are **coalesced** from several sources, so the
  value the app reads may differ from the raw column value. The precedence
  differs between the two: `created_by` is column-first
  (`row.created_by || data.created_by || row.owner_email || data.user_email`),
  while `user_email` is data-first
  (`data.user_email || row.user_email || row.owner_email`).
- On write, `recordPayload` (lines 115–131) duplicates `created_by`/`user_email`
  into *both* the wrapper columns and inside `data`. This intentional
  duplication is what makes the RLS ownership-key OR-chain (below) reliable.

**Drift summary.** There are **no TypeScript types or interfaces mirroring any
of these tables.** `src/api/` contains only `backendClient.js` (which is
`// @ts-nocheck`). The only `.ts` file in `src/` is `src/utils/index.ts` (a
single `createPageUrl` helper, no record types). The `@typedef`s that exist
(`src/lib/nutrition/computeNutritionPlan.js`) describe nutrition-calculation
inputs, **not** DB record shapes. Therefore:

- The de-facto record contract is `flattenRecord` / `recordPayload`, not a type.
- There is no compile-time check that `data` payloads match anything.
- "Schema drift" here is structural by design: the DB is generic; all typing is
  absent.

### Server-side filtering implication

`_select` (lines 202–224) maps query criteria to SQL: `id`, `created_by`, and
`user_email` filter against **real columns**; any other key filters against
`data->>key` (the JSONB path, line 181–183). So the only first-class queryable
columns are `id`, `created_by`, `user_email` (plus the date columns for
ordering); everything else is a JSONB extraction backed by the GIN index.

---

## 5. RLS policies (entity tables)

RLS is **enabled** on every entity table (line 53). Four policies per table
(SELECT/INSERT/UPDATE/DELETE), all sharing the same ownership predicate.

**SELECT — "read own records"** (lines 60–71), `using`:

```sql
auth.role() = 'service_role'
or owner_id = auth.uid()
or owner_email = (auth.jwt() ->> 'email')
or created_by = (auth.jwt() ->> 'email')
or user_email = (auth.jwt() ->> 'email')
```

**INSERT — "insert own records"** (lines 73–84): same predicate in `with check`.

**UPDATE — "update own records"** (lines 86–104): same predicate in **both**
`using` and `with check`.

**DELETE — "delete own records"** (lines 106–117): same predicate in `using`.

Key points:

- A row is "yours" if **any** of four ownership keys match the caller:
  `owner_id` (uuid), or any of `owner_email` / `created_by` / `user_email`
  (email from JWT). This OR-chain is why writes duplicate the email into
  multiple columns.
- `service_role` bypasses ownership entirely (used by edge functions — e.g.
  the RevenueCat webhook writing `user_subscriptions`).
- Policies are dropped-if-exists then recreated, so re-running the migration is
  idempotent.

---

## 6. `house_listings` (standalone, real columns)

The only table with a domain-specific layout. Created in
`20260622000000_house_board.sql`. Backs the public, no-login
`executelabs.ca/house` board (see `legal/house.html`). Verbatim definition
(lines 11–26):

```sql
create table if not exists public.house_listings (
  id            uuid primary key default gen_random_uuid(),
  title         text,
  url           text,
  gist          text,
  neighbourhood text,
  price         integer,
  beds          text,
  baths         text,
  tags          jsonb not null default '[]'::jsonb,
  gym           text,
  misc          text,
  added_by      text,
  votes         jsonb not null default '{}'::jsonb,   -- { "<name>": "love" | "maybe" | "pass" }
  created_at    timestamptz not null default now()
);
```

| Column          | Type          | Null?    | Default              | Notes |
|-----------------|---------------|----------|----------------------|-------|
| `id`            | `uuid`        | not null | `gen_random_uuid()`  | Primary key. |
| `title`         | `text`        | nullable | —                    | |
| `url`           | `text`        | nullable | —                    | |
| `gist`          | `text`        | nullable | —                    | Free-text summary. |
| `neighbourhood` | `text`        | nullable | —                    | |
| `price`         | `integer`     | nullable | —                    | |
| `beds`          | `text`        | nullable | —                    | Stored as text, not numeric. |
| `baths`         | `text`        | nullable | —                    | Stored as text, not numeric. |
| `tags`          | `jsonb`       | not null | `'[]'::jsonb`        | Array of tags. |
| `gym`           | `text`        | nullable | —                    | |
| `misc`          | `text`        | nullable | —                    | |
| `added_by`      | `text`        | nullable | —                    | Display name typed on device (no auth). |
| `votes`         | `jsonb`       | not null | `'{}'::jsonb`        | Map `{ "<name>": "love" \| "maybe" \| "pass" }` (comment in SQL). |
| `created_at`    | `timestamptz` | not null | `now()`              | Note: `created_at`, **not** `created_date` (unlike entity tables). |

Other facts:

- Index: `house_listings_created_at_idx` on `(created_at desc)` (line 28).
- RLS **enabled** (line 30) but **fully permissive** — `for select/insert/
  update/delete` all `using (true)` / `with check (true)` (lines 38–41). Anyone
  with the `anon` key can read and write. Intentional: public unlisted board,
  no auth (see header comment). No ownership enforcement.
- `replica identity full` (line 44) so Realtime DELETE/UPDATE events carry the
  full old row.
- Added to `supabase_realtime` publication, guarded so re-runs don't error
  (lines 47–59).
- **Not** in the `TABLES` map / not an `EntityClient`. Accessed directly via the
  Supabase client by the house board page, not through the generic entity API.
- No `updated_date` column and no `touch_backend_record` trigger (it has no
  update-timestamp concept).

---

## 7. Relationships overview

- **No foreign keys are declared anywhere.** Not between entity tables, not to
  `auth.users`. `owner_id` *holds* `auth.uid()` but is not a DB-enforced FK.
- **Relationships are by convention, inside `data`** (and via the email/uid
  ownership keys), not via DB constraints. E.g. a `WorkoutPlan`/`MealPlan`
  relates to a date and to the master `AIPlan` through fields stored in `data`
  (UNVERIFIED — see the generation code in `src/lib/plans/` for the actual
  linking fields).
- **Ownership graph:** every entity row is tied to a user through the four
  ownership keys (`owner_id` / `owner_email` / `created_by` / `user_email`),
  which is also the unit RLS enforces on. This is the only schema-level
  "relationship" between rows and the authenticated user.
- `app_users` (`User` entity) is **separate** from Supabase's `auth.users`.
  Auth identity comes from `auth.users` (managed by Supabase, not in these
  migrations); `app_users` is an application-level record in the generic
  entity store.
- `house_listings` is **standalone** — no relationship to any entity table or
  to auth.

---

## 8. What is NOT verifiable from the schema (read these to go deeper)

- The actual field set of any entity's `data` JSONB — read the writer code:
  `generateInitialPlanBundle.js`, `src/lib/plans/*`, `src/lib/vitalsLog.js`,
  `src/lib/subscription.js`, `src/lib/personalizationSync.js`, etc.
- `auth.users` and other Supabase-managed schemas (not defined in these
  migrations).
- Edge-function-only behavior (e.g. `revenuecatWebhook` writing
  `user_subscriptions` under `service_role`) — structure of what it writes is
  still just `data jsonb`.

---

## Last verified against

- `supabase/migrations/20260526000000_supabase_backend.sql` (entity-table
  template, indexes, trigger, RLS, storage bucket/policies, realtime publication)
- `supabase/migrations/20260622000000_house_board.sql` (`house_listings` table,
  permissive RLS, replica identity, realtime)
- `src/api/backendClient.js` (`TABLES` map, `EntityClient`, `flattenRecord`,
  `recordPayload`, `mergeUpdate`, `_select` server-filter logic)
- `src/utils/index.ts` (confirmed: no record types — only `createPageUrl`)
- `src/lib/nutrition/computeNutritionPlan.js` (confirmed: `@typedef`s are
  calculation inputs, not table mirrors)
- Glob of `src/**/*.ts` and `src/**/*.d.ts` (confirmed: no TypeScript types
  mirroring any table)
