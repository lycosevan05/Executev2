-- Run after the staged billing fence and checkout admission in a disposable database.
begin;
do $$
declare
  fixture_owner constant uuid := '11111111-1111-1111-1111-111111111111';
  closed_owner constant uuid := '22222222-2222-2222-2222-222222222222';
  unrelated constant uuid := '33333333-3333-3333-3333-333333333333';
  returning_owner constant uuid := '44444444-4444-4444-4444-444444444444';
  email constant text := 'writer-first@example.invalid';
  closed_email constant text := 'deletion-first@example.invalid';
  unrelated_email constant text := 'unrelated@example.invalid';
  session_id constant text := 'cs_test_verified';
  observed jsonb;
  earlier uuid;
begin
  if has_function_privilege('authenticated', 'public.begin_guarded_stripe_checkout(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.acknowledge_guarded_stripe_checkout(uuid,text,uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.finish_guarded_stripe_checkout_drain(uuid,text,jsonb)', 'execute')
     or has_table_privilege('service_role', 'execute_checkout_private.dispatch', 'delete') then
    raise exception 'Checkout guard permissions are too broad';
  end if;
  earlier := public.begin_guarded_stripe_checkout(fixture_owner, email);
  if earlier is null then raise exception 'Registration returned no dispatch'; end if;
  if (select stripe_session_id from public.close_and_list_guarded_stripe_checkouts(fixture_owner,email)) is not null
     or not exists (select from execute_checkout_private.dispatch d where d.dispatch_id = earlier) then
    raise exception 'Closure lost an unknown dispatch';
  end if;
  begin
    delete from auth.users where id = fixture_owner;
    raise exception 'Hard Auth deletion silently discarded an unverified checkout';
  exception when foreign_key_violation then null;
  end;
  begin
    perform public.acknowledge_guarded_stripe_checkout(unrelated, unrelated_email, earlier, session_id);
    raise exception 'Foreign receipt acknowledged';
  exception when invalid_parameter_value then null;
  end;
  if public.acknowledge_guarded_stripe_checkout(fixture_owner, email, earlier, session_id) is not false then
    raise exception 'Concurrent closure let an acknowledged checkout URL escape';
  end if;
  begin
    perform public.acknowledge_guarded_stripe_checkout(fixture_owner, email, earlier, 'cs_test_different');
    raise exception 'Exact receipt overwritten';
  exception when invalid_parameter_value then null;
  end;
  if public.acknowledge_guarded_stripe_checkout(fixture_owner, email, earlier, session_id) is not false then
    raise exception 'Repeating the same receipt reopened a checkout URL';
  end if;
  select jsonb_agg(to_jsonb(d)) into observed
  from public.close_and_list_guarded_stripe_checkouts(fixture_owner,email) d;
  begin
    perform public.finish_guarded_stripe_checkout_drain(fixture_owner,email,observed);
    raise exception 'Closure finished without the projection fence';
  exception when object_not_in_prerequisite_state then null;
  end;
  if not public.close_account_billing_projection(fixture_owner,email,'[]') then
    raise exception 'Projection fence unavailable';
  end if;
  begin
    perform public.finish_guarded_stripe_checkout_drain(fixture_owner,email,'[]');
    raise exception 'Changed inventory finished successfully';
  exception when serialization_failure then null;
  end;
  if not public.finish_guarded_stripe_checkout_drain(fixture_owner,email,observed) then
    raise exception 'Checkout drain did not finish';
  end if;
  if exists (select from execute_checkout_private.dispatch d where d.owner_id = fixture_owner)
     or not exists (select from execute_checkout_private.closed_admission a where a.owner_id = fixture_owner) then
    raise exception 'Checkout history or closure failed to settle';
  end if;
  -- A retry can complete the now-empty ledger without reopening this owner.
  if not public.finish_guarded_stripe_checkout_drain(fixture_owner,email,'[]') then
    raise exception 'Completed drain was not retryable';
  end if;
  begin
    perform public.begin_guarded_stripe_checkout(fixture_owner,email);
    raise exception 'Closure reopened before Auth removal';
  exception when object_not_in_prerequisite_state then null;
  end;
  delete from auth.users where id = fixture_owner;
  if exists (select from execute_checkout_private.closed_admission a where a.owner_id = fixture_owner) then
    raise exception 'Auth removal retained the owner closure';
  end if;
  insert into auth.users(id,email) values (returning_owner, upper(email));
  begin
    perform public.begin_guarded_stripe_checkout(returning_owner,upper(email));
    raise exception 'Same-email replacement could pay while provider reconciliation remains fenced';
  exception when object_not_in_prerequisite_state then null;
  end;
  if exists (select from public.close_and_list_guarded_stripe_checkouts(closed_owner,closed_email)) then
    raise exception 'Clean closure invented a dispatch';
  end if;
  begin
    perform public.begin_guarded_stripe_checkout(closed_owner,closed_email);
    raise exception 'Close-first ordering admitted a new checkout';
  exception when object_not_in_prerequisite_state then null;
  end;
  if public.begin_guarded_stripe_checkout(unrelated,unrelated_email) is null then
    raise exception 'Unrelated owner could not register checkout';
  end if;
end;
$$;
rollback;
