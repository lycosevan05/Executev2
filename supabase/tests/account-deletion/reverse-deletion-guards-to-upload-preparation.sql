-- Restore the E71 upload-preparation baseline after disabling deletion and
-- safely reversing the writer cutover, billing fence, checkout and custody.
-- Use a fresh administrative session after all admitted work is reconciled.
begin isolation level read committed;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local search_path = pg_catalog;

-- Let direct Storage transactions finish before taking the upload ledger locks.
-- The Storage policies and routines themselves stay installed.
lock table storage.objects in share mode;
lock table public.user_subscriptions in access exclusive mode;
lock table execute_deletion_private.retired_stripe_subscription,
           execute_storage_deletion_guard.closed_upload_admission,
           execute_storage_deletion_guard.pending_upload_dispatch
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
  if to_regprocedure('public.close_and_list_guarded_account_upload_dispatches(uuid)') is not null
    or exists (
      select from pg_policy where polrelid = 'storage.objects'::regclass
        and polname in ('uploads require canonical writer for insert', 'uploads require canonical writer for update')
    ) then
    raise exception 'reverse the writer cutover first';
  end if;
  if to_regprocedure('execute_storage_deletion_guard.current_owner_can_upload()') is null
    or to_regprocedure('public.close_account_upload_admission(uuid)') is null
    or to_regprocedure('public.begin_account_upload_dispatch(uuid,text)') is null
    or to_regprocedure('public.begin_exact_account_upload_dispatch(uuid,text)') is null
    or to_regprocedure('public.finish_account_upload_dispatch(uuid,uuid)') is null
    or to_regprocedure('public.close_and_list_account_upload_dispatches(uuid)') is null
    or (select count(*) from pg_policy where polrelid = 'storage.objects'::regclass
        and polname in ('account deletion uploads insert guard', 'account deletion uploads update guard')
        and not polpermissive) <> 2 then
    raise exception 'E71 upload preparation is incomplete';
  end if;
  if to_regnamespace('execute_checkout_private') is not null
    or to_regprocedure('public.begin_guarded_stripe_checkout(uuid,text)') is not null then
    raise exception 'reverse Stripe Checkout admission first';
  end if;
  if to_regnamespace('execute_apple_grant_private') is not null
    or to_regprocedure('public.execute_close_apple_grants(uuid,text,text)') is not null then
    raise exception 'reverse Apple grant custody first';
  end if;
  if to_regclass('execute_deletion_private.closed_billing_identity') is not null
    or to_regclass('execute_deletion_private.billing_projection_fence_key') is not null
    or to_regprocedure('public.close_account_billing_projection(uuid,text,jsonb)') is not null then
    raise exception 'reverse the billing projection fence first';
  end if;
  if exists (select from execute_deletion_private.retired_stripe_subscription) then
    raise exception 'Stripe retirement markers require reconciliation';
  end if;
  if exists (select from execute_storage_deletion_guard.closed_upload_admission)
    or exists (select from execute_storage_deletion_guard.pending_upload_dispatch) then
    raise exception 'pending upload state requires reconciliation';
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
notify pgrst, 'reload schema';
commit;
