-- Opt in only after applying owned-entity-auth-guard.sql to the isolated fixture.
begin;
set local lock_timeout = '5s';

create function public.pin_authenticated_legacy_entity_owner()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
declare
  actor_id uuid := auth.uid();
  actor_email text := nullif(auth.jwt() ->> 'email', '');
begin
  -- RLS checks the final NEW row after BEFORE triggers. Preserve the complete
  -- legacy predicate before replacing the null with an authoritative UUID.
  if actor_id is null or actor_email is null
     or (actor_email in (new.owner_email, new.created_by, new.user_email)) is not true
     or coalesce(nullif(new.owner_email, ''), actor_email) <> actor_email
     or coalesce(nullif(new.created_by, ''), actor_email) <> actor_email
     or coalesce(nullif(new.user_email, ''), actor_email) <> actor_email
     or (tg_table_name = 'user_subscriptions'
         and coalesce(nullif(new.data ->> 'user_id', ''), actor_email) <> actor_email)
  then
    raise exception using errcode = '42501', message = 'Legacy entity ownership is inconsistent';
  end if;

  new.owner_id := actor_id;
  return new;
end;
$$;

revoke execute on function public.pin_authenticated_legacy_entity_owner()
  from public, anon, authenticated, service_role;

do $$
declare
  entity text;
  relation regclass;
  entity_tables constant text[] := array[
    'ai_plans', 'app_users', 'custom_checklist_items', 'daily_logs', 'food_logs',
    'goal_progress_entries', 'goals', 'injury_profiles', 'meal_plans',
    'nutrition_profiles', 'readiness_check_ins', 'saved_recipes', 'user_ai_contexts',
    'user_page_layouts', 'user_profiles', 'user_subscriptions', 'workout_logs',
    'workout_plans', 'workout_profiles'
  ];
begin
  foreach entity in array entity_tables loop
    relation := format('public.%I', entity)::regclass;
    if not exists (
      select 1 from pg_catalog.pg_constraint
      where conname = 'account_deletion_live_owner' and conrelid = relation
        and confrelid = 'auth.users'::regclass and contype = 'f'
        and confdeltype = 'r' and not condeferrable
        and conkey = (select array[attnum] from pg_catalog.pg_attribute
                       where attrelid = relation and attname = 'owner_id' and not attisdropped)
        and confkey = (select array[attnum] from pg_catalog.pg_attribute
                        where attrelid = 'auth.users'::regclass and attname = 'id' and not attisdropped)
    ) then
      raise exception 'Apply the UUID deletion guard before binding legacy writes on %', relation;
    end if;

    execute format(
      'create trigger pin_authenticated_legacy_owner
       before insert or update on public.%I for each row
       when (new.owner_id is null and current_user = ''authenticated'')
       execute function public.pin_authenticated_legacy_entity_owner()',
      entity
    );
  end loop;
end;
$$;

commit;
