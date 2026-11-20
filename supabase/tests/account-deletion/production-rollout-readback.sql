-- Read-only aggregate on Executev2. The caller must verify the linked ref.
-- A zero count is current catalog evidence, not evidence of client migration.
with baseline as (
  select
    exists (select from storage.buckets where id = 'uploads') as uploads_bucket,
    to_regprocedure('public.begin_exact_account_upload_dispatch(uuid,text)') is not null as exact_dispatch,
    to_regprocedure('public.close_and_list_guarded_account_upload_dispatches(uuid)') is not null as writer_cutover,
    to_regprocedure('public.close_account_billing_projection(uuid,text,jsonb)') is not null as billing_fence,
    to_regprocedure('public.read_verified_billing_subject(text,text,uuid)') is not null as verified_billing,
    to_regprocedure('public.read_execute_billing_projection()') is not null as compatible_client_read,
    to_regnamespace('execute_apple_grant_private') is not null as apple_custody,
    to_regnamespace('execute_checkout_private') is not null as checkout_admission,
    to_regnamespace('cron') is not null as scheduler,
    (select count(*) from pg_constraint where conname = 'account_deletion_live_owner') as guarded_entities,
    (select count(*) from pg_policy where polrelid = to_regclass('storage.objects')
      and polname in ('uploads require canonical writer for insert', 'uploads require canonical writer for update')
      and not polpermissive) as direct_writer_cutover_policies
), billing as (
  select count(*) filter (where data ? 'verified_billing_project') as tagged_rows,
         count(*) filter (where data->>'verified_billing_environment' = 'PRODUCTION') as tagged_production_rows,
         count(*) filter (where nullif(data->>'revenuecat_app_user_id','') is not null
           and (owner_id is null or not data ? 'verified_billing_project')) as unverified_legacy_revenuecat_rows,
         count(*) filter (where nullif(data->>'stripe_subscription_id','') is not null
           or case when jsonb_typeof(data->'stripe_subscription_ids') = 'array'
             then jsonb_array_length(data->'stripe_subscription_ids') > 0 else false end) as stripe_linked_rows
  from public.user_subscriptions
)
select * from baseline cross join billing;
