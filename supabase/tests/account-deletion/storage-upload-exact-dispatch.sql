-- Optional canonical writer RPC. Install after the E64 upload-dispatch guard.
begin;
set local lock_timeout = '5s';

create function public.begin_exact_account_upload_dispatch(p_owner_id uuid, p_object_name text)
returns table (dispatch_id uuid, object_name text)
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
declare
  new_id uuid := gen_random_uuid();
  filename text := split_part(p_object_name, '/', 2);
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Upload dispatch requires a fresh snapshot' using errcode = 'PT409';
  end if;
  if p_owner_id is null or p_object_name is null or char_length(filename) not between 1 and 255
     or filename ~ '[^A-Za-z0-9._-]' or filename in ('.', '..')
     or p_object_name <> p_owner_id::text || '/' || filename then
    raise exception 'Invalid upload dispatch' using errcode = '22023';
  end if;

  perform 1 from auth.users where id = p_owner_id for key share;
  if not found or exists (
    select from execute_storage_deletion_guard.closed_upload_admission where owner_id = p_owner_id
  ) then
    raise exception 'Upload admission is closed' using errcode = '55000';
  end if;

  insert into execute_storage_deletion_guard.pending_upload_dispatch
    values (new_id, p_owner_id, p_object_name);
  return query select new_id, p_object_name;
end;
$$;

revoke all on function public.begin_exact_account_upload_dispatch(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_exact_account_upload_dispatch(uuid, text) to service_role;

notify pgrst, 'reload schema';
commit;
