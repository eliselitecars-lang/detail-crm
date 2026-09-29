-- 30 comms: formatting helpers, template variables (shop time zone, money,
-- links from platform_config), customer opt-out guard, queue_message,
-- enqueue_template_message / enqueue_customer_template / preview, the
-- messages table's role rules and cross-shop isolation.
\ir fixtures/two_shops.psql
-- shop A takes online bookings, so {{booking_page_link}} links to a live page
-- (it is blank while online booking is off: 30_link_availability.sql)
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

-- ------------------------------------------------------------ formatting
select tests.eq(public.format_money(0, 'usd'), '$0.00', 'zero');
select tests.eq(public.format_money(5, 'usd'), '$0.05', 'cents');
select tests.eq(public.format_money(123456, 'usd'), '$1,234.56', 'thousands separator');
select tests.eq(public.format_money(100000000, 'usd'), '$1,000,000.00', 'millions');
select tests.eq(public.format_money(-500, 'usd'), '-$5.00', 'negative');
select tests.eq(public.format_money(1234, 'eur'), '€12.34', 'euro');
select tests.eq(public.format_money(1234, 'GBP'), '£12.34', 'currency code is case-insensitive');
select tests.eq(public.format_money(1500, 'jpy'), '¥1,500', 'zero-decimal currency');
select tests.eq(public.format_money(1200, 'chf'), 'CHF 12.00', 'other currencies use the ISO code');
select tests.eq(public.format_money(null, 'usd'), null::text, 'null amount');
select tests.eq(public.format_phone('+12055550101'), '(205) 555-0101', 'NANP display');
select tests.eq(public.format_phone('+442071234567'), '+442071234567', 'other numbers unchanged');
select tests.eq(public.format_phone(null), null::text, 'null phone');

-- ------------------------------------------------------------ platform_config
select tests.eq(public.app_url('/x'), null::text, 'no app_base_url configured: no links');
select tests.throws($$insert into public.platform_config (key, value) values ('app_base_url', 'not a url')$$, '23514',
                    'app_base_url must be an http(s) URL');
select tests.as_service();
select tests.lives($$insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test/')$$,
                   'service_role writes platform config');
select tests.as_superuser();
select tests.eq(public.app_url('/booking/abc'), 'https://app.example.test/booking/abc', 'trailing slash is trimmed');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.platform_config$$, '42501', 'owners cannot read platform config');
select tests.throws($$update public.platform_config set value = 'https://evil.test'$$, '42501', 'or write it');
select tests.throws($$select public.app_url('/x')$$, '42501', 'app_url is internal');
select tests.as_superuser();

-- shop A setup
-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100', phone = '+12055550199', review_url = 'https://reviews.example.test/shop-a'
 where id = tests.fx('shop_a');

