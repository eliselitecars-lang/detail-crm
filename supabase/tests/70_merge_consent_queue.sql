-- 70 ops: merge_customers (P-20) — consent follows its address and queued
-- messages survive the merge.
--   consent   a survivor's opt-in given without a phone / email is not
--             carried onto the duplicate's address; the duplicate's opt-in
--             comes with its address; the same address on both keeps either
--             opt-in; the survivor's own address keeps its own; an opt-out
--             stamp (from either) leaves no opt-in on.
--   queue     a scheduled staff send, an automatic appointment reminder and a
--             marketing campaign email queued for the duplicate are
--             re-addressed to the survivor's address, pass the claim-time
--             checks (comms_withdraw_reason) and are claimed; the automation
--             log does not queue them again; the unsubscribe credential
--             follows the email's new address; promotions only move to an
--             address with marketing consent, and an attempted marketing
--             email keeps its inbox and link; a message already addressed
--             to a stale address is not re-addressed; duplicates of the
--             survivor's own messages (same campaign; same reminder slot) are
--             cancelled, other reminder offsets kept; shop B untouched.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');

-- ============================================================ consent follows its address
select tests.authenticate_as(tests.fx('u_admin_a'));
-- (1) survivor: text box ticked while it had no number; duplicate: a number that never consented
insert into public.customers (shop_id, first_name, email, sms_opt_in)
  values (tests.fx('shop_a'), 'Dana', 'dana@example.com', true) returning tests.fx_set('tgt1', id);
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Dana', '+12055550199', false) returning tests.fx_set('src1', id);
select public.merge_customers(tests.fx('src1'), tests.fx('tgt1'));
select tests.eq((select jsonb_build_array(phone, sms_opt_in) from public.customers where id = tests.fx('tgt1')),
                '["+12055550199", false]'::jsonb,
                'the survivor takes the number, not text consent that number never gave');
-- (2) the same for email
insert into public.customers (shop_id, first_name, phone, email_opt_in)
  values (tests.fx('shop_a'), 'Eve', '+12055550198', true) returning tests.fx_set('tgt2', id);
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Eve', 'eve@example.com', false) returning tests.fx_set('src2', id);
select public.merge_customers(tests.fx('src2'), tests.fx('tgt2'));
select tests.eq((select jsonb_build_array(email, email_opt_in) from public.customers where id = tests.fx('tgt2')),
                '["eve@example.com", false]'::jsonb, 'nor email consent that inbox never gave');
-- (3) the duplicate's opt-in comes with its address
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Finn') returning tests.fx_set('tgt3', id);
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in, email_opt_in)
  values (tests.fx('shop_a'), 'Finn', '+12055550197', 'finn@example.com', true, true) returning tests.fx_set('src3', id);
select public.merge_customers(tests.fx('src3'), tests.fx('tgt3'));
select tests.eq((select jsonb_build_array(phone, sms_opt_in, email, email_opt_in) from public.customers where id = tests.fx('tgt3')),
                '["+12055550197", true, "finn@example.com", true]'::jsonb,
                'consent given with the duplicate''s number and inbox moves with them');
-- (4) the same address on both: either opt-in counts; (5) the survivor's own address keeps its own opt-in
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in, email_opt_in)
  values (tests.fx('shop_a'), 'Gia', '+12055550196', 'gia@example.com', false, true) returning tests.fx_set('tgt4', id);
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in, email_opt_in)
  values (tests.fx('shop_a'), 'Gia', '+12055550196', 'gia.other@example.com', true, false) returning tests.fx_set('src4', id);
select public.merge_customers(tests.fx('src4'), tests.fx('tgt4'));
select tests.eq((select jsonb_build_array(sms_opt_in, email, email_opt_in) from public.customers where id = tests.fx('tgt4')),
                '[true, "gia@example.com", true]'::jsonb,
                'the same number consented on the duplicate: on; the survivor''s own inbox keeps its opt-in');
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Hal', '+12055550195', false) returning tests.fx_set('tgt5', id);
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Hal', '+12055550194', true) returning tests.fx_set('src5', id);
select public.merge_customers(tests.fx('src5'), tests.fx('tgt5'));
select tests.eq((select jsonb_build_array(phone, sms_opt_in) from public.customers where id = tests.fx('tgt5')),
                '["+12055550195", false]'::jsonb, 'another number''s consent never lands on the survivor''s number');
