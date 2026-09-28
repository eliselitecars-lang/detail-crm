-- 80 comms: up to 3 appointment reminders and per-service follow-ups (P-4,
-- 0081/0086) — reminder offsets (CHECKs, normalisation, channel sync, old
-- clients, reset), one reminder per offset exactly once, only the nearest
-- of several due offsets, per-offset reschedule follow, rows without an
-- offset (single-reminder shops / before P-4), manual reminders per offset
-- window, and service follow-ups: once per (job, row), package expansion,
-- skipped when the service is booked again, 24 h window, marketing consent
-- (and its re-check), the shop switch, rebook link, 4-per-channel limit,
-- roles and cross-shop FKs.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.messages set status = 'cancelled' where status = 'queued';
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Remy', 'remy@example.com', '+12055550121', true) returning tests.fx_set('cust_r', id);

-- ============================================================ offsets: checks and normalisation
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.message_templates set reminder_offsets_minutes = '{-10080,-60,-1440,-60}'
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms';
select tests.eq((select array_agg(reminder_offsets_minutes::text || ' ' || offset_minutes order by channel) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'),
                array['{-60,-1440,-10080} -60', '{-60,-1440,-10080} -60'],
                'de-duplicated, sorted (nearest first), offset_minutes follows, every channel shares it');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = '{-60,-120,-180,-240}'
                      where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'at most 3');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = '{-60,30}'
                      where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'never after the start');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = '{-50000}'
                      where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'at most 30 days before');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = '{}'
                      where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'not empty');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = array[null]::integer[]
                      where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'no nulls');
select tests.throws($$update public.message_templates set reminder_offsets_minutes = '{-60}'
                      where shop_id = tests.fx('shop_a') and key = 'review_request' and channel = 'sms'$$, '23514',
                    'only appointment reminders have several offsets');
-- a client that only knows offset_minutes switches back to one reminder
update public.message_templates set offset_minutes = -120
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email';
select tests.eq((select array_agg(coalesce(reminder_offsets_minutes::text, 'null') || ' ' || offset_minutes order by channel)
                   from public.message_templates where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'),
                array['null -120', 'null -120'], 'offset_minutes alone: a single reminder again (both channels)');
-- reset
update public.message_templates set reminder_offsets_minutes = '{-60,-1440}'
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms';
select public.reset_message_template((select id from public.message_templates
                                       where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email'));
select tests.eq((select array_agg(coalesce(reminder_offsets_minutes::text, 'null') || ' ' || offset_minutes order by channel)
                   from public.message_templates where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'),
                array['null -1440', 'null -1440'], 'reset: one reminder a day before, on every channel');
-- a new channel row adopts its siblings' schedule
update public.message_templates set reminder_offsets_minutes = '{-10080,-1440,-60}'
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms';
delete from public.message_templates where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email';
insert into public.message_templates (shop_id, key, channel, subject, body)
  values (tests.fx('shop_a'), 'appointment_reminder', 'email', 'Reminder - {{shop_name}}',
          E'Hi {{customer_first_name}}, see you {{job_date}} at {{job_time}}.\nManage it: {{booking_link}}');
select tests.eq((select reminder_offsets_minutes::text || ' ' || offset_minutes from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email'),
                '{-60,-1440,-10080} -60', 'a re-added channel adopts the shared offsets');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.message_templates set reminder_offsets_minutes = '{-60}'
                                   where key = 'appointment_reminder'$$), 0::bigint, 'managers cannot change the schedule');

-- ============================================================ three reminders, once each
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), '2025-07-20 15:00Z', '2025-07-20 17:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('j1', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-13 14:59Z'), 0, 'not before a week ahead');
select tests.eq(public.enqueue_due_automations('2025-07-13 15:00Z'), 2, 'the week-ahead reminder (sms + email)');
select tests.eq(public.enqueue_due_automations('2025-07-13 16:00Z'), 0, 'once');
select tests.eq(public.enqueue_due_automations('2025-07-19 15:00Z'), 2, 'the day-before reminder');
select tests.eq(public.enqueue_due_automations('2025-07-20 14:00Z'), 2, 'the hour-before reminder');
select tests.eq(public.enqueue_due_automations('2025-07-20 14:30Z'), 0, 'nothing more');
select tests.eq((select array_agg(reminder_offset_minutes::text || ':' || outcome || ':' || cardinality(message_ids)
                                  order by reminder_offset_minutes)
                   from public.job_automation_log where job_id = tests.fx('j1')),
                array['-10080:queued:2', '-1440:queued:2', '-60:queued:2'], 'one log row per offset');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('j1')), 6::bigint, 'six messages');
