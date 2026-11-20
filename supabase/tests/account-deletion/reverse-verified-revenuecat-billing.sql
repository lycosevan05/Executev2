-- Clean-install reversal for the optional verified billing stage.
-- An enrolled cohort or any written projection needs a migration plan.
begin;
set local lock_timeout = '5s';
lock table public.user_subscriptions in exclusive mode;
lock table execute_revenuecat_private.billing_cohort in exclusive mode;
do $$
begin
  if exists (select from execute_revenuecat_private.billing_cohort)
     or exists (select from public.user_subscriptions where data ? 'verified_billing_project') then
    raise exception 'Verified billing has enrolled owners or projections' using errcode = '55000';
  end if;
end;
$$;
drop trigger reject_cohort_legacy_billing_write on public.user_subscriptions;
drop policy "verified billing insert is service owned" on public.user_subscriptions;
drop policy "verified billing update is service owned" on public.user_subscriptions;
drop policy "verified billing delete is service owned" on public.user_subscriptions;
drop function public.apply_verified_billing_projections(text,text,jsonb);
drop function public.read_verified_billing_subject(text,text,uuid);
drop function public.activate_verified_billing_owner(text,uuid,text);
drop function execute_revenuecat_private.reject_cohort_legacy_write();
drop table execute_revenuecat_private.billing_cohort;
notify pgrst, 'reload schema';
commit;
