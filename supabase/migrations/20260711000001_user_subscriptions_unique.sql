-- Atomic upsert for user_subscriptions (B13).
-- upsertRecordBy was read-then-write: concurrent Stripe/RevenueCat webhooks
-- could each miss the other's insert and create duplicate rows for one user
-- (keyed by data->>'user_id' = email), making premium state flap.

-- 1) Dedupe existing rows: keep the newest (updated_date, id) per user_id.
delete from public.user_subscriptions a
using public.user_subscriptions b
where a.data->>'user_id' = b.data->>'user_id'
  and a.data->>'user_id' is not null
  and (a.updated_date, a.id) < (b.updated_date, b.id);

-- 2) Enforce one row per user_id going forward. Partial so legacy rows
--    without a user_id key don't block the index.
create unique index if not exists user_subscriptions_user_id_key
  on public.user_subscriptions ((data->>'user_id'))
  where data->>'user_id' is not null;

-- 3) Atomic upsert used by stripeWebhook + revenuecatWebhook (service role).
--    Plain-SQL ON CONFLICT supports the expression + partial-index clause
--    (PostgREST .upsert() does not, hence the RPC).
create or replace function public.upsert_user_subscription(p_user_id text, p_data jsonb)
returns setof jsonb
language sql
security invoker
as $$
  insert into public.user_subscriptions (owner_email, created_by, user_email, data)
  values (
    p_user_id,
    p_user_id,
    p_user_id,
    p_data || jsonb_build_object('user_id', p_user_id, 'created_by', p_user_id, 'user_email', p_user_id)
  )
  on conflict ((data->>'user_id')) where data->>'user_id' is not null
  do update set
    data = user_subscriptions.data || excluded.data,
    updated_date = now()
  returning to_jsonb(user_subscriptions.*);
$$;

grant execute on function public.upsert_user_subscription(text, jsonb) to service_role;
