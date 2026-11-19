-- Use only a disposable database with Auth users and identities fixture tables.
insert into auth.users(id) values
  ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'),
  ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef');
insert into auth.identities(user_id, provider, identity_data) values
  ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'apple', '{"sub":"exact-apple-owner"}'),
  ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef', 'google', '{"sub":"unrelated-identity"}');

do $$
begin
  if has_function_privilege('authenticated', 'public.execute_close_apple_grants(uuid,text,text)', 'execute')
    or has_function_privilege('anon', 'public.execute_capture_apple_grant(uuid,text,text,uuid,text,text,text,text)', 'execute')
    or has_table_privilege('service_role', 'execute_apple_grant_private.grants', 'select')
    or not has_function_privilege('service_role', 'public.execute_capture_apple_grant(uuid,text,text,uuid,text,text,text,text)', 'execute') then
    raise exception 'incorrect grant access';
  end if;
end;
$$;

set role service_role;
do $$
declare
  owner_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  witness_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef';
  first_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-111111111111';
  second_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-222222222222';
  later_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-333333333333';
  client_id constant text := 'invalid.example.apple-qa';
  subject_id constant text := 'exact-apple-owner';
  closure jsonb;
begin
  if public.execute_has_apple_grant(owner_id, subject_id, client_id, array[repeat('a', 64)]) then
    raise exception 'unexpected initial grant';
  end if;
  begin
    perform public.execute_capture_apple_grant(witness_id, subject_id, client_id, first_id, 'v1',
      repeat('a', 64), repeat('a', 24), repeat('a', 34));
    raise exception 'accepted unrelated owner';
  exception when object_not_in_prerequisite_state then
    null;
  end;
  perform public.execute_capture_apple_grant(owner_id, subject_id, client_id, first_id, 'v1',
    repeat('a', 64), repeat('a', 24), repeat('a', 34));
  perform public.execute_capture_apple_grant(owner_id, subject_id, client_id, later_id, 'v1',
    repeat('a', 64), repeat('b', 24), repeat('b', 34));
  perform public.execute_capture_apple_grant(owner_id, subject_id, client_id, second_id, 'v2',
    repeat('b', 64), repeat('a', 24), repeat('a', 34));
  if not public.execute_has_apple_grant(owner_id, subject_id, client_id, array[repeat('b', 64)]) then
    raise exception 'previously verified grant was not recognized';
  end if;
  if public.execute_has_apple_grant(owner_id, subject_id, client_id, array[repeat('c', 64)]) then
    raise exception 'unexpected grant before closure';
  end if;
  begin
    perform public.execute_confirm_apple_grant_revoked(owner_id, first_id);
    raise exception 'consumed a grant before closure';
  exception when object_not_in_prerequisite_state then
    null;
  end;
  closure := public.execute_close_apple_grants(owner_id, subject_id, client_id);
  if closure->>'revoked' <> 'false' or jsonb_array_length(closure->'grants') <> 2
    or closure->'grants'->0->>'id' <> first_id::text then
    raise exception 'closure did not snapshot both distinct grants';
  end if;
  begin
    perform public.execute_capture_apple_grant(owner_id, subject_id, client_id, later_id, 'v1',
      repeat('c', 64), repeat('a', 24), repeat('a', 34));
    raise exception 'accepted an in-flight capture after closure';
  exception when object_not_in_prerequisite_state then
    null;
  end;
  begin
    perform public.execute_close_apple_grants(owner_id, subject_id, 'invalid.example.changed');
    raise exception 'accepted client ID change after closure';
  exception when object_not_in_prerequisite_state then
    null;
  end;
  perform public.execute_confirm_apple_grant_revoked(owner_id, first_id);
  perform public.execute_confirm_apple_grant_revoked(owner_id, first_id);
  closure := public.execute_close_apple_grants(owner_id, subject_id, client_id);
  if closure->>'revoked' <> 'false' or jsonb_array_length(closure->'grants') <> 1
    or closure->'grants'->0->>'id' <> second_id::text then
    raise exception 'closure lost the remaining grant after a partial revocation';
  end if;
end;
$$;
reset role;

do $$
begin
  begin
    delete from auth.users where id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    raise exception 'Auth deletion discarded a pending Apple grant';
  exception when foreign_key_violation then
    null;
  end;
end;
$$;

set role service_role;
do $$
declare
  owner_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  witness_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef';
  second_id constant uuid := 'aaaaaaaa-bbbb-cccc-dddd-222222222222';
  client_id constant text := 'invalid.example.apple-qa';
begin
  perform public.execute_confirm_apple_grant_revoked(owner_id, second_id);
  if public.execute_close_apple_grants(owner_id, 'exact-apple-owner', client_id)
    <> '{"revoked":true,"grants":[]}'::jsonb then
    raise exception 'lost receipt across the deletion retry';
  end if;
  if public.execute_close_apple_grants(witness_id, null, client_id)
    <> '{"revoked":false,"grants":[]}'::jsonb then
    raise exception 'could not distinguish an unrelated account from a revoked user';
  end if;
end;
$$;
reset role;
delete from auth.users where id in (
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef'
);
do $$
begin
  if exists (select from execute_apple_grant_private.closures)
    or exists (select from execute_apple_grant_private.grants) then
    raise exception 'Apple lifecycle left orphaned grant state';
  end if;
end;
$$;
