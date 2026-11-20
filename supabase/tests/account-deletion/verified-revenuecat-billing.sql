-- Optional verified-only cohort over the E73 ledger and billing fence.
-- In an isolated project, activate a pre-enrolled fresh owner only after
-- independent inventory has verified there are no legacy billing assets.
begin;
set local lock_timeout = '5s';

create table execute_revenuecat_private.billing_cohort (
  project text collate "C" not null,
  owner_key bytea not null,
  environment text not null check (environment in ('SANDBOX', 'PRODUCTION')),
  primary key (project, owner_key),
  foreign key (project, owner_key)
    references execute_revenuecat_private.accounts(project, owner_key)
);
revoke all on execute_revenuecat_private.billing_cohort from public, anon, authenticated, service_role;

-- The legacy policies allow owner writes. Protect UUID-backed projections at
-- the row boundary while allowing the ordinary legacy path for other owners.
create policy "verified billing insert is service owned" on public.user_subscriptions
  as restrictive for insert to anon, authenticated
  with check (not (data ? 'verified_billing_project'));
create policy "verified billing update is service owned" on public.user_subscriptions
  as restrictive for update to anon, authenticated
  using (not (data ? 'verified_billing_project'))
  with check (not (data ? 'verified_billing_project'));
create policy "verified billing delete is service owned" on public.user_subscriptions
  as restrictive for delete to anon, authenticated
  using (not (data ? 'verified_billing_project'));

create function execute_revenuecat_private.reject_cohort_legacy_write()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if new.data ? 'verified_billing_project' then
    return new;
  end if;
  if exists (
    select
    from execute_revenuecat_private.billing_cohort c
    join execute_revenuecat_private.accounts a using (project, owner_key)
    join auth.users u on u.id = a.owner_id
    where a.owner_id = new.owner_id or exists (
      select from execute_deletion_private.billing_projection_identities(new) i
      where i in (lower(btrim(u.email)), u.id::text)
    )
  ) then
    raise exception 'Verified billing owner requires the UUID writer' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger reject_cohort_legacy_billing_write before insert or update on public.user_subscriptions
  for each row execute function execute_revenuecat_private.reject_cohort_legacy_write();

create function public.activate_verified_billing_owner(p_project text, p_owner_id uuid, p_environment text)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  owner_key_value bytea;
  owner_email_value text;
  current_environment text;
begin
  if p_environment is null or p_environment not in ('SANDBOX', 'PRODUCTION')
     or current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Invalid verified billing activation' using errcode = '22023';
  end if;
  select u.email into owner_email_value from auth.users u where u.id = p_owner_id for share;
  if owner_email_value is null or owner_email_value !~ '^[^[:space:]@]+@[^[:space:]@]+$' then
    raise exception 'Verified billing requires a current Auth owner' using errcode = '55000';
  end if;
  -- Match deletion's Auth-then-projection ordering. This lock also drains
  -- legacy writes before the no-overlap check and activation commit.
  lock table public.user_subscriptions in exclusive mode;
  if execute_revenuecat_private.billing_owner_closed(p_owner_id) is distinct from false then
    raise exception 'Verified billing admission is closed or unavailable' using errcode = '55000';
  end if;
  owner_key_value := execute_revenuecat_private.identity_fingerprint(p_project, 'owner', p_owner_id::text);
  perform 1 from execute_revenuecat_private.accounts a
    where a.project = p_project and a.owner_key = owner_key_value and a.owner_id = p_owner_id
    for update;
  if not found then
    raise exception 'Verified billing requires an enrolled owner' using errcode = '55000';
  end if;
  select c.environment into current_environment
    from execute_revenuecat_private.billing_cohort c
    where c.project = p_project and c.owner_key = owner_key_value;
  if found then
    if current_environment = p_environment then return true; end if;
    raise exception 'Verified billing environment already bound' using errcode = '23514';
  end if;
  if exists (
    select from execute_revenuecat_private.billing_cohort c
    join execute_revenuecat_private.accounts a using (project, owner_key)
    where a.owner_id = p_owner_id
  ) or exists (
    select from public.user_subscriptions s
    where s.owner_id = p_owner_id or exists (
      select from execute_deletion_private.billing_projection_identities(s) i
      where i in (lower(btrim(owner_email_value)), p_owner_id::text)
    )
  ) then
    raise exception 'Existing billing requires verified migration' using errcode = '23514';
  end if;
  insert into execute_revenuecat_private.billing_cohort (project, owner_key, environment)
    values (p_project, owner_key_value, p_environment);
  return true;
end;
$$;

