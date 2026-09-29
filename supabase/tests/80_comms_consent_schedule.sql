-- 80 comms: consent belongs to an address, and promotions respect archived
-- customers and waking hours.
--   * import_customers applies a row's text / email consent only to the
--     phone / email the row gives, and only when that is the address the
--     customer ends up with (0087)
--   * marketing keys are never queued for, and are withdrawn from, archived
--     customers (enqueue_message_core 0083, comms_withdraw_reason 0085)
--   * per-service follow-ups are due at 10:00 shop-local on the local date of
--     completed_at + offset_days (DST-proof), and a late run outside
--     08:00-21:00 holds them until 10:00 (comms_marketing_send_after, 0086)
--   * the generic follow_up automation (also promotional, due at the minute of
--     the day the job was closed) keeps the same 08:00-21:00 window in each
--     shop's own timezone; transactional automations are not held
--   * a per-service follow-up is skipped while the customer has any open job
--     with the service (or a package containing it), whatever its dates
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));

-- ================================================================ import consent
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Nora', 'nora@example.com', '+12055550131', false) returning tests.fx_set('cust_n', id);
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Nell', 'nell@example.com', '+12055550132', false) returning tests.fx_set('cust_nl', id);
insert into public.customers (shop_id, first_name, email)
  values (tests.fx('shop_a'), 'Pia', 'pia@example.com') returning tests.fx_set('cust_p', id);
insert into public.customers (shop_id, first_name, phone)
  values (tests.fx('shop_a'), 'Quinn', '+12055550133') returning tests.fx_set('cust_q', id);
select tests.authenticate_as(tests.fx('u_manager_a'));

-- matched by email, the file has another phone: the number on file never consented
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Nora", "email": "nora@example.com", "phone": "(205) 555-0199", "sms_opt_in": "yes"}]'::jsonb, true) as dry \gset
select tests.ok((:'dry'::jsonb) #>> '{rows,0,message}' like '%text consent not applied%phone is not the one on file%',
                'the dry run says why consent would not be applied');
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Nora", "email": "nora@example.com", "phone": "(205) 555-0199", "sms_opt_in": "yes"}]'::jsonb, false) as res \gset
select tests.eq((select phone from public.customers where id = tests.fx('cust_n')), '+12055550131', 'the number on file is kept');
select tests.eq((select sms_opt_in from public.customers where id = tests.fx('cust_n')), false,
                'the file''s text consent (for +12055550199) is not applied to +12055550131');
