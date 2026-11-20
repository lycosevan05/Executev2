-- Optional compatibility read for the web and Capacitor clients.
-- Install after verified-revenuecat-billing.sql. Remove it before structural rollback.
begin;
set local lock_timeout = '5s';

create function public.read_execute_billing_projection()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  caller uuid := auth.uid();
  cohorts integer;
  provider_project text;
  provider_environment text;
  subject jsonb;
  projection jsonb;
begin
  if caller is null or not exists (select from auth.users where id = caller) then
    return jsonb_build_object('state', 'unavailable');
  end if;
  if execute_revenuecat_private.billing_owner_closed(caller) is distinct from false then
    return jsonb_build_object('state', 'unavailable');
  end if;
  select count(*), min(c.project), min(c.environment)
    into cohorts, provider_project, provider_environment
    from execute_revenuecat_private.billing_cohort c
    join execute_revenuecat_private.accounts a using (project, owner_key)
    where a.owner_id = caller;
  if cohorts = 0 then return jsonb_build_object('state', 'legacy'); end if;
  if cohorts <> 1 or provider_environment <> 'PRODUCTION' then
    return jsonb_build_object('state', 'unavailable');
  end if;

  subject := public.read_verified_billing_subject(provider_project, null, caller);
  if subject->>'state' <> 'active' or subject->>'owner_id' is distinct from caller::text then
    return jsonb_build_object('state', 'unavailable');
  end if;
  projection := subject->'subscription'->'data';
  return jsonb_build_object('state', 'verified', 'subscription', case when projection is not null then
    jsonb_build_object(
      'plan', projection->'plan', 'status', projection->'status', 'store', projection->'store',
      'current_period_start', projection->'current_period_start',
      'current_period_end', projection->'current_period_end',
      'cancel_at_period_end', projection->'cancel_at_period_end'
    )
    else null end);
end;
$$;

revoke all on function public.read_execute_billing_projection() from public, anon, authenticated, service_role;
grant execute on function public.read_execute_billing_projection() to authenticated;
notify pgrst, 'reload schema';
commit;
