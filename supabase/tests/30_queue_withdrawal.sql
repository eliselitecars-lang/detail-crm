-- 30 comms: queued messages follow their context until the sender claims
-- them. Appointment messages are withdrawn when the job is cancelled,
-- marked no-show, moved to another customer or deleted, and re-rendered
-- when it is rescheduled; campaign messages stop when marketing consent is
-- withdrawn or the campaign is cancelled (also for in-flight retries, and a
-- launched campaign cannot be deleted to escape that); messages never go to
-- a customer's previous phone / email; stale job and campaign messages are
-- never sent after a sender outage.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
update public.customers set phone = '+13125550101' where id = tests.fx('cust_b');
update public.jobs set status = 'scheduled' where id in (tests.fx('job_a'), tests.fx('job_b'));

-- ============================================================ cancelled appointment
-- Regression: a reminder scheduled for later is not sent once the job is cancelled.
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('rem', public.enqueue_template_message(tests.fx('job_a'), 'appointment_reminder', '2025-06-02 12:00Z'));
select tests.fx_set('conf', public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', '2025-06-02 12:00Z'));
select tests.fx_set('conf_mail', public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', '2025-06-02 12:00Z', 'email'));
select tests.ok(tests.fx('rem') is not null and tests.fx('conf') is not null and tests.fx('conf_mail') is not null,
                'reminder and confirmations scheduled');
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after, template_key)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_a'), 'outbound', 'sms', '+12055550101', 'Receipt', 'queued',
          '2025-06-02 12:00Z', 'payment_receipt')
  returning tests.fx_set('receipt', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled', cancel_reason = 'customer called' where id = tests.fx('job_a');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the appointment was cancelled') and count(*) = 3
                   from public.messages where id in (tests.fx('rem'), tests.fx('conf'), tests.fx('conf_mail'))),
                'queued appointment messages are withdrawn when the job is cancelled');
select tests.eq((select status::text from public.messages where id = tests.fx('receipt')), 'queued',
                'non-appointment messages of the job (receipts) are kept');
select tests.throws_like($$select public.enqueue_template_message(tests.fx('job_a'), 'appointment_reminder')$$, '55000',
                         '%cancelled%', 'staff cannot queue appointment messages for a cancelled job');
select tests.as_service();
create temp table cx_claim on commit drop as select * from public.claim_queued_messages(50, '2025-06-02 12:01Z');
select tests.eq((select count(*) from cx_claim c where c.job_id = tests.fx('job_a') and c.template_key = 'appointment_reminder'),
                0::bigint, 'a reminder for a cancelled appointment must not be sent');
select tests.eq((select array_agg(c.id) from cx_claim c where c.job_id = tests.fx('job_a')), array[tests.fx('receipt')],
                'only the receipt is handed to the sender');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'sms',
                                                 tests.fx('job_a')),
                null::uuid, 'the internal enqueue is a no-op for a cancelled appointment');

-- the claim re-checks the job: a message queued behind the trigger's back
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after, template_key)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_a'), 'outbound', 'sms', '+12055550101', 'On my way', 'queued',
          '2025-06-02 12:00Z', 'on_the_way')
  returning tests.fx_set('late_otw', id);
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-06-02 12:01Z') c where c.job_id = tests.fx('job_a')),
                0::bigint, 'nothing of the cancelled appointment is handed to the sender');
select tests.ok((select status = 'cancelled' and error = 'the appointment was cancelled' and attempts = 0
                   from public.messages where id = tests.fx('late_otw')), 'the claim cancels it instead');

-- no-show
select tests.as_superuser();
update public.customers set phone = '+12055550102' where id = tests.fx('cust_a2');
update public.jobs set status = 'scheduled' where id = tests.fx('job_a2');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('rem2', public.enqueue_template_message(tests.fx('job_a2'), 'appointment_reminder', '2025-06-02 12:00Z'));
update public.jobs set status = 'no_show' where id = tests.fx('job_a2');
select tests.ok((select status = 'cancelled' and error = 'the appointment was marked as a no-show'
                   from public.messages where id = tests.fx('rem2')), 'a no-show withdraws queued appointment messages');

