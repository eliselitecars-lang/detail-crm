-- 126 (0126): the marketing unsubscribe link ends marketing consent only
-- (transactional email keeps flowing), "also stop those" is a full opt-out,
-- only the customer can opt back in (the /u/ page's resubscribe or the
-- client portal), and every opt-in restored by the customer is logged.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- marketing email carries the shop's postal address (0119)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203', tax_rate_bps = 0
 where id = tests.fx('shop_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key in ('follow_up', 'invoice_sent');
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
-- a second customer record with the same address (a duplicate)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Alice', 'ALICE@example.com', true) returning tests.fx_set('cust_a_dup', id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));

-- ============================================================ scope / source basics
select tests.as_superuser();
insert into public.comms_suppressions (shop_id, channel, address) values (tests.fx('shop_b'), 'email', 'legacy@example.com');
select tests.eq((select scope || '/' || coalesce(source, 'null') from public.comms_suppressions
                  where shop_id = tests.fx('shop_b') and address = 'legacy@example.com'), 'all/null',
                'a row written without a scope (every row before 0126) is a full opt-out');
select tests.as_service();
select public.comms_suppress(tests.fx('shop_b'), 'email', 'staff@example.com');
select tests.eq((select scope from public.comms_suppressions where shop_id = tests.fx('shop_b') and address = 'staff@example.com'),
                'all', 'comms_suppress defaults to scope all');
select tests.throws($$select public.comms_suppress(tests.fx('shop_b'), 'sms', '+12055550111', now(), 'marketing')$$, '22023',
                    'SMS has no marketing-only opt-out');
select tests.as_superuser();
select tests.throws($$insert into public.comms_suppressions (shop_id, channel, address, scope) values (tests.fx('shop_b'), 'sms', '+12055550112', 'marketing')$$,
                    '23514', 'constraint: SMS rows are scope all');
select tests.throws($$update public.comms_suppressions set source = 'bogus' where address = 'legacy@example.com'$$, '23514',
                    'source is from the known list');

-- ============================================================ a marketing email and its link
select tests.as_service();
select tests.fx_set('fu1', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')));
select tests.as_superuser();
select tests.ok(tests.fx('fu1') is not null, 'setup: a follow-up email is queued');
select tests.fx_set('tok', (select unsubscribe_token from public.messages where id = tests.fx('fu1')));
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) -> 'unsubscribed', 'false'::jsonb, 'not unsubscribed yet');
select tests.ok(public.public_unsubscribe(tests.fx('tok')), 'the link unsubscribes (anon, POST)');
select tests.as_superuser();
select tests.eq((select scope || '/' || source from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'marketing/link', 'recorded as a marketing-only opt-out from the link');
select tests.ok((select bool_and(email_opted_out_at is null and not email_opt_in) and count(*) = 2
                   from public.customers where id in (tests.fx('cust_a'), tests.fx('cust_a_dup'))),
                'every record with the address: marketing consent off, no all-email stamp');
select tests.eq((select status::text from public.messages where id = tests.fx('fu1')), 'cancelled',
                'the queued promotion is withdrawn');
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) - 'shop_logo_path' - 'shop_name',
                '{"unsubscribed": true, "scope": "marketing", "can_resubscribe": true}'::jsonb, 'the page''s state');
select tests.ok(public.public_unsubscribe(tests.fx('tok'), 'list_unsubscribe'), 'idempotent (one-click)');

-- transactional email continues
select tests.as_service();
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'invoice_sent', 'email', tests.fx('job_a'))
                  is not null, 'invoice_sent still queues after a marketing unsubscribe');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'email', tests.fx('job_a'))
                  is not null, 'so does a booking confirmation');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Your visit', 'See you soon')$$,
                   'staff can still email the customer one-to-one');
-- marketing does not
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')),
                null::uuid, 'follow_up is not queued');
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'service_followup', 'email', 'Hi', 'Time for a wash',
                                            tests.fx('job_a')),
                null::uuid, 'nor a per-service follow-up');
