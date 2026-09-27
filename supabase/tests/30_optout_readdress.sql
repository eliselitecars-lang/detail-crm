-- 30 comms: an opt-out belongs to the ADDRESS, so it stays with the address
-- when a customer's phone / email changes (customers_comms_suppressed).
-- Regression: the stamps (customers.sms_opted_out_at / email_opted_out_at)
-- were carried forward when staff saved a new phone or email, so a customer
-- who once opted out at an old number / inbox could never be messaged at the
-- new one (invoices, receipts, reminders all refused), the new address was
-- treated as opted out for campaigns, and staff could not clear it (42501).
-- The same happened when the verified owner of an email replaced an
-- unverified phone a stranger had STOPped (create_online_booking, 0042).
-- Now the stamps are recomputed from comms_suppressions for the new address;
-- the old address keeps its opt-out; recording an opt-out and person-level
-- opt-outs (recorded while there was no address) still hold.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');

-- ============================================================ the reported case (repro)
-- Alice opted out at her OLD email and number
select tests.as_service();
select public.comms_suppress(tests.fx('shop_a'), 'email', 'alice@example.com');
select public.comms_suppress(tests.fx('shop_a'), 'sms', '+12055550101');
select tests.as_superuser();
select tests.ok((select sms_opted_out_at is not null and email_opted_out_at is not null from public.customers
                  where id = tests.fx('cust_a')), 'setup: Alice is opted out at her old addresses');

-- staff save her NEW email and number (neither ever opted out)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.customers set email = 'alice.new@example.com', phone = '+12055550188'
                                   where id = tests.fx('cust_a')$$), 1::bigint,
                'staff can save new contact details (no 42501)');
select tests.eq((select count(*) from public.comms_suppressions where address in ('alice.new@example.com', '+12055550188')),
                0::bigint, 'new addresses not suppressed');
select tests.ok((select sms_opted_out_at is null and email_opted_out_at is null from public.customers
                  where id = tests.fx('cust_a')), 'the old addresses'' opt-outs no longer apply to her');
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Hi', 'Your invoice')$$,
                   'transactional email to the new, never-unsubscribed address is allowed');
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Hi')$$,
                   'text to the new, never-opted-out number is allowed');
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', null, 'sms') is not null,
                'templates are queued to the new number');
select tests.ok(public.enqueue_template_message(tests.fx('job_a'), 'booking_confirmed', null, 'email') is not null,
                'and to the new email');
-- the old addresses stay suppressed for everyone
select tests.eq((select array_agg(address order by address) from public.comms_suppressions where shop_id = tests.fx('shop_a')),
                array['+12055550101', 'alice@example.com'], 'the old addresses keep their opt-outs');
insert into public.customers (shop_id, first_name, phone, email, sms_opt_in, email_opt_in)
  values (tests.fx('shop_a'), 'Newcomer', '+12055550101', 'ALICE@example.com', true, true) returning tests.fx_set('c_new', id);
select tests.ok((select sms_opted_out_at is not null and email_opted_out_at is not null and not sms_opt_in and not email_opt_in
                   from public.customers where id = tests.fx('c_new')),
                'a customer with the old addresses is still opted out');

-- the claim does not cancel what was queued to the new addresses
select tests.as_service();
create temp table claimed on commit drop as select * from public.claim_queued_messages(50, now() + interval '1 minute');
select tests.eq((select count(*) from claimed where customer_id = tests.fx('cust_a')), 4::bigint,
                'the sender is handed every message to the new addresses');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_a') and status = 'cancelled'),
                0::bigint, 'none was withdrawn as opted out');

-- campaigns: the new addresses are an ordinary audience; the old ones are not
select tests.as_superuser();
update public.customers set sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'sms', '{}'), 1, 'her new number is in the SMS audience');
select tests.eq(public.preview_campaign_audience(tests.fx('shop_a'), 'email', '{}'), 1, 'her new email is in the email audience');

