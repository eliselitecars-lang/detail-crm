-- 30 comms: campaigns + campaign_recipients — audience filters (tags,
-- lifecycle, last visit in the shop time zone), consent (opt-in required,
-- opt-out wins, archived excluded, one message per address), launch exactly
-- once, compliance footers, scheduling, cancel, email unsubscribe, role
-- rules and cross-shop isolation.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));
-- shop A takes online bookings, so {{booking_page_link}} links to a live page
-- (it is blank while online booking is off: 30_link_availability.sql)
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.customers set sms_opt_in = true, email_opt_in = true, tags = '{vip}' where id = tests.fx('cust_a');
update public.customers set phone = '+13125550101', sms_opt_in = true where id = tests.fx('cust_b');
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in, email_opt_in, tags, lifecycle, sms_opted_out_at,
                              archived_at, created_at) values
  (tests.fx('shop_a'), 'Vera',  '+12055550111', 'vera@example.com', true, true, '{VIP,fleet}', 'lead', null, null, now()),
  (tests.fx('shop_a'), 'Otto',  '+12055550112', null, true, false, '{vip}', 'customer', now(), null, now()),
  (tests.fx('shop_a'), 'Nina',  '+12055550113', 'nina@example.com', false, false, '{vip}', 'customer', null, null, now()),
  (tests.fx('shop_a'), 'Arch',  '+12055550114', null, true, false, '{vip}', 'customer', null, now(), now()),
  (tests.fx('shop_a'), 'Dup',   '+12055550111', null, true, false, '{vip}', 'customer', null, null, '2020-01-01Z'),
  (tests.fx('shop_a'), 'Rita',  '+12055550116', null, true, false, '{retail}', 'customer', null, null, now());
select tests.fx_set('c_' || lower(first_name), id) from public.customers
 where shop_id = tests.fx('shop_a') and first_name in ('Vera', 'Otto', 'Nina', 'Arch', 'Dup', 'Rita');

-- visits: Alice's last completed job is 2025-03-10 22:00 local (03-11 03:00Z); Vera's 2025-06-10
update public.jobs set status = 'completed' where id = tests.fx('job_a');
update public.jobs set completed_at = '2025-03-11 03:00Z' where id = tests.fx('job_a');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('c_vera'), 'scheduled', '2025-06-10 15:00Z', '2025-06-10 16:00Z')
  returning tests.fx_set('job_vera', id);
update public.jobs set status = 'completed' where id = tests.fx('job_vera');
update public.jobs set completed_at = '2025-06-10 17:00Z' where id = tests.fx('job_vera');

-- ------------------------------------------------------------ audience
select tests.ok(public.campaign_audience_valid('{}'), 'empty audience');
select tests.ok(public.campaign_audience_valid('{"tags": ["vip"], "lifecycle": "lead", "last_visit_before": "2025-01-31", "last_visit_after": "2024-01-01"}'),
                'full audience');
select tests.ok(not public.campaign_audience_valid('{"foo": 1}'), 'unknown key');
select tests.ok(not public.campaign_audience_valid('{"tags": "vip"}'), 'tags must be an array');
select tests.ok(not public.campaign_audience_valid('{"tags": [1]}'), 'tags must be strings');
select tests.ok(not public.campaign_audience_valid('{"tags": [" "]}'), 'tags must not be blank');
select tests.ok(not public.campaign_audience_valid('{"lifecycle": "vip"}'), 'lifecycle must be lead or customer');
select tests.ok(not public.campaign_audience_valid('{"last_visit_before": "2025-02-30"}'), 'dates must be real');
select tests.ok(not public.campaign_audience_valid('{"last_visit_after": "yesterday"}'), 'dates must be YYYY-MM-DD');
select tests.ok(not public.campaign_audience_valid('[]'), 'audience must be an object');
select tests.ok(not public.campaign_audience_valid(null), 'audience must not be null');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{}'), 3,
                'sms: opted-in, not opted-out, not archived, one per number (Alice, Vera, Rita)');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 2, 'email: Alice and Vera');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"tags": ["vip"]}'), 2, 'tags any-of, case-insensitive');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"tags": ["fleet", "retail"]}'), 2, 'several tags');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"tags": []}'), 3, 'no tags = everyone');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"lifecycle": "lead"}'), 1, 'lifecycle');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"last_visit_before": "2025-04-01"}'), 1,
                'last visit before (Alice)');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"last_visit_after": "2025-04-01"}'), 1,
                'last visit on/after (Vera)');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms',
                                                 '{"last_visit_after": "2025-01-01", "last_visit_before": "2025-07-01"}'), 2,
                'visit window; customers without visits never match');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"last_visit_before": "2025-03-11"}'), 1,
                'last visit compares local dates (22:00 on March 10 local is before March 11)');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"last_visit_after": "2025-03-11"}'), 1,
                'and is not on/after March 11 (only Vera)');
