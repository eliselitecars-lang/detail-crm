-- 30 comms: enqueue_due_automations — appointment reminders, review
-- requests and follow-ups: due-time math, exactly-once (re-runs and
-- markers), stale (>24 h) skip, offset 0 reminders, status rules, disabled
-- templates, opt-outs, missing contact info, job_automation_log access and
-- isolation.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test');
update public.shops set sms_from_number = '+12055550100', review_url = 'https://reviews.example.test/shop-a'
 where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
update public.customers set phone = '+13125550101' where id = tests.fx('cust_b');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
update public.message_templates set enabled = false where shop_id = tests.fx('shop_b') and key = 'appointment_reminder';
insert into public.customers (shop_id, first_name, phone, email, sms_opted_out_at)
  values (tests.fx('shop_a'), 'Half', '+12055550155', 'half@example.com', now()) returning tests.fx_set('cust_half', id);
insert into public.customers (shop_id, first_name, phone, email, sms_opted_out_at, email_opted_out_at)
  values (tests.fx('shop_a'), 'None', '+12055550156', 'none@example.com', now(), now()) returning tests.fx_set('cust_none', id);

-- ------------------------------------------------------------ access
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.enqueue_due_automations()$$, '42501', 'staff cannot run automations');
select tests.as_anon();
select tests.throws($$select public.enqueue_due_automations()$$, '42501', 'anon cannot run automations');

-- ------------------------------------------------------------ appointment reminders
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-01 14:59Z'), 0, 'job A reminder not due yet (24 h before 15:00Z)');
select tests.eq(public.enqueue_due_automations('2025-06-01 15:00Z'), 2, 'job A reminder due: sms + email');
select tests.ok((select bool_and(template_key = 'appointment_reminder' and status = 'queued' and send_after = '2025-06-01 15:00Z'
                                 and sent_by is null and customer_id = tests.fx('cust_a'))
                   and count(*) = 2 and array_agg(channel::text order by channel) = array['sms', 'email']
                   from public.messages where job_id = tests.fx('job_a')), 'reminders queued on both channels');
select tests.ok((select body like 'Reminder: your appointment with Shop A is on Monday, June 2 at 10:00 AM.%'
                   from public.messages where job_id = tests.fx('job_a') and channel = 'sms'), 'reminder text');
select tests.eq((select reminder_sent_at from public.jobs where id = tests.fx('job_a')), '2025-06-01 15:00Z'::timestamptz,
                'jobs.reminder_sent_at marker');
select tests.ok((select outcome = 'queued' and cardinality(message_ids) = 2 and due_at = '2025-06-01 15:00Z'
                        and processed_at = '2025-06-01 15:00Z'
                   from public.job_automation_log where job_id = tests.fx('job_a') and key = 'appointment_reminder'),
                'automation log row');
select tests.eq(public.enqueue_due_automations('2025-06-01 15:00Z'), 0, 're-running is a no-op');
select tests.eq(public.enqueue_due_automations('2025-06-01 20:00Z'), 0, 'later runs do not repeat the reminder');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_a')), 2::bigint, 'still exactly two messages');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_b')),
                'a shop with the reminder disabled is not processed');

-- enabling the template later still catches jobs due within the window
update public.message_templates set enabled = true where shop_id = tests.fx('shop_b') and key = 'appointment_reminder' and channel = 'sms';
select tests.eq(public.enqueue_due_automations('2025-06-01 15:30Z'), 1, 'shop B reminder once enabled (sms only)');
select tests.eq((select array_agg(channel::text) from public.messages where job_id = tests.fx('job_b')), array['sms'],
                'only the enabled channel is used');

-- due, but the customer cannot be reached: logged as skipped, never retried
select tests.eq(public.enqueue_due_automations('2025-06-01 18:00Z'), 0, 'job A2 customer has no phone or email');
select tests.ok((select outcome = 'skipped' and message_ids = '{}' from public.job_automation_log
                  where job_id = tests.fx('job_a2') and key = 'appointment_reminder'), 'skipped outcome logged');