-- ============================================================ moving back to an opted-out address
update public.customers set phone = '+12055550101', email = 'Alice@Example.com', sms_opt_in = true, email_opt_in = true
 where id = tests.fx('cust_a');
select tests.ok((select sms_opted_out_at is not null and email_opted_out_at is not null and not sms_opt_in and not email_opt_in
                   from public.customers where id = tests.fx('cust_a')),
                'moving back to an opted-out address opts her out again (case-insensitive email)');
select tests.throws_like($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Hi')$$,
                         '55000', '%opted out%', 'the opted-out number is refused');
-- removing the address drops the stamp; the address stays suppressed
update public.customers set phone = null where id = tests.fx('cust_a');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('cust_a')),
                'no number, no number opt-out');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = '+12055550101'),
                'removing the number never lifts its opt-out');

-- ============================================================ opt-outs that still hold
-- recording an opt-out together with the new number keeps it (and suppresses the number)
update public.customers set phone = '+12055550177', sms_opted_out_at = now() where id = tests.fx('cust_a');
select tests.ok((select sms_opted_out_at = now() from public.customers where id = tests.fx('cust_a')),
                'an opt-out recorded with the new number is kept');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = '+12055550177'),
                'and suppresses that number');
-- a case-only email edit is the same address: the opt-out stays
update public.customers set email = 'ALICE@EXAMPLE.COM' where id = tests.fx('cust_a');
select tests.ok((select email_opted_out_at is not null from public.customers where id = tests.fx('cust_a')),
                'changing only the case of the email keeps its opt-out');
-- a person-level opt-out recorded while there was no address applies to the first one given
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Quiet') returning tests.fx_set('c_quiet', id);
update public.customers set sms_opted_out_at = now(), email_opted_out_at = now() where id = tests.fx('c_quiet');
update public.customers set phone = '+12055550166', email = 'quiet@example.com' where id = tests.fx('c_quiet');
select tests.ok((select sms_opted_out_at is not null and email_opted_out_at is not null from public.customers
                  where id = tests.fx('c_quiet')), 'an opt-out recorded before any address still holds');
select tests.eq((select count(*) from public.comms_suppressions where shop_id = tests.fx('shop_a')
                   and address in ('+12055550166', 'quiet@example.com')), 2::bigint,
                'and the addresses given later are suppressed');
-- staff still cannot clear an opt-out directly
select tests.throws($$update public.customers set sms_opted_out_at = null where id = tests.fx('c_quiet')$$, '42501',
                    'staff cannot clear an SMS opt-out');
select tests.throws($$update public.customers set email_opted_out_at = null where id = tests.fx('c_quiet')$$, '42501',
                    'staff cannot clear an email opt-out');
-- a staff re-address with an explicit clear is still refused
select tests.throws($$update public.customers set phone = '+12055550155', sms_opted_out_at = null where id = tests.fx('c_quiet')$$,
                    '42501', 'clearing the stamp explicitly is refused even with a new number');

-- trusted code that re-addresses a customer does not lift the old opt-out either
select tests.as_service();
update public.customers set phone = '+12055550155' where id = tests.fx('c_quiet');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('c_quiet')),
                'service_role re-address: the new number is not opted out');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = '+12055550166'),
                'the previous number keeps its opt-out');
-- clearing a stamp without changing the address (trusted) still clears the address
update public.customers set email_opted_out_at = null where id = tests.fx('c_quiet');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = 'quiet@example.com'),
                'a trusted clear without an address change lifts that address''s opt-out');

-- ============================================================ cross-shop isolation
select tests.as_service();
select public.comms_suppress(tests.fx('shop_b'), 'sms', '+12055550144');
select tests.as_superuser();
update public.customers set phone = '+12055550144' where id = tests.fx('cust_b');
select tests.ok((select sms_opted_out_at is not null from public.customers where id = tests.fx('cust_b')),
                'shop B: re-addressed onto its own suppressed number is opted out');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set phone = '+12055550144' where id = tests.fx('c_quiet');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('c_quiet')),
                'shop A: the same number is not opted out (another shop''s opt-out)');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.customers set phone = '+12055550133' where id = tests.fx('cust_a')$$), 0::bigint,
                'another shop''s manager cannot re-address shop A''s customer');

