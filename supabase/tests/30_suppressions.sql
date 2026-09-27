-- 30 comms: opt-outs belong to the ADDRESS (comms_suppressions). An email
-- unsubscribe or an SMS STOP follows the number / inbox across duplicate,
-- new, re-addressed and re-created customers on every outbound path
-- (campaign audiences, queue_message, templates, the sender's claim);
-- START / service_role clear it for the whole address; staff can record but
-- never clear or write suppressions; shop isolation and constraints.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
update public.customers set email_opt_in = true where id = tests.fx('cust_a');

-- ============================================================ email unsubscribe follows the address
-- Regression: two customers share an email; campaign 1 reaches the newer one,
-- who unsubscribes; campaign 2 must not fall back to the older record.
insert into public.customers (shop_id, first_name, email, email_opt_in, created_at)
  values (tests.fx('shop_a'), 'Old', 'dup@example.com', true, '2025-01-01Z') returning tests.fx_set('c_old', id);
insert into public.customers (shop_id, first_name, email, email_opt_in, created_at)
  values (tests.fx('shop_a'), 'New', 'Dup@Example.com', true, '2025-02-01Z') returning tests.fx_set('c_new', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 2,
                'one recipient per address (case-insensitive), plus Alice');
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Spring', 'email', 'Spring sale', 'Hi {{customer_first_name}}') returning tests.fx_set('camp1', id);
select public.launch_campaign(tests.fx('camp1'));
select tests.reset();
select tests.fx_set('msg1', (select id from public.messages where campaign_id = tests.fx('camp1')
                                                              and customer_id in (tests.fx('c_old'), tests.fx('c_new'))));
select tests.eq((select customer_id from public.messages where id = tests.fx('msg1')), tests.fx('c_new'),
                'the most recently created customer of the address is the recipient');

select tests.fx_set('msg1_token', (select unsubscribe_token from public.messages where id = tests.fx('msg1')));
select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('msg1_token')), 'unsubscribe link accepted');
select tests.as_superuser();
select tests.ok((select bool_and(email_opted_out_at = now() and not email_opt_in) and count(*) = 2
                   from public.customers where id in (tests.fx('c_old'), tests.fx('c_new'))),
                'every customer of the shop with the address is opted out');
select tests.eq((select array_agg(address) from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'email'), array['dup@example.com'],
                'the address is suppressed (normalized to lower case)');
select tests.ok((select status = 'queued' from public.messages where campaign_id = tests.fx('camp1')
                                                               and customer_id = tests.fx('cust_a')),
                'other recipients are untouched');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Summer', 'email', 'Summer sale', 'Hi {{customer_first_name}}') returning tests.fx_set('camp2', id);
select tests.eq((public.launch_campaign(tests.fx('camp2'))).recipient_count, 1, 'second campaign reaches Alice only');
select tests.reset();
select tests.eq((select count(*) from public.messages where campaign_id = tests.fx('camp2') and lower(to_address) = 'dup@example.com'),
                0::bigint, 'an unsubscribed email address must not receive the next campaign');

-- a duplicate created later (any case) starts out unsubscribed and is never an audience member
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Third', 'DUP@example.COM', true) returning tests.fx_set('c_third', id);
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('c_third')),
                'a new customer with a suppressed email is opted out on creation');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 1, 'audience still excludes the address');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('c_old'), 'email', 'Hi', 'Hello')$$,
                         '55000', '%unsubscribed%', 'free-form email to the address is refused');

-- the claim checks the address itself: a queued email to a suppressed address
-- whose customer row is not stamped (e.g. the email was edited after queueing)
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, subject, body, status, send_after)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'outbound', 'email', 'dup@EXAMPLE.com', 'Hi', 'Hello', 'queued', '2025-06-01Z')
  returning tests.fx_set('m_addr', id);
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, '2025-06-01 00:01Z') c where c.id = tests.fx('m_addr')),
                0::bigint, 'the sender is never handed email to a suppressed address');
select tests.ok((select status = 'cancelled' and error like '%opted out%' from public.messages where id = tests.fx('m_addr')),
                'cancelled as opted out');

