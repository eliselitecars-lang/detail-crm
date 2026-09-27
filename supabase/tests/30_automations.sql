-- 30 comms: enqueue_due_automations — appointment reminders, review
-- requests and follow-ups: due-time math, exactly-once (re-runs and
-- markers), reminders once per appointment time (reschedules), stale
-- (>24 h) skip, offset 0 reminders, status rules, disabled templates,
-- opt-outs, marketing consent for follow-ups, missing contact info,
-- job_automation_log access and isolation.
\ir fixtures/two_shops.psql
-- shop A takes online bookings, so {{booking_page_link}} links to a live page
-- (it is blank while online booking is off: 30_link_availability.sql)
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
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
-- (booked long before the reminder fell due)
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-30 15:00Z', '2025-06-30 16:00Z', '2025-06-01 12:00Z')
  returning tests.fx_set('job_st', id);
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

-- ------------------------------------------------------------ rescheduled after the reminder went out
-- Regression: the reminder markers were once per JOB, so an appointment
-- moved after its 24-hour reminder was sent never got a reminder for the new
-- time.
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-10 15:00Z', '2025-07-10 17:00Z')
  returning tests.fx_set('job_rs', id);
select tests.eq(public.enqueue_due_automations('2025-07-09 15:00Z'), 2, 'reminder for the original time');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-07-09 15:00Z') c where c.job_id = tests.fx('job_rs')),
                2::bigint, 'handed to the sender');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = '2025-07-17 15:00Z', scheduled_end = '2025-07-17 17:00Z' where id = tests.fx('job_rs');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-16 14:59Z'), 0, 'not due before 24 h ahead of the new time');
select tests.eq(public.enqueue_due_automations('2025-07-16 15:00Z'), 2,
                'the rescheduled appointment gets a reminder 24 h before the new time');
select tests.ok((select body like 'Reminder: your appointment with Shop A is on Thursday, July 17 at 10:00 AM.%'
                   from public.messages where job_id = tests.fx('job_rs') and channel = 'sms' and status = 'queued'),
                'the new reminder names the new time');
select tests.eq((select array_agg(scheduled_for order by scheduled_for) from public.job_automation_log
                  where job_id = tests.fx('job_rs') and key = 'appointment_reminder'),
                array['2025-07-10 15:00Z', '2025-07-17 15:00Z']::timestamptz[], 'one log row per appointment time');
select tests.eq((select reminder_sent_at from public.jobs where id = tests.fx('job_rs')), '2025-07-16 15:00Z'::timestamptz,
                'reminder_sent_at is the latest reminder');
select tests.eq(public.enqueue_due_automations('2025-07-16 16:00Z'), 0, 'still once per appointment time');
-- moved back to the time that was already reminded while the new reminder
-- is still queued: the queued copies are duplicates and are withdrawn
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = '2025-07-10 15:00Z', scheduled_end = '2025-07-10 17:00Z' where id = tests.fx('job_rs');
select tests.as_service();
select tests.ok((select bool_and(status = 'cancelled' and error = 'a reminder for this appointment time was already sent')
                        and count(*) = 2
                   from public.messages where job_id = tests.fx('job_rs') and send_after = '2025-07-16 15:00Z'),
                'a time that was already reminded is not reminded twice');
select tests.eq(public.enqueue_due_automations('2025-07-09 15:30Z'), 0, 'and no new reminder for it');

-- a reminder still QUEUED when the appointment moves is re-rendered for the
-- new time and counts as its reminder (no second one)
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-22 15:00Z', '2025-07-22 16:00Z')
  returning tests.fx_set('job_mv', id);
select tests.eq(public.enqueue_due_automations('2025-07-21 15:00Z'), 2, 'reminder queued');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = '2025-07-22 18:00Z', scheduled_end = '2025-07-22 19:00Z' where id = tests.fx('job_mv');
select tests.as_service();
select tests.ok((select bool_and(status = 'queued') and count(*) = 2
                        and bool_and(body like '%1:00 PM%')
                   from public.messages where job_id = tests.fx('job_mv')), 'the queued reminder now names the new time');
select tests.eq((select array_agg(scheduled_for) from public.job_automation_log where job_id = tests.fx('job_mv')),
                array['2025-07-22 18:00Z']::timestamptz[], 'its log row follows the appointment');