-- (6) an opt-out stamp leaves no opt-in on
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Ivy') returning tests.fx_set('tgt6', id);
insert into public.customers (shop_id, first_name, phone, sms_opt_in, sms_opted_out_at)
  values (tests.fx('shop_a'), 'Ivy', '+12055550193', true, '2025-01-01Z') returning tests.fx_set('src6', id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.merge_customers(tests.fx('src6'), tests.fx('tgt6'));
select tests.eq((select jsonb_build_array(phone, sms_opt_in, sms_opted_out_at is not null) from public.customers where id = tests.fx('tgt6')),
                '["+12055550193", false, true]'::jsonb, 'an opted-out number arrives opted out, never opted in');

-- ============================================================ queued messages survive the merge
select tests.as_superuser();
-- nothing else of the fixture shops is due (rolled back with the file)
update public.messages set status = 'cancelled' where status = 'queued' and shop_id in (tests.fx('shop_a'), tests.fx('shop_b'));
update public.message_templates set enabled = true, reminder_offsets_minutes = '{-1440}'
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms';
update public.message_templates set enabled = false
 where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email';
insert into public.customers (shop_id, first_name, phone, email, tags, email_opt_in, sms_opt_in)
  values (tests.fx('shop_a'), 'Dup', '+12055550181', 'dup@example.com', '{mergeq}', true, true) returning tests.fx_set('dup', id);
insert into public.customers (shop_id, first_name, phone, email, tags, email_opt_in)
  values (tests.fx('shop_a'), 'Survivor', '+12055550182', 'surv@example.com', '{mergeq}', true) returning tests.fx_set('surv', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('dup'), now() + interval '3 days', now() + interval '3 days 2 hours')
  returning tests.fx_set('job', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('dup'), now() + interval '20 hours', now() + interval '22 hours')
  returning tests.fx_set('job_rem', id);
-- (a) a scheduled staff send
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('msg', public.enqueue_template_message(tests.fx('job'), 'booking_confirmed', now() + interval '1 day', 'sms'));
-- (b) the automatic reminder
select tests.as_service();
select public.enqueue_due_automations(now());
select tests.fx_set('msg_rem', (select m.id from public.messages m
                                 where m.job_id = tests.fx('job_rem') and m.template_key = 'appointment_reminder'
                                   and m.status = 'queued'));
select tests.ok(tests.fx('msg_rem') is not null, 'the reminder is queued for the duplicate');
-- (c) a marketing email campaign reaching only the duplicate, and one reaching both
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body, audience)
  values (tests.fx('shop_a'), 'Only dup', 'email', 'News', 'Hello', '{"tags": ["mergeq"]}') returning tests.fx_set('camp1', id);
update public.customers set tags = '{}' where id = tests.fx('surv');
select public.launch_campaign(tests.fx('camp1'));
update public.customers set tags = '{mergeq}' where id = tests.fx('surv');
insert into public.campaigns (shop_id, name, channel, subject, body, audience)
  values (tests.fx('shop_a'), 'Both', 'email', 'Offer', 'Hi', '{"tags": ["mergeq"]}') returning tests.fx_set('camp2', id);
select public.launch_campaign(tests.fx('camp2'));
select tests.as_superuser();
select tests.fx_set('msg_c1', (select message_id from public.campaign_recipients where campaign_id = tests.fx('camp1')));
select tests.fx_set('tok_c1', (select unsubscribe_token from public.messages where id = tests.fx('msg_c1')));
select tests.fx_set('msg_c2_dup', (select message_id from public.campaign_recipients
                                    where campaign_id = tests.fx('camp2') and customer_id = tests.fx('dup')));
select tests.fx_set('msg_c2_surv', (select message_id from public.campaign_recipients
                                     where campaign_id = tests.fx('camp2') and customer_id = tests.fx('surv')));
-- (c2) a promotional text: the survivor's number never consented to marketing
select tests.as_service();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('dup'), 'outbound', 'sms', '+12055550181', 'Come back!', 'queued', 'follow_up', now())
  returning tests.fx_set('msg_promo', id);
-- (c3) a marketing email that already had a send attempt: its link may be in the old inbox
insert into public.messages (shop_id, customer_id, direction, channel, to_address, subject, body, status, template_key,
                             send_after, unsubscribe_token, attempts)
  values (tests.fx('shop_a'), tests.fx('dup'), 'outbound', 'email', 'dup@example.com', 'Hi', 'Come back!', 'queued', 'follow_up',
          now() + interval '1 day', gen_random_uuid(), 1)
  returning tests.fx_set('msg_tried', id);
select tests.fx_set('tok_tried', (select unsubscribe_token from public.messages where id = tests.fx('msg_tried')));
-- (d) a message to an address the duplicate no longer has
select tests.as_service();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after)
  values (tests.fx('shop_a'), tests.fx('dup'), 'outbound', 'sms', '+12055550180', 'Old number', 'queued', now())
  returning tests.fx_set('msg_stale', id);
-- (e) reminder log rows: the survivor already has this slot (same job, start, offset); another offset is the duplicate's only
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('surv'), tests.fx('job'), 'outbound', 'sms', '+12055550182', 'Reminder (survivor)', 'queued',
          'appointment_reminder', now() + interval '2 days') returning tests.fx_set('msg_slot_surv', id);
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('dup'), tests.fx('job'), 'outbound', 'sms', '+12055550181', 'Reminder (dup)', 'queued',
          'appointment_reminder', now() + interval '2 days') returning tests.fx_set('msg_slot_dup', id);
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('dup'), tests.fx('job'), 'outbound', 'sms', '+12055550181', 'Week reminder (dup)', 'queued',
          'appointment_reminder', now() + interval '1 day') returning tests.fx_set('msg_week_dup', id);
insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes, due_at,
                                       processed_at, outcome, message_ids)
  values (tests.fx('shop_a'), tests.fx('job'), tests.fx('surv'), 'appointment_reminder',
          (select scheduled_start from public.jobs where id = tests.fx('job')), -1440, now() + interval '2 days', now(), 'queued',
          array[tests.fx('msg_slot_surv')]),
         (tests.fx('shop_a'), tests.fx('job'), tests.fx('dup'), 'appointment_reminder',
          (select scheduled_start from public.jobs where id = tests.fx('job')), -1440, now() + interval '2 days', now(), 'queued',
          array[tests.fx('msg_slot_dup')]),
         (tests.fx('shop_a'), tests.fx('job'), tests.fx('dup'), 'appointment_reminder',
          (select scheduled_start from public.jobs where id = tests.fx('job')), -2880, now() + interval '1 day', now(), 'queued',
          array[tests.fx('msg_week_dup')]);
-- shop B's queued message (isolation)
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after)
  values (tests.fx('shop_b'), tests.fx('cust_b'), 'outbound', 'sms', '+12055550170', 'B', 'queued', now() + interval '1 day')
  returning tests.fx_set('msg_b', id);

select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('dup'), tests.fx('surv'));
select tests.as_superuser();

-- (a) the scheduled staff send
select tests.eq((select array[status::text, customer_id::text, to_address] from public.messages where id = tests.fx('msg')),
                array['queued', tests.fx('surv')::text, '+12055550182'], 'kept, moved and re-addressed to the survivor''s number');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '1 day') from public.messages m where m.id = tests.fx('msg')),
                null, 'a merge never costs the customer a queued message');
-- (b) the reminder: claimed and delivered, not withdrawn; the log is not re-run
select tests.as_service();
select tests.eq((select to_address from public.claim_queued_messages(500, now()) c where c.id = tests.fx('msg_rem')), '+12055550182',
                'the reminder is claimed for the survivor''s number');
select tests.eq((select array[status::text, coalesce(error, '')] from public.messages where id = tests.fx('msg_rem')),
                array['sending', ''], 'and is being sent, not withdrawn');
select tests.eq(public.enqueue_due_automations(now()), 0, 'the automation log still covers it: nothing queued twice');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_rem') and template_key = 'appointment_reminder'),
                1::bigint, 'one reminder in all');
-- (c) campaigns
select tests.as_superuser();
select tests.eq((select array[status::text, to_address, customer_id::text] from public.messages where id = tests.fx('msg_c1')),
                array['sending', 'surv@example.com', tests.fx('surv')::text],
                'the campaign email goes to the survivor''s inbox (claimed above)');
select tests.eq((select address from public.comms_unsubscribe_tokens where token = tests.fx('tok_c1')::uuid), 'surv@example.com',
                'its unsubscribe link opts out the inbox it is sent to');
select tests.eq((select jsonb_build_array(d.status, d.error, s.status)
                   from public.messages d, public.messages s where d.id = tests.fx('msg_c2_dup') and s.id = tests.fx('msg_c2_surv')),
                '["cancelled", "a duplicate of the surviving customer''s message (customers merged)", "sending"]'::jsonb,
                'a campaign reaching both sends the survivor one email');
select tests.eq((select count(*) from public.campaign_recipients where campaign_id = tests.fx('camp2')), 1::bigint,
                'one recipient row');
select tests.eq((select array[to_address, public.comms_withdraw_reason(m, now())] from public.messages m where m.id = tests.fx('msg_promo')),
                array['+12055550181', 'the customer''s contact details changed before sending'],
                'a promotion is never pointed at a number without marketing consent; it is withdrawn');
select tests.eq((select array[m.to_address, u.address] from public.messages m join public.comms_unsubscribe_tokens u on u.message_id = m.id
                  where m.id = tests.fx('msg_tried')),
                array['dup@example.com', 'dup@example.com'], 'a marketing email already attempted keeps its inbox and its link');
-- (d) a stale address is not re-addressed
select tests.eq((select array[status::text, to_address, error] from public.messages where id = tests.fx('msg_stale')),
                array['cancelled', '+12055550180', 'the customer''s contact details changed before sending'],
                'a message the duplicate would not have received either is still withdrawn');
-- (e) reminder slots
select tests.eq((select jsonb_agg(jsonb_build_array(body, status, to_address) order by body) from public.messages
                  where id in (tests.fx('msg_slot_surv'), tests.fx('msg_slot_dup'), tests.fx('msg_week_dup'))),
                '[["Reminder (dup)", "cancelled", "+12055550181"], ["Reminder (survivor)", "queued", "+12055550182"],
                  ["Week reminder (dup)", "queued", "+12055550182"]]'::jsonb,
                'the duplicate''s copy of the survivor''s reminder is cancelled; its other offset is kept and re-addressed');
select tests.eq((select array_agg(reminder_offset_minutes order by reminder_offset_minutes) from public.job_automation_log
                  where job_id = tests.fx('job') and customer_id = tests.fx('surv')),
                array[-2880, -1440], 'one log row per offset, all the survivor''s');
-- shop B
select tests.eq((select array[status::text, to_address] from public.messages where id = tests.fx('msg_b')),
                array['queued', '+12055550170'], 'shop B is untouched');
