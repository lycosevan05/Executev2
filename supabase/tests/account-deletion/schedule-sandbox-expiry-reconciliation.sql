-- Dedicated hosted deletion rehearsal only. Add the random, route-specific
-- execute_sandbox_expiry_job_secret to Vault and the Edge secret separately.
-- This job neither uses nor stores a service-role key.
begin;

do $$
begin
  if (select count(*) from vault.decrypted_secrets
      where name = 'execute_sandbox_expiry_job_secret'
        and length(decrypted_secret) >= 32) <> 1 then
    raise exception 'Sandbox expiry job secret unavailable';
  end if;
end;
$$;

select cron.schedule(
  'execute-sandbox-expiry-reconciliation',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url := 'https://rnhwzvliewgsxhqysiom.supabase.co/functions/v1/revenuecatExpiryReconcile',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
        where name = 'execute_sandbox_expiry_job_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 25000
  )
  $job$
);

commit;
