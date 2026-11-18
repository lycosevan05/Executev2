\set ON_ERROR_STOP 1
-- Run only against a new, disposable database after the normal fixture
-- bootstrap, baseline migration chain, and billing-projection-fence.sql.
begin;

insert into public.user_subscriptions (id, owner_email, data)
values
  ('d7111111-1111-4111-8111-111111111111', 'writer-first@example.invalid',
   '{"user_id":"writer-first@example.invalid","stripe_subscription_id":"sub_old","plan":"premium"}'),
  ('d7222222-2222-4222-8222-222222222222', 'unrelated@example.invalid',
   '{"user_id":"unrelated@example.invalid","plan":"free"}');

do $$
declare
  target constant uuid := '11111111-1111-1111-1111-111111111111';
  successor constant uuid := 'f7111111-1111-4111-8111-111111111111';
  email constant text := 'writer-first@example.invalid';
  row_id constant uuid := 'd7111111-1111-4111-8111-111111111111';
  witness constant uuid := 'd7222222-2222-4222-8222-222222222222';
  expected jsonb;
  observed jsonb;
  item jsonb;
  rejected integer := 0;
begin
  if has_function_privilege('authenticated', 'public.close_account_billing_projection(uuid,text,jsonb)', 'execute')
     or has_table_privilege('service_role', 'execute_deletion_private.closed_billing_identity', 'select')
     or has_table_privilege('service_role', 'execute_deletion_private.billing_projection_fence_key', 'select') then
    raise exception 'Fence controls are not isolated';
  end if;

  select jsonb_build_array(to_jsonb(snapshot)) into expected
  from (select id, owner_id, owner_email, created_by, user_email, data
        from public.user_subscriptions where id = row_id) snapshot;
  if expected is null then raise exception 'Missing fixture'; end if;
  update public.user_subscriptions set data = data || '{"revenuecat_plan":"premium"}'
    where id = row_id;
  begin
    perform public.close_account_billing_projection(target, email, expected);
    raise exception 'Stale provider projection accepted for deletion';
  exception when serialization_failure then null;
  end;
  if exists (select from execute_deletion_private.closed_billing_identity) then
    raise exception 'Stale preflight left a durable marker';
  end if;
  select jsonb_build_array(to_jsonb(snapshot)) into expected
  from (select id, owner_id, owner_email, created_by, user_email, data
        from public.user_subscriptions where id = row_id) snapshot;

  -- A valid owned row with a foreign alias refuses deletion before a marker.
  update public.user_subscriptions
    set owner_id = target, data = data || '{"revenuecat_app_user_id":"foreign@example.invalid"}'
    where id = row_id;
  begin
    perform public.close_account_billing_projection(target, email, expected);
    raise exception 'Ambiguous provider alias accepted for deletion';
  exception when check_violation then null;
  end;
  update public.user_subscriptions
    set owner_id = null, data = data - 'revenuecat_app_user_id'
    where id = row_id;
  if not public.close_account_billing_projection(target, email, expected) then
    raise exception 'Exact billing projection could not be fenced';
  end if;

  -- A same-owner retry may revalidate the exact current row without reopening
  -- writes. Both previously inventoried and unseen provider IDs are held.
  if not public.close_account_billing_projection(target, email, expected) then
    raise exception 'Same-owner retry failed';
  end if;
  for item in select value from jsonb_array_elements('[
      {"stripe_subscription_id":"sub_old","plan":"premium"},
      {"stripe_subscription_id":"sub_unseen","plan":"premium"},
      {"revenuecat_product_id":"external_sandbox","revenuecat_plan":"premium"},
      {"plan":"premium"}
    ]'::jsonb)
  loop
    begin
      perform public.upsert_user_subscription(email, item);
      raise exception 'Closed billing identity accepted a provider projection';
    exception when check_violation then rejected := rejected + 1;
    end;
  end loop;
  if rejected <> 4 then raise exception 'Provider rejection mismatch'; end if;

  delete from public.user_subscriptions where id = row_id;
  delete from auth.users where id = target;
  insert into auth.users(id, email) values (successor, email);
  begin
    perform public.upsert_user_subscription(upper(email), '{"stripe_subscription_id":"sub_late"}');
    raise exception 'Closed identity accepted a late write after account reuse';
  exception when check_violation then null;
  end;
  begin
    perform public.upsert_user_subscription(target::text, '{"plan":"premium"}');
    raise exception 'Closed owner UUID accepted a late write';
  exception when check_violation then null;
  end;
  begin
    perform public.close_account_billing_projection(successor, email, '[]'::jsonb);
    raise exception 'Successor altered the previous owner marker';
  exception when check_violation then null;
  end;
  begin
    insert into public.user_subscriptions (owner_id, owner_email, data)
      values (successor, email, '{"plan":"premium"}');
    raise exception 'Projection with an email column and no provider ID escaped the hold';
  exception when check_violation then null;
  end;

  select to_jsonb(subscription) into observed from public.user_subscriptions as subscription where id = witness;
  begin
    perform public.reconcile_revenuecat_subscriptions(jsonb_build_array(
      jsonb_build_object('user_id', 'unrelated@example.invalid',
        'expected_updated_date', observed->>'updated_date', 'data', jsonb_build_object('plan', 'premium')),
      jsonb_build_object('user_id', email,
        'expected_updated_date', null, 'data', jsonb_build_object('revenuecat_plan', 'premium'))
    ));
    raise exception 'Mixed provider batch accepted a closed identity';
  exception when check_violation then null;
  end;
  if observed is distinct from (select to_jsonb(s) from public.user_subscriptions s where s.id = witness) then
    raise exception 'Guarded provider batch leaked a partial write';
  end if;
  perform public.upsert_user_subscription('unrelated@example.invalid', '{"plan":"premium"}');
  if (select data->>'plan' from public.user_subscriptions where id = witness) <> 'premium' then
    raise exception 'Unrelated billing update was blocked';
  end if;
end;
$$;

rollback;
\echo 'PASS: late known, unseen and email-only provider projections stay blocked after same-email reuse'