-- ------------------------------------------------------------ template variables
select tests.fx_set('tok_a', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.eq(public.comms_job_vars(tests.fx('job_a')),
                jsonb_build_object(
                  'customer_first_name', 'Alice', 'customer_name', 'Alice Anders', 'shop_name', 'Shop A',
                  'shop_phone', '(205) 555-0199', 'review_link', 'https://reviews.example.test/shop-a',
                  'booking_page_link', 'https://app.example.test/book/shop-a',
                  'job_number', (select number::text from public.jobs where id = tests.fx('job_a')),
                  'job_date', 'Monday, June 2', 'job_time', '10:00 AM', 'vehicle', '2021 Honda Civic',
                  'services', 'Full Detail',
                  'booking_link', 'https://app.example.test/booking/' || tests.fx('tok_a'),
                  'quote_link', null, 'invoice_link', null, 'amount', '$200.00', 'balance', '$200.00',
                  'rebook_link', 'https://app.example.test/book/shop-a',
                  'portal_link', 'https://app.example.test/portal?shop=shop-a'),
                'job vars: names, shop, local date/time (CDT), vehicle, services, links, money, rebook link (0083), portal link (0128)');

-- winter (CST) and a UTC time that is still the previous local day
update public.jobs set scheduled_start = '2025-01-15 15:00Z', scheduled_end = '2025-01-15 16:00Z' where id = tests.fx('job_a2');
select tests.eq(public.comms_job_vars(tests.fx('job_a2')) ->> 'job_date', 'Wednesday, January 15', 'winter date');
select tests.eq(public.comms_job_vars(tests.fx('job_a2')) ->> 'job_time', '9:00 AM', 'winter time is CST (UTC-6)');
update public.jobs set scheduled_start = '2025-06-03 02:30Z', scheduled_end = '2025-06-03 03:00Z' where id = tests.fx('job_a2');
select tests.eq(public.comms_job_vars(tests.fx('job_a2')) ->> 'job_date', 'Monday, June 2', 'late evening stays on the local day');
select tests.eq(public.comms_job_vars(tests.fx('job_a2')) ->> 'job_time', '9:30 PM', 'PM times');
select tests.ok((public.comms_job_vars(tests.fx('job_a2')) ->> 'services') is null, 'no line items: no services');
select tests.ok((public.comms_job_vars(tests.fx('job_a2')) -> 'customer_name') = '"Aaron Other"', 'customer name');
-- another shop's time zone
update public.shops set timezone = 'America/Los_Angeles' where id = tests.fx('shop_b');
select tests.eq(public.comms_job_vars(tests.fx('job_b')) ->> 'job_time', '8:00 AM', 'Los Angeles shop: PDT');
select tests.eq(public.comms_job_vars(tests.fx('job_b')) ->> 'shop_phone', null, 'no shop phone');
select tests.eq(public.comms_job_vars(tests.fx('job_b')) ->> 'amount', '$50.00', 'shop B job total');
-- unscheduled job and company-only customer
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_req', id);
select tests.ok((public.comms_job_vars(tests.fx('job_req')) ->> 'job_date') is null
                and (public.comms_job_vars(tests.fx('job_req')) ->> 'job_time') is null, 'unscheduled: no date/time');
select tests.eq(public.comms_job_vars(tests.fx('job_req')) ->> 'customer_first_name', 'Fleet Co', 'company-only first name');
select tests.eq(public.comms_job_vars(tests.fx('job_req')) ->> 'amount', '$0.00', 'no lines: zero');
select tests.eq(public.comms_customer_vars(tests.fx('shop_a'), tests.fx('cust_a3')) ->> 'customer_name', 'Fleet Co',
                'company-only full name');
select tests.eq(public.comms_job_vars(gen_random_uuid()), null::jsonb, 'unknown job: null');
select tests.eq(public.render_template('Hi {{customer_first_name}}, see you {{job_date}} at {{job_time}}.',
                                       public.comms_job_vars(tests.fx('job_a'))),
                'Hi Alice, see you Monday, June 2 at 10:00 AM.', 'rendering with job vars');

-- money documents (only when the money range is installed)
do $$
declare
  v_inv   uuid;
  v_tok   uuid;
  v_q     uuid;
  v_qtok  uuid;
begin
  if to_regclass('public.invoices') is null then
    return;
  end if;
  perform tests.authenticate_as(tests.fx('u_manager_a'));
  execute 'select (public.create_invoice_from_job($1)).id' into v_inv using tests.fx('job_a');
  execute 'select public.mark_invoice_sent($1)' using v_inv;
  execute 'select public.record_manual_payment($1, 5000, ''cash'', 1000)' using v_inv;
  perform tests.as_superuser();
  execute 'select public_token from public.invoices where id = $1' into v_tok using v_inv;
  perform tests.eq(public.comms_job_vars(tests.fx('job_a')) ->> 'invoice_link', 'https://app.example.test/i/' || v_tok,
                   'issued invoice link');
  perform tests.eq(public.comms_job_vars(tests.fx('job_a')) ->> 'amount', '$200.00', 'invoice total');
  perform tests.eq(public.comms_job_vars(tests.fx('job_a')) ->> 'balance', '$150.00', 'balance after payment (tip excluded)');

  execute 'insert into public.invoices (shop_id, job_id, customer_id, status, tax_rate_bps) values ($1, $2, $3, ''draft'', 0)'
    using tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2');
  perform tests.ok((public.comms_job_vars(tests.fx('job_a2')) ->> 'invoice_link') is null, 'draft invoices are not linked');

  execute 'insert into public.quotes (shop_id, customer_id, status, tax_rate_bps) values ($1, $2, ''sent'', 0)
           returning id, public_token' into v_q, v_qtok using tests.fx('shop_a'), tests.fx('cust_a');
  update public.jobs set quote_id = v_q where id = tests.fx('job_a');
  perform tests.eq(public.comms_job_vars(tests.fx('job_a')) ->> 'quote_link', 'https://app.example.test/q/' || v_qtok,
                   'the job''s quote link');
  -- the integration layer (0041) queues payment receipts for the payment
  -- above; this file counts only the messages it queues itself
  delete from public.messages where template_key = 'payment_receipt';
end
$$;

-- checked wrapper
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.template_vars_for_job(tests.fx('job_a')) ->> 'customer_first_name', 'Alice', 'managers get job vars');
select tests.throws($$select public.template_vars_for_job(tests.fx('job_b'))$$, 'P0002', 'not for another shop''s job');
select tests.throws($$select public.comms_job_vars(tests.fx('job_a'))$$, '42501', 'internal builders are not callable');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.template_vars_for_job(tests.fx('job_a'))$$, 'P0002', 'technicians do not get raw vars');
select tests.as_service();
select tests.eq(public.template_vars_for_job(tests.fx('job_b')) ->> 'customer_first_name', 'Bob', 'service_role gets any job');
select tests.as_anon();
select tests.throws($$select public.template_vars_for_job(tests.fx('job_a'))$$, '42501', 'anon cannot');
select tests.as_superuser();

