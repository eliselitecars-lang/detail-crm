-- 30 comms: automations never repeat a message staff already sent by hand.
-- Regression: enqueue_due_automations looked only at job_automation_log and
-- jobs.review_requested_at, which enqueue_template_message never writes, so
-- a review request (or reminder) a manager had sent went out a second time
-- on every channel (SPEC §4.7: review requests exactly once per job). A
-- channel on which the job already has a live (not failed / cancelled)
-- message of the key is skipped; for reminders only one announcing the
-- job's current appointment to its current customer counts.
\ir fixtures/two_shops.psql
-- shop A takes online bookings, so {{booking_page_link}} links to a live page
-- (it is blank while online booking is off: 30_link_availability.sql)
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100', review_url = 'https://reviews.example.test/a'
 where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199', review_url = 'https://reviews.example.test/b'
 where id = tests.fx('shop_b');
update public.customers set phone = '+13125550101' where id = tests.fx('cust_b');
update public.message_templates set enabled = false where key = 'appointment_reminder';

-- ============================================================ review request (repro)
update public.jobs set status = 'completed' where id in (tests.fx('job_a'), tests.fx('job_b'));
update public.jobs set completed_at = '2025-06-02 17:00Z' where id in (tests.fx('job_a'), tests.fx('job_b'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'review_request', null, 'sms') is not null,
                'manager sends the review request by text');
select tests.as_service();
select public.enqueue_due_automations('2025-06-02 19:00Z');
select tests.eq((select count(*) from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'review_request' and channel = 'sms'
                    and status not in ('failed', 'cancelled')),
                1::bigint, 'the customer is asked for a review by text exactly once per job');
select tests.eq((select count(*) from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'review_request' and channel = 'email'),
                1::bigint, 'the email the manager did not send still goes out');
select tests.eq(public.enqueue_due_automations('2025-06-02 20:00Z'), 0, 're-running adds nothing');

-- shop B (nothing sent by hand) is unaffected: both channels
select tests.eq((select array_agg(channel::text order by channel) from public.messages
                  where job_id = tests.fx('job_b') and template_key = 'review_request'), array['sms'],
                'shop B''s customer gets the automated request (sms; no email on file)');

-- a manual request that failed does not count
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-10 15:00Z', '2025-06-10 16:00Z')
  returning tests.fx_set('job_f', id);
update public.jobs set status = 'completed' where id = tests.fx('job_f');
update public.jobs set completed_at = '2025-06-10 17:00Z' where id = tests.fx('job_f');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('failed_rr', public.enqueue_template_message(tests.fx('job_f'), 'review_request', null, 'sms'));
select tests.fx_set('cancelled_rr', public.enqueue_template_message(tests.fx('job_f'), 'review_request', null, 'email'));
select tests.as_superuser();
update public.messages set status = 'failed', error = 'undelivered' where id = tests.fx('failed_rr');
update public.messages set status = 'cancelled', error = 'withdrawn' where id = tests.fx('cancelled_rr');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-10 19:00Z'), 2,
                'a failed or withdrawn manual request does not block the automated one');

-- ============================================================ follow-up
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
update public.customers set sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-01 15:00Z', '2025-07-01 16:00Z')
  returning tests.fx_set('job_fu', id);
update public.jobs set status = 'completed' where id = tests.fx('job_fu');
update public.jobs set completed_at = '2025-07-01 17:00Z', review_requested_at = '2025-07-01 17:00Z'
 where id = tests.fx('job_fu');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(public.enqueue_template_message(tests.fx('job_fu'), 'follow_up', null, 'email') is not null,
                'manager emails the follow-up');
select tests.as_service();
-- run when the follow-up falls due (completed_at + the template offset)
select public.enqueue_due_automations(j.completed_at + make_interval(mins => t.offset_minutes))
  from public.jobs j join public.message_templates t on t.shop_id = j.shop_id and t.key = 'follow_up' and t.channel = 'sms'
 where j.id = tests.fx('job_fu');
select tests.eq((select array_agg(channel::text order by channel) from public.messages
                  where job_id = tests.fx('job_fu') and template_key = 'follow_up'), array['sms', 'email'],
                'the follow-up email is not repeated; the text still goes out');

