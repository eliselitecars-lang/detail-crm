-- 30 comms: links that are not available never go out blank.
-- Regressions:
--   * the automatic deposit receipt email said "View your invoice: " with
--     nothing after it (a deposit has no issued invoice yet; the same for a
--     payment on a draft invoice);
--   * {{booking_page_link}} always linked to /book/<slug>, even while the
--     shop's online booking is off (the page then has nothing to book), so
--     the default membership welcome and follow-up sent a dead "book here".
-- Now booking_page_link is blank while online booking is off, and automatic
-- messages leave out the lines whose link is blank (comms_render_parts);
-- quote_sent / invoice_sent / review_request are not sent without the link
-- they exist to deliver; campaigns using an unavailable link cannot launch.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set phone = '+12055550199' where id = tests.fx('shop_a');
update public.customers set email = 'bob@example.com', email_opt_in = true where id = tests.fx('cust_b');

-- ============================================================ pure helpers
select tests.eq(public.comms_unavailable_links(
                  '{{invoice_link}} {{ quote_link }} {{invoice_link}} {{review_link}} {{booking_link}} {{shop_name}}',
                  '{"invoice_link": null, "quote_link": "  ", "review_link": "https://r.test", "booking_link": 5}'),
                array['booking_link', 'invoice_link', 'quote_link'],
                'null, blank and non-string link values are unavailable; sorted and distinct');
select tests.eq(public.comms_unavailable_links('{{booking_page_link}} {{unsubscribe_link}} {{shop_name}}', '{}'),
                array['booking_page_link'], 'missing keys count; unsubscribe_link and other names never do');
select tests.eq(public.comms_unavailable_links('{{invoice_link}}', '[1]'), array['invoice_link'], 'non-object vars');
select tests.eq(public.comms_unavailable_links(null, '{}'), '{}'::text[], 'null text');

select tests.eq(public.comms_omit_unavailable_values(
                  E'Hi,\n\nThanks!\n\nView your invoice: {{invoice_link}}\n\n{{shop_name}}', '{"invoice_link": null}'),
                E'Hi,\n\nThanks!\n\n{{shop_name}}', 'the line and the blank line that set it apart are left out');
select tests.eq(public.comms_omit_unavailable_values(
                  E'Hi,\n\nView your invoice: {{invoice_link}}\n\n{{shop_name}}', '{"invoice_link": "https://x.test/i/1"}'),
                E'Hi,\n\nView your invoice: {{invoice_link}}\n\n{{shop_name}}', 'unchanged when the link is available');
select tests.eq(public.comms_omit_unavailable_values(E'A\nB {{quote_link}}\nC', '{}'), E'A\nC', 'single line breaks');
select tests.eq(public.comms_omit_unavailable_values(E'Book: {{booking_page_link}}\r\n\r\nBye', '{}'), E'Bye',
                'CRLF text, link on the first line');
select tests.eq(public.comms_omit_unavailable_values(E'Hi\n\nLink: {{quote_link}}', '{}'), E'Hi\n', 'link on the last line');
select tests.eq(public.comms_omit_unavailable_values('Book: {{booking_page_link}}', '{}'), '', 'only line');
select tests.eq(public.comms_omit_unavailable_values('Hi {{shop_name}}', '{}'), 'Hi {{shop_name}}', 'no link placeholders');
select tests.eq(public.comms_omit_unavailable_values(null, '{}'), null::text, 'null');

select tests.eq(public.comms_key_required_link('quote_sent'), 'quote_link', 'quote_sent needs its quote link');
select tests.eq(public.comms_key_required_link('invoice_sent'), 'invoice_link', 'invoice_sent needs its invoice link');
select tests.eq(public.comms_key_required_link('review_request'), 'review_link', 'review_request needs the review link');
select tests.eq(public.comms_key_required_link('payment_receipt'), null::text, 'a receipt stands on its own');

-- ============================================================ #2 deposit receipt (repro)
select to_regclass('public.integration_events') is not null as has_integration \gset
\if :has_integration
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5000, 0, 'deposit', 'card', null, tests.fx('job_a'),
                                    null, null, 'ch_dep1', null, 'visa', '4242');
select tests.as_superuser();
select tests.ok((select count(*) = 1 from public.messages where job_id = tests.fx('job_a') and template_key = 'payment_receipt'
                   and channel = 'email'), 'deposit receipt email queued');
select tests.ok((select body !~ 'View your invoice:[[:space:]]*(\n|$)' from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'payment_receipt' and channel = 'email'),
                'the receipt does not end a sentence with a blank invoice link');