select tests.eq(public.enqueue_due_automations('2025-07-21 18:00Z'), 0, 'so the new time is not reminded twice');
-- moved (while queued) to a time whose earlier attempt was skipped (the
-- customer had no contact details then): the queued reminder becomes that
-- time's reminder instead of being dropped as a duplicate
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Quinn') returning tests.fx_set('cust_quinn', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_quinn'), 'scheduled', '2025-07-23 15:00Z', '2025-07-23 16:00Z')
  returning tests.fx_set('job_q', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-22 15:00Z'), 0, 'Quinn cannot be reached yet');
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('job_q')), 'skipped', 'skipped for July 23');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set phone = '+12055550181' where id = tests.fx('cust_quinn');
update public.jobs set scheduled_start = '2025-07-23 20:00Z', scheduled_end = '2025-07-23 21:00Z' where id = tests.fx('job_q');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-22 20:00Z'), 1, 'reminder for the later time (sms)');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = '2025-07-23 15:00Z', scheduled_end = '2025-07-23 16:00Z' where id = tests.fx('job_q');
select tests.as_service();
select tests.ok((select status = 'queued' and body like '%10:00 AM%' from public.messages where job_id = tests.fx('job_q')),
                'the queued reminder is kept and names the original time again');
select tests.ok((select count(*) = 1 and bool_and(outcome = 'queued' and scheduled_for = '2025-07-23 15:00Z'
                                                  and cardinality(message_ids) = 1)
                   from public.job_automation_log where job_id = tests.fx('job_q')),
                'the skipped row now records it');
select tests.eq(public.enqueue_due_automations('2025-07-22 20:30Z'), 0, 'no second reminder');

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
-- Follow-ups are promotional: like campaigns they need the channel's
-- marketing opt-in. Regression: they went to every completed-job customer.
-- Alice opts in to both channels; Nora (same completion time) never did;
-- Sam opted in to texts only.
select tests.as_superuser();
update public.customers set sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
insert into public.customers (shop_id, first_name, phone, email)
  values (tests.fx('shop_a'), 'Nora', '+12055550161', 'nora@example.com') returning tests.fx_set('cust_nora', id);
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in)
  values (tests.fx('shop_a'), 'Sam', '+12055550162', 'sam@example.com', true) returning tests.fx_set('cust_sam', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_nora'), '2025-06-02 15:00Z', '2025-06-02 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_sam'), '2025-06-02 15:00Z', '2025-06-02 16:00Z');
select tests.fx_set(k, (select id from public.jobs where customer_id = tests.fx(c)))
  from (values ('job_nora', 'cust_nora'), ('job_sam', 'cust_sam')) v(k, c);
update public.jobs set status = 'completed' where id in (tests.fx('job_nora'), tests.fx('job_sam'));
update public.jobs set completed_at = '2025-06-02 17:00Z' where id in (tests.fx('job_nora'), tests.fx('job_sam'));
delete from public.job_automation_log where job_id in (tests.fx('job_nora'), tests.fx('job_sam'));
update public.jobs set review_requested_at = '2025-06-02 19:00Z' where id in (tests.fx('job_nora'), tests.fx('job_sam'));
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-02 16:59Z'), 0, 'follow-up not due before 30 days');
select tests.eq(public.enqueue_due_automations('2025-07-02 17:00Z'), 3,
                'follow-ups 30 days after completion (shop A only): Alice sms + email, Sam sms');
select tests.ok((select bool_and(body like '%https://app.example.test/book/shop-a%') and count(*) = 2
                   from public.messages where job_id = tests.fx('job_a') and template_key = 'follow_up'),
                'follow-ups link to the booking page');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_nora') and template_key = 'follow_up'), 0::bigint,
                'promotional follow-up must not go to a customer without sms_opt_in/email_opt_in');
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('job_nora') and key = 'follow_up'), 'skipped',
                'logged as skipped');
select tests.eq((select array_agg(channel::text) from public.messages where job_id = tests.fx('job_sam') and template_key = 'follow_up'),
                array['sms'], 'only the channel the customer opted in to');
select tests.ok((select body like E'%\nReply STOP to opt out.' from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'follow_up' and channel = 'sms'),
                'a follow-up text carries the opt-out line');
select tests.ok((select body not like '%Reply STOP%' from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'follow_up' and channel = 'email'),
                'emails have no SMS footer');
-- consent withdrawn after queueing: the claim withdraws the follow-up
select tests.as_superuser();
update public.customers set sms_opt_in = false where id = tests.fx('cust_sam');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-07-02 17:01Z') c where c.job_id = tests.fx('job_sam')),
                0::bigint, 'a follow-up is not sent once marketing consent is withdrawn');
select tests.eq((select error from public.messages where job_id = tests.fx('job_sam') and template_key = 'follow_up'),
                'the recipient withdrew marketing consent before sending', 'cancelled with the reason');
-- staff cannot push a follow-up past the consent rule either
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.enqueue_template_message(tests.fx('job_nora'), 'follow_up'), null::uuid,
                'a manual follow-up to a customer without marketing consent is not queued');
