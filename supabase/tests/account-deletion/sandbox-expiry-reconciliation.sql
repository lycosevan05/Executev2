-- Staged Sandbox due-owner inventory. Install after verified-revenuecat-billing.sql.
begin;
set local lock_timeout = '5s';

create function public.list_due_verified_sandbox_app_store_owners(p_project text)
returns setof jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
begin atomic
  select subject.value
  from public.user_subscriptions s
  cross join lateral (select coalesce(
    s.data->>'revenuecat_current_period_end',
    case when s.data->>'store' = 'app_store' then s.data->>'current_period_end' end
  ) as raw) deadline
  cross join lateral (select case
    when deadline.raw ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
      and pg_input_is_valid(deadline.raw, 'timestamptz')
      then deadline.raw::timestamptz
  end as due_at) period
  cross join lateral (select public.read_verified_billing_subject(p_project, null, s.owner_id) as value) subject
  where s.owner_id is not null and s.data->>'user_id' = s.owner_id::text
    and s.data->>'verified_billing_project' = p_project
    and s.data->>'verified_billing_environment' = 'SANDBOX'
    and s.data->>'revenuecat_environment' = 'SANDBOX'
    and s.data->>'revenuecat_plan' = 'premium'
    and period.due_at <= statement_timestamp()
    and subject.value->>'state' = 'active'
  order by period.due_at, s.owner_id
  limit 12;
end;

revoke all on function public.list_due_verified_sandbox_app_store_owners(text)
  from public, anon, authenticated, service_role;
grant execute on function public.list_due_verified_sandbox_app_store_owners(text)
  to service_role;
notify pgrst, 'reload schema';
commit;
