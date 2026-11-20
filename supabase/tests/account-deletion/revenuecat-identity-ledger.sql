-- Optional W09 identity foundation. Apply after the billing projection fence
-- in an isolated rehearsal. Nothing enrolls existing customers on install.
begin;
set local lock_timeout = '5s';

create schema execute_revenuecat_private;
revoke all on schema execute_revenuecat_private from public, anon, authenticated, service_role;

create table execute_revenuecat_private.identity_key (
  singleton boolean primary key default true check (singleton),
  salt bytea not null default convert_to(gen_random_uuid()::text, 'UTF8')
);
insert into execute_revenuecat_private.identity_key default values;

create table execute_revenuecat_private.accounts (
  project text collate "C" not null,
  owner_key bytea not null,
  owner_id uuid,
  customer_id uuid,
  retired_at timestamptz,
  primary key (project, owner_key),
  check ((retired_at is null and owner_id is not null and customer_id is not null and owner_id <> customer_id)
         or (retired_at is not null and owner_id is null and customer_id is null))
);

-- Both canonical IDs and verified aliases use this one project-wide namespace.
-- Keep fingerprints after Auth deletion. No reference points into auth.users.
create table execute_revenuecat_private.identifiers (
  project text collate "C" not null,
  identifier_key bytea not null,
  owner_key bytea not null,
  primary key (project, identifier_key),
  foreign key (project, owner_key)
    references execute_revenuecat_private.accounts(project, owner_key)
);
revoke all on all tables in schema execute_revenuecat_private from public, anon, authenticated, service_role;

create function execute_revenuecat_private.identity_fingerprint(
  p_project text, p_kind text, p_value text
)
returns bytea
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
  fingerprint bytea;
begin
  if p_project is null or p_project collate "C" !~ '^[A-Za-z0-9_-]{1,100}$'
     or p_value is null or char_length(p_value) not between 1 and 100
     or p_value <> btrim(p_value) or p_value collate "C" ~ '[[:cntrl:]/]' then
    raise exception 'Invalid RevenueCat identity' using errcode = '22023';
  end if;
  select sha256(salt || convert_to('execute/revenuecat/v1:' || p_project || ':' || p_kind || ':' || p_value, 'UTF8'))
    into fingerprint from execute_revenuecat_private.identity_key where singleton;
  if fingerprint is null then
    raise exception 'RevenueCat identity ledger is unavailable' using errcode = '55000';
  end if;
  return fingerprint;
end;
$$;

-- A SQL-standard body tracks the fence dependencies in PostgreSQL. NULL
-- means unavailable and is distinct from both an open and a closed owner.
create function execute_revenuecat_private.billing_owner_closed(p_owner uuid)
returns boolean
language sql stable
set search_path = pg_catalog, pg_temp
return (
  select exists (
    select from execute_deletion_private.closed_billing_identity
    where owner_fingerprint = execute_deletion_private.billing_identity_fingerprint('owner:' || p_owner::text)
  ) from execute_deletion_private.billing_projection_fence_key where singleton
);

create function execute_revenuecat_private.lock_projection()
returns void
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'RevenueCat identity requires a fresh snapshot' using errcode = '40001';
  end if;
  -- The existing fence takes EXCLUSIVE on this table, so whichever operation
  -- acquires its lock first determines what the next operation can observe.
  lock table public.user_subscriptions in row share mode;
end;
$$;

create function execute_revenuecat_private.require_open_owner(p_owner uuid)
returns void
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  -- Follow the fence's Auth-then-projection lock order.
  perform 1 from auth.users where id = p_owner for share;
  if not found then
    raise exception 'RevenueCat identity requires a live Auth owner' using errcode = '55000';
  end if;
  perform execute_revenuecat_private.lock_projection();
  if execute_revenuecat_private.billing_owner_closed(p_owner) is distinct from false then
    raise exception 'RevenueCat identity admission is closed or unavailable' using errcode = '55000';
  end if;
end;
$$;

create function public.ensure_revenuecat_customer_id(p_project text, p_owner_id uuid)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_owner_key bytea;
  customer uuid;
begin
  perform execute_revenuecat_private.require_open_owner(p_owner_id);
  v_owner_key := execute_revenuecat_private.identity_fingerprint(p_project, 'owner', p_owner_id::text);
  customer := gen_random_uuid();
  insert into execute_revenuecat_private.accounts (project, owner_key, owner_id, customer_id)
    values (p_project, v_owner_key, p_owner_id, customer)
    on conflict do nothing;
  if found then
    insert into execute_revenuecat_private.identifiers (project, identifier_key, owner_key)
      values (p_project, execute_revenuecat_private.identity_fingerprint(p_project, 'customer', customer::text), v_owner_key);
    return customer;
  end if;

  -- An overlapping registration commits the owner and canonical ID together.
  select a.customer_id into customer from execute_revenuecat_private.accounts a
    where a.project = p_project and a.owner_key = v_owner_key
      and a.owner_id = p_owner_id for update;
  if customer is null then
    raise exception 'RevenueCat identity is closed' using errcode = '55000';
  end if;
  return customer;