-- ------------------------------------------------------------ opt-out guard (staff writes)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, phone, email, sms_opted_out_at, email_opted_out_at)
  values (tests.fx('shop_a'), 'Opted', '+12055550177', 'opted@example.com', '2020-01-01Z', '2020-01-01Z')
  returning tests.fx_set('cust_opt', id);
select tests.ok((select sms_opted_out_at = now() and email_opted_out_at = now() from public.customers
                  where id = tests.fx('cust_opt')), 'staff-recorded opt-outs are stamped with the server time');
select tests.throws_like($$update public.customers set sms_opted_out_at = null where id = tests.fx('cust_opt')$$, '42501',
                         '%START%', 'staff cannot clear an SMS opt-out');
select tests.throws($$update public.customers set email_opted_out_at = null where id = tests.fx('cust_opt')$$, '42501',
                    'staff cannot clear an email opt-out');
select tests.lives($$update public.customers set sms_opted_out_at = '2021-01-01Z' where id = tests.fx('cust_opt')$$);
select tests.eq((select sms_opted_out_at from public.customers where id = tests.fx('cust_opt')), now(),
                'an opt-out time cannot be rewritten');
select tests.lives($$update public.customers set sms_opted_out_at = '2021-01-01Z' where id = tests.fx('cust_a2')$$);
select tests.eq((select sms_opted_out_at from public.customers where id = tests.fx('cust_a2')), now(),
                'staff may record an opt-out');
select tests.as_superuser();
update public.customers set sms_opted_out_at = null where id = tests.fx('cust_a2');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('cust_a2')),
                'trusted code may clear opt-outs');

-- ------------------------------------------------------------ queue_message (staff free-form)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('msg_1', (public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', 'ignored',
                                                   E'  Your car is ready.\n ', tests.fx('job_a'))).id);
select tests.ok((select direction = 'outbound' and status = 'queued' and channel = 'sms' and to_address = '+12055550101'
                        and subject is null and body = 'Your car is ready.' and sent_by = tests.fx('u_manager_a')
                        and job_id = tests.fx('job_a') and send_after = now() and template_key is null
                   from public.messages where id = tests.fx('msg_1')), 'sms queued for the customer''s phone');
select tests.fx_set('msg_2', (public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', null, 'Hello there')).id);
select tests.ok((select to_address = 'alice@example.com' and subject = 'Message from Shop A'
                   from public.messages where id = tests.fx('msg_2')), 'email gets a default subject');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a2'), 'sms', null, 'hi')$$, '22023',
                         '%no mobile%', 'no phone');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a2'), 'email', null, 'hi')$$, '22023',
                         '%no email%', 'no email');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_opt'), 'sms', null, 'hi')$$, '55000',
                         '%opted out%', 'SMS opt-out blocks free-form texts');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_opt'), 'email', 'x', 'hi')$$, '55000',
                         '%unsubscribed%', 'email opt-out blocks free-form email');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, '   ')$$, '22023', 'empty body');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, repeat('x', 1601))$$, '22023',
                    'texts are at most 1600 characters');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi', tests.fx('job_a2'))$$,
                    '22023', 'the job must belong to the customer');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_b'), 'sms', null, 'hi')$$, 'P0002',
                    'customers of another shop are not found');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi', tests.fx('job_b'))$$,
                    'P0002', 'jobs of another shop are not found');