select tests.as_superuser();
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes,
                                                             due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('cust_r'), 'appointment_reminder', '2025-07-20 15:00Z', -60,
                              now(), now(), 'skipped')$$, '23505', 'unique per (job, start, customer, offset)');
select tests.lives($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes,
                                                            due_at, processed_at, outcome)
                     values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('cust_r'), 'appointment_reminder', '2025-07-20 15:00Z', null,
                             now(), now(), 'skipped')$$, 'a row without an offset is another key');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes,
                                                             due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('cust_r'), 'appointment_reminder', '2025-07-20 15:00Z', null,
                              now(), now(), 'skipped')$$, '23505', '… but only one (nulls not distinct)');
select tests.throws($$insert into public.job_automation_log (shop_id, job_id, customer_id, key, reminder_offset_minutes, due_at,
                                                             processed_at, outcome)
                      values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('cust_r'), 'review_request', -60, now(), now(), 'skipped')$$,
                    '23514', 'offsets only on reminder rows');

-- booked inside the window: only the nearest due offset is sent
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), '2025-07-22 15:00Z', '2025-07-22 16:00Z', '2025-07-22 13:00Z')
  returning tests.fx_set('j2', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-22 13:10Z'), 2, 'week and day offsets due at once: one reminder');
select tests.eq((select array_agg(reminder_offset_minutes::text || ':' || outcome order by reminder_offset_minutes)
                   from public.job_automation_log where job_id = tests.fx('j2')),
                array['-10080:skipped', '-1440:queued'], 'the superseded offset is logged skipped');
select tests.eq(public.enqueue_due_automations('2025-07-22 14:00Z'), 2, 'the hour-before one still goes out');

-- a reschedule moves a queued reminder with its offset
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), '2025-07-25 15:00Z', '2025-07-25 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('j3', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-18 15:00Z'), 2, 'week-ahead reminder queued');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-07-26 15:00Z', scheduled_end = '2025-07-26 16:00Z' where id = tests.fx('j3');
select tests.eq((select array[scheduled_for::text, reminder_offset_minutes::text] from public.job_automation_log where job_id = tests.fx('j3')),
                array['2025-07-26 15:00:00+00', '-10080'], 'the queued reminder now announces the new time, same offset');
select tests.ok((select bool_and(body like '%Saturday, July 26%' or body like '%July 26%') from public.messages
                  where job_id = tests.fx('j3') and channel = 'sms'), 're-rendered with the new date');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-19 15:00Z'), 0, 'the new time''s week-ahead reminder is that same message');
select tests.eq(public.enqueue_due_automations('2025-07-25 15:00Z'), 2, 'the day-before one for the new time');

-- rows without an offset (a single-reminder shop, or logged before P-4)
select tests.ok(public.comms_reminder_log_covers(null, '2025-07-01', -60, '2025-07-10', false),
                'single reminder: a row without an offset is the reminder');
select tests.ok(public.comms_reminder_log_covers(null, '2025-07-10 12:00Z', -1440, '2025-07-10 12:00Z', true)
                and not public.comms_reminder_log_covers(null, '2025-07-10 12:00Z', -60, '2025-07-11 11:00Z', true),
                'several: it covers the offsets due by the time it was processed');
select tests.ok(public.comms_reminder_log_covers(-60, '2025-07-01', -60, '2025-07-10', true)
                and not public.comms_reminder_log_covers(-1440, '2025-07-01', -60, '2025-07-10', true), 'or its own offset');
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), '2025-07-28 15:00Z', '2025-07-28 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('j4', id);
insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome)
  values (tests.fx('shop_a'), tests.fx('j4'), tests.fx('cust_r'), 'appointment_reminder', '2025-07-28 15:00Z', '2025-07-27 15:00Z',
          '2025-07-27 15:00Z', 'skipped');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-27 15:05Z'), 0, 'the old single reminder covers the week and day offsets');
select tests.eq(public.enqueue_due_automations('2025-07-28 14:00Z'), 2, '… not the hour-before one');

