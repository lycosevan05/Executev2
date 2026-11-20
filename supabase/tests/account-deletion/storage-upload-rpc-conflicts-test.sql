-- Local PostgreSQL only, after installing the three upload guard scripts.
-- A guard rejection must reach the caller as a business conflict.
begin isolation level repeatable read;
do $$
declare
  owner_id uuid := gen_random_uuid();
begin
  begin
    perform public.begin_account_upload_dispatch(owner_id, 'sample.txt');
    raise exception 'Expected dispatch isolation conflict';
  exception when sqlstate 'PT409' then null;
  end;
  begin
    perform public.begin_exact_account_upload_dispatch(owner_id, owner_id::text || '/sample.txt');
    raise exception 'Expected exact dispatch isolation conflict';
  exception when sqlstate 'PT409' then null;
  end;
  begin
    perform public.close_and_list_account_upload_dispatches(owner_id);
    raise exception 'Expected closure isolation conflict';
  exception when sqlstate 'PT409' then null;
  end;
end $$;
rollback;

begin isolation level read committed;
do $$
declare
  owner_id uuid := gen_random_uuid();
  generated uuid;
  exact uuid;
  pending integer;
begin
  begin
    perform public.close_account_upload_admission(owner_id);
    raise exception 'Expected missing-owner conflict';
  exception when sqlstate 'PT409' then null;
  end;
  insert into auth.users(id) values (owner_id);
  select dispatch_id into strict generated from public.begin_account_upload_dispatch(owner_id, 'sample.txt');
  select dispatch_id into strict exact from public.begin_exact_account_upload_dispatch(owner_id, owner_id::text || '/exact.txt');
  select count(*) into pending from public.close_and_list_account_upload_dispatches(owner_id);
  if pending <> 2 then raise exception 'Closure lost pending dispatches'; end if;
  begin
    perform public.begin_account_upload_dispatch(owner_id, 'closed.txt');
    raise exception 'Closed owner received a new dispatch';
  exception when sqlstate '55000' then null;
  end;
  perform public.finish_account_upload_dispatch(owner_id, generated);
  perform public.finish_account_upload_dispatch(owner_id, exact);
  if exists(select from public.close_and_list_account_upload_dispatches(owner_id)) then
    raise exception 'Completed dispatches remained pending';
  end if;
end $$;
rollback;
