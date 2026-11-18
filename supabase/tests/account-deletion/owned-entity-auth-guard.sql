-- Isolated rollout candidate. Keep this outside the automatic migration chain
-- until the deployed baseline, rollout order and rollback are reviewed.
begin;
set local lock_timeout = '5s';

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
begin
  foreach entity in array entity_tables loop
    execute format(
      'alter table public.%I
         add constraint account_deletion_live_owner
         foreign key (owner_id) references auth.users (id)
         on delete restrict not valid',
      entity
    );
  end loop;
end;
$$;

commit;