-- ============================================================ appointment reminders
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-08-10 15:00Z', '2025-08-10 16:00Z')
  returning tests.fx_set('job_r', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
-- (sent by hand the evening before; the file's clock (now()) is far past these 2025 dates)
select tests.fx_set('manual_rem', public.enqueue_template_message(tests.fx('job_r'), 'appointment_reminder',
                                                                  '2025-08-08 23:00Z', 'sms'));
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-09 15:00Z'), 1, 'a reminder sent by hand: only the email is added');
select tests.eq((select array_agg(channel::text order by channel) from public.messages
                  where job_id = tests.fx('job_r') and template_key = 'appointment_reminder'), array['sms', 'email'],
                'one reminder per channel');

-- both went out for the old time; the job then moved: the new time is
-- reminded on every channel (the manual old-time text does not count)
select tests.as_superuser();
update public.messages set status = 'sent', sent_at = '2025-08-09 15:00Z'
 where job_id = tests.fx('job_r') and template_key = 'appointment_reminder';
update public.messages set created_at = '2025-08-01 12:00Z' where id = tests.fx('manual_rem');
update public.jobs set scheduled_start = '2025-08-12 15:00Z', scheduled_end = '2025-08-12 16:00Z' where id = tests.fx('job_r');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-11 15:00Z'), 2, 'new time: text and email');
select tests.ok((select bool_and(body like '%Tuesday, August 12%') and count(*) = 2 from public.messages
                  where job_id = tests.fx('job_r') and template_key = 'appointment_reminder' and status = 'queued'),
                'announcing the new date');

-- a reminder sent by hand after the move counts for the new time
select tests.as_superuser();
update public.messages set status = 'sent' where job_id = tests.fx('job_r') and status = 'queued';
update public.jobs set scheduled_start = '2025-08-20 15:00Z', scheduled_end = '2025-08-20 16:00Z' where id = tests.fx('job_r');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(public.enqueue_template_message(tests.fx('job_r'), 'appointment_reminder', '2025-08-18 23:00Z', 'email')
                  is not null, 'manager emails a reminder for the new time');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-19 15:00Z'), 1, 'the automation adds only the text');

-- ============================================================ a hand-scheduled reminder the appointment moved ahead of (repro)
-- Regression: staff scheduled a text reminder for the day before the
-- original date; the appointment then moved EARLIER than that send time.
-- The queued manual reminder made the automation skip SMS, and was itself
-- withdrawn at the claim ("already started"): no text reminder at all.
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-10 15:00Z', '2025-07-10 17:00Z')
  returning tests.fx_set('job_e', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('manual_e', public.enqueue_template_message(tests.fx('job_e'), 'appointment_reminder', '2025-07-09 15:00Z', 'sms'));
-- the appointment moves EARLIER, to July 5
update public.jobs set scheduled_start = '2025-07-05 15:00Z', scheduled_end = '2025-07-05 17:00Z' where id = tests.fx('job_e');
select tests.as_superuser();
update public.jobs set appointment_set_at = '2025-07-01 12:00Z' where id = tests.fx('job_e');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-04 15:05Z'), 2,
                'the late manual reminder does not stand in for the automatic one: text and email');
create temp table c1 on commit drop as select * from public.claim_queued_messages(50, '2025-07-04 15:06Z');
create temp table c2 on commit drop as select * from public.claim_queued_messages(50, '2025-07-09 15:01Z');
select tests.ok(exists (select 1 from c1 where c1.job_id = tests.fx('job_e') and c1.channel = 'sms'
                                           and c1.template_key = 'appointment_reminder'),
                'the customer gets an SMS reminder before the (moved) appointment');
select tests.ok(exists (select 1 from c1 where c1.job_id = tests.fx('job_e') and c1.channel = 'email'
                                           and c1.template_key = 'appointment_reminder'),
                'and the email reminder');
select tests.eq((select count(*) from c2 where c2.job_id = tests.fx('job_e')), 0::bigint,
                'the stale manual reminder is not sent after the appointment');
select tests.ok((select status = 'cancelled' and error like '%already started%' from public.messages where id = tests.fx('manual_e')),
                'it is withdrawn at the claim');

-- a hand-scheduled reminder still due BEFORE the moved appointment keeps standing in
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-20 15:00Z', '2025-07-20 17:00Z')
  returning tests.fx_set('job_e2', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('manual_e2', public.enqueue_template_message(tests.fx('job_e2'), 'appointment_reminder', '2025-07-14 15:00Z', 'sms'));
update public.jobs set scheduled_start = '2025-07-15 15:00Z', scheduled_end = '2025-07-15 17:00Z' where id = tests.fx('job_e2');
select tests.as_superuser();
update public.jobs set appointment_set_at = '2025-07-12 12:00Z' where id = tests.fx('job_e2');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-14 15:05Z'), 1,
                'a manual reminder queued for before the new time still counts: only the email is added');
select tests.eq((select array_agg(channel::text order by channel) from public.messages
                  where job_id = tests.fx('job_e2') and template_key = 'appointment_reminder' and status = 'queued'),
                array['sms', 'email'], 'one reminder per channel');
select tests.ok((select body like '%Tuesday, July 15%' from public.messages where id = tests.fx('manual_e2')),
                'the manual one announces the moved date');

-- cross-shop: shop B's job at the same time is reminded on its own, on every channel it can
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_b') and key = 'appointment_reminder';
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_b'), tests.fx('cust_b'), 'scheduled', '2025-07-05 15:00Z', '2025-07-05 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('job_eb', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-04 15:10Z'), 1, 'shop B''s customer is reminded (text; no email on file)');
select tests.ok((select to_address = '+13125550101' from public.messages
                  where job_id = tests.fx('job_eb') and template_key = 'appointment_reminder' and status = 'queued'),
                'at shop B''s customer''s number');

-- a manual reminder to the job's former customer does not count for the new one
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-09-10 15:00Z', '2025-09-10 16:00Z')
  returning tests.fx_set('job_m', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('manual_m', public.enqueue_template_message(tests.fx('job_m'), 'appointment_reminder', null, 'sms'));
select tests.as_superuser();
update public.messages set status = 'sent' where id = tests.fx('manual_m');
update public.customers set phone = '+12055550133', email = null where id = tests.fx('cust_a2');
update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('job_m');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-09-09 15:00Z'), 1, 'the job''s new customer is reminded by text');
select tests.ok((select to_address = '+12055550133' from public.messages
                  where job_id = tests.fx('job_m') and status = 'queued' and template_key = 'appointment_reminder'),
                'at their number');
