-- Opt-in Apple OAuth custody. Arm capture only with a compatible deletion route.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create schema execute_apple_grant_private;
revoke all on schema execute_apple_grant_private from public, anon, authenticated, service_role;

create table execute_apple_grant_private.closures (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  subject text,
  client_id text not null,
  revoked boolean not null default false
);

create table execute_apple_grant_private.grants (
  owner_id uuid not null references auth.users(id) on delete restrict,
  id uuid not null,
  subject text not null check (length(subject) between 1 and 512),
  client_id text not null check (client_id ~ '^[A-Za-z0-9.-]{1,255}$'),
  key_id text not null check (key_id ~ '^[a-z0-9_-]{1,32}$'),
  fingerprint text not null check (fingerprint ~ '^[a-f0-9]{64}$'),
  nonce text not null check (nonce ~ '^[a-f0-9]{24}$'),
  ciphertext text not null check (
    length(ciphertext) between 34 and 16416 and ciphertext ~ '^([a-f0-9]{2})+$'
  ),
  primary key (owner_id, id),
  unique (owner_id, subject, client_id, fingerprint)
);
alter table execute_apple_grant_private.closures enable row level security;
alter table execute_apple_grant_private.grants enable row level security;
revoke all on execute_apple_grant_private.closures, execute_apple_grant_private.grants
  from public, anon, authenticated, service_role;

-- Take the Auth owner lock before touching any Apple rows. No lock spans HTTP.
create function execute_apple_grant_private.lock_owner(p_owner uuid)
returns void
language plpgsql
set search_path = pg_catalog
as $$
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Apple grant custody requires a fresh snapshot' using errcode = '40001';
  end if;
  perform 1 from auth.users where id = p_owner for update;
  if not found then
    raise exception 'Apple grant custody requires a live Auth owner' using errcode = '40001';
  end if;
end;
$$;

create function execute_apple_grant_private.lock_apple_subject(p_owner uuid)
returns text
language sql
volatile
set search_path = pg_catalog
as $$
  select case when count(*) = 1 and length(min(subject)) between 1 and 512 then min(subject) end
  from (
    select identity_data->>'sub' as subject
    from auth.identities where user_id = p_owner and provider = 'apple'
    for share
  ) as linked;
$$;

create function execute_apple_grant_private.assert_capture_open(p_owner uuid, p_subject text)
returns void
language plpgsql
set search_path = pg_catalog
as $$
begin
  perform execute_apple_grant_private.lock_owner(p_owner);
  if p_subject is null or p_subject is distinct from execute_apple_grant_private.lock_apple_subject(p_owner)
    or exists (select from execute_apple_grant_private.closures where owner_id = p_owner) then
    raise exception 'Apple grant capture is unavailable for this owner' using errcode = '55000';
  end if;
end;
$$;

create function public.execute_has_apple_grant(
  p_owner uuid, p_subject text, p_client text, p_fingerprints text[]
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  perform execute_apple_grant_private.assert_capture_open(p_owner, p_subject);
  return exists (
    select from execute_apple_grant_private.grants
    where owner_id = p_owner and subject = p_subject and client_id = p_client
      and fingerprint = any(p_fingerprints)
  );
end;
$$;

create function public.execute_capture_apple_grant(
  p_owner uuid, p_subject text, p_client text, p_id uuid,
  p_key text, p_fingerprint text, p_nonce text, p_ciphertext text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  perform execute_apple_grant_private.assert_capture_open(p_owner, p_subject);
  insert into execute_apple_grant_private.grants (
    owner_id, id, subject, client_id, key_id, fingerprint, nonce, ciphertext
  ) values (
    p_owner, p_id, p_subject, p_client, p_key, p_fingerprint, p_nonce, p_ciphertext
  ) on conflict (owner_id, subject, client_id, fingerprint) do nothing;
  return true;
end;
$$;

create function public.execute_close_apple_grants(
  p_owner uuid, p_subject text, p_client text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
declare
  was_revoked boolean;
begin
  perform execute_apple_grant_private.lock_owner(p_owner);
  if p_client is null or p_client !~ '^[A-Za-z0-9.-]{1,255}$'
    or p_subject is distinct from execute_apple_grant_private.lock_apple_subject(p_owner)
    or exists (
      select from execute_apple_grant_private.grants
      where owner_id = p_owner and (subject is distinct from p_subject or client_id <> p_client)
    )
    or exists (
      select from execute_apple_grant_private.closures
      where owner_id = p_owner and (
        client_id <> p_client or (subject is distinct from p_subject and not (revoked and p_subject is null))
      )
    ) then
    raise exception 'Apple grant custody does not match the current owner' using errcode = '55000';
  end if;

  insert into execute_apple_grant_private.closures (owner_id, subject, client_id)
    values (p_owner, p_subject, p_client) on conflict (owner_id) do nothing;
  select revoked into strict was_revoked from execute_apple_grant_private.closures where owner_id = p_owner;
  return jsonb_build_object('revoked', was_revoked, 'grants', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'subject', subject, 'clientId', client_id, 'keyId', key_id,
      'fingerprint', fingerprint, 'nonce', nonce, 'ciphertext', ciphertext
    ) order by id)
    from execute_apple_grant_private.grants where owner_id = p_owner
  ), '[]'::jsonb));
end;
$$;

create function public.execute_confirm_apple_grant_revoked(p_owner uuid, p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  perform execute_apple_grant_private.lock_owner(p_owner);
  if not exists (select from execute_apple_grant_private.closures where owner_id = p_owner) then
    raise exception 'Apple grant revocation requires closed admission' using errcode = '55000';
  end if;
  delete from execute_apple_grant_private.grants where owner_id = p_owner and id = p_id;
  if found and not exists (select from execute_apple_grant_private.grants where owner_id = p_owner) then
    update execute_apple_grant_private.closures set revoked = true where owner_id = p_owner;
  end if;
  return true;
end;
$$;

revoke all on all functions in schema execute_apple_grant_private from public, anon, authenticated, service_role;
revoke all on function public.execute_has_apple_grant(uuid,text,text,text[]),
  public.execute_capture_apple_grant(uuid,text,text,uuid,text,text,text,text),
  public.execute_close_apple_grants(uuid,text,text),
  public.execute_confirm_apple_grant_revoked(uuid,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.execute_has_apple_grant(uuid,text,text,text[]),
  public.execute_capture_apple_grant(uuid,text,text,uuid,text,text,text,text),
  public.execute_close_apple_grants(uuid,text,text),
  public.execute_confirm_apple_grant_revoked(uuid,uuid)
  to service_role;
notify pgrst, 'reload schema';
commit;