-- ============================================================ reschedule re-renders, customer change withdraws
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-06-10 15:00Z', '2025-06-10 16:00Z')
  returning tests.fx_set('job_r', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('rem_r', public.enqueue_template_message(tests.fx('job_r'), 'appointment_reminder', '2025-06-09 15:00Z'));
select tests.fx_set('rem_r_mail', public.enqueue_template_message(tests.fx('job_r'), 'appointment_reminder', '2025-06-09 15:00Z', 'email'));
select tests.ok((select body like '%Tuesday, June 10 at 10:00 AM%' from public.messages where id = tests.fx('rem_r')),
                'rendered with the original time');
update public.jobs set scheduled_start = '2025-06-12 19:00Z', scheduled_end = '2025-06-12 20:00Z' where id = tests.fx('job_r');
select tests.ok((select status = 'queued' and body like '%Thursday, June 12 at 2:00 PM%' and body not like '%June 10%'
                        and send_after = '2025-06-09 15:00Z'
                   from public.messages where id = tests.fx('rem_r')),
                'a rescheduled job''s queued reminder carries the new date and time (send time kept)');
select tests.ok((select status = 'queued' and body like '%June 12%' and subject is not null
                   from public.messages where id = tests.fx('rem_r_mail')), 'the email copy too');

select tests.fx_set('conf_r', public.enqueue_template_message(tests.fx('job_r'), 'booking_confirmed', '2025-06-09 15:00Z'));
update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_r');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the appointment now belongs to another customer') and count(*) = 3
                   from public.messages where id in (tests.fx('rem_r'), tests.fx('rem_r_mail'), tests.fx('conf_r'))),
                'moving the job to another customer withdraws the previous customer''s appointment messages');

-- ============================================================ staleness (sender outage)
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-10 15:00Z', '2025-07-10 16:00Z')
  returning tests.fx_set('job_s', id);
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after, template_key)
values
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'conf old', 'queued', '2025-07-01 09:59Z', 'booking_confirmed'),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'conf fresh', 'queued', '2025-07-01 12:00Z', 'booking_confirmed'),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'otw old', 'queued', '2025-07-02 07:00Z', 'on_the_way'),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'otw fresh', 'queued', '2025-07-02 09:30Z', 'on_the_way'),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'note old', 'queued', '2025-07-01 09:00Z', null),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_s'), 'outbound', 'sms', '+12055550101', 'invoice old', 'queued', '2025-06-20 09:00Z', 'invoice_sent'),
  (tests.fx('shop_a'), tests.fx('cust_a'), null, 'outbound', 'sms', '+12055550101', 'welcome old', 'queued', '2025-06-20 09:00Z', 'membership_welcome');
select tests.as_service();
create temp table stale_claim on commit drop as select * from public.claim_queued_messages(50, '2025-07-02 10:00Z');
select tests.eq((select array_agg(body order by body) from stale_claim
                  where body in ('conf old', 'conf fresh', 'otw old', 'otw fresh', 'note old', 'invoice old', 'welcome old')),
                array['conf fresh', 'invoice old', 'otw fresh', 'welcome old'],
                'fresh job messages, invoices/receipts and non-job messages are sent');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the message is too old to send') and count(*) = 3
                   from public.messages where body in ('conf old', 'otw old', 'note old')),
                'job messages 24 h (on-the-way: 2 h) past their send time are cancelled, not blasted');

-- a reminder is not sent once the appointment is under way (15 minutes of grace)
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-07-20 15:00Z', '2025-07-20 16:00Z')
  returning tests.fx_set('job_g', id);
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after, template_key)
values
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_g'), 'outbound', 'sms', '+12055550101', 'rem grace', 'queued', '2025-07-20 15:00Z', 'appointment_reminder'),
  (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_g'), 'outbound', 'sms', '+12055550101', 'rem late', 'queued', '2025-07-20 15:01Z', 'appointment_reminder');
-- 'rem grace' is the automation's offset-0 reminder: due at the start itself
insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome,
                                       message_ids)
values (tests.fx('shop_a'), tests.fx('job_g'), tests.fx('cust_a'), 'appointment_reminder', '2025-07-20 15:00Z',
        '2025-07-20 15:00Z', '2025-07-20 15:00Z', 'queued', array[(select id from public.messages where body = 'rem grace')]);
select tests.as_service();
select tests.eq((select array_agg(body) from public.claim_queued_messages(1, '2025-07-20 15:10Z')), array['rem grace'],
                'a reminder at the appointment time goes out within 15 minutes');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-07-20 15:16Z')), 0::bigint, 'not later');
select tests.ok((select status = 'cancelled' and error = 'the appointment has already started' from public.messages
                  where body = 'rem late'), 'a reminder for an appointment that already started is cancelled');

-- ============================================================ campaigns: consent withdrawn after launch
-- Regression: staff turn off the marketing opt-in (appointment texts stay on)
-- before a scheduled campaign goes out.
select tests.as_superuser();
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body, scheduled_at)
  values (tests.fx('shop_a'), 'Holiday', 'sms', 'Holiday special this weekend', '2099-12-01Z') returning tests.fx_set('camp', id);
