-- 95 cross-cutting (0095): (a) technicians never read customer-linked
-- calendar events from blocked_times (regression); (b) saved-card re-save
-- compares with the card's own Stripe customer (cards moved by a merge);
-- (c) gift_card_order_expired; (d) machine-readable HINTs on two 22023
-- refusals; (e) add_fee_line request nonces; (f) import chunk nonces;
-- (g) shop timezone / slug / currency in the report JSON and portal lists.
\ir fixtures/two_shops.psql

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare
  v_state text; v_hint text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_hint = pg_exception_hint;
  return v_state || coalesce(':' || nullif(v_hint, ''), '');
end $$;
grant execute on function pg_temp.err(text) to authenticated, service_role, anon;

-- ============================================================ (a) blocked_times: no customer-linked rows below manager
select tests.as_superuser();
insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, kind, title, customer_id, reason) values
  (tests.fx('shop_a'), null, '2025-06-03 15:00Z', '2025-06-03 16:00Z', 'consultation', 'Consult Alice', tests.fx('cust_a'), 'private'),
  (tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-06-04 15:00Z', '2025-06-04 16:00Z', 'reminder', 'Call Aaron', tests.fx('cust_a2'), 'own'),
  (tests.fx('shop_a'), null, '2025-06-05 15:00Z', '2025-06-05 16:00Z', 'meeting', 'Team meeting', null, 'agenda');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(title) from public.blocked_times), array['Team meeting'],
                'a technician reads only the event that names no customer');
select tests.eq(tests.row_count($$select 1 from public.blocked_times where customer_id is not null or names_customer$$), 0::bigint,
                'no customer id, title or reason of a customer event (shop-wide or their own)');
select tests.eq((select jsonb_agg(jsonb_build_array(event_kind, title, customer_id) order by starts_at)
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-03', '2025-06-06') where event_type = 'blocked_time'),
                '[["consultation", null, null], ["reminder", "Call Aaron", null], ["meeting", "Team meeting", null]]'::jsonb,
                'calendar_events: busy time without the customer (own event keeps its title)');
select tests.as_superuser();
delete from public.customers where id = tests.fx('cust_a3');
update public.blocked_times set customer_id = null where title = 'Consult Alice';
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.blocked_times where title = 'Consult Alice'$$), 0::bigint,
                'an event stays hidden once its customer link is gone (names_customer is sticky)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.blocked_times where shop_id = tests.fx('shop_a')$$), 3::bigint, 'managers read all');

-- ============================================================ (b) saved cards moved by a merge
select tests.as_superuser();
update public.customers set stripe_customer_id = 'cus_Source1' where id = tests.fx('cust_a');
update public.customers set stripe_customer_id = 'cus_Target1' where id = tests.fx('cust_a2');
select tests.as_service();
select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_Moved1', 'visa', '4242', 12, 2030, false,
                                             'cus_Source1');
select tests.as_superuser();
select tests.eq((select stripe_customer_id from public.customer_payment_methods where stripe_payment_method_id = 'pm_Moved1'),
                'cus_Source1', 'the card remembers its Stripe customer');
-- what merge_customers does to the source's cards
update public.customer_payment_methods set customer_id = tests.fx('cust_a2') where stripe_payment_method_id = 'pm_Moved1';
select tests.as_service();
select tests.eq((select concat_ws('/', customer_id = tests.fx('cust_a2'), last4, exp_year, stripe_customer_id)
                   from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Moved1', 'visa', '4242',
                                                              12, 2031, false, 'cus_Source1')),
                't/4242/2031/cus_Source1', 'a moved card is re-saved under its own Stripe customer');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Moved1', 'visa',
                           '4242', 12, 2031, false, 'cus_Target1')$$, '22023', '%another Stripe customer%',
                         'but not claimed for the target''s own Stripe customer');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Fresh1', 'visa',
                           '1111', 12, 2031, false, 'cus_Source1')$$, '22023', '%another Stripe customer%',
                         'a NEW card must still be the customer''s own Stripe customer''s');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_Moved1', 'visa',
                           '4242', 12, 2031, false, 'cus_Source1')$$, '22023', '%another customer%',
                         'and a card saved for one customer is never attached to another');
