-- Opt-in candidate for an isolated or separately approved Storage rollout.
begin;
set local lock_timeout = '5s';

create schema execute_storage_deletion_guard;
revoke all on schema execute_storage_deletion_guard
  from public, anon, authenticated, service_role;
grant usage on schema execute_storage_deletion_guard to authenticated;

create table execute_storage_deletion_guard.closed_upload_admission (
  owner_id uuid primary key references auth.users(id) on delete cascade
);
revoke all on execute_storage_deletion_guard.closed_upload_admission
  from public, anon, authenticated, service_role;

-- A write admission holds KEY SHARE on the live owner until the Storage
-- metadata transaction finishes. The closer takes the conflicting UPDATE lock.
-- The check after taking the lock needs a fresh READ COMMITTED snapshot.
create function execute_storage_deletion_guard.current_owner_can_upload()
returns boolean
language plpgsql
volatile
security definer
set search_path = pg_catalog
as $$
declare
  subject uuid := auth.uid();
begin
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'Storage admission requires a fresh snapshot' using errcode = '40001';
  end if;
  perform 1 from auth.users where id = subject for key share;
  if not found then
    return false;
  end if;
  return not exists (
    select from execute_storage_deletion_guard.closed_upload_admission where owner_id = subject
  );
end;
$$;

revoke all on function execute_storage_deletion_guard.current_owner_can_upload()
  from public, anon, authenticated, service_role;
grant execute on function execute_storage_deletion_guard.current_owner_can_upload() to authenticated;

-- Invoke only after authorization and before taking the final uploads inventory.
-- This transaction deliberately holds no locks across external cleanup calls.
create function public.close_account_upload_admission(p_owner_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
begin
  if p_owner_id is null then
    raise exception 'Storage closure requires an Auth UUID' using errcode = '22023';
  end if;
  perform 1 from auth.users where id = p_owner_id for update;
  if not found then
    raise exception 'Storage closure requires a live account' using errcode = 'PT409';
  end if;
  insert into execute_storage_deletion_guard.closed_upload_admission (owner_id)
    values (p_owner_id) on conflict do nothing;
end;
$$;

revoke all on function public.close_account_upload_admission(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.close_account_upload_admission(uuid) to service_role;

create policy "account deletion uploads insert guard" on storage.objects
  as restrictive for insert to authenticated
  with check (bucket_id <> 'uploads' or (select execute_storage_deletion_guard.current_owner_can_upload()));

create policy "account deletion uploads update guard" on storage.objects
  as restrictive for update to authenticated
  using (bucket_id <> 'uploads' or (select execute_storage_deletion_guard.current_owner_can_upload()))
  with check (bucket_id <> 'uploads' or (select execute_storage_deletion_guard.current_owner_can_upload()));

notify pgrst, 'reload schema';
commit;
