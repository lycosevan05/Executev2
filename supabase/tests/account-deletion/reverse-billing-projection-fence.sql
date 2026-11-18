-- Only after withdrawing the staged deletion route and finishing all admitted
-- work. Keep the old writer guard in place while any identity remains closed.
begin;
set local lock_timeout = '5s';
lock table public.user_subscriptions in exclusive mode;
lock table execute_deletion_private.closed_billing_identity in exclusive mode;
do $$
begin
  if exists (select from execute_deletion_private.closed_billing_identity) then
    raise exception 'Closed billing identities require verified provider reassociation';
  end if;
end;
$$;
drop trigger reject_closed_billing_identity on public.user_subscriptions;
drop function public.close_account_billing_projection(uuid, text, jsonb);
drop function execute_deletion_private.reject_closed_billing_identity();
drop function execute_deletion_private.billing_projection_identities(public.user_subscriptions);
drop function execute_deletion_private.billing_identity_fingerprint(text);
drop table execute_deletion_private.closed_billing_identity;
drop table execute_deletion_private.billing_projection_fence_key;
notify pgrst, 'reload schema';
commit;