select tests.as_superuser();
-- even when the consent flag is forced on behind the triggers' back, the
-- insert gate refuses a marketing template message to the address
alter table public.customers disable trigger customers_30_comms_guard;
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
alter table public.customers enable trigger customers_30_comms_guard;
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')),
                null::uuid, 'messages_01_marketing_suppressed: not inserted');
select tests.as_superuser();
alter table public.customers disable trigger customers_30_comms_guard;
update public.customers set email_opt_in = false where id = tests.fx('cust_a');
alter table public.customers enable trigger customers_30_comms_guard;
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Spring', 'email', 'Spring sale', 'Hi {{customer_first_name}}') returning tests.fx_set('camp', id);
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 0, 'campaigns leave the address out');

-- the claim re-checks: a promotion queued before the suppression existed
-- (e.g. written by other code) is withdrawn at send time
select tests.as_superuser();
update public.customers set email = 'bob@example.com', email_opt_in = true where id = tests.fx('cust_a2');
select tests.as_service();
select tests.fx_set('fu2', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a2'), 'follow_up', 'email',
                                                            tests.fx('job_a2')));
select tests.as_superuser();
select tests.ok(tests.fx('fu2') is not null, 'setup: Bob''s follow-up is queued');
update public.messages set send_after = now() - interval '1 minute' where id = tests.fx('fu2');
insert into public.comms_suppressions (shop_id, channel, address, scope, source)
  values (tests.fx('shop_a'), 'email', 'bob@example.com', 'marketing', 'link');
select tests.as_service();
select tests.eq((select count(*) from public.claim_queued_messages(50, now()) where id = tests.fx('fu2')), 0::bigint,
                'the claim does not hand it to the sender');
select tests.eq((select status::text || ': ' || error from public.messages where id = tests.fx('fu2')),
                'cancelled: the recipient unsubscribed from marketing before sending', 'withdrawn with the reason');

-- ============================================================ nobody but the customer opts back in
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.customers set email_opt_in = true where id = tests.fx('cust_a')$$, '42501',
                         'this address unsubscribed; only the customer can opt back in (their unsubscribe link or the client portal)',
                         'staff cannot turn marketing back on');
select tests.throws($$insert into public.customers (shop_id, first_name, email, email_opt_in)
                      values (tests.fx('shop_a'), 'Alice again', 'alice@example.com', true)$$, '42501',
                    'nor create a record with the address opted in');
select tests.lives($$update public.customers set notes = 'VIP' where id = tests.fx('cust_a')$$, 'other edits still work');
-- trusted code keeps it off
select tests.as_service();
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
select tests.as_superuser();
select tests.ok((select not email_opt_in from public.customers where id = tests.fx('cust_a')),
                'service_role / definer code: the opt-in silently stays off');
-- the CSV import
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.import_customers(tests.fx('shop_a'),
  '[{"first_name": "Alice", "email": "alice@example.com", "email_opt_in": "yes"},
    {"first_name": "Newbie", "email": "alice@EXAMPLE.com", "email_opt_in": "yes"}]'::jsonb, false);
select tests.as_superuser();
select tests.ok((select bool_and(not email_opt_in) from public.customers
                  where shop_id = tests.fx('shop_a') and lower(email::text) = 'alice@example.com'),
                'an import saying "yes" cannot re-subscribe the address');
-- a merge
insert into public.customers (shop_id, first_name, last_name) values (tests.fx('shop_a'), 'Alicia', 'Anders')
  returning tests.fx_set('no_mail', id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('cust_a_dup'), tests.fx('no_mail'));
select tests.as_superuser();
select tests.ok((select lower(email::text) = 'alice@example.com' and not email_opt_in from public.customers where id = tests.fx('no_mail')),
                'a merge that takes the address over does not re-subscribe it');
-- clearing an all-email stamp from a client stays refused
select tests.as_service();
select public.comms_suppress(tests.fx('shop_a'), 'email', 'bob@example.com', now(), 'all', 'staff');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.customers set email_opted_out_at = null where id = tests.fx('cust_a2')$$, '42501',
                    'staff cannot clear an all-email opt-out');