-- service_role re-subscribes the address: cleared for every customer with it
update public.customers set email_opted_out_at = null where id = tests.fx('c_old');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and channel = 'email'),
                'clearing an email opt-out (service_role) removes the suppression');
select tests.ok((select bool_and(email_opted_out_at is null and not email_opt_in) from public.customers
                  where id in (tests.fx('c_old'), tests.fx('c_new'), tests.fx('c_third'))),
                'every customer of the address is cleared; marketing opt-in needs fresh consent');

-- ============================================================ SMS STOP follows the number
-- Regression: STOP from a number no customer has yet; a spouse / duplicate
-- record created later with that number must not be texted.
select tests.as_service();
select tests.eq((select opt_action from public.record_inbound_sms('+12055550100', '+12055550144', 'STOP', 'SMstop1')), 'opt_out',
                'STOP from an unknown number');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and channel = 'sms'
                                                                  and address = '+12055550144'),
                'the number is suppressed although no customer has it');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, phone, sms_opt_in) values (tests.fx('shop_a'), 'Spouse', '+12055550144', true)
  returning tests.fx_set('c_sp', id);
select tests.ok((select sms_opted_out_at is not null and not sms_opt_in from public.customers where id = tests.fx('c_sp')),
                'a customer created with a number that texted STOP starts out opted out (opt-in ignored)');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('c_sp'), '2099-07-01 15:00Z', '2099-07-01 16:00Z') returning tests.fx_set('j_sp', id);
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('c_sp'), 'sms', null, 'Promo!')$$,
                    '55000', 'a number that texted STOP must not be texted again until START');
select tests.eq(public.enqueue_template_message(tests.fx('j_sp'), 'booking_confirmed'), null::uuid,
                'templates to the number are not queued');
select tests.throws($$update public.customers set sms_opted_out_at = null where id = tests.fx('c_sp')$$, '42501',
                    'staff cannot clear the opt-out');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{}'), 0, 'no SMS audience for the number');

-- the claim checks the number itself (queued before the customer was re-addressed)
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, send_after)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'outbound', 'sms', '+12055550144', 'See you soon', 'queued', '2025-06-01Z')
  returning tests.fx_set('m_sms', id);
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, now() + interval '1 minute') c
                  where c.to_address = '+12055550144'),
                0::bigint, 'the sender must never be handed an SMS to a number that texted STOP');
select tests.ok((select status = 'cancelled' and error like '%opted out%' from public.messages where id = tests.fx('m_sms')),
                'cancelled as opted out');

-- deleting and re-creating a customer does not clear the opt-out; neither
-- does moving another customer onto the number
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Temp', '+12055550144')
  returning tests.fx_set('c_tmp', id);
delete from public.customers where id = tests.fx('c_tmp');
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Temp again', '+12055550144')
  returning tests.fx_set('c_tmp2', id);
select tests.ok((select sms_opted_out_at is not null from public.customers where id = tests.fx('c_tmp2')),
                'a deleted-and-recreated customer is still opted out');
update public.customers set phone = '+12055550144', sms_opt_in = true where id = tests.fx('cust_a3');
select tests.ok((select sms_opted_out_at is not null and not sms_opt_in from public.customers where id = tests.fx('cust_a3')),
                'a customer re-addressed to the number is opted out');

-- other shops are unaffected
select tests.as_superuser();
insert into public.customers (shop_id, first_name, phone, sms_opt_in) values (tests.fx('shop_b'), 'Elsewhere', '+12055550144', true)
  returning tests.fx_set('c_b', id);
select tests.ok((select sms_opted_out_at is null and sms_opt_in from public.customers where id = tests.fx('c_b')),
                'the same number in another shop is not suppressed');

-- START clears the number for every customer with it (marketing opt-in stays off)
select tests.as_service();
select tests.eq((select opt_action from public.record_inbound_sms('+12055550100', '+12055550144', 'START', 'SMstart1')), 'opt_in',
                'START');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = '+12055550144'),
                'START removes the suppression');