select tests.throws($$select public.queue_message(tests.fx('shop_b'), tests.fx('cust_b'), 'sms', null, 'hi')$$, '42501',
                    'managers cannot message another shop''s customers');

select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$select public.queue_message(tests.fx('shop_b'), tests.fx('cust_b'), 'email', null, 'hi')$$, '22023',
                         '%no email%', 'shop B customer has no email');
update public.customers set phone = '+13125550100' where id = tests.fx('cust_b');
select tests.throws_like($$select public.queue_message(tests.fx('shop_b'), tests.fx('cust_b'), 'sms', null, 'hi')$$, '55000',
                         '%not set up%', 'a shop without an SMS number cannot text');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi')$$, '42501',
                    'technicians cannot send free-form messages');
select tests.as_anon();
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi')$$, '42501', 'anon cannot');

-- ------------------------------------------------------------ messages table access
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.messages$$), 2::bigint, 'managers read their shop''s messages');
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', 'x', 'queued')$$,
                    '42501', 'no direct inserts');
select tests.throws($$update public.messages set body = 'changed' where id = tests.fx('msg_1')$$, '42501', 'no body edits');
select tests.throws($$update public.messages set status = 'sent' where id = tests.fx('msg_1')$$, '42501', 'no status edits');
select tests.throws($$delete from public.messages where id = tests.fx('msg_1')$$, '42501', 'no deletes');
select tests.eq(tests.row_count($$update public.messages set read_at = now() where id = tests.fx('msg_1')$$), 1::bigint,
                'staff mark messages read');
select tests.eq(tests.row_count($$update public.messages set read_at = null where id = tests.fx('msg_1')$$), 1::bigint,
                'and unread');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.messages$$), 2::bigint, 'admins read messages');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select 1 from public.messages$$), 2::bigint, 'owners read messages');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.messages$$), 0::bigint, 'technicians read no messages directly');
select tests.eq(tests.row_count($$update public.messages set read_at = now()$$), 0::bigint, 'technicians mark nothing read');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$select 1 from public.messages where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'other shops see nothing');
select tests.eq(tests.row_count($$update public.messages set read_at = now() where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'other shops mark nothing read');
select tests.as_superuser();

-- composite FKs keep messages inside their shop
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_b'), 'outbound', 'sms', '+12055550101', 'x', 'queued')$$,
                    '23503', 'a message cannot point at another shop''s customer');
select tests.throws($$insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_b'), 'outbound', 'sms', '+12055550101', 'x', 'queued')$$,
                    '23503', 'a message cannot point at another shop''s job');
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', 'x', 'received')$$,
                    '23514', 'outbound rows are never received');
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', 'alice@example.com', 'x', 'queued')$$,
                    '23514', 'sms needs a phone number');
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'email', 'alice@example.com', 'x', 'queued')$$,
                    '23514', 'outbound email needs a subject');

