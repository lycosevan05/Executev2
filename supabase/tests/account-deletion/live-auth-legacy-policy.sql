-- Staged candidate. Auth liveness for authenticated access to unbound entities.
begin;
set local lock_timeout = '5s';

create schema execute_deletion_guard;
revoke all on schema execute_deletion_guard from public, anon, authenticated, service_role;
grant usage on schema execute_deletion_guard to authenticated;

-- The caller cannot supply an ID or read auth.users directly.
create function execute_deletion_guard.current_auth_owner_exists()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select from auth.users as owner where owner.id = (select auth.uid())
  );
$$;

revoke all on function execute_deletion_guard.current_auth_owner_exists()
  from public, anon, authenticated, service_role;
grant execute on function execute_deletion_guard.current_auth_owner_exists() to authenticated;

do $$
declare
  entity text;
  entity_tables constant text[] := array[
    'ai_plans', 'app_users', 'custom_checklist_items', 'daily_logs', 'food_logs',
    'goal_progress_entries', 'goals', 'injury_profiles', 'meal_plans',
    'nutrition_profiles', 'readiness_check_ins', 'saved_recipes', 'user_ai_contexts',
    'user_page_layouts', 'user_profiles', 'user_subscriptions', 'workout_logs',
    'workout_plans', 'workout_profiles'
  ];
  live_legacy_owner constant text :=
    'owner_id is not null or (select execute_deletion_guard.current_auth_owner_exists())';
begin
  foreach entity in array entity_tables loop
    if not exists (
      select from pg_catalog.pg_policy
      where polname = 'entity ownership guard' and not polpermissive
        and polrelid = format('public.%I', entity)::regclass
    ) then
      raise exception 'Apply the E58 entity ownership guard before liveness on %', entity;
    end if;

    execute format(
      'create policy "live auth for legacy entities" on public.%I
       as restrictive for all to authenticated using (%s) with check (%s)',
      entity, live_legacy_owner, live_legacy_owner
    );
  end loop;
end;
$$;

commit;