select tests.throws($$select public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{"foo": 1}')$$, '22023', 'invalid filter');
select tests.throws($$select public.preview_campaign_audience(tests.fx('shop_b'), 'sms', '{}')$$, '42501', 'not for another shop');
select tests.throws($$select * from public.campaign_audience_customers(tests.fx('shop_a'), 'sms', '{}')$$, '42501',
                    'the resolver is internal');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{}')$$, '42501', 'technicians cannot');

-- ------------------------------------------------------------ campaign rows
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body, audience, status, launched_at, recipient_count)
  values (tests.fx('shop_a'), ' Spring ', 'sms',
          'Hi {{customer_first_name}}, 10% off washes at {{shop_name}} this week! Book: {{booking_page_link}}',
          '{"tags": ["vip"]}', 'launched', now(), 99)
  returning tests.fx_set('camp_sms', id);
select tests.ok((select status = 'draft' and launched_at is null and recipient_count = 0 and name = 'Spring'
                        and created_by = tests.fx('u_manager_a')
                   from public.campaigns where id = tests.fx('camp_sms')), 'new campaigns are drafts');
select tests.throws($$insert into public.campaigns (shop_id, name, channel, body, audience)
                      values (tests.fx('shop_a'), 'Bad', 'sms', 'x', '{"foo": 1}')$$, '23514', 'audience is validated');
select tests.throws($$insert into public.campaigns (shop_id, name, channel, subject, body)
                      values (tests.fx('shop_a'), 'Bad', 'sms', 'Subject', 'x')$$, '23514', 'texts have no subject');
select tests.throws($$insert into public.campaigns (shop_id, name, channel, body)
                      values (tests.fx('shop_b'), 'Bad', 'sms', 'x')$$, '42501', 'not for another shop');
select tests.throws($$update public.campaigns set status = 'launched' where id = tests.fx('camp_sms')$$, '42501',
                    'status changes go through the RPCs');
select tests.eq(tests.row_count($$update public.campaigns set name = 'Spring sale' where id = tests.fx('camp_sms')$$), 1::bigint,
                'drafts are editable');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.campaigns$$), 0::bigint, 'technicians see no campaigns');
select tests.throws($$insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'X', 'sms', 'x')$$,
                    '42501', 'technicians cannot create campaigns');
select tests.throws($$select public.launch_campaign(tests.fx('camp_sms'))$$, '42501', 'technicians cannot launch');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.launch_campaign(tests.fx('camp_sms'))$$, 'P0002', 'other shops cannot launch (not found)');
select tests.throws($$select public.cancel_campaign(tests.fx('camp_sms'))$$, 'P0002', 'or cancel');
select tests.eq(tests.row_count($$select 1 from public.campaigns where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'or read them');

-- ------------------------------------------------------------ launch (exactly once)
-- API callers launch on the server clock: a p_now they send is ignored.
-- Regression: launched_at / the send time could be forged (e.g. 2020).
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select status = 'launched' and launched_at = now() and recipient_count = 2
                        and launched_by = tests.fx('u_manager_a')
                   from public.launch_campaign(tests.fx('camp_sms'), '2020-01-01 00:00Z')),
                'launched to 2 recipients; API callers must not choose launched_at / send time');