select tests.eq((:'res'::jsonb) #>> '{rows,0,action}', 'skip', 'nothing changed');
select tests.ok((:'res'::jsonb) #>> '{rows,0,message}' like 'already up to date; text consent not applied%', 'and says why');

-- same number, written differently: consent applies
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Nell", "email": "NELL@example.com", "phone": "205.555.0132", "sms_opt_in": "Y", "email_opt_in": "yes"}]'::jsonb, false) as res2 \gset
select tests.eq((select concat_ws('/', sms_opt_in::text, email_opt_in::text) from public.customers where id = tests.fx('cust_nl')), 'true/true',
                'the row''s phone and email are the ones on file: consent applies');
select tests.eq((:'res2'::jsonb) #>> '{rows,0,message}', null, 'no note');

-- matched by email with no phone on file: the file's phone is added with its consent
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Pia", "email": "pia@example.com", "phone": "2055550134", "sms_opt_in": true}]'::jsonb, false);
select tests.eq((select concat_ws('/', phone, sms_opt_in::text) from public.customers where id = tests.fx('cust_p')), '+12055550134/true',
                'the phone the customer ends up with is the one that consented');

-- matched by phone (no email on file): the file's email is added with its consent
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Quinn", "email": "quinn@example.com", "phone": "+1 205 555 0133", "email_opt_in": "1", "sms_opt_in": "1"}]'::jsonb, false);
select tests.eq((select concat_ws('/', email, email_opt_in::text, sms_opt_in::text) from public.customers where id = tests.fx('cust_q')),
                'quinn@example.com/true/true', 'matched by phone: both addresses are the row''s');

-- new customers: consent without the address is not kept for a later one
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Omar", "email": "omar@example.com", "sms_opt_in": "yes"},
    {"first_name": "Opal", "phone": "2055550135", "email_opt_in": "yes", "sms_opt_in": "yes"}]'::jsonb, false) as res3 \gset
select tests.eq((select sms_opt_in from public.customers where email = 'omar@example.com'), false, 'no text consent without a number');
select tests.ok((:'res3'::jsonb) #>> '{rows,0,message}' like '%text consent not applied: the row has no phone%', '(reported)');
select tests.eq((select concat_ws('/', sms_opt_in::text, email_opt_in::text) from public.customers
                  where shop_id = tests.fx('shop_a') and phone = '+12055550135'), 'true/false',
                'no email consent without an email; the number''s consent applies');
select tests.ok((:'res3'::jsonb) #>> '{rows,1,message}' like '%email consent not applied: the row has no email%', '(reported)');
-- a staff member adds a number later: it has not consented
select tests.as_superuser();
update public.customers set phone = '+12055550136' where email = 'omar@example.com';
select tests.eq((select sms_opt_in from public.customers where email = 'omar@example.com'), false,
                'a number added later inherits no consent');

-- opt-outs still win
update public.customers set sms_opted_out_at = now(), sms_opt_in = false where id = tests.fx('cust_nl');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Nell", "email": "nell@example.com", "phone": "2055550132", "sms_opt_in": "yes"}]'::jsonb, false);
select tests.eq((select sms_opt_in from public.customers where id = tests.fx('cust_nl')), false, 'an opt-out is never cleared');

-- another shop's customer with the same email is untouched
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_b'), 'Nora', 'nora@example.com', '+12055550199', false) returning tests.fx_set('cust_nb', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Nora", "email": "nora@example.com", "phone": "(205) 555-0199", "sms_opt_in": "yes"}]'::jsonb, false);
select tests.as_superuser();
select tests.eq((select sms_opt_in from public.customers where id = tests.fx('cust_nb')), false, 'shop B''s Nora is untouched');

-- ============================================================ archived customers
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.messages set status = 'cancelled' where status = 'queued';
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'service_followup';
insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
  values (tests.fx('shop_a'), tests.fx('svc_a'), 'sms', 30, 'Hi {{customer_first_name}}, time for your next detail. {{rebook_link}}');

insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Remy', 'remy@example.com', '+12055550121', true) returning tests.fx_set('cust_r', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_r'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z')
  returning tests.fx_set('jf1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf1'), tests.fx('svc_a'), 'Full Detail', 20000);
update public.customers set archived_at = '2025-05-10 12:00Z' where id = tests.fx('cust_r');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 16:00Z'), 0, 'an archived customer gets no promotional follow-up');
select tests.eq((select outcome::text from public.job_automation_log where job_id = tests.fx('jf1') and key = 'service_followup'),
                'skipped', '(logged as skipped)');

-- queued before the customer was archived: withdrawn at send time
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Rita', 'rita@example.com', '+12055550122', true) returning tests.fx_set('cust_rt', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_rt'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z')
  returning tests.fx_set('jf2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jf2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 16:00Z'), 1, 'a customer on file gets it');
select tests.eq((select public.comms_withdraw_reason(m, '2025-05-31 16:05Z') from public.messages m
                  where m.job_id = tests.fx('jf2') and m.template_key = 'service_followup'), null, '(sendable)');
select tests.as_superuser();
update public.customers set archived_at = '2025-05-31 16:02Z' where id = tests.fx('cust_rt');
select tests.as_service();
select tests.eq((select public.comms_withdraw_reason(m, '2025-05-31 16:05Z') from public.messages m
                  where m.job_id = tests.fx('jf2') and m.template_key = 'service_followup'),
                'the customer was archived before sending', 'archived after queueing: withdrawn');

-- the core: marketing keys skip archived customers, transactional ones do not
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_rt'), 'follow_up', 'sms', null, 'Come back soon'),
                null::uuid, 'no follow_up promotion for an archived customer');
select tests.ok(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_rt'), 'lead_received', 'sms', null,
                                            'Thanks, we got your request') is not null,
                'a transactional message still reaches them');
select tests.as_superuser();
update public.customers set archived_at = null where id = tests.fx('cust_rt');
select tests.as_service();
select tests.ok(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_rt'), 'follow_up', 'sms', null, 'Come back soon') is not null,
                'restored: promotions resume');