select tests.ok((select reminder_sent_at is null from public.jobs where id = tests.fx('job_a2')), 'no marker when nothing was sent');
update public.customers set phone = '+12055550102' where id = tests.fx('cust_a2');
select tests.eq(public.enqueue_due_automations('2025-06-01 18:05Z'), 0, 'a skipped automation is not retried');
select tests.eq((select count(*) from public.job_automation_log where job_id = tests.fx('job_a2')), 1::bigint, 'one log row');

-- status rules and consent
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-20 15:00Z', '2025-06-20 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', '2025-06-20 16:00Z', '2025-06-20 17:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-20 17:00Z', '2025-06-20 18:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'confirmed', '2025-06-20 18:00Z', '2025-06-20 19:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_half'), 'scheduled', '2025-06-20 19:00Z', '2025-06-20 20:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_none'), 'scheduled', '2025-06-20 19:30Z', '2025-06-20 20:00Z');
select tests.fx_set(k, (select id from public.jobs where shop_id = tests.fx('shop_a') and scheduled_start = t))
  from (values ('job_cx', '2025-06-20 15:00Z'::timestamptz), ('job_rq', '2025-06-20 16:00Z'), ('job_ns', '2025-06-20 17:00Z'),
               ('job_cf', '2025-06-20 18:00Z'), ('job_half', '2025-06-20 19:00Z'), ('job_none', '2025-06-20 19:30Z')) v(k, t);
update public.jobs set status = 'cancelled' where id = tests.fx('job_cx');
update public.jobs set status = 'no_show' where id = tests.fx('job_ns');
select tests.eq(public.enqueue_due_automations('2025-06-19 20:00Z'), 3,
                'confirmed job: sms + email; SMS-opted-out customer: email only');
select tests.ok(not exists (select 1 from public.job_automation_log
                             where job_id in (tests.fx('job_cx'), tests.fx('job_rq'), tests.fx('job_ns'))),
                'cancelled, requested and no-show jobs get no reminder');
select tests.eq((select cardinality(message_ids) from public.job_automation_log where job_id = tests.fx('job_cf')), 2,
                'confirmed jobs are reminded');
select tests.eq((select array_agg(channel::text) from public.messages where job_id = tests.fx('job_half')), array['email'],
                'an SMS opt-out blocks the reminder text but not the email');
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('job_none')), 'skipped',
                'a customer opted out of everything gets nothing');

-- stale: never blast messages whose send time is more than 24 h old
update public.message_templates set offset_minutes = -4320
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms';
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-30 15:00Z', '2025-06-30 16:00Z') returning tests.fx_set('job_st', id);
select tests.eq(public.enqueue_due_automations('2025-06-29 15:00Z'), 0, 'due 48 h ago (3-day reminder): skipped as stale');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_st')), 'stale runs log nothing');
select tests.eq(public.enqueue_due_automations('2025-06-28 14:00Z'), 2, 'due 23 h ago: still sent');
select tests.eq((select due_at from public.job_automation_log where job_id = tests.fx('job_st')), '2025-06-27 15:00Z'::timestamptz,
                'due time follows the (synced) 3-day offset');
