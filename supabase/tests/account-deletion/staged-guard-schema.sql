-- Read-only catalog snapshot for the guarded-deletion change surface.
-- Capture before adding the guards, after installation, and after reversal.
with namespaces as (
  select oid, nspname, nspowner, nspacl
  from pg_catalog.pg_namespace
  where nspname in (
    'execute_apple_grant_private', 'execute_checkout_private', 'execute_deletion_guard',
    'execute_deletion_private', 'execute_revenuecat_private', 'execute_storage_deletion_guard'
  )
), relations as (
  select c.oid, n.nspname, c.relname, c.relowner, c.relacl, c.relrowsecurity, c.relforcerowsecurity
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p') and (
    n.oid in (select oid from namespaces)
    or (n.nspname = 'auth' and c.relname = 'users')
    or (n.nspname = 'storage' and c.relname = 'objects')
    or (n.nspname = 'public' and c.relname in (
      'ai_plans', 'app_users', 'custom_checklist_items', 'daily_logs', 'food_logs',
      'goal_progress_entries', 'goals', 'injury_profiles', 'meal_plans',
      'nutrition_profiles', 'readiness_check_ins', 'saved_recipes', 'user_ai_contexts',
      'user_page_layouts', 'user_profiles', 'user_subscriptions', 'workout_logs',
      'workout_plans', 'workout_profiles'
    ))
  )
), catalog as (
  select 'schema' as object_type, nspname::text as object_name,
    jsonb_build_array(pg_catalog.pg_get_userbyid(nspowner), nspacl) as definition from namespaces
  union all
  select 'table', format('%I.%I', r.nspname, r.relname),
    jsonb_build_array(pg_catalog.pg_get_userbyid(r.relowner), r.relacl, r.relrowsecurity, r.relforcerowsecurity)
  from relations r
  union all
  select 'column', format('%I.%I.%I', r.nspname, r.relname, a.attname),
    jsonb_build_array(a.attnum, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
      a.attidentity, a.attgenerated, pg_catalog.pg_get_expr(d.adbin, d.adrelid))
  from relations r
  join pg_catalog.pg_attribute a on a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  union all
  select 'policy', format('%I.%I.%I', r.nspname, r.relname, p.policyname),
    jsonb_build_array(p.permissive, p.roles, p.cmd, p.qual, p.with_check)
  from relations r
  join pg_catalog.pg_policies p on p.schemaname = r.nspname and p.tablename = r.relname
  union all
  select 'constraint', format('%I.%I.%I', r.nspname, r.relname, c.conname),
    jsonb_build_array(pg_catalog.pg_get_constraintdef(c.oid), c.convalidated)
  from relations r join pg_catalog.pg_constraint c on c.conrelid = r.oid
  union all
  select 'trigger', format('%I.%I.%I', r.nspname, r.relname, t.tgname),
    jsonb_build_array(pg_catalog.pg_get_triggerdef(t.oid), t.tgenabled)
  from relations r join pg_catalog.pg_trigger t on t.tgrelid = r.oid and not t.tgisinternal
  union all
  select 'index', format('%I.%I.%I', r.nspname, r.relname, i.relname),
    jsonb_build_array(pg_catalog.pg_get_indexdef(x.indexrelid), x.indisvalid)
  from relations r
  join pg_catalog.pg_index x on x.indrelid = r.oid
  join pg_catalog.pg_class i on i.oid = x.indexrelid
  union all
  select 'function', format('%I.%I(%s)', n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid)),
    jsonb_build_array(pg_catalog.pg_get_functiondef(p.oid), pg_catalog.pg_get_userbyid(p.proowner), p.proacl)
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where p.prokind in ('f', 'p') and (n.oid in (select oid from namespaces)
    or (n.nspname = 'public' and p.proname in (
      'pin_authenticated_legacy_entity_owner',
      'retire_account_stripe_subscription_rows',
      'close_account_upload_admission',
      'begin_account_upload_dispatch',
      'finish_account_upload_dispatch',
      'close_and_list_account_upload_dispatches',
      'begin_exact_account_upload_dispatch',
      'close_and_list_guarded_account_upload_dispatches',
      'close_account_billing_projection',
      'begin_guarded_stripe_checkout',
      'acknowledge_guarded_stripe_checkout',
      'close_and_list_guarded_stripe_checkouts',
      'finish_guarded_stripe_checkout_drain',
      'execute_has_apple_grant',
      'execute_capture_apple_grant',
      'execute_close_apple_grants',
      'execute_confirm_apple_grant_revoked',
      'ensure_revenuecat_customer_id',
      'attach_verified_revenuecat_alias',
      'resolve_revenuecat_identity',
      'retire_revenuecat_identity',
      'activate_verified_billing_owner',
      'read_verified_billing_subject',
      'apply_verified_billing_projections'
    )))
)
select coalesce(jsonb_agg(to_jsonb(catalog) order by object_type, object_name), '[]'::jsonb) as guard_schema
from catalog;
