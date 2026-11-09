-- Atomic entity updates for the native client and the web RPC fast path.
-- Caller RLS and table privileges remain authoritative. Ownership columns are
-- immutable here; subscription truth is reserved for provider reconciliation.
begin;

create or replace function public.patch_record(p_table text, p_id uuid, p_patch jsonb)
returns setof jsonb
language plpgsql
security invoker
set search_path = pg_catalog
as $$
begin
  if p_table is null or p_table not in (
    'ai_plans', 'custom_checklist_items', 'daily_logs', 'food_logs',
    'goals', 'goal_progress_entries', 'injury_profiles', 'meal_plans',
    'nutrition_profiles', 'readiness_check_ins', 'saved_recipes',
    'app_users', 'user_ai_contexts', 'user_page_layouts', 'user_profiles',
    'workout_logs', 'workout_plans', 'workout_profiles'
  ) then
    raise exception using errcode = '22023', message = 'patch_record: table not allowed';
  end if;
  if p_id is null or p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception using errcode = '22023', message = 'patch_record: ID and object patch required';
  end if;

  return query execute format(
    'update public.%I as target
       set data = target.data || $2, updated_date = now()
     where target.id = $1
     returning to_jsonb(target.*)',
    p_table
  ) using p_id, p_patch;
end;
$$;

revoke all on function public.patch_record(text, uuid, jsonb) from public, anon;
grant execute on function public.patch_record(text, uuid, jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
commit;
