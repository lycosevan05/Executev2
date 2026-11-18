-- Intersect the existing entity policies with authoritative UUID ownership.
-- Legacy email matching is limited to rows without a UUID and with consistent
-- attribution. Existing policies still decide which operations are granted.
do $$
declare
  entity text;
  email_claim constant text := $expr$(select auth.jwt() ->> 'email')$expr$;
  ownership_guard text;
  entity_tables constant text[] := array[
    'ai_plans', 'custom_checklist_items', 'daily_logs', 'food_logs', 'goals',
    'goal_progress_entries', 'injury_profiles', 'meal_plans', 'nutrition_profiles',
    'readiness_check_ins', 'saved_recipes', 'app_users', 'user_ai_contexts',
    'user_page_layouts', 'user_profiles', 'user_subscriptions', 'workout_logs',
    'workout_plans', 'workout_profiles'
  ];
begin
  foreach entity in array entity_tables loop
    ownership_guard := format($policy$
      (select auth.role()) = 'service_role'
      or (
        (select auth.uid()) is not null
        and (
          owner_id = (select auth.uid())
          or (
            owner_id is null
            and nullif(%1$s, '') is not null
            and %1$s in (owner_email, created_by, user_email)
            and coalesce(nullif(owner_email, ''), %1$s) = %1$s
            and coalesce(nullif(created_by, ''), %1$s) = %1$s
            and coalesce(nullif(user_email, ''), %1$s) = %1$s
            %2$s
          )
        )
      )
    $policy$, email_claim, case when entity = 'user_subscriptions'
      then format('and coalesce(nullif(data ->> %L, %L), %s) = %s',
                  'user_id', '', email_claim, email_claim)
      else ''
    end);

    execute format(
      'create policy "entity ownership guard" on public.%I
       as restrictive for all to public using (%s) with check (%s)',
      entity, ownership_guard, ownership_guard
    );
  end loop;
end;
$$;