select tests.eq((select array_agg(c.first_name order by c.first_name)
                   from public.campaign_recipients r join public.customers c on c.id = r.customer_id
                  where r.campaign_id = tests.fx('camp_sms')), array['Alice', 'Vera'], 'recipients materialized');
select tests.ok((select bool_and(m.id = r.message_id and m.to_address = r.to_address and m.campaign_id = tests.fx('camp_sms')
                                 and m.status = 'queued' and m.send_after = now()
                                 and m.template_key is null and m.sent_by = tests.fx('u_manager_a'))
                   from public.campaign_recipients r join public.messages m on m.id = r.message_id
                  where r.campaign_id = tests.fx('camp_sms')), 'one queued message per recipient');
select tests.eq((select m.body from public.messages m where m.campaign_id = tests.fx('camp_sms') and m.to_address = '+12055550101'),
                E'Hi Alice, 10% off washes at Shop A this week! Book: https://app.example.test/book/shop-a\nReply STOP to opt out.',
                'personalized, with the STOP footer');
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_sms'))$$, '55000', '%already launched%',
                         'a campaign launches once');
select tests.eq((select count(*) from public.messages where campaign_id = tests.fx('camp_sms')), 2::bigint, 'no duplicates');
select tests.throws($$update public.campaigns set name = 'x' where id = tests.fx('camp_sms')$$, '42501', 'launched campaigns are read-only');
select tests.throws($$delete from public.campaigns where id = tests.fx('camp_sms')$$, '42501', 'launched campaigns cannot be deleted');
select tests.eq(tests.row_count($$select 1 from public.campaign_recipients$$), 2::bigint, 'managers read recipients');
select tests.throws($$delete from public.campaign_recipients$$, '42501', 'recipients are not writable');

-- cancel: queued messages are withdrawn; in-flight ones stay
select tests.as_superuser();   -- Alice's copy is first in line (other queued mail was queued "now" too)
update public.messages set send_after = now() - interval '1 minute'
 where campaign_id = tests.fx('camp_sms') and to_address = '+12055550101';
select tests.as_service();
select tests.eq((select array_agg(c.campaign_id) from public.claim_queued_messages(1, now()) c), array[tests.fx('camp_sms')],
                'one message goes out');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select status = 'cancelled' and cancelled_at = now() from public.cancel_campaign(tests.fx('camp_sms'))),
                'campaign cancelled');
select tests.eq((select array_agg(status::text order by status) from public.messages where campaign_id = tests.fx('camp_sms')),
                array['sending', 'cancelled'], 'queued messages cancelled, the one being sent is untouched');
select tests.throws($$select public.cancel_campaign(tests.fx('camp_sms'))$$, '55000', 'already cancelled');
select tests.throws($$select public.launch_campaign(tests.fx('camp_sms'))$$, '55000', 'cancelled campaigns cannot launch');
-- a campaign that was launched stays the record of what was sent, even once
-- cancelled. Regression: deleting it unlinked its messages (campaign_id set
-- null), so an in-flight one lost the "campaign cancelled" and marketing
-- consent checks and was re-queued as an ordinary message on retry.
select tests.throws_like($$delete from public.campaigns where id = tests.fx('camp_sms')$$, '42501', '%kept as the record%',
                         'a cancelled campaign that was launched cannot be deleted');
select tests.eq((select count(*) from public.messages where campaign_id = tests.fx('camp_sms')), 2::bigint,
                'its messages keep their campaign');
select tests.as_service();
select tests.throws($$delete from public.campaigns where id = tests.fx('camp_sms')$$, '23503',
                    'the messages FK keeps it even for trusted callers');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Never sent', 'sms', 'Hello')
  returning tests.fx_set('camp_cx', id);
select public.cancel_campaign(tests.fx('camp_cx'));
select tests.eq(tests.row_count($$delete from public.campaigns where id = tests.fx('camp_cx')$$), 1::bigint,
                'a cancelled draft (never launched) can be deleted');