create function public.read_verified_billing_subject(
  p_project text, p_identifier text default null, p_owner_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  binding execute_revenuecat_private.accounts%rowtype;
  owner_email_value text;
  cohort_environment text;
  existing_row public.user_subscriptions%rowtype;
  subscription_value jsonb;
begin
  if (p_identifier is null) = (p_owner_id is null) then
    raise exception 'One verified billing identity is required' using errcode = '22023';
  end if;
  if p_identifier is not null then
    select a.* into binding from execute_revenuecat_private.identifiers i
    join execute_revenuecat_private.accounts a using (project, owner_key)
    where i.project = p_project and i.identifier_key =
      execute_revenuecat_private.identity_fingerprint(p_project, 'customer', p_identifier);
  else
    select a.* into binding from execute_revenuecat_private.accounts a
      where a.project = p_project and a.owner_key =
        execute_revenuecat_private.identity_fingerprint(p_project, 'owner', p_owner_id::text);
  end if;
  if binding.owner_key is null then return jsonb_build_object('state', 'unresolved'); end if;
  if binding.retired_at is not null then return jsonb_build_object('state', 'retired'); end if;
  select c.environment, u.email into cohort_environment, owner_email_value
    from execute_revenuecat_private.billing_cohort c
    join auth.users u on u.id = binding.owner_id
    where c.project = p_project and c.owner_key = binding.owner_key;
  if cohort_environment is null or owner_email_value is null
     or execute_revenuecat_private.billing_owner_closed(binding.owner_id) is distinct from false then
    return jsonb_build_object('state', 'blocked');
  end if;

  select s.* into existing_row from public.user_subscriptions s
    where s.data->>'user_id' = binding.owner_id::text;
  if found then
    if existing_row.owner_id is distinct from binding.owner_id
       or existing_row.data->>'verified_billing_project' is distinct from p_project
       or existing_row.data->>'verified_billing_environment' is distinct from cohort_environment then
      return jsonb_build_object('state', 'blocked');
    end if;
    subscription_value := jsonb_build_object('data', existing_row.data, 'updated_date', existing_row.updated_date);
  end if;
  return jsonb_build_object(
    'state', 'active', 'owner_id', binding.owner_id, 'customer_id', binding.customer_id,
    'email', owner_email_value, 'environment', cohort_environment, 'subscription', subscription_value
  );
end;
$$;

create function public.apply_verified_billing_projections(p_project text, p_environment text, p_changes jsonb)
returns integer
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  item jsonb;
  exact_owner uuid;
  subject jsonb;
  expected_revision timestamptz;
  current_revision timestamptz;
  merged_data jsonb;
  changed integer;
  applied integer := 0;
begin
  if p_environment is null or p_environment not in ('SANDBOX', 'PRODUCTION')
     or jsonb_typeof(p_changes) is distinct from 'array'
     or jsonb_array_length(p_changes) not between 1 and 100
     or current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Invalid verified billing batch' using errcode = '22023';
  end if;
  if exists (
    select from jsonb_array_elements(p_changes) i
    where jsonb_typeof(i) is distinct from 'object'
       or jsonb_typeof(i->'data') is distinct from 'object'
       or octet_length(i->>'data') > 32768
       or i->>'owner_id' is null or i->>'customer_id' is null
       or i->>'expected_email' is null or not (i ? 'expected_updated_date')
  ) or (
    select count(distinct (i->>'owner_id')::uuid) from jsonb_array_elements(p_changes) i
  ) <> jsonb_array_length(p_changes) then
    raise exception 'Invalid verified billing change' using errcode = '22023';
  end if;

  -- Shared by both writers and mutually exclusive with deletion closure.
  perform 1 from auth.users u
    where u.id in (select (i->>'owner_id')::uuid from jsonb_array_elements(p_changes) i)
    order by u.id for share;
  lock table public.user_subscriptions in exclusive mode;

  for item in select value from jsonb_array_elements(p_changes) order by value->>'owner_id' loop
    exact_owner := (item->>'owner_id')::uuid;
    subject := public.read_verified_billing_subject(p_project, null, exact_owner);
    current_revision := (subject->'subscription'->>'updated_date')::timestamptz;
    expected_revision := (item->>'expected_updated_date')::timestamptz;
    if subject->>'state' is distinct from 'active'
       or subject->>'customer_id' is distinct from item->>'customer_id'
       or subject->>'email' is distinct from item->>'expected_email'
       or subject->>'environment' is distinct from p_environment
       or current_revision is distinct from expected_revision then
      raise exception 'Verified billing ownership or revision changed' using errcode = '40001';
    end if;
    if nullif(item->'data'->>'revenuecat_app_user_id', '') is not null
       and item->'data'->>'revenuecat_app_user_id' is distinct from subject->>'customer_id' then
      raise exception 'Verified billing provider identity changed' using errcode = '23514';
    end if;
    if item->'data'->>'revenuecat_environment' is not null
       and item->'data'->>'revenuecat_environment' is distinct from p_environment then
      raise exception 'Verified billing provider environment changed' using errcode = '23514';
    end if;
    merged_data := (coalesce(nullif(subject->'subscription'->'data', 'null'::jsonb), '{}'::jsonb) || (item->'data'))
      - array['owner_id','owner_email','created_by','user_email','revenuecat_app_user_id'];
    merged_data := merged_data || jsonb_build_object(
      'user_id', exact_owner, 'verified_billing_project', p_project,
      'verified_billing_environment', p_environment
    );
    if current_revision is null then
      insert into public.user_subscriptions (owner_id, owner_email, created_by, user_email, data)
        values (exact_owner, null, null, null, merged_data);
    else
      update public.user_subscriptions set data = merged_data
        where owner_id = exact_owner and data->>'user_id' = exact_owner::text
          and updated_date = current_revision;
    end if;
    get diagnostics changed = row_count;
    if changed <> 1 then
      raise exception 'Verified billing write was incomplete' using errcode = '40001';
    end if;
    applied := applied + 1;
  end loop;
  return applied;
end;
$$;

revoke all on function execute_revenuecat_private.reject_cohort_legacy_write() from public, anon, authenticated, service_role;
revoke all on function public.activate_verified_billing_owner(text,uuid,text),
  public.read_verified_billing_subject(text,text,uuid),
  public.apply_verified_billing_projections(text,text,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.activate_verified_billing_owner(text,uuid,text),
  public.read_verified_billing_subject(text,text,uuid),
  public.apply_verified_billing_projections(text,text,jsonb) to service_role;
notify pgrst, 'reload schema';
commit;
