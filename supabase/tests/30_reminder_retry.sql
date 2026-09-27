-- 30 comms: appointment messages that come back for a retry after the job
-- moved, and the reminder grace period.
--   * Regression: a reminder the sender had claimed when the appointment was
--     rescheduled kept its rendered body; a provider retry re-queued it and
--     it went out with the OLD date and time (plus a second, correct
--     reminder later). Now a retried reminder whose log row is for another
--     time is withdrawn (the new time gets its own reminder), and any other
--     retried appointment message is re-rendered for the job as it is now.
--   * Regression: every reminder got the 15-minute grace after the start,
--     so a delayed 1-hour reminder still went out after the appointment had
--     begun. The grace is now only for reminders due at the start itself.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test');
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
update public.customers set phone = '+13125550101' where id = tests.fx('cust_b');
-- shop B's reminders stay off until the cross-shop check at the end
update public.message_templates set enabled = false where shop_id = tests.fx('shop_b') and key = 'appointment_reminder';

-- ============================================================ #3 repro: reminder in flight, job moved, provider retry
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-01 15:00Z'), 2, 'job A reminder queued (sms+email)');
create temp table claim1 on commit drop as select * from public.claim_queued_messages(50, '2025-06-01 15:00Z');
select tests.fx_set('m', (select id from claim1 where job_id = tests.fx('job_a') and channel = 'sms'));
select tests.fx_set('m_mail', (select id from claim1 where job_id = tests.fx('job_a') and channel = 'email'));
select tests.ok((select body like '%Monday, June 2 at 10:00 AM%' from public.messages where id = tests.fx('m')), 'old date');
-- the email went out; the text hits a rate limit
select tests.eq((select status::text from public.mark_message_result(tests.fx('m_mail'), 'sent', 'em-1', null, null,
                                                                     '2025-06-01 15:00Z')), 'sent', 'email sent');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-06-05 15:00Z', scheduled_end = '2025-06-05 17:00Z' where id = tests.fx('job_a');
select tests.as_service();
select tests.eq((select status::text from public.mark_message_result(tests.fx('m'), 'queued', null, 'Twilio 429', null,
                                                                     '2025-06-01 15:01Z')),
                'cancelled', 'the retried reminder announcing the old time is withdrawn');
select tests.eq((select error from public.messages where id = tests.fx('m')),
                'the appointment was rescheduled; the new time gets its own reminder', 'with the reason');
select tests.ok(not exists (select 1 from public.claim_queued_messages(50, '2025-06-01 15:10Z') c
                             where c.id = tests.fx('m') and c.body like '%June 2 at 10:00 AM%'),
                'a retried reminder must not be sent with the appointment''s previous date');
select tests.ok(exists (select 1 from public.job_automation_log where job_id = tests.fx('job_a')
                         and scheduled_for = '2025-06-02 15:00Z'),
                'the old time stays logged: its email reminder reached the customer');
select tests.eq(public.enqueue_due_automations('2025-06-04 15:00Z'), 2, 'the new time gets its own reminder (sms+email)');
select tests.ok((select bool_and(body like '%Thursday, June 5%10:00 AM%') and count(*) = 2 from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'appointment_reminder' and status = 'queued'),
                'announcing the new date');
select tests.eq(public.enqueue_due_automations('2025-06-04 15:30Z'), 0, 'exactly once');

-- ============================================================ nothing of the old time reached anyone: its log row goes
select tests.as_superuser();
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'
   and channel = 'email';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-10 15:00Z', '2025-07-10 16:00Z')
  returning tests.fx_set('job_r', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-09 15:00Z'), 1, 'sms-only reminder queued');
select tests.fx_set('r1', (select id from public.claim_queued_messages(50, '2025-07-09 15:00Z') where job_id = tests.fx('job_r')));
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-07-11 15:00Z', scheduled_end = '2025-07-11 16:00Z' where id = tests.fx('job_r');
select tests.as_service();
select tests.eq((select status::text from public.mark_message_result(tests.fx('r1'), 'queued', null, 'timeout', null,
                                                                     '2025-07-09 15:01Z')), 'cancelled', 'withdrawn');
select tests.ok(not exists (select 1 from public.job_automation_log where job_id = tests.fx('job_r')),
                'a log row whose reminder reached nobody is dropped');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-07-10 15:00Z', scheduled_end = '2025-07-10 16:00Z' where id = tests.fx('job_r');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-09 15:05Z'), 1,
                'moved back to the original time, the customer is reminded after all');

-- ============================================================ reminder log row followed the job: retry is re-rendered
-- A queued copy made the log row follow the reschedule, so the in-flight
-- copy that comes back is the reminder for the NEW time.
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'
   and channel = 'email';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-08-10 15:00Z', '2025-08-10 16:00Z')
  returning tests.fx_set('job_f', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-09 15:00Z'), 2, 'sms + email reminder');
select tests.fx_set('f_sms', (select id from public.messages where job_id = tests.fx('job_f') and channel = 'sms'));
select tests.as_superuser();
-- the sender claims only the text; the email is still queued
update public.messages set send_after = '2025-08-09 16:00Z' where job_id = tests.fx('job_f') and channel = 'email';
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-08-09 15:00Z') where job_id = tests.fx('job_f')),
                1::bigint, 'text claimed');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-08-12 15:00Z', scheduled_end = '2025-08-12 16:00Z' where id = tests.fx('job_f');
select tests.eq((select scheduled_for from public.job_automation_log where job_id = tests.fx('job_f')),
                '2025-08-12 15:00Z'::timestamptz, 'the log row followed the queued email');