select tests.lives($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Fresh2', 'visa',
                     '5555', 12, 2031, false, 'cus_Target1')$$, 'a new card of the target''s Stripe customer is saved');
select tests.as_superuser();
update public.customer_payment_methods set stripe_customer_id = null where stripe_payment_method_id = 'pm_Fresh2';
select tests.as_service();
select tests.lives($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Fresh2', 'visa',
                     '5555', 1, 2032, false, 'cus_Target1')$$, 'a legacy card without its Stripe customer: the customer''s applies');
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_Fresh2', 'visa',
                      '5555', 1, 2032, false, 'cus_Source1')$$, '22023', 'and refuses another');

-- ============================================================ (c) gift_card_order_expired
select tests.as_superuser();
insert into public.gift_card_orders (shop_id, value_cents, price_cents, purchaser_name, purchaser_email, recipient_email,
                                     stripe_checkout_session_id, status) values
  (tests.fx('shop_a'), 5000, 5000, 'Pat', 'pat@example.com', 'sam@example.com', 'cs_test_Open1', 'pending'),
  (tests.fx('shop_a'), 5000, 5000, 'Pat', 'pat@example.com', 'sam@example.com', 'cs_test_Paid1', 'paid');
select tests.fx_set('gco_open', (select id from public.gift_card_orders where stripe_checkout_session_id = 'cs_test_Open1'));
select tests.fx_set('gco_tok', (select token from public.gift_card_orders where stripe_checkout_session_id = 'cs_test_Open1'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.gift_card_order_expired('cs_test_Open1')$$, '42501', 'staff cannot expire orders');
select tests.as_anon();
select tests.throws($$select public.gift_card_order_expired('cs_test_Open1')$$, '42501', 'anon neither');
select tests.as_service();
select tests.eq(public.gift_card_order_expired('cs_test_Open1'),
                jsonb_build_object('order_id', tests.fx('gco_open'), 'status', 'expired', 'changed', true), 'a pending order expires');
select tests.eq(public.gift_card_order_expired('cs_test_Open1'),
                jsonb_build_object('order_id', tests.fx('gco_open'), 'status', 'expired', 'changed', false), 'idempotent');
select tests.eq(public.gift_card_order_expired('cs_test_Paid1') - 'order_id', '{"status": "paid", "changed": false}'::jsonb,
                'a paid order is never touched');
select tests.throws($$select public.gift_card_order_expired('cs_test_Nobody')$$, 'P0002', 'unknown session');
select tests.throws($$select public.gift_card_order_expired('sess_1')$$, '22023', 'malformed session id');
select tests.throws($$select public.gift_card_order_expired(null)$$, '22023', 'no session id');
select tests.as_anon();
select tests.eq(public.public_gift_card_order_status(tests.fx('gco_tok')) ->> 'status', 'expired', 'the success page shows it expired');

-- ============================================================ (d) distinct refusals (HINT)
select tests.as_superuser();
update public.gift_card_settings set online_enabled = true, allow_custom_amount = true, min_custom_cents = 1000, max_custom_cents = 50000
 where shop_id = tests.fx('shop_a');
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, online_joinable)
  values (tests.fx('shop_a'), 'Club', 4000, 'month', 1, true) returning tests.fx_set('club', id);
create function pg_temp.gift(p_amount integer, p_email text default 'pat@example.com') returns text language sql as $$
  select pg_temp.err(format('select public.gift_card_order_prepare(%L, %L::jsonb)', 'shop-a',
    jsonb_build_object('amount_cents', p_amount, 'purchaser', jsonb_build_object('name', 'Pat', 'email', p_email),
                       'recipient', jsonb_build_object('email', 'sam@example.com')))) $$;
create function pg_temp.join() returns text language sql as $$
  select pg_temp.err(format('select public.membership_join_prepare(%L, %L, %L::jsonb)', 'shop-a', tests.fx('club'),
    jsonb_build_object('customer', jsonb_build_object('first_name', 'Jo', 'email', 'jo@example.com')))) $$;