select tests.as_service();
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_b') and key = 'follow_up'),
                'follow-ups are off by default (shop B)');
select tests.eq(public.enqueue_due_automations('2025-07-02 17:00Z'), 0, 're-running is a no-op');

-- ------------------------------------------------------------ job_automation_log access & isolation
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(tests.row_count($$select 1 from public.job_automation_log$$) >= 6, 'managers see their shop''s automation log');
select tests.eq(tests.row_count($$select 1 from public.job_automation_log where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'but not another shop''s');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'follow_up', now(), now(), 'skipped')$$, '42501',
                    'no direct writes');
select tests.throws($$delete from public.job_automation_log$$, '42501', 'no direct deletes');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_automation_log$$), 0::bigint, 'technicians see no automation log');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_automation_log$$), 1::bigint, 'shop B sees its own row only');
select tests.as_superuser();
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_b'), tests.fx('cust_a'), 'follow_up', now(), now(), 'skipped')$$, '23503',
                    'the log cannot point at another shop''s job');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_b'), 'follow_up', now(), now(), 'skipped')$$, '23503',
                    'the log cannot point at another shop''s customer');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'on_the_way', now(), now(), 'skipped')$$, '23514',
                    'only time-based keys are automations');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'appointment_reminder', '2025-06-02 18:00Z', now(), now(), 'skipped')$$,
                    '23505', 'one reminder row per job, appointment time and recipient');
select tests.lives($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome)
                     values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a3'), 'appointment_reminder', '2025-06-02 18:00Z', now(), now(), 'skipped')$$,
                   'another recipient of the same appointment time gets its own row');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('cust_a3'), 'follow_up', now(), now(), 'skipped')$$,
                    '23505', 'one review / follow-up row per job, whoever the recipient');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'appointment_reminder', now(), now(), 'skipped')$$,
                    '23514', 'a reminder row names its appointment time');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'follow_up', now(), now(), now(), 'skipped')$$,
                    '23514', 'only reminders name an appointment time');

-- ------------------------------------------------------------ reminders for appointments booked inside the offset
-- Regression: staleness was measured from the due time alone, so with a
-- 48 h reminder an appointment booked (or moved / confirmed) 20 h ahead was
-- due 28 h in the past when it was created and never got a reminder.
-- Staleness now runs from greatest(due time, jobs.appointment_set_at).
select tests.as_superuser();
update public.message_templates set offset_minutes = -2880 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-08-11 01:00Z', '2025-08-11 02:00Z', '2025-08-09 19:00Z')
  returning tests.fx_set('job_30h', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-08-10 15:00Z', '2025-08-10 16:00Z', '2025-08-09 19:00Z')
  returning tests.fx_set('job_20h', id);
-- booked weeks ago: its 48 h reminder fell due during an outage 25 h before the run
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-08-12 15:00Z', '2025-08-12 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('job_outage', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-09 19:00Z'), 4, 'the 30 h and 20 h bookings are reminded right away');
select tests.eq(public.enqueue_due_automations('2025-08-10 09:00Z'), 0, 'once');
-- booked 6.5 h ahead, after that run: its 48 h reminder was due 47 h before
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-08-10 16:00Z', '2025-08-10 17:00Z', '2025-08-10 09:30Z')
  returning tests.fx_set('job_late', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-10 14:55Z'), 2,
                'a same-day booking is reminded on the next run');
select tests.ok(exists (select 1 from public.messages where job_id = tests.fx('job_late') and template_key = 'appointment_reminder'),
                'the same-day booking got the reminder');
select tests.ok(exists (select 1 from public.messages where job_id = tests.fx('job_30h') and template_key = 'appointment_reminder'),
                'booked 30 h ahead: reminded');
select tests.ok(exists (select 1 from public.messages where job_id = tests.fx('job_20h') and template_key = 'appointment_reminder'),
                'booked 20 h ahead: reminded too');
select tests.eq((select due_at from public.job_automation_log where job_id = tests.fx('job_20h')), '2025-08-08 15:00Z'::timestamptz,
                'the log keeps the nominal due time');
select tests.eq(public.enqueue_due_automations('2025-08-11 16:00Z'), 0, 'an appointment whose reminder fell due 25 h ago is stale');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_outage')), 'nothing logged for it');

-- appointment_set_at follows the appointment and is server-maintained for API clients
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set appointment_set_at = '2020-01-01Z' where id = tests.fx('job_outage');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_outage')), '2025-07-01 12:00Z'::timestamptz,
                'clients cannot set appointment_set_at');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-09-01 15:00Z', '2025-09-01 16:00Z', '2020-01-01Z')
  returning tests.fx_set('job_client_ins', id);
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_client_ins')), now(),
                'nor on insert: the server clock is used');