-- a reminder sent by hand stands in only for the offset whose window it went out in
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, appointment_set_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), '2025-08-05 15:00Z', '2025-08-05 16:00Z', '2025-07-01 12:00Z')
  returning tests.fx_set('j5', id);
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, template_key, send_after,
                             created_at, sent_at, sent_by)
  values (tests.fx('shop_a'), tests.fx('cust_r'), tests.fx('j5'), 'outbound', 'sms', '+12055550121', 'Reminder (by hand)', 'sent',
          'appointment_reminder', '2025-07-29 16:00Z', '2025-07-29 16:00Z', '2025-07-29 16:00Z', tests.fx('u_manager_a'));
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-29 17:00Z'), 1, 'week-ahead: the manual text stands in (email only)');
select tests.eq(public.enqueue_due_automations('2025-08-04 15:00Z'), 2, 'day-before: both channels again');

-- ============================================================ per-service follow-ups
select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Showroom Package', 'package', 240)
  returning tests.fx_set('pkg', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg'), tests.fx('svc_a'));
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Ceramic Coating', 480)
  returning tests.fx_set('svc_c', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
  values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 30,
          E'  Hi {{customer_first_name}}, time for your next detail at {{shop_name}}.\nBook: {{rebook_link}}  ')
  returning tests.fx_set('fu_sms', id);
insert into public.service_followups (shop_id, service_id, channel, offset_days, subject, body)
  values (tests.fx('shop_a'), tests.fx('svc_a'), 'email', 30, 'Time for a detail?',
          E'Hi {{customer_first_name}},\n\nBook your next detail: {{rebook_link}}')
  returning tests.fx_set('fu_email', id);
insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
  values (tests.fx('shop_a'), tests.fx('pkg'), 'sms', 60, 'Hi {{customer_first_name}}, your package is due for a refresh.')
  returning tests.fx_set('fu_pkg', id);
select tests.eq((select body from public.service_followups where id = tests.fx('fu_sms')),
                E'Hi {{customer_first_name}}, time for your next detail at {{shop_name}}.\nBook: {{rebook_link}}', 'body trimmed');
select tests.throws($$insert into public.service_followups (shop_id, service_id, channel, offset_days, subject, body)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 30, 'x', 'y')$$, '23514', 'texts have no subject');
select tests.throws($$insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), 'email', 30, 'y')$$, '23514', 'emails need a subject');
select tests.throws($$insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 0, 'y')$$, '23514', 'at least a day later');
select tests.throws($$insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
                      values (tests.fx('shop_a'), tests.fx('svc_b'), 'sms', 30, 'y')$$, '23503', 'another shop''s service');
insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
  select tests.fx('shop_a'), tests.fx('svc_a'), 'sms', d, 'Follow-up ' || d from unnest(array[60, 90, 120]) d;
select tests.throws_like($$insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
                           values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 150, 'Fifth')$$, '23514', '%at most 4%',
                         'at most 4 per service and channel');
select tests.lives($$update public.service_followups set offset_days = 45 where body = 'Follow-up 60'$$, 'editing within the limit');
delete from public.service_followups where body like 'Follow-up %';
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.service_followups$$), 0::bigint, 'technicians do not read them');
select tests.throws($$insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 30, 'x')$$, '42501', 'nor write them');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.service_followups$$), 0::bigint, 'shop B sees none of them');

-- completed jobs: one with the service, one with the package
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make, model, category_id)
  values (tests.fx('shop_a'), tests.fx('cust_r'), 'Mazda', 'CX-5', tests.fx('cat_car_a')) returning tests.fx_set('veh_r', id);
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), tests.fx('veh_r'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z')
  returning tests.fx_set('jf1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf1'), tests.fx('svc_a'), 'Full Detail', 20000),
         (tests.fx('shop_a'), tests.fx('jf1'), tests.fx('svc_a'), 'Full Detail (second car)', 20000);
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in, email_opt_in)
  values (tests.fx('shop_a'), 'Pat', 'pat@example.com', '+12055550122', true, true) returning tests.fx_set('cust_p', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_p'), 'completed', '2025-05-02 14:00Z', '2025-05-02 18:00Z', '2025-05-02 18:00Z')
  returning tests.fx_set('jf2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf2'), tests.fx('pkg'), 'Showroom Package', 40000);

-- the shop switch (service_followup templates) is off by default
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 18:00Z'), 0, 'the service_followup templates are off: nothing');
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'service_followup';
select tests.as_service();
-- due at 10:00 shop-local (CDT) on the local date of completed_at + offset_days
select tests.eq(public.enqueue_service_followups('2025-05-31 14:59Z'), 0, 'not before 10:00 local on day offset_days');
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 1,
                'job 1: the sms follow-up (Remy has not opted in to marketing email)');