grant execute on function pg_temp.gift(integer, text), pg_temp.join() to service_role;
select tests.as_service();
select tests.eq(pg_temp.gift(500), '22023:amount_out_of_range', 'gift card amount below the range: 22023 + HINT amount_out_of_range');
select tests.eq(pg_temp.gift(60000), '22023:amount_out_of_range', 'above the range too');
select tests.throws_like(format('select public.gift_card_order_prepare(%L, %L::jsonb)', 'shop-a',
                           jsonb_build_object('amount_cents', 500, 'purchaser', jsonb_build_object('name', 'Pat', 'email', 'pat@example.com'),
                                              'recipient', jsonb_build_object('email', 'sam@example.com'))),
                         '22023', 'amount out of range: choose between $10.00 and $500.00', 'the message is unchanged');
select tests.eq(pg_temp.gift(2000, 'not-an-email'), '22023', 'other invalid input: 22023 without the hint');
select tests.eq(pg_temp.join(), 'no error', 'first join prepares the membership');
update public.memberships set status = 'active', stripe_subscription_id = 'sub_Club1'
 where plan_id = tests.fx('club') and shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.join(), '22023:already_member', 'joining again: 22023 + HINT already_member');
select tests.throws_like(format('select public.membership_join_prepare(%L, %L, %L::jsonb)', 'shop-a', tests.fx('club'),
                           jsonb_build_object('customer', jsonb_build_object('first_name', 'Jo', 'email', 'jo@example.com'))),
                         '22023', 'this customer already has this membership', 'the message is unchanged');

-- ============================================================ (e) add_fee_line request nonces
select tests.as_superuser();
insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), 'Travel', 2500) returning tests.fx_set('fee', id);
create function pg_temp.fee_lines(p_job uuid) returns bigint language sql as $$
  select count(*) from public.job_line_items where job_id = p_job and fee_id = tests.fx('fee') $$;
grant execute on function pg_temp.fee_lines(uuid) to authenticated;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('fee_line', public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0001'));
select tests.eq(public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0001'), tests.fx('fee_line'),
                'a retry with the same nonce returns the same line');
select tests.eq(pg_temp.fee_lines(tests.fx('job_a')), 1::bigint, 'and adds no second fee');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('job_a2'), tests.fx('fee'), 'fee-nonce-0001')$$, '22023',
                         '%different request%', 'the nonce of another request is refused');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'bad')$$, '22023', '%request_nonce%',
                         'a malformed nonce is refused');
select tests.ok(public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0002') <> tests.fx('fee_line'),
                'a new nonce is a new request');
select tests.ok(public.add_fee_line(p_doc_kind => 'job', p_doc_id => tests.fx('job_a'), p_fee_id => tests.fx('fee')) is not null,
                'callers without a nonce keep working');
select tests.eq(pg_temp.fee_lines(tests.fx('job_a')), 3::bigint, 'three fee lines in all');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.ok(public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0001') <> tests.fx('fee_line'),
                'nonces are per person');
select tests.throws($$select id from public.client_requests$$, '42501', 'the ledger is not readable');
select tests.as_superuser();
update public.shop_fees set archived_at = now() where id = tests.fx('fee');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0001'), tests.fx('fee_line'),
                'a retry after the fee was archived still answers with the line it added');
select tests.throws($$select public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0003')$$, '22023',
                    'a new request for the archived fee is refused');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee'), 'fee-nonce-0001')$$, '42501',
                    'the role check comes before any replay');

-- ============================================================ (f) import chunk nonces
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table imp as
  select public.import_customers(tests.fx('shop_a'),
           '[{"first_name": "Ivy", "email": "ivy@example.com"}, {"first_name": "Max", "email": "max@example.com"}]',
           false, null, 'list.csv', 'import-chunk-1') as r;
select tests.eq((select r -> 'counts' ->> 'created' from imp), '2', 'the chunk imports two customers');
select tests.eq((select public.import_customers(tests.fx('shop_a'),
                   '[{"first_name": "Ivy", "email": "ivy@example.com"}, {"first_name": "Max", "email": "max@example.com"}]',
                   false, null, 'list.csv', 'import-chunk-1')) - 'replayed', (select r from imp),
                'the retried chunk answers with the first result');
