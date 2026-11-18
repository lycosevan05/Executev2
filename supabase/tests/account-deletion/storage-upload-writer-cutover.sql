-- Optional direct-write cutover. Install only after deploying and verifying the
-- canonical guarded writer and migrating all supported clients on that project.
begin;
set local lock_timeout = '5s';

create policy "uploads require canonical writer for insert" on storage.objects
  as restrictive for insert to anon, authenticated
  with check (bucket_id <> 'uploads');

create policy "uploads require canonical writer for update" on storage.objects
  as restrictive for update to anon, authenticated
  using (bucket_id <> 'uploads')
  with check (bucket_id <> 'uploads');


-- Staged deletion uses this RPC so enabling the Edge Function alone cannot
-- start cleanup while authenticated direct-write admission is still possible.
create function public.close_and_list_guarded_account_upload_dispatches(p_owner_id uuid)
returns table (dispatch_id uuid, object_name text)
language plpgsql
security definer
set search_path = pg_catalog
set lock_timeout = '5s'
as $$
declare
  objects regclass := 'storage.objects'::regclass;
  writer_roles oid[] := array['anon'::regrole::oid, 'authenticated'::regrole::oid];
  predicate text := '(bucket_id <> ''uploads''::text)';
begin
  lock table storage.objects in access share mode;
  if not exists (select from pg_class where oid = objects and relrowsecurity)
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
    raise exception 'Canonical upload cutover is not active' using errcode = '55000';
  end if;
  return query select pending.dispatch_id, pending.object_name
    from public.close_and_list_account_upload_dispatches(p_owner_id) pending;
end;
$$;

revoke all on function public.close_and_list_guarded_account_upload_dispatches(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.close_and_list_guarded_account_upload_dispatches(uuid) to service_role;

notify pgrst, 'reload schema';

commit;
