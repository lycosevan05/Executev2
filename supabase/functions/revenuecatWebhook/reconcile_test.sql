-- LOCAL TEST DATABASE ONLY. Apply the schema, unique-email and reconciliation
-- migrations first. All fixture writes roll back; never use production for QA.
begin;
insert into public.user_subscriptions(owner_email, created_by, user_email, data, updated_date)
values ('transfer-a@example.test', 'transfer-a@example.test', 'transfer-a@example.test',
  '{"user_id":"transfer-a@example.test","plan":"premium","status":"active","stripe_customer_id":"cus_preserve","unrelated":"preserve"}',
  '2026-10-21T20:00:00.123456Z');

-- 1. A source update and a new destination commit in one call, without losing
-- email ownership, unrelated fields, or existing Stripe identifiers.
do $$
declare n integer;
begin
  select public.reconcile_revenuecat_subscriptions('[
    {"user_id":"transfer-a@example.test","expected_updated_date":"2026-10-21T20:00:00.123456Z","data":{"plan":"free","status":"canceled"}},
    {"user_id":"transfer-b@example.test","expected_updated_date":null,"data":{"plan":"premium","status":"active"}}
  ]') into n;
  if n <> 2 then raise exception 'Expected two applied changes'; end if;
  if not exists(select 1 from public.user_subscriptions where data->>'user_id'='transfer-a@example.test'
    and data->>'plan'='free' and data->>'unrelated'='preserve' and data->>'stripe_customer_id'='cus_preserve')
    then raise exception 'Source/metadata reconciliation failed'; end if;
  if not exists(select 1 from public.user_subscriptions where data->>'user_id'='transfer-b@example.test'
    and data->>'plan'='premium' and owner_email='transfer-b@example.test' and user_email='transfer-b@example.test')
    then raise exception 'Destination/ownership reconciliation failed'; end if;
end $$;

-- 2. A destination revision conflict rolls back the source write too.
do $$
declare before_rows jsonb; after_rows jsonb; source_revision text;
begin
  select jsonb_agg(to_jsonb(s) order by id) into before_rows from public.user_subscriptions s;
  select updated_date::text into source_revision from public.user_subscriptions where data->>'user_id'='transfer-a@example.test';
  begin
    perform public.reconcile_revenuecat_subscriptions(jsonb_build_array(
      jsonb_build_object('user_id','transfer-a@example.test','expected_updated_date',source_revision,'data','{"plan":"premium"}'::jsonb),
      jsonb_build_object('user_id','transfer-b@example.test','expected_updated_date','2000-01-01','data','{"plan":"free"}'::jsonb)
    ));
    raise exception 'Expected a revision conflict';
  exception when sqlstate '40001' then null;
  end;
  select jsonb_agg(to_jsonb(s) order by id) into after_rows from public.user_subscriptions s;
  if before_rows is distinct from after_rows then raise exception 'Partial transfer escaped rollback'; end if;
end $$;

-- 3. An expected-absent row that another writer created is never overwritten.
do $$
begin
  begin
    perform public.reconcile_revenuecat_subscriptions('[{"user_id":"transfer-b@example.test","expected_updated_date":null,"data":{"plan":"free"}}]');
    raise exception 'Expected an insert-race conflict';
  exception when sqlstate '40001' then null;
  end;
  if not exists(select 1 from public.user_subscriptions where data->>'user_id'='transfer-b@example.test' and data->>'plan'='premium')
    then raise exception 'Concurrent entitlement overwritten'; end if;
end $$;

-- 4. Duplicate delivery with freshly read revisions keeps one row per email.
do $$
declare changes jsonb;
begin
  select jsonb_agg(jsonb_build_object('user_id',data->>'user_id','expected_updated_date',updated_date::text,'data',data))
    into changes from public.user_subscriptions where data->>'user_id' in ('transfer-a@example.test','transfer-b@example.test');
  perform public.reconcile_revenuecat_subscriptions(changes);
  if (select count(*) from public.user_subscriptions where data->>'user_id' in ('transfer-a@example.test','transfer-b@example.test')) <> 2
    then raise exception 'Duplicate subscription rows created'; end if;
end $$;

-- 5. Anonymous identifiers are refused by the database boundary too.
do $$
begin
  begin
    perform public.reconcile_revenuecat_subscriptions('[{"user_id":"$RCAnonymousID:qa","expected_updated_date":null,"data":{}}]');
    raise exception 'Anonymous row was accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid reconciliation change' then raise; end if;
  end;
end $$;

-- 6. Only the service role can call the RPC; it does not bypass table RLS.
do $$
begin
  if has_function_privilege('anon','public.reconcile_revenuecat_subscriptions(jsonb)','EXECUTE')
     or has_function_privilege('authenticated','public.reconcile_revenuecat_subscriptions(jsonb)','EXECUTE')
     or not has_function_privilege('service_role','public.reconcile_revenuecat_subscriptions(jsonb)','EXECUTE')
     or (select prosecdef from pg_proc where oid='public.reconcile_revenuecat_subscriptions(jsonb)'::regprocedure)
    then raise exception 'RPC access boundary changed'; end if;
end $$;
rollback;