-- ------------------------------------------------------------ enqueue_template_message
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('msg_conf', public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed'));
select tests.eq((select body from public.messages where id = tests.fx('msg_conf')),
                'Hi Alice, your appointment with Shop A is confirmed for Monday, June 2 at 10:00 AM. Manage your booking: '
                  || 'https://app.example.test/booking/' || tests.fx('tok_a'),
                'the default confirmation renders with the job''s vars');
select tests.ok((select template_key = 'booking_confirmed' and status = 'queued' and sent_by = tests.fx('u_manager_a')
                        and job_id = tests.fx('job_a') and customer_id = tests.fx('cust_a') and to_address = '+12055550101'
                   from public.messages where id = tests.fx('msg_conf')), 'template message metadata');
select tests.fx_set('msg_conf_e', public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', p_channel => 'email'));
select tests.ok((select channel = 'email' and to_address = 'alice@example.com'
                        and subject = 'Your appointment is confirmed - Shop A' and body like 'Hi Alice,%Vehicle: 2021 Honda Civic%'
                   from public.messages where id = tests.fx('msg_conf_e')), 'email template: subject and body rendered');
select tests.eq(public.enqueue_template_message(tests.fx('job_a'), 'follow_up'), null::uuid, 'disabled template: no-op');
select tests.eq(public.enqueue_template_message(tests.fx('job_a'), 'job_started', p_channel => 'email'), null::uuid,
                'missing template: no-op');
select tests.eq(public.enqueue_template_message(tests.fx('job_a2'), 'booking_confirmed'), null::uuid, 'no phone: no-op');
select tests.eq(public.enqueue_template_message(tests.fx('job_a2'), 'booking_confirmed', p_channel => 'email'), null::uuid,
                'no email: no-op');
select tests.fx_set('msg_later', public.enqueue_template_message(tests.fx('job_a'), 'appointment_reminder', '2030-01-01Z'));
select tests.eq((select send_after from public.messages where id = tests.fx('msg_later')), '2030-01-01Z'::timestamptz,
                'managers may schedule a template message');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_b'), 'booking_confirmed')$$, 'P0002',
                    'jobs of another shop are not found');
select tests.throws($$select public.enqueue_template_message(gen_random_uuid(), 'booking_confirmed')$$, 'P0002', 'unknown job');

-- opted-out customers get nothing
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_opt'), '2025-06-05 15:00Z', '2025-06-05 16:00Z') returning tests.fx_set('job_opt', id);
select tests.eq(public.enqueue_template_message(tests.fx('job_opt'), 'booking_confirmed'), null::uuid, 'SMS opt-out: no-op');
select tests.eq(public.enqueue_template_message(tests.fx('job_opt'), 'booking_confirmed', p_channel => 'email'), null::uuid,
                'email opt-out: no-op');

-- technicians: on-the-way / started / complete on assigned jobs only
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.fx_set('msg_otw', public.enqueue_template_message(tests.fx('job_a'), 'on_the_way'));
select tests.as_superuser();
select tests.ok((select body = 'Hi Alice, your technician from Shop A is on the way. See you soon!' and sent_by = tests.fx('u_tech_a')
                   from public.messages where id = tests.fx('msg_otw')), 'technician sends on-the-way');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'job_completed') is not null, 'technician sends job complete');
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'job_started') is not null, 'technician sends job started');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'review_request')$$, '42501',
                    'technicians cannot send other templates');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a2'), 'on_the_way')$$, '42501',
                    'technicians only message customers of assigned jobs');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', now() + interval '1 hour')$$, '42501',
                    'technicians cannot schedule');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_b'), 'on_the_way')$$, 'P0002',
                    'another shop''s job is not found');
select tests.eq(tests.row_count($$select 1 from public.messages$$), 0::bigint, 'technicians still cannot read messages');
select tests.throws($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'on_the_way')$$, '42501',
                    'the internal enqueue is not callable by staff');

-- preview (nothing queued)
select tests.eq((select body from public.preview_template_message(tests.fx('job_a'), 'on_the_way')),
                'Hi Alice, your technician from Shop A is on the way. See you soon!', 'technician previews on-the-way');
select tests.throws($$select * from public.preview_template_message(tests.fx('job_a'), 'invoice_sent')$$, '42501',
                    'technicians cannot preview other templates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select enabled = false and to_address = '+12055550101' and body like 'Hi Alice, it has been a while%'
                   from public.preview_template_message(tests.fx('job_a'), 'follow_up')), 'preview shows disabled templates too');
select tests.ok((select subject = 'Appointment reminder - Shop A' and to_address = 'alice@example.com'
                   from public.preview_template_message(tests.fx('job_a'), 'appointment_reminder', 'email')), 'email preview');
select tests.throws($$select * from public.preview_template_message(tests.fx('job_a'), 'job_started', 'email')$$, 'P0002',
                    'preview of a missing template');
select tests.throws($$select * from public.preview_template_message(tests.fx('job_b'), 'on_the_way')$$, 'P0002',
                    'no previews for another shop');

-- service_role: any key, and the internal enqueue with extra vars
select tests.as_service();
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'review_request') is not null, 'service_role sends any template');
select tests.fx_set('msg_rcpt', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                                                                 tests.fx('job_a'), '{"amount": "$25.00"}'));
select tests.eq((select body from public.messages where id = tests.fx('msg_rcpt')),
                E'Thank you, Alice! Shop A received your payment of $25.00.\nRemaining balance: '
                  || (public.comms_job_vars(tests.fx('job_a')) ->> 'balance') || '.',
                'extra vars override job vars');
select tests.ok((select sent_by is null from public.messages where id = tests.fx('msg_rcpt')), 'no staff sender for automated sends');
select tests.fx_set('msg_welcome', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'email'));
select tests.ok((select job_id is null and subject = 'Welcome to your membership - Shop A'
                        and body like '%book here: https://app.example.test/book/shop-a%'
                   from public.messages where id = tests.fx('msg_welcome')), 'customer-level template without a job');
