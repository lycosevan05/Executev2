-- Optional staged billing gate. Keep the marker until billing providers and
-- clients stop identifying the account by email. Never install independently
-- of the staged deletion, checkout, and provider-identity rollout.
begin;
set local lock_timeout = '5s';

create schema if not exists execute_deletion_private;
revoke all on schema execute_deletion_private from public, anon, authenticated, service_role;

create table execute_deletion_private.billing_projection_fence_key (
  singleton boolean primary key default true check (singleton),
  salt bytea not null default convert_to(gen_random_uuid()::text, 'UTF8')
);
insert into execute_deletion_private.billing_projection_fence_key default values;
create table execute_deletion_private.closed_billing_identity (
  email_fingerprint bytea primary key,
  owner_fingerprint bytea not null
);
create index closed_billing_identity_owner on
  execute_deletion_private.closed_billing_identity(owner_fingerprint);
revoke all on execute_deletion_private.billing_projection_fence_key,
  execute_deletion_private.closed_billing_identity
  from public, anon, authenticated, service_role;

create function execute_deletion_private.billing_identity_fingerprint(p_identity text)
returns bytea
language sql stable
set search_path = pg_catalog, pg_temp
as $$
  select sha256(salt || convert_to(p_identity, 'UTF8'))
  from execute_deletion_private.billing_projection_fence_key
  where singleton
$$;

create function execute_deletion_private.billing_projection_identities(p_row public.user_subscriptions)
returns setof text
language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select distinct lower(btrim(value))
  from unnest(array[
    p_row.owner_email, p_row.created_by, p_row.user_email,
    p_row.data->>'user_id', p_row.data->>'owner_email', p_row.data->>'created_by',
    p_row.data->>'user_email', p_row.data->>'revenuecat_app_user_id'
  ]) as identities(value)
  where btrim(value) <> ''
$$;

create function execute_deletion_private.reject_closed_billing_identity()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Billing projection requires a fresh snapshot' using errcode = '40001';
  end if;
  if not exists (select from execute_deletion_private.billing_projection_fence_key where singleton) then
    raise exception 'Billing projection fence is unavailable' using errcode = '55000';
  end if;
  if exists (
    select
    from execute_deletion_private.billing_projection_identities(new) identity
    join execute_deletion_private.closed_billing_identity closed
      on closed.email_fingerprint = execute_deletion_private.billing_identity_fingerprint('email:' || identity)
      or closed.owner_fingerprint = execute_deletion_private.billing_identity_fingerprint('owner:' || identity)
  ) or (tg_op = 'UPDATE' and exists (
    select
    from execute_deletion_private.billing_projection_identities(old) identity
    join execute_deletion_private.closed_billing_identity closed
      on closed.email_fingerprint = execute_deletion_private.billing_identity_fingerprint('email:' || identity)
      or closed.owner_fingerprint = execute_deletion_private.billing_identity_fingerprint('owner:' || identity)
  )) or exists (
    select from execute_deletion_private.closed_billing_identity closed
    where closed.owner_fingerprint = execute_deletion_private.billing_identity_fingerprint('owner:' || new.owner_id::text)
      or (tg_op = 'UPDATE' and closed.owner_fingerprint =
        execute_deletion_private.billing_identity_fingerprint('owner:' || old.owner_id::text))
  ) then
    raise exception 'Billing projection requires verified account reassociation' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger reject_closed_billing_identity
  before insert or update on public.user_subscriptions
  for each row execute function execute_deletion_private.reject_closed_billing_identity();

create function public.close_account_billing_projection(
  p_owner_id uuid, p_email text, p_rows jsonb
)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  normalized text;
  email_key bytea;
  owner_key bytea;
  existing_owner bytea;
  actual jsonb;
  expected jsonb;
begin
  if p_owner_id is null or nullif(p_email, '') is null
     or jsonb_typeof(p_rows) is distinct from 'array'
     or jsonb_array_length(p_rows) > 100 then
    raise exception 'Invalid billing-fence request' using errcode = '22023';
  end if;
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Billing fence requires a fresh snapshot' using errcode = '40001';
  end if;
  perform 1 from auth.users
    where id = p_owner_id and email = p_email
    for share;
  if not found then
    raise exception 'Account identity changed during billing preflight' using errcode = '40001';
  end if;

  normalized := lower(btrim(p_email));
  email_key := execute_deletion_private.billing_identity_fingerprint('email:' || normalized);
  owner_key := execute_deletion_private.billing_identity_fingerprint('owner:' || p_owner_id::text);
  if normalized !~ '^[^[:space:]@]+@[^[:space:]@]+$' or email_key is null or owner_key is null then
    raise exception 'Billing identity cannot be verified' using errcode = '22023';
  end if;

  lock table public.user_subscriptions in exclusive mode;
  select owner_fingerprint into existing_owner
    from execute_deletion_private.closed_billing_identity
    where email_fingerprint = email_key;
  if found and existing_owner <> owner_key then
    raise exception 'Billing identity requires verified account reassociation' using errcode = '23514';
  end if;
  -- Include any row with the same normalized identity, regardless of the
  -- field, so an alternate email case or foreign owner cannot evade preflight.
  if exists (
    select from public.user_subscriptions as subscription
    where (subscription.owner_id = p_owner_id or exists (
      select from execute_deletion_private.billing_projection_identities(subscription) identity
      where identity in (normalized, p_owner_id::text)
    ))
    and (
      (subscription.owner_id is not null and subscription.owner_id <> p_owner_id)
      or exists (
        select from execute_deletion_private.billing_projection_identities(subscription) alias
        where alias not in (normalized, p_owner_id::text)
      )
    )
  ) then
    raise exception 'Billing projection ownership is ambiguous' using errcode = '23514';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', subscription.id,
    'owner_id', subscription.owner_id,
    'owner_email', subscription.owner_email,
    'created_by', subscription.created_by,
    'user_email', subscription.user_email,
    'data', subscription.data
  ) order by subscription.id), '[]'::jsonb) into actual
  from public.user_subscriptions as subscription
  where subscription.owner_id = p_owner_id or exists (
    select from execute_deletion_private.billing_projection_identities(subscription) identity
    where identity in (normalized, p_owner_id::text)
  );
  select coalesce(jsonb_agg(item order by item->>'id'), '[]'::jsonb) into expected
    from jsonb_array_elements(p_rows) as snapshots(item);
  if actual is distinct from expected then
    raise exception 'Billing projections changed during preflight' using errcode = '40001';
  end if;

  insert into execute_deletion_private.closed_billing_identity (email_fingerprint, owner_fingerprint)
    values (email_key, owner_key)
    on conflict (email_fingerprint) do nothing;
  return true;
end;
$$;

revoke all on function execute_deletion_private.billing_identity_fingerprint(text),
  execute_deletion_private.billing_projection_identities(public.user_subscriptions),
  execute_deletion_private.reject_closed_billing_identity()
  from public, anon, authenticated, service_role;
revoke all on function public.close_account_billing_projection(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.close_account_billing_projection(uuid, text, jsonb) to service_role;
notify pgrst, 'reload schema';
commit;
