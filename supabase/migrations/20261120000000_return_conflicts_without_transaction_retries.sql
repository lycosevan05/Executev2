-- These application conflicts require new caller input. PostgREST 14 may
-- retry a transaction indefinitely if an RPC raises serialization_failure.
-- PT409 returns HTTP 409 to the caller and preserves the atomic rollback.
do $migration$
declare
  routine record;
  target regprocedure;
  definition text;
  old_clause constant text := 'using errcode = ''40001''';
  new_clause constant text := 'using errcode = ''PT409''';
  old_count integer;
  new_count integer;
begin
  for routine in select * from (values
    ('public.reconcile_revenuecat_subscriptions(jsonb)', 3, true),
    ('public.close_account_upload_admission(uuid)', 1, false),
    ('public.begin_account_upload_dispatch(uuid,text)', 1, false),
    ('public.close_and_list_account_upload_dispatches(uuid)', 1, false),
    ('public.begin_exact_account_upload_dispatch(uuid,text)', 1, false)
  ) as targets(signature, conflicts, required)
  loop
    target := to_regprocedure(routine.signature);
    if target is null then
      if routine.required then
        raise exception 'Missing required billing function %', routine.signature;
      end if;
      -- Upload guards are installed separately for projects using that route.
      continue;
    end if;
    definition := pg_get_functiondef(target);
    old_count := cardinality(string_to_array(definition, old_clause)) - 1;
    new_count := cardinality(string_to_array(definition, new_clause)) - 1;
    if old_count = routine.conflicts and new_count = 0 then
      -- Retain the signature, security mode, search path, owner and grants.
      execute replace(definition, old_clause, new_clause);
    elsif old_count <> 0 or new_count <> routine.conflicts then
      raise exception 'Unexpected conflict handling in %', routine.signature;
    end if;
  end loop;
end
$migration$;
