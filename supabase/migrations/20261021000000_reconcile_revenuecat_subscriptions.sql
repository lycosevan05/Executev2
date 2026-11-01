-- Both sides of a RevenueCat transfer must commit together. Keep the existing
-- Stripe upsert RPC and unique email index; reject stale provider snapshots if
-- any participant changed after the webhook read its row.
-- No deduplication/deletion: if legacy duplicate emails exist, this must fail
-- and be reviewed before rollout. Do not run unrelated pending migrations.
create unique index if not exists user_subscriptions_user_id_key
  on public.user_subscriptions ((data->>'user_id'))
  where data->>'user_id' is not null;

create or replace function public.reconcile_revenuecat_subscriptions(p_changes jsonb)
returns integer
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  item jsonb;
  user_key text;
  expected_revision timestamptz;
  existing_row public.user_subscriptions%rowtype;
  merged_data jsonb;
  applied integer := 0;
  inserted_count integer;
begin
  if jsonb_typeof(p_changes) is distinct from 'array'
     or jsonb_array_length(p_changes) not between 1 and 200 then
    raise exception 'Invalid reconciliation batch';
  end if;

  for item in select value from jsonb_array_elements(p_changes) order by value->>'user_id'
  loop
    user_key := item->>'user_id';
    if user_key is null or user_key !~ '^[^[:space:]@]+@[^[:space:]@]+$'
       or jsonb_typeof(item->'data') is distinct from 'object'
       or not (item ? 'expected_updated_date') then
      raise exception 'Invalid reconciliation change';
    end if;
    expected_revision := (item->>'expected_updated_date')::timestamptz;
    -- Consistent lock ordering avoids deadlocks for overlapping A/B transfers.
    perform pg_advisory_xact_lock(hashtextextended('rc-subscription:' || user_key, 0));
    select * into existing_row from public.user_subscriptions
      where data->>'user_id' = user_key for update;

    if found then
      if expected_revision is null or existing_row.updated_date <> expected_revision then
        raise exception 'Subscription changed during reconciliation' using errcode = '40001';
      end if;
      merged_data := existing_row.data || (item->'data') || jsonb_build_object('user_id', user_key);
      update public.user_subscriptions set data = merged_data, updated_date = now()
        where id = existing_row.id;
    else
      if expected_revision is not null then
        raise exception 'Subscription disappeared during reconciliation' using errcode = '40001';
      end if;
      merged_data := (item->'data') || jsonb_build_object(
        'user_id', user_key, 'created_by', user_key, 'user_email', user_key);
      insert into public.user_subscriptions (owner_email, created_by, user_email, data)
        values (user_key, user_key, user_key, merged_data)
        on conflict ((data->>'user_id')) where data->>'user_id' is not null do nothing;
      get diagnostics inserted_count = row_count;
      if inserted_count <> 1 then
        raise exception 'Subscription created during reconciliation' using errcode = '40001';
      end if;
    end if;
    applied := applied + 1;
  end loop;
  return applied;
end;
$$;

revoke all on function public.reconcile_revenuecat_subscriptions(jsonb) from public, anon, authenticated;
grant execute on function public.reconcile_revenuecat_subscriptions(jsonb) to service_role;