-- ============================================================ the customer resubscribes
select tests.as_anon();
select tests.eq(public.public_resubscribe(gen_random_uuid()), false, 'unknown token: false');
select tests.eq(public.public_resubscribe(null), false, 'null token: false');
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.7"}', true);
select tests.ok(public.public_resubscribe(tests.fx('tok')), 'the /u/ page''s Resubscribe');
select set_config('request.headers', '', true);
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.comms_suppressions
                             where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'the suppression is gone');
select tests.ok((select bool_and(email_opt_in and email_opted_out_at is null) from public.customers
                  where shop_id = tests.fx('shop_a') and lower(email::text) = 'alice@example.com' and archived_at is null),
                'every current record with the address is opted in again');
select tests.eq((select count(*) from public.customer_consent_events e
                  where e.shop_id = tests.fx('shop_a') and e.address_key = 'alice@example.com'
                    and e.action = 'opt_in' and e.source = 'resubscribe_link' and e.channel = 'email'
                    and e.client_ip = '203.0.113.7'::inet),
                (select count(*) from public.customers
                  where shop_id = tests.fx('shop_a') and lower(email::text) = 'alice@example.com' and archived_at is null),
                'one consent event per record, with the connection');
select tests.as_service();
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a'))
                  is not null, 'promotions reach the address again');

-- ============================================================ "also stop those": all email
select tests.as_superuser();
select tests.fx_set('tok2', (select unsubscribe_token from public.messages
                              where customer_id = tests.fx('cust_a') and template_key = 'follow_up' and status = 'queued'));
