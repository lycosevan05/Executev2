-- Optional staged checkout guard. Install after the billing projection fence.
begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regclass('execute_deletion_private.closed_billing_identity') is null
     or to_regprocedure('public.close_account_billing_projection(uuid,text,jsonb)') is null then
    raise exception 'Install the billing projection fence before checkout admission';
  end if;
end;
$$;

create schema execute_checkout_private;
revoke all on schema execute_checkout_private from public, anon, authenticated, service_role;

create table execute_checkout_private.closed_admission (
  owner_id uuid primary key references auth.users(id) on delete cascade
);
create table execute_checkout_private.dispatch (
  dispatch_id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  stripe_session_id text unique
    check (stripe_session_id ~ '^cs_(test|live)_[A-Za-z0-9]+$' and length(stripe_session_id) <= 255)
);
create index checkout_dispatch_owner on execute_checkout_private.dispatch(owner_id, dispatch_id);
revoke all on execute_checkout_private.closed_admission, execute_checkout_private.dispatch
  from public, anon, authenticated, service_role;

-- One lock coordinates registration, acknowledgement, closure, and Auth removal.
-- READ COMMITTED gives a fresh snapshot of admission after acquiring the lock.
create function execute_checkout_private.lock_live_owner(p_owner_id uuid, p_email text)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Checkout requires a fresh snapshot' using errcode = '40001';
  end if;
  if p_owner_id is null or p_email is null or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+$' then
    raise exception 'Invalid checkout identity' using errcode = '22023';
  end if;
  perform 1 from auth.users where id = p_owner_id and email = p_email for update;
  if not found then
    raise exception 'Checkout identity changed' using errcode = '40001';
  end if;
end;
$$;

create function public.begin_guarded_stripe_checkout(p_owner_id uuid, p_email text)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  result uuid;
  email_key bytea;
begin
  perform execute_checkout_private.lock_live_owner(p_owner_id, p_email);
  if exists (select from execute_checkout_private.closed_admission where owner_id = p_owner_id) then
    raise exception 'Checkout admission is closed' using errcode = '55000';
  end if;
  -- A new UUID with the same email must not pay into a blocked projection.
  lock table execute_deletion_private.closed_billing_identity in share mode;
  email_key := execute_deletion_private.billing_identity_fingerprint('email:' || lower(p_email));
  if email_key is null then
    raise exception 'Checkout projection fence is unavailable' using errcode = '55000';
  end if;
  if exists (select from execute_deletion_private.closed_billing_identity where email_fingerprint = email_key) then
    raise exception 'Checkout requires verified billing reassociation' using errcode = '55000';
  end if;
  if (select count(*) from execute_checkout_private.dispatch where owner_id = p_owner_id) >= 100 then
    raise exception 'Checkout dispatch history needs reconciliation' using errcode = '55000';
  end if;
  insert into execute_checkout_private.dispatch(owner_id) values (p_owner_id)
    returning dispatch_id into result;
  return result;
end;
$$;

-- Even after admission closes, preserve an exact provider receipt for the
-- drain. The return value only authorizes sending a URL back to checkout.
create function public.acknowledge_guarded_stripe_checkout(
  p_owner_id uuid, p_email text, p_dispatch_id uuid, p_session_id text
)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
begin
  perform execute_checkout_private.lock_live_owner(p_owner_id, p_email);
  if p_session_id is null or p_session_id !~ '^cs_(test|live)_[A-Za-z0-9]+$' or length(p_session_id) > 255 then
    raise exception 'Invalid checkout receipt' using errcode = '22023';
  end if;
  update execute_checkout_private.dispatch set stripe_session_id = p_session_id
    where dispatch_id = p_dispatch_id and owner_id = p_owner_id
      and (stripe_session_id is null or stripe_session_id = p_session_id);
  if not found then
    raise exception 'Checkout receipt does not match a dispatch' using errcode = '22023';
  end if;
  return not exists (select from execute_checkout_private.closed_admission where owner_id = p_owner_id);
end;
$$;

create function public.close_and_list_guarded_stripe_checkouts(p_owner_id uuid, p_email text)
returns table (dispatch_id uuid, stripe_session_id text)
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
begin
  perform execute_checkout_private.lock_live_owner(p_owner_id, p_email);
  -- Checkout may expire a Stripe object only when projection closure is available.
  if to_regprocedure('public.close_account_billing_projection(uuid,text,jsonb)') is null
     or execute_deletion_private.billing_identity_fingerprint('email:' || lower(p_email)) is null then
    raise exception 'Checkout projection fence is unavailable' using errcode = '55000';
  end if;
  insert into execute_checkout_private.closed_admission(owner_id) values (p_owner_id)
    on conflict do nothing;
  return query select d.dispatch_id, d.stripe_session_id
    from execute_checkout_private.dispatch d where d.owner_id = p_owner_id
    order by d.dispatch_id limit 101;
end;
$$;

-- Called by the deletion runtime after expiring/canceling the exact verified
-- provider inventory. Keep admission closed until Auth removal commits.
create function public.finish_guarded_stripe_checkout_drain(
  p_owner_id uuid, p_email text, p_rows jsonb
)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  actual jsonb;
  expected jsonb;
begin
  perform execute_checkout_private.lock_live_owner(p_owner_id, p_email);
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 100
     or not exists (select from execute_checkout_private.closed_admission where owner_id = p_owner_id)
     or not exists (
        select from execute_deletion_private.closed_billing_identity
        where email_fingerprint = execute_deletion_private.billing_identity_fingerprint('email:' || lower(p_email))
          and owner_fingerprint = execute_deletion_private.billing_identity_fingerprint('owner:' || p_owner_id::text)
     ) or exists (
        select from execute_checkout_private.dispatch where owner_id = p_owner_id and stripe_session_id is null
     ) then
    raise exception 'Checkout drain is incomplete' using errcode = '55000';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'dispatch_id', d.dispatch_id, 'stripe_session_id', d.stripe_session_id
  ) order by d.dispatch_id), '[]'::jsonb) into actual
  from execute_checkout_private.dispatch d where d.owner_id = p_owner_id;
  select coalesce(jsonb_agg(item order by item->>'dispatch_id'), '[]'::jsonb) into expected
  from jsonb_array_elements(p_rows) as inventory(item);
  if actual is distinct from expected then
    raise exception 'Checkout inventory changed' using errcode = '40001';
  end if;
  delete from execute_checkout_private.dispatch where owner_id = p_owner_id;
  return true;
end;
$$;

revoke all on function execute_checkout_private.lock_live_owner(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.begin_guarded_stripe_checkout(uuid, text),
  public.acknowledge_guarded_stripe_checkout(uuid, text, uuid, text),
  public.close_and_list_guarded_stripe_checkouts(uuid, text),
  public.finish_guarded_stripe_checkout_drain(uuid, text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_guarded_stripe_checkout(uuid, text),
  public.acknowledge_guarded_stripe_checkout(uuid, text, uuid, text),
  public.close_and_list_guarded_stripe_checkouts(uuid, text),
  public.finish_guarded_stripe_checkout_drain(uuid, text, jsonb) to service_role;

notify pgrst, 'reload schema';
commit;
