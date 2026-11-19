-- Reverse the first three optional upload guard files before writer cutover.
-- Stop the canonical upload endpoint and reconcile outstanding work first.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

lock table execute_storage_deletion_guard.closed_upload_admission,
           execute_storage_deletion_guard.pending_upload_dispatch
  in access exclusive mode;

do $$
begin
  if to_regprocedure('public.close_and_list_guarded_account_upload_dispatches(uuid)') is not null
    or exists (
      select from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname in ('uploads require canonical writer for insert', 'uploads require canonical writer for update')
    ) then
    raise exception 'reverse the writer cutover before upload preparation';
  end if;
  if exists (select from execute_storage_deletion_guard.closed_upload_admission)
    or exists (select from execute_storage_deletion_guard.pending_upload_dispatch) then
    raise exception 'pending upload state requires reconciliation';
  end if;
end;
$$;

drop policy "account deletion uploads insert guard" on storage.objects;
drop policy "account deletion uploads update guard" on storage.objects;
drop function public.begin_exact_account_upload_dispatch(uuid, text);
drop function public.begin_account_upload_dispatch(uuid, text);
drop function public.finish_account_upload_dispatch(uuid, uuid);
drop function public.close_and_list_account_upload_dispatches(uuid);
drop table execute_storage_deletion_guard.pending_upload_dispatch;
drop function public.close_account_upload_admission(uuid);
drop function execute_storage_deletion_guard.current_owner_can_upload();
drop table execute_storage_deletion_guard.closed_upload_admission;
drop schema execute_storage_deletion_guard;
notify pgrst, 'reload schema';
commit;