select public.launch_campaign(tests.fx('camp'));
update public.customers set sms_opt_in = false where id = tests.fx('cust_a');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2099-12-01 00:01Z') c where c.campaign_id = tests.fx('camp')),
                0::bigint, 'a campaign message must not be sent to a customer who withdrew marketing consent');
select tests.ok((select status = 'cancelled' and error = 'the recipient withdrew marketing consent before sending'
                   from public.messages where campaign_id = tests.fx('camp')), 'cancelled with the reason');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('cust_a')),
                'transactional texts stay allowed');

-- campaign messages are also stale after 24 h
select tests.as_superuser();
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body, scheduled_at)
  values (tests.fx('shop_a'), 'Weekend', 'sms', 'Weekend deal', '2099-11-01Z') returning tests.fx_set('camp_st', id);
select public.launch_campaign(tests.fx('camp_st'));
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2099-11-02 00:01Z') c where c.campaign_id = tests.fx('camp_st')),
                0::bigint, 'a campaign held up for more than 24 h is not blasted late');
select tests.ok((select status = 'cancelled' and error = 'the message is too old to send'
                   from public.messages where campaign_id = tests.fx('camp_st')), 'cancelled as stale');

-- ============================================================ campaigns: cancelled while in flight, then retried
-- Regression: the provider asks for a retry after the campaign was cancelled.
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Promo', 'sms', 'Promo this weekend')
  returning tests.fx_set('camp_x', id);
select public.launch_campaign(tests.fx('camp_x'));
select tests.as_service();
select tests.fx_set('m_x', (select c.id from public.claim_queued_messages(50, now() + interval '1 minute') c
                             where c.campaign_id = tests.fx('camp_x')));
select tests.ok(tests.fx('m_x') is not null, 'the campaign message is in flight');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.cancel_campaign(tests.fx('camp_x'));
select tests.eq((select status::text from public.messages where id = tests.fx('m_x')), 'sending', 'in-flight message untouched');
select tests.as_service();
select tests.ok((select status = 'cancelled' and error = 'the campaign was cancelled'
                   from public.mark_message_result(tests.fx('m_x'), 'queued', null, 'Twilio 429', null, now() + interval '2 minutes')),
                'a retry of a cancelled campaign''s message is cancelled instead of re-queued');
select tests.eq((select count(*) from public.claim_queued_messages(50, now() + interval '1 hour') c where c.campaign_id = tests.fx('camp_x')),
                0::bigint, 'a message of a cancelled campaign must not be re-sent on retry');
-- and the claim itself never hands out a cancelled campaign's message
select tests.as_superuser();
update public.messages set status = 'queued', error = null where id = tests.fx('m_x');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, now() + interval '1 hour') c where c.campaign_id = tests.fx('camp_x')),
                0::bigint, 'the claim cancels queued messages of a cancelled campaign');
select tests.ok((select status = 'cancelled' and error = 'the campaign was cancelled' from public.messages where id = tests.fx('m_x')),
                'cancelled with the reason');
-- an ordinary retry still works
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after, attempts, claimed_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', 'retry me', 'sending', '2099-01-01Z', 1, '2099-01-01Z')
  returning tests.fx_set('m_retry', id);
select tests.as_service();
select tests.ok((select status = 'queued' and send_after = '2099-01-01 00:02Z'
                   from public.mark_message_result(tests.fx('m_retry'), 'queued', null, 'Twilio 503', null, '2099-01-01 00:00Z')),
                'retries of messages that may still be sent are re-queued with backoff');

-- ============================================================ isolation
-- cancelling shop A's job never touches shop B's queue
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('rem_b', public.enqueue_template_message(tests.fx('job_b'), 'appointment_reminder', '2025-06-02 12:00Z'));
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'appointment_reminder')$$, 'P0002',
                    'another shop''s job is not found');
select tests.as_superuser();
update public.jobs set status = 'cancelled' where id = tests.fx('job_s');
select tests.eq((select status::text from public.messages where id = tests.fx('rem_b')), 'queued', 'shop B''s reminder is untouched');

-- ============================================================ cancelled campaign deleted while a message is in flight
-- Regression: deleting a cancelled campaign set messages.campaign_id to
-- null, so its in-flight message lost the campaign checks and a provider
-- retry re-queued it as an ordinary message. Launched campaigns are now kept.
select tests.as_superuser();
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Promo 2', 'sms', 'Promo this weekend')
  returning tests.fx_set('camp_y', id);
