-- 30 comms: queued messages follow their context until the sender claims
-- them. Appointment messages are withdrawn when the job is cancelled,
-- marked no-show or moved to another customer, and re-rendered when it is
-- rescheduled; campaign messages stop when marketing consent is withdrawn
-- or the campaign is cancelled (also for in-flight retries); stale job and
-- campaign messages are never sent after a sender outage.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test');
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
