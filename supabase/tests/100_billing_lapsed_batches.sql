-- 100 billing: batches skip a lapsed shop without breaking the others —
-- per-service follow-ups, appointment reminders (enqueue_due_automations),
-- campaign sends (claim_queued_messages) and document follow-ups: in the
-- same run the active shop is processed and the lapsed one is left alone
-- (nothing logged), so once it renews, what is still inside the 24 h window
-- goes out. Billing off processes everyone.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
update public.customers set phone = '+13125550101', sms_opt_in = true where id = tests.fx('cust_b');
-- the rest of the queue is not this file's business
update public.messages set status = 'cancelled' where status = 'queued';

-- per-service follow-ups: a job of each shop completed 2025-05-01, due 30 days later at 10:00 CDT
update public.message_templates set enabled = true
 where shop_id in (tests.fx('shop_a'), tests.fx('shop_b')) and key = 'service_followup';
insert into public.service_followups (shop_id, service_id, channel, offset_days, body) values
  (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 30, 'Time for your next detail at {{shop_name}}.'),
  (tests.fx('shop_b'), tests.fx('svc_b'), 'sms', 30, 'Time for your next wash at {{shop_name}}.');
-- (shop A's customer has no open job with the service: Alice's job_a would hold her follow-up back)
insert into public.customers (shop_id, first_name, phone, sms_opt_in) values (tests.fx('shop_a'), 'Remy', '+12055550122', true)
  returning tests.fx_set('cust_r', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at) values
  (tests.fx('shop_a'), tests.fx('cust_r'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z'),
  (tests.fx('shop_b'), tests.fx('cust_b'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z');
select tests.fx_set('done_a', (select id from public.jobs where shop_id = tests.fx('shop_a') and completed_at = '2025-05-01 16:00Z'));
select tests.fx_set('done_b', (select id from public.jobs where shop_id = tests.fx('shop_b') and completed_at = '2025-05-01 16:00Z'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('done_a'), tests.fx('svc_a'), 'Full Detail', 20000),
  (tests.fx('shop_b'), tests.fx('done_b'), tests.fx('svc_b'), 'Wash', 5000);

-- campaigns launched (while billing is off) by each shop, sent now
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'A deal', 'sms', 'Deal at Shop A')
  returning tests.fx_set('camp_a', id);
select public.launch_campaign(tests.fx('camp_a'));
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_b'), 'B deal', 'sms', 'Deal at Shop B')
  returning tests.fx_set('camp_b', id);
select public.launch_campaign(tests.fx('camp_b'));

-- billing on: A lapsed (never subscribed, no trial), B active
select tests.as_service();
select public.set_billing_config(true, 0);
update public.shop_billing set status = 'active', current_period_end = now() + interval '20 days' where shop_id = tests.fx('shop_b');

create function pg_temp.queued(p_shop uuid, p_key text) returns bigint language sql as $$
  select count(*) from public.messages
   where shop_id = p_shop and template_key::text = p_key and status = 'queued' and direction = 'outbound' $$;
grant execute on function pg_temp.queued(uuid, text) to service_role;

-- ============================================================ per-service follow-ups
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 1, 'one follow-up: the active shop''s');
select tests.eq(pg_temp.queued(tests.fx('shop_b'), 'service_followup'), 1::bigint, 'shop B''s is queued');
select tests.eq(pg_temp.queued(tests.fx('shop_a'), 'service_followup'), 0::bigint, 'shop A''s is not');
select tests.eq((select count(*) from public.job_automation_log where job_id = tests.fx('done_a')), 0::bigint,
                'and nothing is logged for it');

-- ============================================================ appointment reminders
select tests.eq(public.enqueue_due_automations('2025-06-01 15:00Z'), 1, 'one reminder: shop B (sms only)');
select tests.eq(pg_temp.queued(tests.fx('shop_b'), 'appointment_reminder'), 1::bigint, 'shop B reminded');
select tests.eq(pg_temp.queued(tests.fx('shop_a'), 'appointment_reminder'), 0::bigint, 'shop A skipped');
select tests.ok((select reminder_sent_at is null from public.jobs where id = tests.fx('job_a'))
                and not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_a')),
                'no marker and no log row for the lapsed shop');

-- ============================================================ campaign sends
select tests.eq((select array_agg(c.shop_id order by c.shop_id) from public.claim_queued_messages(100, now()) c
                  where c.campaign_id is not null),
                array[tests.fx('shop_b')], 'the sender claims only the active shop''s campaign message');
select tests.eq((select array_agg(status::text) from public.messages where campaign_id = tests.fx('camp_a')), array['queued', 'queued'],
                'shop A''s campaign messages (Alice, Remy) wait in the queue');

-- ============================================================ renewing: what is still due goes out
select public.billing_set_comp(tests.fx('shop_a'), 'infinity');
select tests.eq(public.enqueue_service_followups('2025-05-31 15:30Z'), 1, 'shop A''s follow-up now');
select tests.eq(public.enqueue_due_automations('2025-06-01 15:10Z'), 2, 'shop A''s reminder now (sms + email)');
select tests.eq((select array_agg(c.campaign_id) from public.claim_queued_messages(100, now()) c where c.campaign_id is not null),
                array[tests.fx('camp_a'), tests.fx('camp_a')], 'and its campaign messages');
select tests.eq(public.enqueue_due_automations('2025-06-01 15:20Z'), 0, 'exactly once');

-- ============================================================ document follow-ups
-- (waking hours: both shops on a fixed-offset zone where it is about noon now)
select tests.as_superuser();
select case when o >= 0 then 'Etc/GMT-' || o else 'Etc/GMT+' || -o end as tz
  from (select 12 - extract(hour from now() at time zone 'UTC')::integer as o) x \gset
update public.shops set timezone = :'tz' where id in (tests.fx('shop_a'), tests.fx('shop_b'));
update public.followup_settings set quote_enabled = true where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'));
update public.message_templates set enabled = true
 where shop_id in (tests.fx('shop_a'), tests.fx('shop_b')) and key = 'quote_reminder' and channel = 'sms';
insert into public.quotes (shop_id, customer_id, valid_until) values
  (tests.fx('shop_a'), tests.fx('cust_a'), current_date + 30), (tests.fx('shop_b'), tests.fx('cust_b'), current_date + 30);
select tests.fx_set('q_a', (select id from public.quotes where shop_id = tests.fx('shop_a') and customer_id = tests.fx('cust_a')));
select tests.fx_set('q_b', (select id from public.quotes where shop_id = tests.fx('shop_b') and customer_id = tests.fx('cust_b')));
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('q_a'), 'Coating', 100000), (tests.fx('shop_b'), tests.fx('q_b'), 'Coating', 100000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.mark_quote_sent(tests.fx('q_a'));
select tests.authenticate_as(tests.fx('u_manager_b'));
select public.mark_quote_sent(tests.fx('q_b'));
select tests.as_service();
select public.billing_set_comp(tests.fx('shop_a'), null);   -- lapsed again
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 1, 'one quote reminder: shop B''s');
select tests.ok((select count(*) = 1 from public.messages where quote_id = tests.fx('q_b') and template_key = 'quote_reminder')
                and not exists (select 1 from public.messages where quote_id = tests.fx('q_a'))
                and not exists (select 1 from public.document_followup_log where doc_id = tests.fx('q_a')),
                'shop A''s quote is skipped and not logged');
select public.billing_set_comp(tests.fx('shop_a'), 'infinity');
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours 1 minute'), 1, 'renewed: shop A''s reminder goes out');

-- ============================================================ billing off processes everyone
select public.billing_set_comp(tests.fx('shop_a'), null);
select public.set_billing_config(false, 0);
select tests.as_superuser();
update public.shops set timezone = 'America/Chicago' where id in (tests.fx('shop_a'), tests.fx('shop_b'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-02 15:00Z', '2025-07-02 16:00Z'),
  (tests.fx('shop_b'), tests.fx('cust_b'), 'scheduled', '2025-07-02 15:00Z', '2025-07-02 16:00Z');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-01 15:00Z'), 3, 'billing off: both shops reminded (A sms + email, B sms)');