select public.launch_campaign(tests.fx('camp_y'));
select tests.as_service();
select tests.fx_set('m_y', (select c.id from public.claim_queued_messages(50, now() + interval '1 minute') c
                             where c.campaign_id = tests.fx('camp_y')));
select tests.ok(tests.fx('m_y') is not null, 'the campaign message is in flight');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.cancel_campaign(tests.fx('camp_y'));
select tests.throws($$delete from public.campaigns where id = tests.fx('camp_y')$$, '42501',
                    'the cancelled campaign cannot be deleted while it has messages');
select tests.eq(tests.row_count($$select 1 from public.campaigns where id = tests.fx('camp_y')$$), 1::bigint, 'it is still there');
select tests.as_service();
select tests.ok((select status = 'cancelled' and error = 'the campaign was cancelled' and campaign_id = tests.fx('camp_y')
                   from public.mark_message_result(tests.fx('m_y'), 'queued', null, 'Twilio 429', null, now() + interval '2 minutes')),
                'a message of a cancelled campaign must not be re-queued');
select tests.eq((select count(*) from public.claim_queued_messages(50, now() + interval '1 hour') c where c.id = tests.fx('m_y')),
                0::bigint, 'a message of a cancelled campaign must not be re-sent on retry');

-- ============================================================ deleted appointment
-- Regression: deleting a job set its messages' job_id to null, so queued
-- reminders / confirmations of the deleted appointment were still sent.
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-08-05 15:00Z', '2025-08-05 16:00Z')
  returning tests.fx_set('job_del', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('del_rem', public.enqueue_template_message(tests.fx('job_del'), 'appointment_reminder', '2025-08-04 15:00Z'));
select tests.fx_set('del_conf', public.enqueue_template_message(tests.fx('job_del'), 'booking_confirmed', '2025-08-04 15:00Z', 'email'));
select tests.fx_set('del_note', (public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'See you soon',
                                                      tests.fx('job_del'))).id);
select tests.ok(tests.fx('del_rem') is not null and tests.fx('del_conf') is not null, 'reminder and confirmation queued');
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, send_after,
                             template_key, attempts, claimed_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_del'), 'outbound', 'sms', '+12055550101', 'On my way', 'sending',
          '2025-08-05 14:00Z', 'on_the_way', 1, '2025-08-05 14:00Z')
  returning tests.fx_set('del_otw', id);
-- a delete that is refused (the job has an invoice) withdraws nothing
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-08-06 15:00Z', '2025-08-06 16:00Z')
  returning tests.fx_set('job_inv', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_inv'), 'Wash', 5000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.create_invoice_from_job(tests.fx('job_inv'));
select tests.fx_set('inv_rem', public.enqueue_template_message(tests.fx('job_inv'), 'appointment_reminder', '2025-08-05 15:00Z'));
select tests.throws($$delete from public.jobs where id = tests.fx('job_inv')$$, null, 'a job with an invoice cannot be deleted');
select tests.eq((select status::text from public.messages where id = tests.fx('inv_rem')), 'queued',
                'so its reminder stays queued');

select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('del_b', public.enqueue_template_message(tests.fx('job_b'), 'booking_confirmed', '2025-08-04 15:00Z'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_del')$$), 1::bigint, 'the job is deleted');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the appointment was deleted') and count(*) = 2
                   from public.messages where id in (tests.fx('del_rem'), tests.fx('del_conf'))),
                'its queued templated messages are withdrawn');
select tests.ok((select status = 'queued' and job_id is null from public.messages where id = tests.fx('del_note')),
                'a free-form staff message is kept');
select tests.as_superuser();
select tests.eq((select status::text from public.messages where id = tests.fx('del_b')), 'queued',
                'shop B''s queue is untouched');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-08-04 15:01Z') c
                  where c.id in (tests.fx('del_rem'), tests.fx('del_conf'))),
                0::bigint, 'an appointment reminder for a deleted appointment must not be sent');
select tests.ok((select status = 'cancelled' and error = 'the appointment was deleted'
                   from public.mark_message_result(tests.fx('del_otw'), 'queued', null, 'timeout', null, '2025-08-05 14:01Z')),
                'an in-flight appointment message of a deleted job is not retried');

-- ============================================================ changed phone number / email
-- Regression: messages queued before staff corrected a customer's number or
-- email still went to the previous address.
select tests.as_superuser();
insert into public.customers (shop_id, first_name, phone, email)
  values (tests.fx('shop_a'), 'Carl', '+12055550171', 'carl@example.com') returning tests.fx_set('cust_carl', id);
