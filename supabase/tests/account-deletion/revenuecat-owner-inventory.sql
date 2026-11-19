-- Read-only aggregate for a specifically approved project. Do not use an email
-- match to assign a provider identity or modify account ownership.
with projected as (
  select
    s.owner_id,
    nullif(trim(s.data->>'revenuecat_app_user_id'), '') as provider_id,
    nullif(lower(trim(s.data->>'user_id')), '') as legacy_key
  from public.user_subscriptions s
  where nullif(trim(s.data->>'revenuecat_app_user_id'), '') is not null
), owner_inventory as (
  select p.*,
    exists (select 1 from auth.users u where u.id = p.owner_id) as has_auth_owner,
    (select count(*) from auth.users u where lower(trim(u.email)) = p.legacy_key) as email_matches
  from projected p
)
select
  count(*) as revenuecat_rows,
  count(*) filter (
    where provider_id ~ '^[^[:space:]@]+@[^[:space:]@]+$'
  ) as email_provider_ids,
  count(*) filter (
    where provider_id ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
  ) as uuid_provider_ids,
  count(*) filter (where has_auth_owner) as rows_with_auth_uuid,
  count(*) filter (
    where has_auth_owner and lower(provider_id) = owner_id::text
  ) as provider_id_matches_auth_uuid,
  count(*) filter (where email_matches = 0) as no_current_legacy_email_match,
  count(*) filter (where email_matches = 1) as one_current_legacy_email_match,
  count(*) filter (where email_matches > 1) as ambiguous_current_legacy_email
from owner_inventory;