select tests.eq((select public.import_customers(tests.fx('shop_a'),
                   '[{"first_name": "Ivy", "email": "ivy@example.com"}, {"first_name": "Max", "email": "max@example.com"}]',
                   false, null, 'list.csv', 'import-chunk-1')) -> 'replayed', 'true'::jsonb, 'marked as a replay');
select tests.eq((select count(*) from public.import_batches where shop_id = tests.fx('shop_a')), 1::bigint, 'one batch');
select tests.eq((select row_count from public.import_batches where shop_id = tests.fx('shop_a')), 2, 'counted once');
select tests.throws_like($$select public.import_customers(tests.fx('shop_a'), '[{"first_name": "Zed"}]', false, null, 'list.csv',
                                                         'import-chunk-1')$$, '22023', '%different request%',
                         'another chunk with the same nonce is refused');
select tests.eq((select r -> 'counts' ->> 'skipped' from (select public.import_customers(tests.fx('shop_a'),
                   '[{"first_name": "Ivy", "email": "ivy@example.com"}]', true, null, null, 'import-chunk-1') as r) x), '1',
                'a dry run ignores the nonce');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email in ('ivy@example.com', 'max@example.com')),
                2::bigint, 'each customer exists once');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('svc_batch', (public.import_services(tests.fx('shop_a'), '[{"name": "Clay Bar", "prices": {"base": 5000}}]', false,
                                                         null, 'svc.csv', 'import-svc-1') ->> 'batch_id')::uuid);
select tests.eq((public.import_services(tests.fx('shop_a'), '[{"name": "Clay Bar", "prices": {"base": 5000}}]', false, null, 'svc.csv',
                                        'import-svc-1') ->> 'batch_id')::uuid, tests.fx('svc_batch'), 'services: the same batch back');
select tests.as_superuser();
select tests.eq((select count(*) from public.services where shop_id = tests.fx('shop_a') and name = 'Clay Bar'), 1::bigint,
                'the service is imported once');
select tests.ok(has_function_privilege('authenticated', 'public.import_customers(uuid, jsonb, boolean, uuid, text, text)', 'execute')
                and not has_function_privilege('anon', 'public.import_services(uuid, jsonb, boolean, uuid, text, text)', 'execute')
                and has_function_privilege('authenticated', 'public.add_fee_line(text, uuid, uuid, text)', 'execute')
                and to_regprocedure('public.add_fee_line(text, uuid, uuid)') is null
                and to_regprocedure('public.import_customers(uuid, jsonb, boolean, uuid, text)') is null,
                'the new signatures replace the old ones');

-- ============================================================ (g) timezone / slug / currency
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_client') where id = tests.fx('cust_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
update public.shops set timezone = 'America/Denver', currency = 'cad' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table rep as select public.publish_job_report(tests.fx('job_a')) as r;
grant select on rep to anon, authenticated;
select tests.lives(format($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', %L, auth.uid(), auth.uid()::text)$$,
                          tests.fx('shop_a') || '/customers/' || tests.fx('cust_a') || '/id.pdf'), 'upload a customer file');
insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes, customer_visible)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('shop_a') || '/customers/' || tests.fx('cust_a') || '/id.pdf', 'ID.pdf',
          'application/pdf', 100, true);
select tests.as_anon();
select tests.eq(public.public_get_job_report(((select r from rep) ->> 'token')::uuid) #>> '{shop,timezone}', 'America/Denver',
                'job report: the shop''s timezone');
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq((select jsonb_build_array(d -> 'shop_name', d -> 'shop_slug', d -> 'timezone', d -> 'currency')
                   from jsonb_array_elements(public.portal_job_reports()) d),
                '["Shop A", "shop-a", "America/Denver", "cad"]'::jsonb, 'portal_job_reports: slug, timezone, currency');
select tests.eq((select jsonb_build_array(d -> 'file_name', d -> 'shop_slug', d -> 'timezone', d -> 'currency')
                   from jsonb_array_elements(public.portal_documents()) d),
                '["ID.pdf", "shop-a", "America/Denver", "cad"]'::jsonb, 'portal_documents: slug, timezone, currency');