-- ================================================= follow-up time of day
select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
-- completed 23:30 CDT (04:30Z the next day)
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Sam', 'sam@example.com', '+12055550123', true) returning tests.fx_set('cust_s', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_s'), 'completed', '2025-05-01 22:00Z', '2025-05-02 00:00Z', '2025-05-02 04:30Z')
  returning tests.fx_set('js1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('js1'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 14:59Z'), 0, 'not before 10:00 local on day 30 (May 31)');
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 1, 'due at 10:00 CDT');
select tests.eq((select to_char(send_after at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') from public.messages
                  where job_id = tests.fx('js1') and template_key = 'service_followup'),
                '2025-05-31 10:00', 'a promotional text is not sent at 23:30 local');
select tests.eq((select due_at from public.job_automation_log where job_id = tests.fx('js1') and key = 'service_followup'),
                '2025-05-31 15:00Z'::timestamptz, 'the log records the 10:00 due time');

-- the scheduler runs late at night: held until the next 10:00
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Tess', 'tess@example.com', '+12055550124', true) returning tests.fx_set('cust_t', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_t'), 'completed', '2025-05-01 22:00Z', '2025-05-02 00:00Z', '2025-05-02 04:30Z')
  returning tests.fx_set('js2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('js2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select public.enqueue_service_followups('2025-06-01 04:30Z');
select tests.eq((select to_char(send_after at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') from public.messages
                  where job_id = tests.fx('js2') and template_key = 'service_followup'),
                '2025-06-01 10:00', 'a run at 23:30 local holds the text until 10:00 the next morning');
select tests.eq((select public.comms_withdraw_reason(m, '2025-06-01 15:01Z') from public.messages m
                  where m.job_id = tests.fx('js2') and m.template_key = 'service_followup'), null,
                'and it is not stale when it goes out');

-- DST: completed in CDT, due after the switch to CST — still 10:00 local
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Uma', 'uma@example.com', '+12055550125', true) returning tests.fx_set('cust_u', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_u'), 'completed', '2025-10-15 14:00Z', '2025-10-15 16:00Z', '2025-10-15 16:00Z')
  returning tests.fx_set('js3', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('js3'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-11-14 15:59Z'), 0, 'not before 10:00 CST');
select tests.eq(public.enqueue_service_followups('2025-11-14 16:00Z'), 1, '10:00 CST = 16:00Z');
select tests.eq(public.enqueue_service_followups('2025-11-15 16:00Z'), 0, 'exactly once');

-- ======================================== the generic follow_up keeps waking hours
-- enqueue_due_automations queues follow_up (also a marketing key) at
-- completed_at + offset_minutes, i.e. at the minute of the day the job was
-- closed; outside 08:00-21:00 shop-local it is held until 10:00 like the
-- per-service follow-ups. Transactional automations are not held.
select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
update public.service_followups set enabled = false where shop_id = tests.fx('shop_a');
update public.message_templates set enabled = true
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'sms';
update public.message_templates set enabled = false
 where shop_id = tests.fx('shop_a') and (key in ('review_request', 'appointment_reminder')
                                         or (key = 'follow_up' and channel = 'email'));
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Nia', '+12055550177', true) returning tests.fx_set('cust_fn', id);
-- closed at 22:40 CDT (03:40Z the next day)
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_fn'), 'completed', '2025-06-01 23:00Z', '2025-06-02 01:00Z', '2025-06-02 03:40Z')
  returning tests.fx_set('jfu_night', id);
-- shop B (Los Angeles) closes a job at the same instant: 20:40 PDT, inside its window
update public.shops set timezone = 'America/Los_Angeles' where id = tests.fx('shop_b');
update public.message_templates set enabled = false where shop_id = tests.fx('shop_b');
update public.message_templates set enabled = true
 where shop_id = tests.fx('shop_b') and key = 'follow_up' and channel = 'email';
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_b'), 'Lou', 'lou@example.com', true) returning tests.fx_set('cust_fb', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_b'), tests.fx('cust_fb'), 'completed', '2025-06-01 23:00Z', '2025-06-02 01:00Z', '2025-06-02 03:40Z')
  returning tests.fx_set('jfu_b', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-02 03:39Z'), 0, 'follow_up not due before 30 days');
select tests.eq(public.enqueue_due_automations('2025-07-02 03:40Z'), 2, 'follow_up queued in both shops');
select tests.eq((select to_char(send_after at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') from public.messages
                  where job_id = tests.fx('jfu_night') and template_key = 'follow_up'),
                '2025-07-02 10:00', 'a follow_up due at 22:40 local is held until 10:00 the next morning');
select tests.eq((select due_at from public.job_automation_log where job_id = tests.fx('jfu_night') and key = 'follow_up'),
                '2025-07-02 03:40Z'::timestamptz, 'the log still records when it fell due');
select tests.eq((select send_after from public.messages where job_id = tests.fx('jfu_b') and template_key = 'follow_up'),
                '2025-07-02 03:40Z'::timestamptz, 'shop B''s own timezone decides: 20:40 PDT goes out now');
select tests.eq((select count(*) from public.claim_queued_messages(500, '2025-07-02 03:41Z') c
                  where c.job_id = tests.fx('jfu_night') and c.template_key = 'follow_up'), 0::bigint,
                'not handed to the sender at 22:41 local');
select tests.eq((select count(*) from public.claim_queued_messages(500, '2025-07-02 14:59Z') c
                  where c.job_id = tests.fx('jfu_night')), 0::bigint, 'nor at 09:59');
select tests.eq((select count(*) from public.claim_queued_messages(500, '2025-07-02 15:00Z') c
                  where c.job_id = tests.fx('jfu_night') and c.template_key = 'follow_up'), 1::bigint,
                'sent at 10:00 local, not withdrawn as stale');
select tests.eq(public.enqueue_due_automations('2025-07-02 15:00Z'), 0, 'processed once');

-- a run before 08:00 local: the same morning at 10:00
select tests.as_superuser();
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Ona', '+12055550178', true) returning tests.fx_set('cust_fo', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_fo'), 'completed', '2025-06-10 10:00Z', '2025-06-10 11:30Z', '2025-06-10 12:15Z')
  returning tests.fx_set('jfu_early', id);   -- 07:15 CDT