select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('tok2')), 'marketing first');
select tests.ok(public.public_unsubscribe_all(tests.fx('tok2')), 'then everything');
select tests.eq(public.public_unsubscribe_all(gen_random_uuid()), false, 'unknown token: false');
select tests.as_superuser();
select tests.eq((select scope || '/' || source from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'all/customer_all', 'upgraded to a full opt-out');
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('cust_a')),
                'the customer is stamped');
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'invoice_sent', 'email', tests.fx('job_a')),
                null::uuid, 'transactional email stops too');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Hi', 'Hello')$$,
                         '55000', '%unsubscribed%', 'and staff email is refused');
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok2')) ->> 'scope', 'all', 'the page shows the full opt-out');
select tests.ok(public.public_unsubscribe(tests.fx('tok2')), 'a later marketing click does not loosen it');
select tests.as_superuser();
select tests.eq((select scope from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'all', 'still all');

-- ============================================================ STOP is recorded as sms_stop
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+13125550100', tests.fx('shop_a'))
  on conflict (phone_number) do nothing;
select tests.as_service();
select * from public.record_inbound_sms('+13125550100', '+12055550101', 'STOP', 'SM_stop_126');
select tests.as_superuser();
select tests.eq((select scope || '/' || source from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'sms' and address = '+12055550101'),
                'all/sms_stop', 'STOP texts: scope all, source sms_stop');

-- ============================================================ the client portal toggle
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
select tests.fx_set('u_mallory', tests.create_user('mallory@example.com'));
select tests.fx_set('u_unconfirmed', tests.create_user('unconfirmed@example.com', false));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq((select jsonb_agg(e - 'unsubscribed_at') from jsonb_array_elements(public.portal_email_marketing()) e),
                jsonb_build_array(jsonb_build_object('customer_id', tests.fx('cust_a'), 'shop_slug', 'shop-a', 'shop_name', 'Shop A',
                                                     'email', 'alice@example.com', 'email_opt_in', false,
                                                     'unsubscribed_scope', 'all')),
                'portal_email_marketing lists her record and its state');
select tests.eq(public.portal_set_email_marketing(tests.fx('cust_a'), true), true, 'she turns marketing email back on');
select tests.as_superuser();
select tests.ok((select email_opt_in and email_opted_out_at is null from public.customers where id = tests.fx('cust_a')),
                'opted in, the full opt-out lifted by the customer herself');
select tests.ok(not exists (select 1 from public.comms_suppressions
                             where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'no suppression left');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(public.portal_set_email_marketing(tests.fx('cust_a'), false), false, 'and off again');
select tests.as_superuser();
select tests.eq((select scope || '/' || source from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'marketing/portal', 'off = a marketing-only opt-out from the portal');
select tests.eq((select array_agg(action order by created_at, action) from public.customer_consent_events
                  where customer_id = tests.fx('cust_a') and source = 'portal'), array['opt_in', 'opt_out'],
                'both logged');
select tests.authenticate_as(tests.fx('u_mallory'));
select tests.throws($$select public.portal_set_email_marketing(tests.fx('cust_a'), true)$$, 'P0002',
                    'another account (email differs) cannot');
select tests.eq(public.portal_email_marketing(), '[]'::jsonb, 'and sees nothing');
select tests.authenticate_as(tests.fx('u_unconfirmed'));
select tests.throws($$select public.portal_set_email_marketing(tests.fx('cust_a'), true)$$, '42501', 'an unconfirmed account cannot');
select tests.as_anon();
select tests.throws($$select public.portal_set_email_marketing(tests.fx('cust_a'), true)$$, '42501', 'anon cannot');
select tests.throws($$select public.portal_email_marketing()$$, '42501', 'nor list');

-- ============================================================ resubscribe needs a current customer
select tests.as_superuser();
insert into public.comms_unsubscribe_tokens (shop_id, token, address) values (tests.fx('shop_a'), gen_random_uuid(), 'gone@example.com')
  returning tests.fx_set('tok_gone', token);
insert into public.comms_suppressions (shop_id, channel, address, scope, source)
  values (tests.fx('shop_a'), 'email', 'gone@example.com', 'marketing', 'link');
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok_gone')) -> 'can_resubscribe', 'false'::jsonb, 'nobody to resubscribe');
select tests.eq(public.public_resubscribe(tests.fx('tok_gone')), false, 'refused');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = 'gone@example.com'),
                'the address keeps its opt-out');

-- ============================================================ consent events: access
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select count(*) from public.customer_consent_events) > 0, 'managers read their shop''s consent events');
select tests.throws($$insert into public.customer_consent_events (shop_id, customer_id, channel, address_key, action, source)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'alice@example.com', 'opt_in', 'portal')$$,
                    '42501', 'clients cannot write them');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.customer_consent_events), 0::bigint, 'technicians do not read them');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.customer_consent_events), 0::bigint, 'nor another shop');
select tests.as_anon();
select tests.throws($$select count(*) from public.customer_consent_events$$, '42501', 'anon has no access');

-- erasing the customer (0125) removes their consent history
select tests.as_superuser();
delete from public.customer_payment_methods where customer_id = tests.fx('cust_a');
select tests.as_service();
select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'));
select tests.as_superuser();
select tests.eq((select count(*) from public.customer_consent_events where customer_id = tests.fx('cust_a')), 0::bigint,
                'an erased customer''s consent events are removed');

-- grants
select tests.ok(has_function_privilege('anon', 'public.public_resubscribe(uuid)', 'execute')
                and has_function_privilege('anon', 'public.public_unsubscribe_all(uuid)', 'execute')
                and has_function_privilege('anon', 'public.public_unsubscribe(uuid, text)', 'execute'),
                'the /u/ page RPCs are anon');
select tests.ok(not has_function_privilege('anon', 'public.portal_set_email_marketing(uuid, boolean)', 'execute')
                and has_function_privilege('authenticated', 'public.portal_set_email_marketing(uuid, boolean)', 'execute'),
                'the portal toggle is signed-in only');
select tests.ok(not has_function_privilege('authenticated', 'public.comms_is_marketing_suppressed(uuid, public.message_channel, text)', 'execute')
                and not has_function_privilege('authenticated', 'public.comms_suppress(uuid, public.message_channel, text, timestamptz, text, text)', 'execute'),
                'the internals are service-only');
