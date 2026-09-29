-- 30 comms: email unsubscribe credentials. The /u/<token> link and the
-- List-Unsubscribe headers use messages.unsubscribe_token — random per
-- marketing email, never the message id — and public_unsubscribe accepts
-- only that token on campaign / marketing-template email. Marketing
-- follow_up emails get a working {{unsubscribe_link}} and the unsubscribe
-- footer like campaign emails; transactional email gets neither. Shop
-- isolation and constraints.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));
-- shop A takes online bookings, so the follow-up's {{booking_page_link}} is live
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
-- a shop B customer with Alice's address (isolation checks)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_b'), 'Alice B', 'alice@example.com', true) returning tests.fx_set('cust_b_alice', id);

-- ============================================================ technicians cannot unsubscribe customers
-- Regression: public_unsubscribe accepted the id of ANY outbound email, and
-- enqueue_template_message returns the new message's id to technicians, so
-- a technician could queue a job_completed email and opt the customer out
-- of all shop email (transactional included) without signing in.
do $$
declare
  v_msg uuid;
begin
  perform tests.authenticate_as(tests.fx('u_tech_a'));
  v_msg := public.enqueue_template_message(tests.fx('job_a'), 'job_completed', null, 'email');
  perform tests.ok(v_msg is not null, 'technician queued the job_completed email');
  perform tests.fx_set('tech_mail', v_msg);
  perform tests.as_anon();
  perform tests.eq(public.public_unsubscribe(v_msg), false, 'the message id is not an unsubscribe credential');
  perform tests.as_superuser();
  perform tests.eq((select email_opted_out_at is null from public.customers where id = tests.fx('cust_a')), true,
                   'a technician must not be able to opt a customer out of all shop email');
  perform tests.eq((select count(*) from public.comms_suppressions where shop_id = tests.fx('shop_a')), 0::bigint,
                   'no email suppression recorded for the customer by the technician');
  perform tests.eq((select status::text from public.messages where id = v_msg), 'queued', 'the email is still queued');
end
$$;
select tests.ok((select unsubscribe_token is null and body not like '%/u/%' from public.messages where id = tests.fx('tech_mail')),
                'transactional email carries no unsubscribe token or link');
-- an authenticated technician calling it directly fares no better
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.public_unsubscribe(tests.fx('tech_mail')), false, 'not as a signed-in technician either');
select tests.eq(tests.row_count($$select 1 from public.messages where unsubscribe_token is not null$$), 0::bigint,
                'technicians see no message rows (and so no tokens)');

-- a transactional template that uses {{unsubscribe_link}} renders it empty and gets no token
select tests.as_superuser();
update public.message_templates set body = 'Confirmed. {{unsubscribe_link}}'
 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'email';
select tests.as_service();
select tests.fx_set('conf_mail', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed',
                                                                  'email', tests.fx('job_a'),
                                                                  '{"unsubscribe_link": "https://evil.example/u/x"}'));
select tests.ok((select body = 'Confirmed.' and unsubscribe_token is null from public.messages where id = tests.fx('conf_mail')),
                'transactional email: empty unsubscribe_link (not even from extra vars), no token');

-- ============================================================ marketing follow_up email carries a working link
-- Regression: follow_up is marketing (opt-in, SMS opt-out line) but its
-- email had no unsubscribe link, and {{unsubscribe_link}} rendered empty.
select tests.as_superuser();
update public.message_templates set enabled = true, body = 'Come back! Unsubscribe: {{unsubscribe_link}}'
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'email';
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'sms';
update public.customers set email_opt_in = true, sms_opt_in = true where id = tests.fx('cust_a');
select tests.as_service();
select tests.fx_set('fu_mail', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email',
                                                                tests.fx('job_a'), '{"unsubscribe_link": "https://evil.example/u/x"}'));
select tests.ok(tests.fx('fu_mail') is not null, 'queued');
select tests.fx_set('fu_token', (select unsubscribe_token from public.messages where id = tests.fx('fu_mail')));
select tests.ok(tests.fx('fu_token') is not null and tests.fx('fu_token') <> tests.fx('fu_mail'),
                'the marketing email has its own random unsubscribe token');
select tests.ok((select body like '%https://app.example.test/u/%' from public.messages
                  where customer_id = tests.fx('cust_a') and template_key = 'follow_up' and channel = 'email'),
                'marketing follow_up email carries a working unsubscribe link');
select tests.eq((select body from public.messages where id = tests.fx('fu_mail')),
                'Come back! Unsubscribe: https://app.example.test/u/' || tests.fx('fu_token')
                  || E'\n\nShop A · 100 Main St, Birmingham, AL 35203',
                'the placed link is used (no duplicate footer; extra vars cannot replace it); the postal address ends it (0119)');

-- the seeded wording (no placeholder) gets the unsubscribe footer
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.reset_message_template(id) from public.message_templates
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'email';
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'email';
select tests.as_service();
select tests.fx_set('fu_mail2', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email',
                                                                 tests.fx('job_a')));
select tests.ok((select body like E'Hi Alice,\n\nIt has been a while since your last visit to Shop A.%'
                        and body like E'%\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/'
                                      || unsubscribe_token::text || E'\n\nShop A · 100 Main St, Birmingham, AL 35203'
                   from public.messages where id = tests.fx('fu_mail2')),
                'default follow_up wording ends with the unsubscribe footer, then the postal address (0119)');