select tests.ok((select bool_and(sms_opted_out_at is null and not sms_opt_in) and count(*) = 3 from public.customers
                  where shop_id = tests.fx('shop_a') and phone = '+12055550144'),
                'every customer with the number can be texted again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('c_sp'), 'sms', null, 'Welcome back')$$,
                   'texting works again after START');

-- a staff-recorded opt-out suppresses the number for duplicates too and
-- withdraws texts still queued to it
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Dup1', '+12055550133')
  returning tests.fx_set('c_d1', id);
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Dup2', '+12055550133')
  returning tests.fx_set('c_d2', id);
select tests.fx_set('m_d2', (public.queue_message(tests.fx('shop_a'), tests.fx('c_d2'), 'sms', null, 'Hello')).id);
update public.customers set sms_opted_out_at = '2000-01-01Z' where id = tests.fx('c_d1');
select tests.ok((select sms_opted_out_at = now() from public.customers where id = tests.fx('c_d1')),
                'staff opt-outs are stamped with the server time');
select tests.ok((select sms_opted_out_at = now() from public.customers where id = tests.fx('c_d2')),
                'the duplicate record is opted out as well');
select tests.ok((select status = 'cancelled' and error like '%opted out%' from public.messages where id = tests.fx('m_d2')),
                'texts queued to the number are withdrawn');

-- ============================================================ access, isolation, constraints
select tests.eq(tests.row_count($$select 1 from public.comms_suppressions$$), 1::bigint, 'managers read their shop''s suppressions');
select tests.throws($$insert into public.comms_suppressions (shop_id, channel, address)
                      values (tests.fx('shop_a'), 'sms', '+12055550199')$$, '42501', 'staff cannot add suppressions directly');
select tests.throws($$delete from public.comms_suppressions$$, '42501', 'staff cannot delete suppressions');
select tests.throws($$update public.comms_suppressions set opted_out_at = now()$$, '42501', 'staff cannot edit suppressions');
select tests.throws($$select public.comms_suppress(tests.fx('shop_a'), 'sms', '+12055550199')$$, '42501',
                    'staff cannot call the internal suppress helper');
select tests.throws($$select public.comms_unsuppress(tests.fx('shop_a'), 'sms', '+12055550133')$$, '42501',
                    'staff cannot call the internal unsuppress helper');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.comms_suppressions$$), 0::bigint, 'technicians see no suppressions');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.comms_suppressions$$), 0::bigint, 'another shop sees none of them');
select tests.eq(tests.row_count($$select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'not even by shop id');
select tests.as_anon();
select tests.throws($$select 1 from public.comms_suppressions$$, '42501', 'anon has no access');

select tests.as_service();
select tests.ok(public.comms_suppress(tests.fx('shop_b'), 'email', ' Bob@Example.com '), 'service_role suppresses an address');
select tests.ok(not public.comms_suppress(tests.fx('shop_b'), 'email', 'bob@example.com'), 'suppressing twice is a no-op');
select tests.throws($$select public.comms_suppress(tests.fx('shop_b'), 'sms', '555-0100')$$, '22023', 'invalid number');
select tests.throws($$select public.comms_suppress(tests.fx('shop_b'), 'email', '  ')$$, '22023', 'blank address');
select tests.ok(public.comms_unsuppress(tests.fx('shop_b'), 'email', 'BOB@example.com'), 'service_role clears it');
select tests.ok(not public.comms_unsuppress(tests.fx('shop_b'), 'email', 'bob@example.com'), 'clearing twice is a no-op');
select tests.as_superuser();
select tests.throws($$insert into public.comms_suppressions (shop_id, channel, address) values (tests.fx('shop_a'), 'email', 'Up@Example.com')$$,
                    '23514', 'email addresses are stored lower-cased');
select tests.throws($$insert into public.comms_suppressions (shop_id, channel, address) values (tests.fx('shop_a'), 'sms', 'hello')$$,
                    '23514', 'SMS addresses are E.164');
select tests.throws($$insert into public.comms_suppressions (shop_id, channel, address) values (tests.fx('shop_a'), 'sms', '+12055550133')$$,
                    '23505', 'one suppression per shop, channel and address');
