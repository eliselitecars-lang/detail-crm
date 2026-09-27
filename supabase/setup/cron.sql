-- ============================================================================
-- Detail CRM — one-time scheduler setup (pg_cron + pg_net + Vault)
--
-- NOT a migration: it holds deploy-specific values, so it is run by hand,
-- once per project (and again whenever the values change). It is idempotent:
-- secrets are upserted and every job is unscheduled before being scheduled.
--
-- Jobs:
--   detail-crm-process-queue    every minute   POST messaging {"action":"process_queue"}
--                                              (sends queued SMS/email via Twilio/Resend)
--   detail-crm-run-automations  every 5 min    public.enqueue_due_automations()
--                                              (reminders / review requests / follow-ups;
--                                              the next process_queue run sends them)
--   detail-crm-expire-quotes    daily 06:05    public.expire_quotes()
--                               UTC            (quotes also expire lazily on public access)
--
-- HOW TO RUN
--   1. Deploy the functions and set the function secrets (see
--      supabase/functions/README.md), including
--        CRON_SECRET="$(openssl rand -hex 32)"      (at least 24 characters)
--   2. Copy this file somewhere PRIVATE (never commit the edited copy) and
--      replace the two placeholders below:
--        <PROJECT_REF>  your Supabase project ref (Dashboard -> Project Settings)
--        <CRON_SECRET>  exactly the CRON_SECRET function secret from step 1
--   3. Run it in the Dashboard SQL editor (or psql as postgres).
--   The script refuses to run while a placeholder is still present.
--
-- The URL and secret live in Supabase Vault (encrypted at rest) and are read
-- when each job runs, so they never appear in cron.job.command or in logs.
-- To rotate CRON_SECRET: set the new function secret, then re-run this file
-- with the new value (both sides must match; the function compares in
-- constant time and answers 401 otherwise).
--
-- Twilio webhooks are configured per shop number in the Twilio Console, not
-- here (see supabase/setup/twilio.md):
--   A message comes in:  https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=<SHOP_UUID>#rc=3&rp=all
--   (the status callback URL is sent with each outbound SMS automatically)
-- ============================================================================

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault;

-- ---------------------------------------------------------------------------
-- 1. Secrets (upsert into Vault)
-- ---------------------------------------------------------------------------
do $setup$
declare
  -- >>> EDIT THESE TWO VALUES (in a private copy) <<<
  v_functions_url constant text := 'https://<PROJECT_REF>.supabase.co/functions/v1';
  v_cron_secret   constant text := '<CRON_SECRET>';
  -- >>> END OF EDITS <<<
  v_id uuid;
begin
  if v_functions_url like '%<PROJECT_REF>%' or v_cron_secret = '<CRON_SECRET>' then
    raise exception 'cron.sql: replace <PROJECT_REF> and <CRON_SECRET> before running';
  end if;
  if v_functions_url !~ '^https://[^/[:space:]]+/functions/v1$' then
    raise exception 'cron.sql: the functions URL must look like https://<ref>.supabase.co/functions/v1';
  end if;
  if char_length(v_cron_secret) < 24 then
    raise exception 'cron.sql: CRON_SECRET must be at least 24 characters (same value as the function secret)';
  end if;

  select s.id into v_id from vault.secrets s where s.name = 'detail_crm_functions_url';
  if v_id is null then
    perform vault.create_secret(v_functions_url, 'detail_crm_functions_url',
                                'Detail CRM: public edge functions base URL (cron jobs)');
  else
    perform vault.update_secret(v_id, v_functions_url);
  end if;

  v_id := null;
  select s.id into v_id from vault.secrets s where s.name = 'detail_crm_cron_secret';
  if v_id is null then
    perform vault.create_secret(v_cron_secret, 'detail_crm_cron_secret',
                                'Detail CRM: x-cron-secret for the messaging function (= CRON_SECRET)');
  else
    perform vault.update_secret(v_id, v_cron_secret);
  end if;
end
$setup$;

-- ---------------------------------------------------------------------------
-- 2. Jobs (unschedule-if-exists, then schedule)
-- ---------------------------------------------------------------------------
select cron.unschedule(j.jobid)
  from cron.job j
 where j.jobname in ('detail-crm-process-queue', 'detail-crm-run-automations', 'detail-crm-expire-quotes',
                     'detail-crm-sweep-payment-sheets');

-- Send queued messages. The function drains up to 200 messages within ~45 s
-- per call; overlapping runs are safe (claim_queued_messages skips locked rows).
select cron.schedule(
  'detail-crm-process-queue',
  '* * * * *',
  $job$
  select net.http_post(
    url := (select s.decrypted_secret from vault.decrypted_secrets s
             where s.name = 'detail_crm_functions_url') || '/messaging',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select s.decrypted_secret from vault.decrypted_secrets s
                         where s.name = 'detail_crm_cron_secret')),
    body := '{"action":"process_queue"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $job$
);

-- Queue due automations directly in SQL (no HTTP hop). The same work is also
-- exposed as POST messaging {"action":"run_automations"} (x-cron-secret) for
-- manual runs.
select cron.schedule(
  'detail-crm-run-automations',
  '*/5 * * * *',
  $job$ select public.enqueue_due_automations(); $job$
);

select cron.schedule(
  'detail-crm-expire-quotes',
  '5 6 * * *',
  $job$ select public.expire_quotes(); $job$
);

-- Abandon iOS PaymentSheet intents left unconfirmed for 30+ minutes: cancels
-- them in Stripe and marks their pending payment rows cancelled, so a
-- dismissed sheet never keeps an invoice locked (void / pricing / line items).
select cron.schedule(
  'detail-crm-sweep-payment-sheets',
  '*/10 * * * *',
  $job$
  select net.http_post(
    url := (select s.decrypted_secret from vault.decrypted_secrets s
             where s.name = 'detail_crm_functions_url') || '/payments',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select s.decrypted_secret from vault.decrypted_secrets s
                         where s.name = 'detail_crm_cron_secret')),
    body := '{"action":"sweep_payment_sheets"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $job$
);

-- ---------------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------------
--   select jobname, schedule, active from cron.job where jobname like 'detail-crm-%';
--   select j.jobname, d.status, d.return_message, d.start_time
--     from cron.job_run_details d join cron.job j using (jobid)
--    where j.jobname like 'detail-crm-%' order by d.start_time desc limit 20;
--   -- HTTP results of process_queue (kept ~6 h by pg_net):
--   select id, status_code, content, created from net._http_response order by created desc limit 10;
--   -- 401 => the Vault secret and the CRON_SECRET function secret differ.
--
-- Remove everything
--   select cron.unschedule(jobid) from cron.job where jobname like 'detail-crm-%';
--   delete from vault.secrets where name in ('detail_crm_functions_url', 'detail_crm_cron_secret');
