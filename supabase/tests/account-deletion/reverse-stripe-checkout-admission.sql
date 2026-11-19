-- Withdraw the staged deletion and guarded checkout routes before reversal.
-- Restore writer access only after separately reconciling provider outcomes.
begin;
set local lock_timeout = '5s';
lock table execute_checkout_private.closed_admission,
  execute_checkout_private.dispatch in access exclusive mode;
do $$
begin
  if exists (select from execute_checkout_private.closed_admission)
    or exists (select from execute_checkout_private.dispatch) then
    raise exception 'Checkout dispatches and closures require verified reconciliation';
  end if;
end;
$$;
drop function public.close_and_list_guarded_stripe_checkouts(uuid, text);
drop function public.finish_guarded_stripe_checkout_drain(uuid, text, jsonb);
drop function public.acknowledge_guarded_stripe_checkout(uuid, text, uuid, text);
drop function public.begin_guarded_stripe_checkout(uuid, text);
drop function execute_checkout_private.lock_live_owner(uuid, text);
drop table execute_checkout_private.dispatch, execute_checkout_private.closed_admission;
drop schema execute_checkout_private;
notify pgrst, 'reload schema';
commit;
