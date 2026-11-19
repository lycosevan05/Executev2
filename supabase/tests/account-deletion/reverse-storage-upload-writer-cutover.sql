-- Restore the upload preparation phase after disabling and draining deletion.
-- The canonical writer and its dispatch registration stay installed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local search_path = pg_catalog;

-- Use the same lock order as the cutover closure RPC. Keep its policy check,
-- closure and dispatch registration from racing the safety checks below.
lock table storage.objects in access exclusive mode;
lock table execute_storage_deletion_guard.closed_upload_admission,
           execute_storage_deletion_guard.pending_upload_dispatch
  in access exclusive mode;

do $$
declare
  objects regclass := 'storage.objects'::regclass;
  writer_roles oid[] := array['anon'::regrole::oid, 'authenticated'::regrole::oid];
  predicate text := '(bucket_id <> ''uploads''::text)';
begin
  if to_regprocedure('public.begin_exact_account_upload_dispatch(uuid,text)') is null
     or to_regprocedure('public.close_and_list_guarded_account_upload_dispatches(uuid)') is null
     or not exists (select from pg_class where oid = objects and relrowsecurity)
     or not exists (
       select from pg_policy
       where polrelid = objects and polname = 'uploads require canonical writer for insert'
         and not polpermissive and polcmd = 'a'
         and polroles @> writer_roles and polroles <@ writer_roles
         and polqual is null and pg_get_expr(polwithcheck, polrelid) = predicate
     )
     or not exists (
       select from pg_policy
       where polrelid = objects and polname = 'uploads require canonical writer for update'
         and not polpermissive and polcmd = 'w'
         and polroles @> writer_roles and polroles <@ writer_roles
         and pg_get_expr(polqual, polrelid) = predicate
         and pg_get_expr(polwithcheck, polrelid) = predicate
     ) then
    raise exception 'canonical upload cutover schema changed';
  end if;
  if exists (select from execute_storage_deletion_guard.closed_upload_admission)
    or exists (select from execute_storage_deletion_guard.pending_upload_dispatch) then
    raise exception 'pending upload state requires reconciliation';
  end if;
end;
$$;

drop function public.close_and_list_guarded_account_upload_dispatches(uuid);
drop policy "uploads require canonical writer for insert" on storage.objects;
drop policy "uploads require canonical writer for update" on storage.objects;
notify pgrst, 'reload schema';
commit;
