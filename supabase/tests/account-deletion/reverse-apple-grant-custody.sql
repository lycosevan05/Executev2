-- Disable capture and stop the staged deletion endpoint first.
-- Retained grants and active deletion markers require an approved handoff.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

lock table execute_apple_grant_private.closures,
  execute_apple_grant_private.grants in access exclusive mode;
do $$
begin
  if exists (select from execute_apple_grant_private.grants)
    or exists (select from execute_apple_grant_private.closures) then
    raise exception 'Apple grant custody has active records';
  end if;
end;
$$;
drop function public.execute_has_apple_grant(uuid,text,text,text[]);
drop function public.execute_capture_apple_grant(uuid,text,text,uuid,text,text,text,text);
drop function public.execute_close_apple_grants(uuid,text,text);
drop function public.execute_confirm_apple_grant_revoked(uuid,uuid);
drop function execute_apple_grant_private.assert_capture_open(uuid,text);
drop function execute_apple_grant_private.lock_apple_subject(uuid);
drop function execute_apple_grant_private.lock_owner(uuid);
drop table execute_apple_grant_private.grants, execute_apple_grant_private.closures;
drop schema execute_apple_grant_private;
notify pgrst, 'reload schema';
commit;
