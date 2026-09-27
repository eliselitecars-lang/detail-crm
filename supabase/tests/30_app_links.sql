-- 30 comms: app_base_url — customer links in messages. Regression: nothing
-- wrote platform_config.app_base_url, so on a fresh deployment every
-- booking / quote / invoice link went out blank ("Manage your booking:"),
-- follow-up emails were silently dropped and email campaigns refused.
-- Now: set_app_base_url (called by supabase/setup/cron.sql) stores it; while
-- it is unset no link-bearing message is queued (staff get a clear 55000),
-- due automations refuse to run instead of logging jobs as skipped, and
-- campaigns whose wording has a link cannot launch.
\ir fixtures/two_shops.psql
-- shop A takes online bookings, so {{booking_page_link}} links to a live page
-- (it is blank while online booking is off: 30_link_availability.sql)
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.customers set sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';

-- ------------------------------------------------------------ helper
select tests.ok(public.comms_uses_app_links('Manage your booking: {{booking_link}}'), 'booking link');
select tests.ok(public.comms_uses_app_links('Pay: {{ invoice_link }}'), 'spaces inside the braces');
select tests.ok(public.comms_uses_app_links('{{quote_link}}') and public.comms_uses_app_links('{{booking_page_link}}')
                and public.comms_uses_app_links('{{unsubscribe_link}}'), 'quote, booking page and unsubscribe links');
select tests.ok(not public.comms_uses_app_links('Review us: {{review_link}}'), 'the review link is the shop''s own URL');
select tests.ok(not public.comms_uses_app_links('{{Booking_link}} {{booking_links}} {booking_link}'),
                'only exact placeholder names count');
select tests.ok(not public.comms_uses_app_links(null), 'null text');

-- ------------------------------------------------------------ fresh deployment: nothing configured
-- a fresh deployment has no app_base_url (reset explicitly: the database may be shared)
delete from public.platform_config where key = 'app_base_url';
select tests.eq((select count(*) from public.platform_config where key = 'app_base_url'), 0::bigint,
                'fresh deployment: no app_base_url');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', null, 'sms')$$,
                         '55000', '%customer links are not set up%',
                         'staff are told links are not set up instead of sending a blank link');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'follow_up', null, 'email')$$, '55000',
                    'a marketing email without an unsubscribe link is refused too');
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', null, 'sms') is not null,
                'a template without links is still sent');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_a') and template_key <> 'on_the_way'),
                0::bigint, 'nothing with a blank link was queued');

-- internal paths (integration triggers, automations) queue nothing either
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'email',
                                                 tests.fx('job_a')),
                null::uuid, 'the internal core does not queue a message with a blank link');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_completed', 'sms',
                                                 tests.fx('job_a')) is not null,
                true, 'but queues wording without links');
select tests.as_superuser();
update public.message_templates set subject = 'Your booking {{booking_link}}',
                                    body = 'Hi {{customer_first_name}}, see you soon.'
 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'email';
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'email',
                                                 tests.fx('job_a')),
                null::uuid, 'a link in an email subject counts');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.reset_message_template(id) from public.message_templates
 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'email';

select tests.as_service();
select tests.throws_like($$select public.enqueue_due_automations('2025-06-01 15:00Z')$$, '55000', '%app_base_url%',
                         'automations refuse to run while links cannot be built');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_automation_log where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))), 0::bigint,
                'nothing is logged as skipped, so the run catches up once configured');

-- campaigns
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Spring', 'sms', 'Spring detail special at {{shop_name}}! Book: {{booking_page_link}}')
  returning tests.fx_set('camp_link', id);
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Plain', 'sms', 'Spring detail special at {{shop_name}}! Call us to book.')
  returning tests.fx_set('camp_plain', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_link'))$$, '55000', '%customer links are not set up%',
                         'an SMS campaign with a link cannot launch without the app URL');
select tests.eq((select status::text from public.launch_campaign(tests.fx('camp_plain'))), 'launched',
                'one without links can');

-- ------------------------------------------------------------ set_app_base_url (the documented setup step)
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.set_app_base_url('https://evil.example.test')$$, '42501', 'owners cannot set it');
select tests.as_anon();
select tests.throws($$select public.set_app_base_url('https://evil.example.test')$$, '42501', 'anon cannot set it');
select tests.as_service();
select tests.throws($$select public.set_app_base_url(null)$$, '22023', 'a value is required');
select tests.throws($$select public.set_app_base_url('app.example.test')$$, '22023', 'it must be an http(s) origin');
select tests.throws($$select public.set_app_base_url('https://app.example.test/?x=1')$$, '22023', 'no query string');
select tests.eq(public.set_app_base_url(' https://app.example.test/ '), 'https://app.example.test',
                'service_role sets it (trimmed, no trailing slash)');
select tests.eq(public.set_app_base_url('https://app.example.test'), 'https://app.example.test', 're-running is idempotent');
select tests.as_superuser();
select tests.eq((select count(*) from public.platform_config where key = 'app_base_url'), 1::bigint, 'one row');
select tests.eq(public.app_url('/book/shop-a'), 'https://app.example.test/book/shop-a', 'links are built from it');

-- ------------------------------------------------------------ configured: the repro now carries its link
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('msg', public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', null, 'sms'));
select tests.as_superuser();
select tests.ok((select body from public.messages where id = tests.fx('msg'))
                  like '%Manage your booking: https://app.example.test/booking/%',
                'the booking_confirmed text carries the customer''s booking link');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-01 15:00Z'), 2, 'the reminder run catches up (sms + email)');
select tests.ok((select bool_and(body like '%https://app.example.test/booking/%') from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'appointment_reminder'),
                'with the link');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select status::text from public.launch_campaign(tests.fx('camp_link'))), 'launched',
                'the linked campaign launches once configured');
select tests.as_superuser();
select tests.ok((select bool_and(m.body like '%https://app.example.test/book/shop-a%')
                   from public.messages m where m.campaign_id = tests.fx('camp_link')),
                'with the booking page link');

-- another shop's messages use the same platform origin, never shop A's data
select tests.ok(public.comms_job_vars(tests.fx('job_b')) ->> 'booking_link'
                  = 'https://app.example.test/booking/' || (select public_token from public.jobs where id = tests.fx('job_b')),
                'shop B links point at shop B''s own job');