-- a body that already has an opt-out instruction gets no footer; long bodies stay within 1600
insert into public.campaigns (shop_id, name, channel, body, audience)
  values (tests.fx('shop_a'), 'Stop', 'sms', 'Big news from {{shop_name}}! Text STOP to unsubscribe.', '{"lifecycle": "lead"}')
  returning tests.fx_set('camp_stop', id);
select tests.lives($$select public.launch_campaign(tests.fx('camp_stop'))$$);
select tests.eq((select body from public.messages where campaign_id = tests.fx('camp_stop')),
                'Big news from Shop A! Text STOP to unsubscribe.', 'no duplicate opt-out footer');
-- Regression: any use of the word "stop" counted as opt-out language
insert into public.campaigns (shop_id, name, channel, body, audience)
  values (tests.fx('shop_a'), 'Spring', 'sms', 'Stop by this Saturday for our spring detail special!', '{"lifecycle": "lead"}')
  returning tests.fx_set('camp_stopby', id);
select tests.lives($$select public.launch_campaign(tests.fx('camp_stopby'))$$, 'launch');
select tests.eq((select body from public.messages where campaign_id = tests.fx('camp_stopby')),
                E'Stop by this Saturday for our spring detail special!\nReply STOP to opt out.',
                'every marketing SMS must tell the recipient how to opt out');
select tests.eq(public.comms_sms_with_optout('One-stop shop: we stop swirl marks. Non-stop deals!'),
                E'One-stop shop: we stop swirl marks. Non-stop deals!\nReply STOP to opt out.', '"stop" in other senses');
select tests.eq(public.comms_sms_with_optout('Deals! reply "stop" to end'), 'Deals! reply "stop" to end',
                'a quoted instruction counts');
select tests.eq(public.comms_sms_with_optout('Deals! Txt STOP to quit'), 'Deals! Txt STOP to quit', 'txt STOP counts');
select tests.eq(public.comms_sms_with_optout(repeat('b', 1590) || ' Reply STOP to opt out.'),
                left(repeat('b', 1590), 1577) || E'\nReply STOP to opt out.',
                'an instruction cut off by the 1600 limit does not count');
select tests.eq(public.comms_sms_with_optout('  '), null::text, 'blank stays blank');
insert into public.campaigns (shop_id, name, channel, body, audience, scheduled_at)
  values (tests.fx('shop_a'), 'Long', 'sms', repeat('a', 1600), '{"lifecycle": "lead"}', now() + interval '4 days')
  returning tests.fx_set('camp_long', id);
select tests.lives($$select public.launch_campaign(tests.fx('camp_long'))$$);
select tests.ok((select char_length(body) = 1600 and body like '%a' || E'\nReply STOP to opt out.'
                        and send_after = now() + interval '4 days'
                   from public.messages where campaign_id = tests.fx('camp_long')),
                'long bodies are trimmed to fit the footer; scheduled campaigns send at scheduled_at');

-- nobody matches: stays a draft
insert into public.campaigns (shop_id, name, channel, body, audience)
  values (tests.fx('shop_a'), 'Nobody', 'sms', 'Hello', '{"tags": ["nobody"]}') returning tests.fx_set('camp_none', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_none'))$$, '22023', '%no opted-in customers%',
                         'empty audience');
select tests.eq((select status::text from public.campaigns where id = tests.fx('camp_none')), 'draft', 'still a draft');
select tests.eq(tests.row_count($$delete from public.campaigns where id = tests.fx('camp_none')$$), 1::bigint, 'drafts can be deleted');

-- ------------------------------------------------------------ email campaigns + unsubscribe
insert into public.campaigns (shop_id, name, channel, body, audience)
  values (tests.fx('shop_a'), 'News', 'email', 'Hi {{customer_first_name}}, our new ceramic coating packages are here.', '{}')
  returning tests.fx_set('camp_mail', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_mail'))$$, '22023', '%subject%', 'email needs a subject');
update public.campaigns set subject = 'News from {{shop_name}}' where id = tests.fx('camp_mail');
select tests.as_superuser();
delete from public.platform_config where key = 'app_base_url';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_mail'))$$, '55000', '%unsubscribe%',
                         'email campaigns need unsubscribe links');
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.launch_campaign(tests.fx('camp_mail'))).recipient_count, 2, 'email launched');
select tests.fx_set('mail_alice', (select id from public.messages where campaign_id = tests.fx('camp_mail')
                                                                    and to_address = 'alice@example.com'));
