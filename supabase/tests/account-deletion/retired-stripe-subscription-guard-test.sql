-- Synthetic PostgreSQL checks after bootstrap, all baseline migrations and
-- retired-stripe-subscription-guard.sql have been installed.
begin;

do $$
declare
  account_id constant uuid := '11111111-1111-1111-1111-111111111111';
  replacement_id constant uuid := 'b63e86de-de85-42b9-9248-6570d9987395';
  email constant text := 'writer-first@example.invalid';
  row_id constant uuid := '71f75ea5-53da-42ad-817a-4fbf3c44900e';
  foreign_row_id constant uuid := '151de126-9ef0-4741-ab68-6d6c6606512f';
  snapshot jsonb;
  created integer;
begin
  if not has_function_privilege('service_role',
          'public.retire_account_stripe_subscription_rows(uuid,text,jsonb)', 'EXECUTE')
     or has_function_privilege('authenticated',
          'public.retire_account_stripe_subscription_rows(uuid,text,jsonb)', 'EXECUTE')
     or has_function_privilege('anon',
          'public.retire_account_stripe_subscription_rows(uuid,text,jsonb)', 'EXECUTE')
     or has_table_privilege('service_role',
          'execute_deletion_private.retired_stripe_subscription', 'SELECT') then
    raise exception 'Unexpected retirement access';
  end if;
  select public.retire_account_stripe_subscription_rows(account_id, email, '[]') into created;
  if created <> 0 or exists (select from execute_deletion_private.retired_stripe_subscription) then
    raise exception 'Staged preflight changed durable state';
  end if;

  insert into public.user_subscriptions(id, owner_email, data) values
    (row_id, email, jsonb_build_object('user_id', email, 'stripe_subscription_id', 'sub_old',
                                      'stripe_subscription_ids', array['sub_linked', 'sub_old'])),
    (foreign_row_id, 'unrelated@example.invalid',
      '{"user_id":"unrelated@example.invalid","stripe_subscription_id":"sub_unrelated"}');
  snapshot := jsonb_build_object('id', row_id, 'owner_id', null,
                                'owner_email', email, 'created_by', null, 'user_email', null,
                                'legacy_user_id', email, 'stripe_id', 'sub_old',
                                'stripe_ids_json', '["sub_linked","sub_old"]');

  begin
    perform public.retire_account_stripe_subscription_rows(account_id, email,
      jsonb_build_array(snapshot, snapshot || jsonb_build_object('id', foreign_row_id)));
    raise exception 'A mixed-owner snapshot unexpectedly succeeded';
  exception when serialization_failure then null;
  end;
  if exists (select from execute_deletion_private.retired_stripe_subscription)
     or (select count(*) from public.user_subscriptions where id in (row_id, foreign_row_id)) <> 2 then
    raise exception 'A rejected request leaked partial state';
  end if;

  update public.user_subscriptions
    set data = jsonb_set(data, '{stripe_subscription_ids}', '["sub_linked","sub_old","sub_recent"]')
    where id = row_id;
  begin
    perform public.retire_account_stripe_subscription_rows(account_id, email, jsonb_build_array(snapshot));
    raise exception 'An outdated snapshot unexpectedly succeeded';
  exception when serialization_failure then null;
  end;
  if exists (select from execute_deletion_private.retired_stripe_subscription) then
    raise exception 'An outdated snapshot recorded retired references';
  end if;

  snapshot := snapshot || jsonb_build_object('stripe_ids_json', '["sub_linked","sub_old","sub_recent"]');
  select public.retire_account_stripe_subscription_rows(account_id, email, jsonb_build_array(snapshot)) into created;
  if created <> 1
     or (select count(*) from execute_deletion_private.retired_stripe_subscription) <> 3
     or exists (select from public.user_subscriptions where id = row_id)
     or not exists (select from public.user_subscriptions where id = foreign_row_id) then
    raise exception 'Verified retirement did not preserve the intended scope';
  end if;

  delete from auth.users where id = account_id;
  insert into auth.users (id, email) values (replacement_id, email);
  begin
    perform public.retire_account_stripe_subscription_rows(account_id, email, jsonb_build_array(snapshot));
    raise exception 'A removed Auth UUID unexpectedly authorized deletion';
  exception when serialization_failure then null;
  end;

  begin
    perform public.reconcile_revenuecat_subscriptions(jsonb_build_array(jsonb_build_object(
      'user_id', email, 'expected_updated_date', null,
      'data', jsonb_build_object('stripe_subscription_id', 'sub_old', 'plan', 'premium'))));
    raise exception 'A reconciliation unexpectedly restored a retired selected subscription';
  exception when check_violation then null;
  end;
  if public.reconcile_revenuecat_subscriptions(jsonb_build_array(jsonb_build_object(
    'user_id', email, 'expected_updated_date', null,
    'data', jsonb_build_object('stripe_subscription_id', 'sub_replacement', 'plan', 'premium')))) <> 1 then
    raise exception 'A new provider association should succeed for a reused email';
  end if;

  begin
    perform public.upsert_user_subscription(email,
      '{"stripe_subscription_ids":["sub_replacement","sub_linked"],"plan":"premium"}');
    raise exception 'Legacy upsert unexpectedly accepted a retired plural reference';
  exception when check_violation then null;
  end;
  if (select data->>'stripe_subscription_id' from public.user_subscriptions
      where data->>'user_id' = email) <> 'sub_replacement' then
    raise exception 'The replacement subscription was overwritten';
  end if;
end
$$;

rollback;