insert into public.customers (shop_id, first_name, phone, email)
  values (tests.fx('shop_a'), 'Dora', '+12055550172', 'dora@example.com') returning tests.fx_set('cust_dora', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_carl'), 'scheduled', '2025-08-12 15:00Z', '2025-08-12 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_dora'), 'scheduled', '2025-08-12 17:00Z', '2025-08-12 18:00Z');
select tests.fx_set(k, (select id from public.jobs where customer_id = tests.fx(c)))
  from (values ('job_carl', 'cust_carl'), ('job_dora', 'cust_dora')) v(k, c);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-11 15:00Z'), 2, 'Carl''s reminder queued sms + email');
select tests.eq(public.enqueue_due_automations('2025-08-11 17:00Z'), 2, 'Dora''s too');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('carl_note', (public.queue_message(tests.fx('shop_a'), tests.fx('cust_carl'), 'email', 'Hi', 'Parking info',
                                                       tests.fx('job_carl'))).id);
update public.customers set email = 'Dora@Example.com' where id = tests.fx('cust_dora');
update public.customers set phone = '+12055550177', email = 'carl.new@example.com' where id = tests.fx('cust_carl');
select tests.ok((select bool_and(status = 'cancelled' and error = 'the customer''s contact details changed before sending')
                        and count(*) = 3
                   from public.messages where customer_id = tests.fx('cust_carl')),
                'everything queued to Carl''s previous number and address is withdrawn');
select tests.ok((select bool_and(status = 'queued') and count(*) = 2 from public.messages where customer_id = tests.fx('cust_dora')),
                'a change of letter case only is the same address; other customers are untouched');
select tests.as_service();
select tests.eq((select array_agg(c.to_address order by c.channel) from public.claim_queued_messages(50, '2025-08-11 17:01Z') c
                  where c.customer_id = tests.fx('cust_carl')),
                null::text[], 'no message may still go to the previous number / address');
-- the claim / a retry re-checks the address (e.g. a message in flight when it changed)
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after, attempts, claimed_at)
  values (tests.fx('shop_a'), tests.fx('cust_carl'), 'outbound', 'sms', '+12055550171', 'old number', 'sending',
          '2025-08-11 17:00Z', 1, '2025-08-11 17:00Z')
  returning tests.fx_set('carl_flight', id);
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after)
  values (tests.fx('shop_a'), tests.fx('cust_carl'), 'outbound', 'sms', '+12055550171', 'behind the trigger', 'queued',
          '2025-08-11 17:00Z')
  returning tests.fx_set('carl_sneak', id);
select tests.as_service();
select tests.ok((select status = 'cancelled' and error = 'the customer''s contact details changed before sending'
                   from public.mark_message_result(tests.fx('carl_flight'), 'queued', null, 'timeout', null, '2025-08-11 17:01Z')),
                'a retry to the previous number is cancelled');
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-08-11 17:02Z') c where c.id = tests.fx('carl_sneak')),
                0::bigint, 'the claim cancels a message to an address the customer no longer has');
-- the new address works as usual
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.queue_message(tests.fx('shop_a'), tests.fx('cust_carl'), 'sms', null, 'New number saved')).to_address,
                '+12055550177', 'new messages go to the new number');
select tests.as_service();
select tests.eq((select array_agg(c.to_address) from public.claim_queued_messages(50, now()) c where c.customer_id = tests.fx('cust_carl')),
                array['+12055550177'], 'and are sent');

-- ============================================================ deleting a whole shop
-- Launched campaigns keep their messages (NO ACTION FK) and deleting a job
-- withdraws its queued messages, yet deleting the shop still removes
-- everything in one statement (and never touches another shop).
select tests.as_superuser();
update public.customers set sms_opt_in = true where id = tests.fx('cust_b');
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_b'), 'B promo', 'sms', 'Promo')
  returning tests.fx_set('camp_b', id);
select public.launch_campaign(tests.fx('camp_b'));
select tests.fx_set('b_rem', public.enqueue_template_message(tests.fx('job_b'), 'appointment_reminder', '2025-08-20 12:00Z'));
select tests.as_superuser();
create temp table a_before on commit drop as select count(*) as n from public.messages where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.lives($$delete from public.shops where id = tests.fx('shop_b')$$, 'a shop with launched campaigns and queued job messages can be deleted');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_b')), 0::bigint, 'its messages are gone');
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a')), (select n from a_before),
                'shop A''s messages are untouched');
