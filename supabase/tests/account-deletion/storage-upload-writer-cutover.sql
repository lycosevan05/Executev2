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

commit;