update public.jobs set notes = 'Bring the dog hair kit' where id = tests.fx('job_outage');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_outage')), '2025-07-01 12:00Z'::timestamptz,
                'other edits leave it alone');
-- moved into the reminder window: reminded on the next run instead of being treated as overdue
update public.jobs set scheduled_start = '2025-08-12 10:00Z', scheduled_end = '2025-08-12 11:00Z' where id = tests.fx('job_outage');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_outage')), now(), 'rescheduling stamps it');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-11 16:00Z'), 2, 'the rescheduled appointment is reminded');
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', '2025-08-14 15:00Z', '2025-08-14 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('job_req', id);
update public.jobs set status = 'confirmed' where id = tests.fx('job_req');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_req')), now(),
                'confirming a requested booking stamps it');
update public.jobs set status = 'scheduled' where id = tests.fx('job_req');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_req')), now(), 'confirmed -> scheduled keeps it');
update public.jobs set appointment_set_at = '2025-08-01Z' where id = tests.fx('job_req');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_req')), '2025-08-01Z'::timestamptz,
                'trusted code may set it explicitly');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-13 16:00Z'), 0, 'booked long ago and due 25 h ago: stale');
update public.message_templates set offset_minutes = -1440 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';

-- ------------------------------------------------------------ job moved to another customer
-- Regression: the reminder log was per (job, appointment time), so once the
-- customer the job was booked under had been reminded (or had a copy
-- queued), the customer the appointment was moved to never got one.
select tests.as_superuser();
update public.customers set phone = '+12055550177' where id = tests.fx('cust_a3');
insert into public.customers (shop_id, first_name, phone, email)
  values (tests.fx('shop_a'), 'Alice (duplicate)', '+12055550101', 'alice.dup@example.com') returning tests.fx_set('cust_dup', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-08-25 15:00Z', '2025-08-25 16:00Z', '2025-08-01 12:00Z')
  returning tests.fx_set('job_to', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-24 15:00Z'), 2, 'reminder queued to Alice (sms + email)');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-08-24 15:00Z') c where c.job_id = tests.fx('job_to')),
                2::bigint, 'claimed');
select public.mark_message_result(id, 'sent', 'SMto' || left(id::text, 8), null, null, '2025-08-24 15:01Z')
  from public.messages where job_id = tests.fx('job_to');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('job_to');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-24 16:00Z'), 1, 'the new customer is reminded (sms; no email on file)');
select tests.ok(exists (select 1 from public.messages where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a3')
                          and template_key = 'appointment_reminder' and status = 'queued'),
                'the customer the appointment now belongs to gets a reminder');
select tests.eq((select array_agg(customer_id order by processed_at) from public.job_automation_log where job_id = tests.fx('job_to')),
                array[tests.fx('cust_a'), tests.fx('cust_a3')], 'one log row per recipient of the appointment time');
select tests.eq(public.enqueue_due_automations('2025-08-24 16:05Z'), 0, 'still once per recipient');

-- moved again while that copy is still queued (a duplicate record of Alice):
-- the queued copy is withdrawn; the address Alice was already reminded at
-- is not reminded twice, the new email address is
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_dup') where id = tests.fx('job_to');
select tests.as_service();
select tests.eq((select status::text || ': ' || error from public.messages
                  where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a3')),
                'cancelled: the appointment now belongs to another customer', 'the queued copy is withdrawn');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a3')),
                'its log row is dropped: nobody was reminded');
select tests.eq(public.enqueue_due_automations('2025-08-24 16:10Z'), 1, 'duplicate record: email only');
select tests.eq((select array_agg(channel::text || ' ' || to_address) from public.messages
                  where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_dup')),
                array['email alice.dup@example.com'], 'the phone Alice was reminded at is not texted again');

-- back to the customer whose copy was withdrawn: reminded again
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_to');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-24 16:15Z'), 1, 'the customer is reminded after all');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a3')
                  and status = 'queued'), 1::bigint, 'one live copy');
-- back to Alice, who was already reminded for this time: nothing new
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a') where id = tests.fx('job_to');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-24 16:20Z'), 0, 'a recipient already reminded for this time is not reminded twice');
select tests.ok((select count(*) = 2 and bool_and(status = 'sent') from public.messages
                  where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a')), 'Alice has only her original reminder');
select tests.ok(exists (select 1 from public.job_automation_log where job_id = tests.fx('job_to') and customer_id = tests.fx('cust_a')),
                'rows whose reminder went out are kept');

-- cross-shop: the recipient must belong to the log row's shop (composite FK, above) and
-- shop B never sees these rows
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_automation_log where job_id = tests.fx('job_to')$$), 0::bigint,
                'shop B cannot see shop A''s reminder log');