select tests.fx_set('mail_alice_token', (select unsubscribe_token from public.messages where id = tests.fx('mail_alice')));
select tests.eq((select subject || ' | ' || body from public.messages where id = tests.fx('mail_alice')),
                'News from Shop A | Hi Alice, our new ceramic coating packages are here.' || E'\n\n'
                  || 'To unsubscribe from these emails, visit: https://app.example.test/u/' || tests.fx('mail_alice_token')
                  || E'\n\n' || 'Shop A · 100 Main St, Birmingham, AL 35203',
                'email with a per-message unsubscribe link and the shop''s postal address (0119)');
select tests.ok((select count(distinct unsubscribe_token) = 2 and bool_and(unsubscribe_token <> id)
                   from public.messages where campaign_id = tests.fx('camp_mail')),
                'each email has its own random unsubscribe token, distinct from its message id');
select tests.ok((select bool_and(unsubscribe_token is null) from public.messages where campaign_id = tests.fx('camp_stop')),
                'text messages carry no unsubscribe token');

select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('mail_alice')), false, 'a message id is not an unsubscribe token');
select tests.eq(public.public_unsubscribe(null), false, 'null token');
select tests.as_superuser();
select tests.ok((select email_opted_out_at is null and email_opt_in from public.customers where id = tests.fx('cust_a')),
                'still subscribed after the message-id attempt');
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('mail_alice_token')), true, 'anyone with the link can unsubscribe');
select tests.eq(public.public_unsubscribe(gen_random_uuid()), false, 'unknown token');
select tests.as_superuser();
select tests.ok((select email_opted_out_at = now() and not email_opt_in from public.customers where id = tests.fx('cust_a')),
                'Alice unsubscribed from email');
select tests.eq(public.public_unsubscribe((select id from public.messages where campaign_id = tests.fx('camp_stop'))), false,
                'text messages are not unsubscribe tokens');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 1, 'Alice is no longer in email audiences');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(10, now()) where id = tests.fx('mail_alice')),
                0::bigint, 'her queued email is withdrawn at send time');
select tests.eq((select status::text from public.messages where id = tests.fx('mail_alice')), 'cancelled', 'cancelled');

-- a shop without an SMS number cannot run text campaigns
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_b'), 'B', 'sms', 'Hi')
  returning tests.fx_set('camp_b', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_b'))$$, '55000', '%not set up%', 'SMS not configured');
select tests.eq(tests.row_count($$select 1 from public.campaign_recipients$$), 0::bigint, 'shop B sees none of A''s recipients');
select tests.eq(tests.row_count($$select 1 from public.campaigns$$), 1::bigint, 'shop B sees only its campaign');

-- composite FKs
select tests.as_superuser();
select tests.throws($$insert into public.campaign_recipients (shop_id, campaign_id, customer_id, to_address)
                      values (tests.fx('shop_a'), tests.fx('camp_b'), tests.fx('cust_a'), '+12055550101')$$, '23503',
                    'recipient cannot point at another shop''s campaign');
select tests.throws($$insert into public.campaign_recipients (shop_id, campaign_id, customer_id, to_address)
                      values (tests.fx('shop_b'), tests.fx('camp_b'), tests.fx('cust_a'), '+12055550101')$$, '23503',
                    'recipient cannot point at another shop''s customer');
select tests.throws($$insert into public.messages (shop_id, customer_id, campaign_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('camp_b'), 'outbound', 'sms', '+12055550101', 'x', 'queued')$$,
                    '23503', 'messages cannot point at another shop''s campaign');
select tests.throws($$insert into public.campaign_recipients (shop_id, campaign_id, customer_id, to_address)
                      values (tests.fx('shop_a'), tests.fx('camp_sms'), tests.fx('cust_a'), '+12055550101')$$, '23505',
                    'a customer is a recipient once per campaign');