select tests.eq((select body from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'payment_receipt' and channel = 'email'),
                E'Hi Alice,\n\nThank you! We received your payment of $50.00.\n\nRemaining balance: $150.00\n\nShop A',
                'the deposit receipt reads cleanly without the invoice line');
select tests.ok((select body like 'Thank you, Alice! Shop A received your payment of $50.00.%' from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'payment_receipt' and channel = 'sms'),
                'the SMS receipt (no link) is unchanged');

-- a payment on an issued invoice keeps its link
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select public.record_manual_payment(tests.fx('inv'), 2500, 'cash', 0, null);
select tests.as_superuser();
select tests.ok((select body like '%View your invoice: https://app.example.test/i/'
                                  || (select public_token::text from public.invoices where id = tests.fx('inv')) || '%'
                   from public.messages
                  where job_id = tests.fx('job_a') and template_key = 'payment_receipt' and channel = 'email'
                    and body like '%$25.00%'),
                'a receipt for an issued invoice links to it');
\endif

-- the same through the core directly (no integration layer needed)
select tests.as_service();
select tests.fx_set('rcpt', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'email',
                                                             null, '{"amount": "$10.00"}'));
select tests.as_superuser();
select tests.ok((select body not like '%View your invoice%' and body like '%payment of $10.00%'
                   from public.messages where id = tests.fx('rcpt')),
                'a customer-level receipt leaves out the invoice line');

-- ============================================================ #5 booking page link while online booking is off (repro)
select tests.ok(not (select enabled from public.booking_settings where shop_id = tests.fx('shop_a')), 'online booking is off');
-- (the public booking RPCs are in the integration range, 0042)
select to_regprocedure('public.public_booking_catalog(text)') is not null as has_public_booking \gset
\if :has_public_booking
select tests.as_anon();
select tests.throws($$select public.public_booking_catalog('shop-a')$$, '55000', 'the /book/shop-a page has nothing to book');
\endif
select tests.as_service();
select tests.eq(public.comms_customer_vars(tests.fx('shop_a'), tests.fx('cust_a')) -> 'booking_page_link', 'null'::jsonb,
                'booking_page_link is blank while online booking is off');
select tests.eq(public.comms_job_vars(tests.fx('job_a')) -> 'booking_page_link', 'null'::jsonb, 'for job messages too');
select tests.fx_set('m', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'email'));
select tests.ok((select body not like '%/book/shop-a%' from public.messages where id = tests.fx('m')),
                'customers are not sent a "book here" link to a booking page that is turned off');
select tests.eq((select body from public.messages where id = tests.fx('m')),
                E'Hi Alice,\n\nWelcome to your Shop A membership! We are glad to have you.\n\nManage or cancel your membership any time in your account: https://app.example.test/portal?shop=shop-a\n\nQuestions? Call us at (205) 555-0199.\n\nShop A',
                'the welcome still goes out, without the booking line');

-- the follow-up: the SMS is nothing but the booking call, so it is not sent; the email goes without it
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
update public.customers set sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms', tests.fx('job_a')),
                null::uuid, 'no follow-up text whose only point is a dead booking link');
select tests.fx_set('fu', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')));
select tests.ok((select body not like '%/book/%' and body not like '%Book your next appointment here%'
                        and body like '%/u/' || unsubscribe_token::text || E'\n\nShop A · %'
                   from public.messages where id = tests.fx('fu')),
                'the follow-up email leaves out the booking line and keeps its unsubscribe link');

-- once online booking is on, the link is live and included
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.eq(public.comms_customer_vars(tests.fx('shop_a'), null) ->> 'booking_page_link', 'https://app.example.test/book/shop-a',
                'booking_page_link once online booking is on');
select tests.fx_set('m2', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'email'));
select tests.ok((select body like '%book here: https://app.example.test/book/shop-a%' from public.messages where id = tests.fx('m2')),
                'the welcome carries the live booking link');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms', tests.fx('job_a'))
                  is not null, 'and the follow-up text is sent again');
-- cross-shop: shop B's booking is still off, so B's customers never get A's (or a dead) link
select tests.eq(public.comms_customer_vars(tests.fx('shop_b'), tests.fx('cust_b')) -> 'booking_page_link', 'null'::jsonb,
                'shop B''s setting is its own');
select tests.fx_set('mb', public.enqueue_customer_template(tests.fx('shop_b'), tests.fx('cust_b'), 'membership_welcome', 'email'));
select tests.ok((select body not like '%/book/%' from public.messages where id = tests.fx('mb')), 'shop B''s welcome has no link');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_a');

