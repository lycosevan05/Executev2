-- Before reversing the billing fence, stop any ledger users and reverse this
-- optional foundation. A populated ledger needs separate reconciliation.
begin;
set local lock_timeout = '5s';

lock table public.user_subscriptions in exclusive mode;
lock table execute_revenuecat_private.identity_key, execute_revenuecat_private.accounts,
  execute_revenuecat_private.identifiers in access exclusive mode;
do $$
begin
  if exists (select from execute_revenuecat_private.accounts)
     or exists (select from execute_revenuecat_private.identifiers) then
    raise exception 'RevenueCat identity bindings require reconciliation before rollback' using errcode = '55000';
  end if;
end;
$$;

drop function public.retire_revenuecat_identity(text, uuid);
drop function public.resolve_revenuecat_identity(text, text);
drop function public.attach_verified_revenuecat_alias(text, uuid, text);
drop function public.ensure_revenuecat_customer_id(text, uuid);
drop function execute_revenuecat_private.require_open_owner(uuid);
drop function execute_revenuecat_private.lock_projection();
drop function execute_revenuecat_private.billing_owner_closed(uuid);
drop function execute_revenuecat_private.identity_fingerprint(text, text, text);
drop table execute_revenuecat_private.identifiers, execute_revenuecat_private.accounts,
  execute_revenuecat_private.identity_key;
drop schema execute_revenuecat_private;
notify pgrst, 'reload schema';
commit;