select tests.throws($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'on_the_way', 'sms', tests.fx('job_a2'))$$,
                    '22023', 'job must belong to the customer');
select tests.throws($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_b'), 'on_the_way')$$, 'P0002',
                    'customer must belong to the shop');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_b'), tests.fx('cust_b'), 'on_the_way'), null::uuid,
                'shop without SMS number: no-op');
select tests.as_anon();
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'on_the_way')$$, '42501', 'anon cannot enqueue');
select tests.as_superuser();

-- ------------------------------------------------------------ request_nonce: idempotent staff sends
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('nonce_msg', (public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Running late, 10 min',
                                                       null, 'compose-0001')).id);
select tests.eq((public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Running late, 10 min',
                                      null, 'compose-0001')).id, tests.fx('nonce_msg'),
                'a retry with the same nonce returns the first message');
select tests.eq((public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'edited text',
                                      null, 'compose-0001')).body, 'Running late, 10 min',
                'even when the retried body differs, nothing new is queued');
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a') and request_nonce = 'compose-0001'), 1::bigint,
                'one row for the nonce');
select tests.eq((select request_nonce from public.messages where id = tests.fx('nonce_msg')), 'compose-0001', 'the nonce is stored');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi', null, 'short')$$,
                         '22023', '%request_nonce%', 'a malformed nonce is refused');
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi', null, 'has space 123')$$,
                    '22023', 'only letters, digits, - and _');
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'hi', null,
                                                 '550e8400-e29b-41d4-a716-446655440000')$$, 'a UUID string is a valid nonce');
-- another sender with the same nonce gets a message of their own
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.ok((public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Running late, 10 min',
                                      null, 'compose-0001')).id <> tests.fx('nonce_msg'),
                'the same nonce from another user queues a new message');
-- another shop's member cannot use a nonce to read shop A's message
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'x', null, 'compose-0001')$$,
                    '42501', 'shop B cannot replay into shop A');

-- enqueue_template_message
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('nonce_tpl', public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', null, 'sms', 'tpl-nonce-01'));
select tests.ok(tests.fx('nonce_tpl') is not null, 'template send queued');
select tests.eq(public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', null, 'sms', 'tpl-nonce-01'), tests.fx('nonce_tpl'),
                'a template send retried with its nonce returns the same message');
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a') and request_nonce = 'tpl-nonce-01'), 1::bigint,
                'queued once');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', null, 'sms', 'bad nonce!')$$, '22023',
                    'malformed template nonce');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'on_the_way', null, 'sms', 'tpl-nonce-01') <> tests.fx('nonce_tpl'),
                'the assigned technician''s send with the same nonce is their own message');
select tests.throws($$select public.enqueue_template_message(tests.fx('job_a'), 'review_request', null, 'sms', 'tpl-nonce-01')$$, '42501',
                    'a nonce never bypasses the technician rules');

-- enqueue_customer_template (service_role acting for a staff member)
select tests.as_service();
select tests.fx_set('nonce_svc', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                                   null, '{"amount": "$5.00"}', null, tests.fx('u_manager_a'), 'svc-nonce-001'));
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                  null, '{"amount": "$5.00"}', null, tests.fx('u_manager_a'), 'svc-nonce-001'), tests.fx('nonce_svc'),
                'the internal core honours the nonce per sender');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                  null, '{"amount": "$5.00"}', null, tests.fx('u_admin_a'), 'svc-nonce-001') <> tests.fx('nonce_svc'),
                'per sender');
select tests.throws($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                        null, null, null, null, '!!')$$, '22023', 'malformed core nonce');

-- the table enforces the shape and the uniqueness per (shop, sender)
select tests.as_superuser();
select tests.throws($$update public.messages set request_nonce = 'x' where id = tests.fx('msg_1')$$, '23514',
                    'request_nonce shape is checked');
select tests.throws($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, sent_by, request_nonce)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', 'dup', 'queued',
                              tests.fx('u_manager_a'), 'compose-0001')$$, '23505',
                    'a (shop, sender, nonce) is unique');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.messages set request_nonce = 'compose-9999' where id = tests.fx('nonce_msg')$$, '42501',
                    'staff cannot write request_nonce directly');