-- ============================================================ create_online_booking: owner replaces a STOPped unverified phone
select to_regprocedure('public.create_online_booking(text, jsonb, timestamptz)') is not null as has_public_booking \gset
\if :has_public_booking
select tests.as_superuser();
update public.booking_settings
   set enabled = true, slot_interval_minutes = 60, lead_time_minutes = 0, max_days_ahead = 365,
       buffer_minutes = 0, max_concurrent_jobs = 100
 where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at)
  select tests.fx('shop_a'), d, '08:00', '17:00' from generate_series(0, 6) d
  on conflict do nothing;
create function pg_temp.book(p_customer jsonb, p_start text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', jsonb_build_object(
    'customer', p_customer,
    'vehicle', jsonb_build_object('year', 2020, 'make', 'Toyota', 'model', 'Camry', 'category_id', tests.fx('cat_car_a')),
    'service_ids', jsonb_build_array(tests.fx('svc_a')), 'addon_ids', jsonb_build_array(),
    'starts_at', p_start, 'location', jsonb_build_object('type', 'shop')))
$$;
grant execute on function pg_temp.book(jsonb, text) to authenticated, service_role;
-- a stranger books with Olga's email and their own phone, then texts STOP
select tests.as_service();
create temp table o1 on commit drop as select public.create_online_booking('shop-a', jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'Olga', 'email', 'olga@example.com', 'phone', '+12055550611', 'sms_opt_in', true),
    'vehicle', jsonb_build_object('year', 2020, 'make', 'Toyota', 'model', 'Camry', 'category_id', tests.fx('cat_car_a')),
    'service_ids', jsonb_build_array(tests.fx('svc_a')), 'addon_ids', jsonb_build_array(),
    'starts_at', '2025-06-09T15:00:00Z', 'location', jsonb_build_object('type', 'shop')), '2025-06-01 12:00Z') as r;
select tests.fx_set('cust_olga', (select j.customer_id from public.jobs j, o1 where j.public_token = (o1.r ->> 'job_token')::uuid));
select public.record_inbound_sms('+12055550100', '+12055550611', 'STOP', 'SMolga');
select tests.as_superuser();
select tests.ok((select phone_unverified and sms_opted_out_at is not null from public.customers where id = tests.fx('cust_olga')),
                'setup: the unverified phone on Olga''s record texted STOP');
-- the verified owner books with her own number
select tests.fx_set('u_olga', tests.create_user('olga@example.com'));
create temp table live on commit drop as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a')], (now() at time zone 'America/Chicago')::date + 3,
                                  (now() at time zone 'America/Chicago')::date + 3,
                                  tests.fx('cat_car_a')) s;
grant select on live to authenticated;
select tests.authenticate_as(tests.fx('u_olga'));
create temp table o2 on commit drop as
  select pg_temp.book(jsonb_build_object('first_name', 'Olga', 'email', 'olga@example.com', 'phone', '+12055550612'),
                      (select starts_at from live)) as r;
select tests.as_superuser();
select tests.ok((select phone = '+12055550612' and sms_opted_out_at is null from public.customers where id = tests.fx('cust_olga')),
                'the stranger''s STOP does not block the owner''s own number');
select tests.ok(exists (select 1 from public.messages m, o2
                         where m.job_id = (select j.id from public.jobs j where j.public_token = (o2.r ->> 'job_token')::uuid)
                           and m.channel = 'sms' and m.to_address = '+12055550612' and m.status = 'queued'),
                'her booking text is queued to her number');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and address = '+12055550611'),
                'the stranger''s number stays opted out');
\endif