select tests.as_service();
select tests.eq((select status::text from public.mark_message_result(tests.fx('f_sms'), 'queued', null, 'Twilio 429', null,
                                                                     '2025-08-09 15:01Z')), 'queued', 'retry re-queued');
select tests.ok((select body like '%Tuesday, August 12 at 10:00 AM%' from public.messages where id = tests.fx('f_sms')),
                'and re-rendered with the new date');
select tests.eq(public.enqueue_due_automations('2025-08-11 15:00Z'), 0, 'no second reminder for the new time');

-- ============================================================ other appointment messages are re-rendered on retry
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-09-10 15:00Z', '2025-09-10 16:00Z')
  returning tests.fx_set('job_c', id);
select tests.fx_set('c_msg', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'sms',
                                                              tests.fx('job_c'), null, '2025-09-01 12:00Z'));
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-09-01 12:00Z') where id = tests.fx('c_msg')),
                1::bigint, 'confirmation claimed');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-09-11 20:30Z', scheduled_end = '2025-09-11 21:30Z' where id = tests.fx('job_c');
select tests.ok((select body like '%Wednesday, September 10 at 10:00 AM%' from public.messages where id = tests.fx('c_msg')),
                'in flight: not touched by the reschedule');
select tests.as_service();
select tests.eq((select status::text from public.mark_message_result(tests.fx('c_msg'), 'queued', null, 'Twilio 429', null,
                                                                     '2025-09-01 12:01Z')), 'queued', 're-queued');
select tests.ok((select body like '%confirmed for Thursday, September 11 at 3:30 PM%' from public.messages
                  where id = tests.fx('c_msg')), 'the retried confirmation announces the new time');
select tests.eq((select array_agg(c.id) from public.claim_queued_messages(50, '2025-09-01 12:05Z') c
                  where c.job_id = tests.fx('job_c')), array[tests.fx('c_msg')], 'and is sent as such');

-- a free-form staff message is never rewritten
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after,
                             claimed_at, attempts)
values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_c'), 'outbound', 'sms', '+12055550101',
        'See you Wednesday!', 'sending', '2025-09-01 12:00Z', '2025-09-01 12:00Z', 1)
returning tests.fx_set('free', id);
select tests.as_service();
select public.mark_message_result(tests.fx('free'), 'queued', null, 'Twilio 429', null, '2025-09-01 12:01Z');
select tests.eq((select body from public.messages where id = tests.fx('free')), 'See you Wednesday!', 'free-form body kept');

-- a template gone empty since: the retry is withdrawn
select tests.fx_set('c_msg2', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'sms',
                                                               tests.fx('job_c'), null, '2025-09-01 13:00Z'));
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-09-01 13:00Z') where id = tests.fx('c_msg2')),
                1::bigint, 'claimed');
select tests.as_superuser();
update public.message_templates set body = '{{vehicle_color}}'
 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'sms';
select tests.as_service();
select tests.ok((select status = 'cancelled' and error = 'the appointment changed and the message no longer applies'
                   from public.mark_message_result(tests.fx('c_msg2'), 'queued', null, 'Twilio 429', null, '2025-09-01 13:01Z')),
                'a retry that now renders empty is withdrawn');

-- ============================================================ #5: grace only for reminders due at the start
select tests.as_superuser();
update public.message_templates set offset_minutes = -60 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-10-02 15:00Z', '2025-10-02 16:00Z'),
         (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-10-03 15:00Z', '2025-10-03 16:00Z')
  returning tests.fx_set('job_g' || extract(day from scheduled_start)::text, id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-10-02 14:00Z'), 2, '1-hour reminder for the 15:00Z appointment');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-10-02 15:10Z') c
                  where c.job_id = tests.fx('job_g2') and c.template_key = 'appointment_reminder'),
                0::bigint, 'a 1-hour reminder is not sent after the appointment has started');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the appointment has already started') and count(*) = 2
                   from public.messages where job_id = tests.fx('job_g2')), 'both copies are withdrawn');
-- before the start it still goes out, even late
select tests.eq(public.enqueue_due_automations('2025-10-03 14:00Z'), 2, 'next day''s 1-hour reminder');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-10-03 14:59Z') c
                  where c.job_id = tests.fx('job_g3')), 2::bigint, 'a delayed reminder still goes out before the start');

-- offset 0 keeps its 15 minutes of grace
select tests.as_superuser();
update public.message_templates set offset_minutes = 0 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-10-04 15:00Z', '2025-10-04 16:00Z')
  returning tests.fx_set('job_g4', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-10-04 15:00Z'), 2, 'reminder at the start time');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-10-04 15:10Z') c
                  where c.job_id = tests.fx('job_g4')), 2::bigint, 'goes out within 15 minutes of the start');

-- a reminder queued by hand gets no grace either
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-10-05 15:00Z', '2025-10-05 16:00Z')
  returning tests.fx_set('job_g5', id);
select tests.as_service();
select tests.fx_set('manual_rem', public.enqueue_template_message(tests.fx('job_g5'), 'appointment_reminder',
                                                                  '2025-10-05 14:30Z', 'sms'));
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-10-05 15:05Z') c
                  where c.id = tests.fx('manual_rem')), 0::bigint, 'a hand-scheduled reminder is not sent after the start');

-- ============================================================ cross-shop: shop B's reminder is unaffected by shop A's moves
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_b') and key = 'appointment_reminder';
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-02 14:00Z'), 1, 'shop B''s 24-hour reminder (sms; Bob has no email)');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-06-02 14:00Z') c
                  where c.shop_id = tests.fx('shop_b')), 1::bigint, 'and it is sent');
