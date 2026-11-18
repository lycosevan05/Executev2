-- Opt-in W09 candidate. Install only in a disposable or separately approved
-- staged environment. The deletion adapter must opt into the matching RPC.
begin;
set local lock_timeout = '5s';

create schema if not exists execute_deletion_private;
revoke all on schema execute_deletion_private from public, anon, authenticated, service_role;
create table execute_deletion_private.retired_stripe_subscription (
  fingerprint bytea primary key
);
revoke all on execute_deletion_private.retired_stripe_subscription
  from public, anon, authenticated, service_role;

create function execute_deletion_private.stripe_subscription_fingerprints(p_data jsonb)
returns setof bytea
language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select distinct sha256(convert_to(id, 'UTF8'))
  from (
    select p_data->>'stripe_subscription_id' as id
    union all
    select value #>> '{}'
    from jsonb_array_elements(
      case when jsonb_typeof(p_data->'stripe_subscription_ids') = 'array'
        then p_data->'stripe_subscription_ids' else '[]'::jsonb end
    ) as links(value)
    where jsonb_typeof(value) = 'string'
  ) as candidates
  where id ~ '^sub_[A-Za-z0-9_]+$' and length(id) <= 1000
$$;

create function execute_deletion_private.reject_retired_stripe_subscription()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  -- The supported provider and PostgREST writes use READ COMMITTED. A fixed
  -- snapshot taken before the retirement lock could otherwise hide a marker.
  if exists (select from execute_deletion_private.stripe_subscription_fingerprints(new.data)) then
    if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
      raise exception 'Stripe projection requires a fresh snapshot' using errcode = '40001';
    end if;
    if exists (
      select from execute_deletion_private.stripe_subscription_fingerprints(new.data) as ref(fingerprint)
      join execute_deletion_private.retired_stripe_subscription retired
        on retired.fingerprint = ref.fingerprint
    ) then
      raise exception 'Stripe projection includes a retired subscription' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger reject_retired_stripe_subscription_insert
  before insert on public.user_subscriptions
  for each row execute function execute_deletion_private.reject_retired_stripe_subscription();
create trigger reject_retired_stripe_subscription_update
  before update of data on public.user_subscriptions
  for each row execute function execute_deletion_private.reject_retired_stripe_subscription();

create function public.retire_account_stripe_subscription_rows(
  p_owner_id uuid, p_email text, p_rows jsonb
)
returns integer
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  expected jsonb;
  existing_row public.user_subscriptions%rowtype;
  removed integer := 0;
begin
  if p_owner_id is null or jsonb_typeof(p_rows) is distinct from 'array'
     or jsonb_array_length(p_rows) > 100 then
    raise exception 'Invalid subscription deletion request' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    return 0;
  end if;
  perform 1 from auth.users
    where id = p_owner_id and email is not distinct from p_email
    for share;
  if not found then
    raise exception 'Account identity changed during deletion' using errcode = '40001';
  end if;
  -- A writer that commits first is visible to the snapshot check below. A
  -- writer arriving second cannot enter the trigger until markers are durable.
  lock table public.user_subscriptions in exclusive mode;
  for expected in select value from jsonb_array_elements(p_rows)
  loop
    if jsonb_typeof(expected) is distinct from 'object'
       or not (expected ?& array['id', 'owner_id', 'owner_email', 'created_by', 'user_email',
                                'legacy_user_id', 'stripe_id', 'stripe_ids_json']) then
      raise exception 'Invalid subscription deletion snapshot' using errcode = '22023';
    end if;
    select * into existing_row from public.user_subscriptions
      where id = (expected->>'id')::uuid;
    if not found
       or existing_row.owner_id is distinct from (expected->>'owner_id')::uuid
       or (existing_row.data->>'stripe_subscription_id') is distinct from (expected->>'stripe_id')
       or (existing_row.data->'stripe_subscription_ids') is distinct from
          (expected->>'stripe_ids_json')::jsonb
       or (existing_row.owner_id is not null and existing_row.owner_id <> p_owner_id)
       or (existing_row.owner_id is null and (
         nullif(p_email, '') is null
         or existing_row.owner_email is distinct from expected->>'owner_email'
         or existing_row.created_by is distinct from expected->>'created_by'
         or existing_row.user_email is distinct from expected->>'user_email'
         or (existing_row.data->>'user_id') is distinct from expected->>'legacy_user_id'
         or not coalesce(p_email = any(array[existing_row.owner_email, existing_row.created_by, existing_row.user_email,
                                             existing_row.data->>'user_id']), false)
         or exists (
           select from unnest(array[existing_row.owner_email, existing_row.created_by, existing_row.user_email,
                                    existing_row.data->>'user_id']) as identities(value)
           where nullif(value, '') is not null and value <> p_email
         )
       )) then
      raise exception 'Subscription changed during account deletion' using errcode = '40001';
    end if;
    insert into execute_deletion_private.retired_stripe_subscription (fingerprint)
      select execute_deletion_private.stripe_subscription_fingerprints(existing_row.data)
      on conflict do nothing;
    delete from public.user_subscriptions where id = existing_row.id;
    if not found then
      raise exception 'Subscription deletion was incomplete' using errcode = '40001';
    end if;
    removed := removed + 1;
  end loop;
  return removed;
end;
$$;

revoke all on function public.retire_account_stripe_subscription_rows(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.retire_account_stripe_subscription_rows(uuid, text, jsonb)
  to service_role;
revoke all on function execute_deletion_private.stripe_subscription_fingerprints(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function execute_deletion_private.reject_retired_stripe_subscription()
  from public, anon, authenticated, service_role;
notify pgrst, 'reload schema';
commit;