select tests.ok((select body = E'Hi Remy, time for your next detail at Shop A.\nBook: https://app.example.test/book/shop-a?services='
                               || tests.fx('svc_a') || '&category=' || tests.fx('cat_car_a') || E'\nReply STOP to opt out.'
                        and template_key = 'service_followup' and job_id = tests.fx('jf1')
                   from public.messages where customer_id = tests.fx('cust_r') and template_key = 'service_followup'),
                'the row''s wording, a rebook link for the service and vehicle size, the opt-out line');
select tests.eq((select array_agg(service_followup_id::text || ':' || outcome order by outcome) from public.job_automation_log
                  where job_id = tests.fx('jf1') and key = 'service_followup'),
                array[tests.fx('fu_sms') || ':queued', tests.fx('fu_email') || ':skipped'], 'once per (job, follow-up row)');
select tests.eq(public.enqueue_service_followups('2025-06-01 15:00Z'), 2, 'job 2 (package): the service''s sms + email');
select tests.ok((select bool_and(body like '%To unsubscribe from these emails, visit: https://app.example.test/u/%'
                                 and unsubscribe_token is not null)
                   from public.messages where customer_id = tests.fx('cust_p') and channel = 'email'),
                'marketing email carries its unsubscribe link');
select tests.eq(public.enqueue_service_followups('2025-06-01 20:00Z'), 0, 'exactly once');
select tests.eq(public.enqueue_service_followups('2025-07-01 15:00Z'), 1, 'the package''s own follow-up (60 days)');
-- consent is re-checked at send time
select tests.as_superuser();
update public.customers set sms_opt_in = false where id = tests.fx('cust_r');
select tests.as_service();
select tests.eq((select public.comms_withdraw_reason(m, '2025-05-31 16:05Z') from public.messages m
                  where m.customer_id = tests.fx('cust_r') and m.template_key = 'service_followup'),
                'the recipient withdrew marketing consent before sending', 'withdrawn consent stops it');

-- the customer booked the service again: no follow-up
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_p'), 'completed', '2025-06-10 14:00Z', '2025-06-10 16:00Z', '2025-06-10 16:00Z')
  returning tests.fx_set('jf3', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf3'), tests.fx('svc_c'), 'Ceramic Coating', 90000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_p'), '2025-07-20 14:00Z', '2025-07-20 16:00Z') returning tests.fx_set('jf4', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf4'), tests.fx('svc_c'), 'Ceramic Coating', 90000);
insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
  values (tests.fx('shop_a'), tests.fx('svc_c'), 'sms', 30, 'Hi {{customer_first_name}}, time for a coating check.');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-07-10 16:00Z'), 0, 'the coating is already booked again: skipped');
select tests.as_superuser();
update public.jobs set status = 'cancelled' where id = tests.fx('jf4');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-07-10 16:30Z'), 1, 'the booking was cancelled: sent');
-- stale: a follow-up that became due more than 24 hours ago
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_p'), 'completed', '2025-03-01 14:00Z', '2025-03-01 16:00Z', '2025-03-01 16:00Z')
  returning tests.fx_set('jf5', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf5'), tests.fx('svc_c'), 'Ceramic Coating', 90000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-04-02 16:00Z'), 0, 'more than 24 hours late: never sent');
-- online booking off: the rebook line is left out
select tests.as_superuser();
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_a');
update public.customers set sms_opt_in = true where id = tests.fx('cust_r');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), 'completed', '2025-08-01 14:00Z', '2025-08-01 16:00Z', '2025-08-01 16:00Z')
  returning tests.fx_set('jf6', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf6'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-08-31 16:00Z'), 1, 'still sent');
select tests.eq((select body from public.messages where job_id = tests.fx('jf6')),
                E'Hi Remy, time for your next detail at Shop A.\nReply STOP to opt out.', 'without the booking link');
-- the automations run includes it; the function is service-only
select tests.eq(public.enqueue_due_automations('2025-09-30 16:00Z'), 0, 'enqueue_due_automations calls it (nothing due)');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.enqueue_service_followups()$$, '42501', 'service-only');
-- deleting a follow-up row drops its log rows
select tests.as_superuser();
delete from public.service_followups where id = tests.fx('fu_email');
select tests.eq((select count(*) from public.job_automation_log where service_followup_id = tests.fx('fu_email')), 0::bigint,
                'log rows go with their follow-up');
