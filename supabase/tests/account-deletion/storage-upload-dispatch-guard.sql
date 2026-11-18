-- Opt-in candidate. Install after storage-upload-admission-guard.sql.
-- Every actual Storage send in the managed writer must have a new dispatch.
begin;
set local lock_timeout = '5s';

create table execute_storage_deletion_guard.pending_upload_dispatch (
  dispatch_id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete restrict,
  object_name text not null
);
create index pending_upload_dispatch_owner on
  execute_storage_deletion_guard.pending_upload_dispatch (owner_id, dispatch_id);
revoke all on execute_storage_deletion_guard.pending_upload_dispatch
  from public, anon, authenticated, service_role;

create function public.begin_account_upload_dispatch(p_owner_id uuid, p_filename text)
returns table (dispatch_id uuid, object_name text)
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
declare
  new_id uuid := gen_random_uuid();
  new_name text;
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Upload dispatch requires a fresh snapshot' using errcode = '40001';
  end if;
  if p_owner_id is null or p_filename is null
     or p_filename !~ '^[A-Za-z0-9._-]{1,120}$' or p_filename in ('.', '..') then
    raise exception 'Invalid upload dispatch' using errcode = '22023';
  end if;

  -- Serialize registration against the existing closure of this Auth UUID.
  perform 1 from auth.users where id = p_owner_id for key share;
  if not found or exists (
    select from execute_storage_deletion_guard.closed_upload_admission where owner_id = p_owner_id
  ) then
    raise exception 'Upload admission is closed' using errcode = '55000';
  end if;

  new_name := p_owner_id::text || '/' || new_id::text || '-' || p_filename;
  insert into execute_storage_deletion_guard.pending_upload_dispatch
    values (new_id, p_owner_id, new_name);
  return query select new_id, new_name;
end;
$$;

-- The writer only acknowledges a definitive terminal outcome from Storage.
-- Retrying an acknowledgment for the same dispatch is safe. Each send needs
-- its own registration, even if an earlier attempt had an unknown outcome.
create function public.finish_account_upload_dispatch(p_owner_id uuid, p_dispatch_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  delete from execute_storage_deletion_guard.pending_upload_dispatch
    where owner_id = p_owner_id and dispatch_id = p_dispatch_id;
end;
$$;

-- An empty response permits a fresh Storage API inventory. A nonempty response
-- retains Auth for retry. Return a bounded set of exact paths for investigation.
create function public.close_and_list_account_upload_dispatches(p_owner_id uuid)
returns table (dispatch_id uuid, object_name text)
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Upload closure requires a fresh snapshot' using errcode = '40001';
  end if;
  perform public.close_account_upload_admission(p_owner_id);
  return query
    select pending.dispatch_id, pending.object_name
    from execute_storage_deletion_guard.pending_upload_dispatch pending
    where pending.owner_id = p_owner_id
    order by pending.dispatch_id
    limit 100;
end;
$$;

revoke all on function public.begin_account_upload_dispatch(uuid, text),
  public.finish_account_upload_dispatch(uuid, uuid),
  public.close_and_list_account_upload_dispatches(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_account_upload_dispatch(uuid, text),
  public.finish_account_upload_dispatch(uuid, uuid),
  public.close_and_list_account_upload_dispatches(uuid) to service_role;

notify pgrst, 'reload schema';
commit;