-- ============================================================ messages that exist to deliver a link
select tests.as_service();
select tests.eq(public.comms_job_vars(tests.fx('job_a2')) -> 'quote_link', 'null'::jsonb, 'job_a2 has no sent quote');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a2'), 'quote_sent', 'email', tests.fx('job_a2')),
                null::uuid, 'no quote email without a quote to link to');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a2'), 'invoice_sent', 'email', tests.fx('job_a2')),
                null::uuid, 'no invoice email without an issued invoice');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_sent', 'email', tests.fx('job_a'),
                                                 '{"quote_link": "https://app.example.test/q/1"}') is not null,
                true, 'with the link it is sent');
select tests.eq((select review_url from public.shops where id = tests.fx('shop_a')), null::text, 'shop A has no review URL');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'review_request', 'email', tests.fx('job_a')),
                null::uuid, 'no review request without a review link');
select tests.as_superuser();
update public.shops set review_url = 'https://reviews.example.test/shop-a' where id = tests.fx('shop_a');
select tests.as_service();
select tests.fx_set('rv', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'review_request', 'email', tests.fx('job_a')));
select tests.ok((select body like '%a review: https://reviews.example.test/shop-a%' from public.messages where id = tests.fx('rv')),
                'with a review URL it is sent with the link');
-- a shop that words its quote message without the link is its own choice
select tests.as_superuser();
update public.message_templates set body = 'Your quote is ready; we will call you to go over it.'
 where shop_id = tests.fx('shop_a') and key = 'quote_sent' and channel = 'sms';
select tests.as_service();
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a2'), 'quote_sent', 'sms', tests.fx('job_a2'))
                  is null, 'Aaron has no phone');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_sent', 'sms', tests.fx('job_a'))
                  is not null, 'a quote text worded without the link is sent');

-- a rescheduled appointment message is re-rendered by the same rules
select tests.as_superuser();
update public.message_templates set body = E'See you {{job_date}}.\nBook more: {{booking_page_link}}'
 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'sms';
select tests.as_service();
select tests.fx_set('bc', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'sms',
                                                           tests.fx('job_a')));
select tests.eq((select body from public.messages where id = tests.fx('bc')), 'See you Monday, June 2.', 'queued without the dead link');
select tests.as_superuser();
update public.jobs set scheduled_start = '2025-06-03 15:00+00', scheduled_end = '2025-06-03 17:00+00' where id = tests.fx('job_a');
select tests.eq((select body from public.messages where id = tests.fx('bc')), 'See you Tuesday, June 3.',
                're-rendered for the new date, still without it');

-- ============================================================ campaigns refuse unavailable links
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Spring', 'sms', 'Spring special at {{shop_name}}! Book: {{booking_page_link}}')
  returning tests.fx_set('c_book', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('c_book'))$$, '55000', '%{{booking_page_link}}%',
                         'a campaign linking to a booking page that is off cannot launch');
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Quotes', 'email', 'Hi', 'See {{quote_link}} and {{invoice_link}}') returning tests.fx_set('c_job', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('c_job'))$$, '55000', '%{{invoice_link}}, {{quote_link}}%',
                         'job links are never available to a campaign');
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Subject link', 'email', 'Book {{booking_page_link}}', 'Hi') returning tests.fx_set('c_subj', id);
select tests.throws($$select public.launch_campaign(tests.fx('c_subj'))$$, '55000', 'the email subject is checked too');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where campaign_id in (tests.fx('c_book'), tests.fx('c_job'), tests.fx('c_subj'))),
                0::bigint, 'nothing was queued');
select tests.eq((select array_agg(distinct status::text) from public.campaigns where id in (tests.fx('c_book'), tests.fx('c_job'))),
                array['draft'], 'the campaigns stay drafts');
-- review_link is the shop's URL: available once set
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Reviews', 'sms', 'Loved your detail? Review us: {{review_link}}') returning tests.fx_set('c_rev', id);
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.eq((select status::text from public.launch_campaign(tests.fx('c_rev'))), 'launched', 'a review link campaign launches');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select status::text from public.launch_campaign(tests.fx('c_book'))), 'launched',
                'the booking campaign launches once online booking is on');
select tests.as_superuser();
select tests.ok((select bool_and(body like '%Book: https://app.example.test/book/shop-a%') from public.messages
                  where campaign_id = tests.fx('c_book')), 'with the live link');
-- shop B's manager cannot launch shop A's campaigns (isolation)
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.launch_campaign(tests.fx('c_job'))$$, 'P0002', 'another shop''s campaign is not found');