-- closed at noon: sent at once
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Pax', '+12055550179', true) returning tests.fx_set('cust_fp', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_fp'), 'completed', '2025-06-10 15:00Z', '2025-06-10 16:30Z', '2025-06-10 17:00Z')
  returning tests.fx_set('jfu_noon', id);    -- 12:00 CDT
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-07-10 12:15Z'), 1, 'early follow_up queued');
select tests.eq((select send_after from public.messages where job_id = tests.fx('jfu_early') and template_key = 'follow_up'),
                '2025-07-10 15:00Z'::timestamptz, '07:15 local: held until 10:00 the same morning');
select tests.eq(public.enqueue_due_automations('2025-07-10 17:00Z'), 1, 'midday follow_up queued');
select tests.eq((select send_after from public.messages where job_id = tests.fx('jfu_noon') and template_key = 'follow_up'),
                '2025-07-10 17:00Z'::timestamptz, 'inside 08:00-21:00: sent at once');

-- DST: due the night the clocks fall back (23:30 CDT Nov 1): 10:00 CST
select tests.as_superuser();
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Rex', '+12055550180', true) returning tests.fx_set('cust_fr', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_fr'), 'completed', '2025-10-02 23:00Z', '2025-10-03 01:00Z', '2025-10-03 04:30Z')
  returning tests.fx_set('jfu_dst', id);
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-11-02 04:30Z'), 1, 'follow_up queued on the fall-back night');
select tests.eq((select send_after from public.messages where job_id = tests.fx('jfu_dst') and template_key = 'follow_up'),
                '2025-11-02 16:00Z'::timestamptz, 'held until 10:00 CST');

-- transactional automations are not held: a review request at 22:40 goes now
select tests.as_superuser();
update public.shops set review_url = 'https://reviews.example.test/shop-a' where id = tests.fx('shop_a');
update public.message_templates set enabled = true, offset_minutes = 120
 where shop_id = tests.fx('shop_a') and key = 'review_request' and channel = 'sms';
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'follow_up';
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Sol', '+12055550181', false) returning tests.fx_set('cust_fs', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_fs'), 'completed', '2025-08-01 22:00Z', '2025-08-02 01:00Z', '2025-08-02 01:40Z')
  returning tests.fx_set('jrr_night', id);   -- 20:40 CDT, review due 22:40 CDT
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-02 03:40Z'), 1, 'review request queued');
select tests.eq((select send_after from public.messages where job_id = tests.fx('jrr_night') and template_key = 'review_request'),
                '2025-08-02 03:40Z'::timestamptz, 'a transactional review request is not held');