update public.message_templates set offset_minutes = -1440
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email';
select tests.eq((select array_agg(distinct offset_minutes) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'), array[-1440], 'offset restored');

-- offset 0 (remind at the appointment time) — regression: the reminder was
-- accepted by the template constraint but never queued
update public.message_templates set offset_minutes = 0 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-24 15:00Z', '2025-06-24 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-25 15:00Z', '2025-06-25 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-26 15:00Z', '2025-06-26 16:00Z');
select tests.fx_set(k, (select id from public.jobs where shop_id = tests.fx('shop_a') and scheduled_start = t))
  from (values ('job_z1', '2025-06-24 15:00Z'::timestamptz), ('job_z2', '2025-06-25 15:00Z'), ('job_z3', '2025-06-26 15:00Z')) v(k, t);
select tests.eq((select sum(public.enqueue_due_automations(t))
                   from generate_series('2025-06-24 14:55Z'::timestamptz, '2025-06-24 15:05Z', interval '1 minute') t)::bigint,
                2::bigint, 'an enabled reminder with offset 0 is queued (sms + email) around the start time');
select tests.ok((select due_at = '2025-06-24 15:00Z' and processed_at = '2025-06-24 15:00Z' and outcome = 'queued'
                   from public.job_automation_log where job_id = tests.fx('job_z1') and key = 'appointment_reminder'),
                'queued on the first run at the appointment time');
select tests.eq(public.enqueue_due_automations('2025-06-25 15:14Z'), 2, 'a missed tick still sends within 15 minutes of the start');
select tests.eq(public.enqueue_due_automations('2025-06-26 15:16Z'), 0, 'but never later than that');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_z3')), 'nothing logged for it');
select tests.eq(public.enqueue_due_automations('2025-06-26 14:59Z'), 0, 'offset 0 is not due before the start');
update public.message_templates set offset_minutes = -1440 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';

-- ------------------------------------------------------------ review requests
update public.jobs set status = 'completed' where id in (tests.fx('job_a'), tests.fx('job_b'));
update public.jobs set completed_at = '2025-06-02 17:00Z' where id in (tests.fx('job_a'), tests.fx('job_b'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-05-01 08:00Z', '2025-05-01 09:00Z') returning tests.fx_set('job_old', id);
update public.jobs set status = 'completed' where id = tests.fx('job_old');
update public.jobs set completed_at = '2025-05-01 10:00Z' where id = tests.fx('job_old');

select tests.eq(public.enqueue_due_automations('2025-06-02 18:59Z'), 0, 'review request not due before 2 h');
select tests.eq(public.enqueue_due_automations('2025-06-02 19:00Z'), 2,
                'review request due 2 h after completion (sms + email); old job is stale');
select tests.ok((select bool_and(body like '%https://reviews.example.test/shop-a%') and count(*) = 2
                   from public.messages where job_id = tests.fx('job_a') and template_key = 'review_request'),
                'review requests carry the review link');
select tests.eq((select review_requested_at from public.jobs where id = tests.fx('job_a')), '2025-06-02 19:00Z'::timestamptz,
                'jobs.review_requested_at marker');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_b') and key = 'review_request'),
                'a shop without a review URL sends no review requests');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_old')),
                'stale review requests / follow-ups are skipped');
select tests.eq(public.enqueue_due_automations('2025-06-02 19:00Z'), 0, 're-running is a no-op');
select tests.eq(public.enqueue_due_automations('2025-06-03 12:00Z'), 0, 'later runs do not repeat');

-- the marker alone also prevents a second review request (e.g. the log row
-- was removed by an operator)
delete from public.job_automation_log where job_id = tests.fx('job_a') and key = 'review_request';
select tests.eq(public.enqueue_due_automations('2025-06-02 19:10Z'), 0, 'review_requested_at blocks a repeat');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_a') and template_key = 'review_request'),
                2::bigint, 'still two review messages');

-- ------------------------------------------------------------ follow-ups
select tests.eq(public.enqueue_due_automations('2025-07-02 16:59Z'), 0, 'follow-up not due before 30 days');
select tests.eq(public.enqueue_due_automations('2025-07-02 17:00Z'), 2, 'follow-up 30 days after completion (shop A only)');
select tests.ok((select bool_and(body like '%https://app.example.test/book/shop-a%') and count(*) = 2
                   from public.messages where job_id = tests.fx('job_a') and template_key = 'follow_up'),
                'follow-ups link to the booking page');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_b') and key = 'follow_up'),
                'follow-ups are off by default (shop B)');
select tests.eq(public.enqueue_due_automations('2025-07-02 17:00Z'), 0, 're-running is a no-op');

-- ------------------------------------------------------------ job_automation_log access & isolation
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(tests.row_count($$select 1 from public.job_automation_log$$) >= 6, 'managers see their shop''s automation log');
select tests.eq(tests.row_count($$select 1 from public.job_automation_log where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'but not another shop''s');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), 'follow_up', now(), now(), 'skipped')$$, '42501',
                    'no direct writes');
select tests.throws($$delete from public.job_automation_log$$, '42501', 'no direct deletes');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_automation_log$$), 0::bigint, 'technicians see no automation log');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_automation_log$$), 1::bigint, 'shop B sees its own row only');
select tests.as_superuser();
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_b'), 'follow_up', now(), now(), 'skipped')$$, '23503',
                    'the log cannot point at another shop''s job');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), 'on_the_way', now(), now(), 'skipped')$$, '23514',
                    'only time-based keys are automations');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), 'appointment_reminder', now(), now(), 'skipped')$$, '23505',
                    'one row per job and key');