select tests.ok((select count(distinct unsubscribe_token) = 2 from public.messages
                  where id in (tests.fx('fu_mail'), tests.fx('fu_mail2'))), 'one token per email');
-- the SMS follow-up has the STOP line and no token
select tests.fx_set('fu_sms', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms',
                                                               tests.fx('job_a')));
select tests.ok((select unsubscribe_token is null and body like E'%\nReply STOP to opt out.' from public.messages
                  where id = tests.fx('fu_sms')), 'SMS follow-up: STOP line, no token');

-- preview shows where the link goes
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select body like E'%\n\nTo unsubscribe from these emails, visit: [unsubscribe link]%'
                   from public.preview_template_message(tests.fx('job_a'), 'follow_up', 'email')),
                'preview of a marketing email shows the unsubscribe footer');
select tests.ok((select body not like '%unsubscribe%'
                   from public.preview_template_message(tests.fx('job_a'), 'job_completed', 'email')),
                'transactional previews have none');

-- the sender gets the token for List-Unsubscribe headers (marketing email only)
select tests.as_service();
select tests.ok((select bool_and(case when c.id in (tests.fx('fu_mail'), tests.fx('fu_mail2'))
                                      then c.unsubscribe_token = m.unsubscribe_token and c.unsubscribe_token is not null
                                      else c.unsubscribe_token is null end)
                        and count(*) >= 4
                   from public.claim_queued_messages(50, now()) c
                   join public.messages m on m.id = c.id),
                'claim_queued_messages returns the unsubscribe token of marketing email only');

-- no app URL: a marketing email is never queued without a working link
select tests.as_superuser();
delete from public.platform_config where key = 'app_base_url';
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')),
                null::uuid, 'no app URL: the follow_up email is not queued');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms', tests.fx('job_a')),
                null::uuid, 'nor the default SMS follow-up: its booking page link would be blank');
select tests.as_superuser();
update public.message_templates set body = 'Hi {{customer_first_name}}, time for your next detail at {{shop_name}}? Call us.'
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'sms';
select tests.as_service();
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms', tests.fx('job_a'))
                  is not null, 'an SMS follow-up worded without links does not need it');
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;

-- the follow_up token unsubscribes (anonymously, shop-scoped)
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('fu_mail')), false, 'the follow-up''s message id is not a token');
select tests.eq(public.public_unsubscribe(tests.fx('fu_token')), true, 'the follow-up''s unsubscribe link works');
select tests.eq(public.public_unsubscribe(tests.fx('fu_token')), true, 'idempotent');
select tests.as_superuser();
select tests.ok((select email_opted_out_at is null and not email_opt_in from public.customers where id = tests.fx('cust_a')),
                'Alice unsubscribed from marketing (0126)');
select tests.eq((select array_agg(address) from public.comms_suppressions where shop_id = tests.fx('shop_a') and channel = 'email'),
                array['alice@example.com'], 'her address is suppressed in shop A');
select tests.ok((select email_opted_out_at is null and email_opt_in from public.customers where id = tests.fx('cust_b_alice')),
                'the same address in shop B is untouched');
select tests.eq((select count(*) from public.comms_suppressions where shop_id = tests.fx('shop_b')), 0::bigint,
                'no suppression in shop B');

-- a token only works on marketing email: a hand-set token on a transactional row is refused
update public.messages set unsubscribe_token = gen_random_uuid() where id = tests.fx('conf_mail')
  returning tests.fx_set('conf_token', unsubscribe_token);
update public.customers set email_opted_out_at = null where id = tests.fx('cust_a');
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('conf_token')), false,
                'transactional email is never an unsubscribe credential');

-- ============================================================ constraints & access
select tests.as_superuser();
select tests.throws($$update public.messages set unsubscribe_token = gen_random_uuid() where id = tests.fx('fu_sms')$$, '23514',
                    'SMS rows carry no unsubscribe token');
select tests.throws($$update public.messages set unsubscribe_token = tests.fx('fu_token') where id = tests.fx('conf_mail')$$, '23505',
                    'tokens are unique');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.messages set unsubscribe_token = gen_random_uuid() where id = tests.fx('conf_mail')$$, '42501',
                    'staff cannot set tokens');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.messages where unsubscribe_token = tests.fx('fu_token')$$), 0::bigint,
                'another shop cannot see shop A''s tokens');

-- ============================================================ comms_email_with_unsubscribe (pure)
select tests.eq(public.comms_email_with_unsubscribe('Hi', 'https://x.test/u/1'),
                E'Hi\n\nTo unsubscribe from these emails, visit: https://x.test/u/1', 'footer appended');
select tests.eq(public.comms_email_with_unsubscribe('Hi https://x.test/u/1 bye', 'https://x.test/u/1'),
                'Hi https://x.test/u/1 bye', 'a body that already places the link is kept');
select tests.eq(public.comms_email_with_unsubscribe('Hi', null), 'Hi', 'no link: unchanged');
select tests.eq(public.comms_email_with_unsubscribe(null, 'https://x.test/u/1'), null::text, 'null body');
select tests.ok((select char_length(b) = 50000 and b like E'%\n\nTo unsubscribe from these emails, visit: https://x.test/u/1'
                   from (select public.comms_email_with_unsubscribe(repeat('a', 50000), 'https://x.test/u/1') b) t),
                'a maximal body is cut to keep the footer within 50000 characters');