end;
$$;

-- Only trusted service code with independent provider and historical ownership
-- evidence may call this function. Matching an email or a webhook alias is
-- insufficient evidence for attaching a legacy RevenueCat ID.
create function public.attach_verified_revenuecat_alias(p_project text, p_owner_id uuid, p_alias text)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_owner_key bytea;
  v_alias_key bytea;
begin
  perform execute_revenuecat_private.require_open_owner(p_owner_id);
  v_owner_key := execute_revenuecat_private.identity_fingerprint(p_project, 'owner', p_owner_id::text);
  v_alias_key := execute_revenuecat_private.identity_fingerprint(p_project, 'customer', p_alias);
  perform 1 from execute_revenuecat_private.accounts a
    where a.project = p_project and a.owner_key = v_owner_key and a.owner_id = p_owner_id for update;
  if not found then
    raise exception 'RevenueCat identity requires active enrollment' using errcode = '55000';
  end if;
  insert into execute_revenuecat_private.identifiers (project, identifier_key, owner_key)
    values (p_project, v_alias_key, v_owner_key) on conflict do nothing;
  if not exists (
    select from execute_revenuecat_private.identifiers i
    where i.project = p_project and i.identifier_key = v_alias_key and i.owner_key = v_owner_key
  ) then
    raise exception 'RevenueCat identifier already belongs to a different owner' using errcode = '23505';
  end if;
end;
$$;

-- Read-only preflight. A future projection writer must verify bindings again
-- under the same admission locks in the transaction that writes projections.
create function public.resolve_revenuecat_identity(p_project text, p_identifier text)
returns table (state text, owner_id uuid, customer_id uuid)
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_identifier_key bytea := execute_revenuecat_private.identity_fingerprint(p_project, 'customer', p_identifier);
begin
  return query
    with matched as (
      select a.owner_id, a.customer_id,
        case
          when a.retired_at is not null then 'retired'
          when u.id is null or execute_revenuecat_private.billing_owner_closed(a.owner_id) is distinct from false
            then 'blocked'
          else 'active'
        end as state
      from execute_revenuecat_private.identifiers i
      join execute_revenuecat_private.accounts a using (project, owner_key)
      left join auth.users u on u.id = a.owner_id
      where i.project = p_project and i.identifier_key = v_identifier_key
    )
    select m.state,
      case when m.state = 'active' then m.owner_id end,
      case when m.state = 'active' then m.customer_id end
    from matched m
    union all select 'unresolved', null::uuid, null::uuid where not exists (select from matched);
end;
$$;

create function public.retire_revenuecat_identity(p_project text, p_owner_id uuid)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_owner_key bytea;
  account execute_revenuecat_private.accounts%rowtype;
begin
  perform execute_revenuecat_private.lock_projection();
  v_owner_key := execute_revenuecat_private.identity_fingerprint(p_project, 'owner', p_owner_id::text);
  select * into account from execute_revenuecat_private.accounts a
    where a.project = p_project and a.owner_key = v_owner_key for update;
  if not found then
    return false;
  end if;
  if account.retired_at is not null then
    return true;
  end if;
  if execute_revenuecat_private.billing_owner_closed(p_owner_id) is distinct from true then
    raise exception 'RevenueCat retirement requires a closed billing fence' using errcode = '55000';
  end if;
  update execute_revenuecat_private.accounts a
  set owner_id = null, customer_id = null, retired_at = clock_timestamp()
  where a.project = p_project and a.owner_key = v_owner_key;
  return true;
end;
$$;

revoke all on all functions in schema execute_revenuecat_private from public, anon, authenticated, service_role;
revoke all on function public.ensure_revenuecat_customer_id(text, uuid),
  public.attach_verified_revenuecat_alias(text, uuid, text),
  public.resolve_revenuecat_identity(text, text),
  public.retire_revenuecat_identity(text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.ensure_revenuecat_customer_id(text, uuid),
  public.attach_verified_revenuecat_alias(text, uuid, text),
  public.resolve_revenuecat_identity(text, text),
  public.retire_revenuecat_identity(text, uuid) to service_role;
notify pgrst, 'reload schema';
commit;