-- ================================== service follow-up: an open request counts as booked
select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'review_request';
update public.service_followups set enabled = true where shop_id = tests.fx('shop_a');
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Rae', '+12055550182', true) returning tests.fx_set('cust_ro', id);
-- the next visit was requested (no time yet) while this one was under way
insert into public.jobs (shop_id, customer_id, status, created_at)
  values (tests.fx('shop_a'), tests.fx('cust_ro'), 'requested', '2025-05-01 15:00Z') returning tests.fx_set('jo_next', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jo_next'), tests.fx('svc_a'), 'Full Detail', 20000);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, created_at)
  values (tests.fx('shop_a'), tests.fx('cust_ro'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z',
          '2025-04-20 12:00Z') returning tests.fx_set('jo_done', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jo_done'), tests.fx('svc_a'), 'Full Detail', 20000);
-- an earlier completed visit with the service does not count as booked again
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_ro'), 'completed', '2025-03-01 14:00Z', '2025-03-01 16:00Z', '2025-03-01 16:00Z')
  returning tests.fx_set('jo_prev', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jo_prev'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 0,
                'an open request created before this job was completed: no follow-up');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('jo_done')), 0::bigint, '(nothing queued)');
-- each open status counts, whatever the dates (even a start before this job)
select tests.as_superuser();
update public.jobs set status = 'scheduled', scheduled_start = '2025-04-25 14:00Z', scheduled_end = '2025-04-25 16:00Z'
 where id = tests.fx('jo_next');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 0, 'scheduled (start before the completion): still booked');
select tests.as_superuser();
update public.jobs set status = 'in_progress' where id = tests.fx('jo_next');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 0, 'in progress: still booked');
-- the request is cancelled: the follow-up goes out
select tests.as_superuser();
update public.jobs set status = 'cancelled' where id = tests.fx('jo_next');
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 1, 'cancelled request: the follow-up is sent');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('jo_done') and template_key = 'service_followup'),
                1::bigint, '(for the completed job)');

-- an open job with a package that includes the service also counts
select tests.as_superuser();
insert into public.services (shop_id, name, duration_minutes, kind)
  values (tests.fx('shop_a'), 'Signature Package', 180, 'package') returning tests.fx_set('pkg_a', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('svc_a'));
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Kai', '+12055550183', true) returning tests.fx_set('cust_rk', id);
insert into public.jobs (shop_id, customer_id, status, created_at)
  values (tests.fx('shop_a'), tests.fx('cust_rk'), 'requested', '2025-04-30 12:00Z') returning tests.fx_set('jk_next', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jk_next'), tests.fx('pkg_a'), 'Signature Package', 30000);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_rk'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z')
  returning tests.fx_set('jk_done', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jk_done'), tests.fx('svc_a'), 'Full Detail', 20000);
-- another customer's open request with the service does not block this one
insert into public.customers (shop_id, first_name, phone, sms_opt_in)
  values (tests.fx('shop_a'), 'Lee', '+12055550184', true) returning tests.fx_set('cust_rl', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_rl'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z')
  returning tests.fx_set('jl_done', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('jl_done'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-31 15:00Z'), 1, 'only Lee (no open request of their own) is followed up');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('jk_done')), 0::bigint,
                'an open request for a package containing the service counts as booked');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('jl_done') and template_key = 'service_followup'),
                1::bigint, 'another customer''s request does not block');

-- comms_marketing_send_after
select tests.eq(public.comms_marketing_send_after('2025-06-01 12:59Z', 'America/Chicago'), '2025-06-01 15:00Z'::timestamptz,
                '07:59 local: the same morning at 10:00');
select tests.eq(public.comms_marketing_send_after('2025-06-01 13:00Z', 'America/Chicago'), '2025-06-01 13:00Z'::timestamptz,
                '08:00 local: now');
select tests.eq(public.comms_marketing_send_after('2025-06-02 01:59Z', 'America/Chicago'), '2025-06-02 01:59Z'::timestamptz,
                '20:59 local: now');
select tests.eq(public.comms_marketing_send_after('2025-06-02 02:00Z', 'America/Chicago'), '2025-06-02 15:00Z'::timestamptz,
                '21:00 local: the next morning at 10:00');
select tests.eq(public.comms_marketing_send_after('2025-03-09 07:30Z', 'America/Chicago'), '2025-03-09 15:00Z'::timestamptz,
                'the night of the spring-forward switch: 10:00 CDT');
select tests.eq(public.comms_marketing_send_after('2025-11-02 04:30Z', 'America/Chicago'), '2025-11-02 16:00Z'::timestamptz,
                'the night of the fall-back switch: 10:00 CST');

-- privileges
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.comms_marketing_send_after(now(), 'UTC')$$, '42501', 'the helper is internal');
select tests.throws($$select public.enqueue_service_followups(now())$$, '42501', 'the run is service-only');
