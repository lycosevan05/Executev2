-- Structural rollback for the eight optional guarded-deletion SQL files.
-- Run only against the approved isolated project after both staged endpoints
-- are stopped and every admitted request has a known outcome.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- Prevent a writer from inserting any marker between the check and the drop.
lock table execute_storage_deletion_guard.closed_upload_admission,
           execute_storage_deletion_guard.pending_upload_dispatch,
           execute_deletion_private.retired_stripe_subscription
  in access exclusive mode;

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
  if exists (select from execute_storage_deletion_guard.closed_upload_admission)
    or exists (select from execute_storage_deletion_guard.pending_upload_dispatch)
    or exists (select from execute_deletion_private.retired_stripe_subscription) then
    raise exception 'pending deletion state requires reconciliation';
  end if;
  foreach entity in array entity_tables loop
    execute format('drop policy "live auth for legacy entities" on public.%I', entity);
    execute format('drop trigger pin_authenticated_legacy_owner on public.%I', entity);
    execute format('alter table public.%I drop constraint account_deletion_live_owner', entity);
  end loop;
end;
$$;
drop function public.pin_authenticated_legacy_entity_owner();
drop function execute_deletion_guard.current_auth_owner_exists();
drop schema execute_deletion_guard;
drop trigger reject_retired_stripe_subscription_insert on public.user_subscriptions;
drop trigger reject_retired_stripe_subscription_update on public.user_subscriptions;
drop function public.retire_account_stripe_subscription_rows(uuid, text, jsonb);
drop function execute_deletion_private.reject_retired_stripe_subscription();
drop function execute_deletion_private.stripe_subscription_fingerprints(jsonb);
drop table execute_deletion_private.retired_stripe_subscription;
drop schema execute_deletion_private;
drop function public.close_and_list_guarded_account_upload_dispatches(uuid);
drop policy "uploads require canonical writer for insert" on storage.objects;
drop policy "uploads require canonical writer for update" on storage.objects;
drop policy "account deletion uploads insert guard" on storage.objects;
drop policy "account deletion uploads update guard" on storage.objects;
drop function public.begin_exact_account_upload_dispatch(uuid, text);
drop function public.begin_account_upload_dispatch(uuid, text);
drop function public.finish_account_upload_dispatch(uuid, uuid);
drop function public.close_and_list_account_upload_dispatches(uuid);
drop table execute_storage_deletion_guard.pending_upload_dispatch;
drop function public.close_account_upload_admission(uuid);
drop function execute_storage_deletion_guard.current_owner_can_upload();
drop table execute_storage_deletion_guard.closed_upload_admission;
drop schema execute_storage_deletion_guard;
notify pgrst, 'reload schema';
commit;
