-- One-round-trip partial update for entity tables (P2).
-- Replaces the client's read -> merge -> write pattern with a single
-- JSONB shallow merge (data || patch), which is equivalent to the old
-- top-level merge. updated_date is maintained by the existing
-- touch_backend_record trigger. SECURITY INVOKER so RLS applies to the
-- calling role.
create or replace function public.patch_record(p_table text, p_id uuid, p_patch jsonb)
returns setof jsonb
language plpgsql
security invoker
as $$
begin
  if p_table not in (
    'ai_plans',
    'custom_checklist_items',
    'daily_logs',
    'food_logs',
    'goals',
    'goal_progress_entries',
    'injury_profiles',
    'meal_plans',
    'nutrition_profiles',
    'readiness_check_ins',
    'saved_recipes',
    'app_users',
    'user_ai_contexts',
    'user_page_layouts',
    'user_profiles',
    'user_subscriptions',
    'workout_logs',
    'workout_plans',
    'workout_profiles'
  ) then
    raise exception 'patch_record: table % not allowed', p_table;
  end if;

  return query execute format(
    'update public.%I set
       data = data || $2,
       user_email = coalesce($2->>''user_email'', user_email),
       created_by = coalesce($2->>''created_by'', created_by)
     where id = $1
     returning to_jsonb(%I.*)',
    p_table, p_table
  ) using p_id, p_patch;
end;
$$;

grant execute on function public.patch_record(text, uuid, jsonb) to authenticated, anon, service_role;
