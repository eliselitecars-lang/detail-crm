-- 125 (0125): a customer's deletion request. erase_customer (service role,
-- through the payments edge; p_actor must be an owner / admin) deletes a
-- customer nothing of accounting references, else anonymises the record in
-- place, keeping every money row. Refused while a membership is live, a
-- payment is in flight, a pay page is open or saved cards remain. Address
-- suppressions outlive the person; an erased record cannot be edited or
-- linked again; clients cannot DELETE customers any more.
\ir fixtures/two_shops.psql

create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end
$$;

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- cust_a: a job with notes, an invoice, a cash payment, messages, files,
-- vehicle details and an email suppression; a duplicate merged into it
update public.customers
   set notes = 'Gate code 4411', tags = '{vip}', address_line1 = '1 Main St', city = 'Birmingham',
       email_opt_in = true, sms_opt_in = true, custom_data = '{}'::jsonb
 where id = tests.fx('cust_a');
update public.vehicles set vin = '1HGCM82633A004352', license_plate = 'ABC123', notes = 'scratch on door'
 where id = tests.fx('veh_a');
update public.jobs set notes = 'Call Alice on arrival', internal_notes = 'Alice prefers mornings',
       location_type = 'mobile', service_address_line1 = '1 Main St', service_city = 'Birmingham'
 where id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
update public.invoices set notes = 'For Alice Anders' where id = tests.fx('inv');
select public.mark_invoice_sent(tests.fx('inv'));
select tests.fx_set('pay', (public.record_manual_payment(tests.fx('inv'), 5000, 'cash')).id);
select tests.as_superuser();
update public.payments set note = 'Alice paid at the door' where id = tests.fx('pay');
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body, status)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_a'), 'outbound', 'email', 'alice@example.com',
          'Hello', 'Hi Alice', 'sent');
select set_config('x.doc_path', tests.fx('shop_a')::text || '/customers/' || tests.fx('cust_a')::text || '/'
                                 || gen_random_uuid()::text || '.pdf', false);
insert into storage.objects (bucket_id, name) values ('documents', current_setting('x.doc_path'));
insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('cust_a'), current_setting('x.doc_path'), 'id.pdf', 'application/pdf', 100)
  returning tests.fx_set('doc', id);
insert into public.notifications (shop_id, user_id, kind, title, body, customer_id)
  values (tests.fx('shop_a'), tests.fx('u_owner_a'), 'new_booking', 'New booking', 'From Alice Anders', tests.fx('cust_a'));
select public.comms_suppress(tests.fx('shop_a'), 'email', 'alice@example.com');
insert into public.comms_unsubscribe_tokens (shop_id, token, address)
  values (tests.fx('shop_a'), gen_random_uuid(), 'alice@example.com');
-- a duplicate merged into cust_a (archived, still carrying a name)
insert into public.customers (shop_id, first_name, last_name, phone) values (tests.fx('shop_a'), 'Ally', 'Anders', '+12055550199')
  returning tests.fx_set('dup_a', id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('dup_a'), tests.fx('cust_a'));
select tests.as_superuser();
select tests.eq((select merged_into_id from public.customers where id = tests.fx('dup_a')), tests.fx('cust_a'), 'setup: merged');

-- money snapshot
create temp table money_before as
  select (select jsonb_agg(to_jsonb(j) - 'updated_at' order by j.id) from (
            select id, number, status, subtotal_cents, discount_cents, tax_cents, total_cents, deposit_required_cents, scheduled_start
              from public.jobs where shop_id = tests.fx('shop_a')) j) as jobs,
         (select jsonb_agg(to_jsonb(i) order by i.id) from (
            select id, number, status, total_cents, amount_paid_cents, balance_cents, issued_at, due_at
              from public.invoices where shop_id = tests.fx('shop_a')) i) as invoices,
         (select jsonb_agg(to_jsonb(p) order by p.id) from (
            select id, kind, method, status, amount_cents, tip_cents, refunded_cents, paid_at, created_at
              from public.payments where shop_id = tests.fx('shop_a')) p) as payments;
grant select on money_before to authenticated, service_role;
select tests.authenticate_as(tests.fx('u_owner_a'));
create temp table reports_before as
  select (select jsonb_agg(to_jsonb(r)) from public.report_revenue_totals(tests.fx('shop_a'), current_date - 30, current_date + 1) r) as revenue,
         (select jsonb_agg(to_jsonb(r)) from public.report_payments(tests.fx('shop_a'), current_date - 30, current_date + 1) r) as payments,
         (select jsonb_agg(to_jsonb(r) order by r.service_id) from public.report_sales_by_service(tests.fx('shop_a'), current_date - 30, current_date + 1) r) as sales,
         (public.report_outstanding(tests.fx('shop_a'), now()) -> 'total_cents') as outstanding;

-- ============================================================ who may erase
select tests.as_superuser();
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_tech_a'))$$,
                    '42501', 'superuser call with a technician actor: 42501');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_tech_a'))$$,
                    '42501', 'technicians cannot call it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_manager_a'))$$,
                    '42501', 'managers cannot call it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_owner_a'))$$,
                    '42501', 'nor owners directly: only the payments edge (service role)');
select tests.as_anon();
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_owner_a'))$$,
                    '42501', 'anon cannot');
select tests.as_service();
select tests.throws_like($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_manager_a'))$$,
                         '42501', 'only owners and admins can delete a customer', 'service role with a manager actor: 42501');
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_tech_a'))$$,
                    '42501', 'service role with a technician actor: 42501');
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_owner_b'))$$,
                    '42501', 'another shop''s owner: 42501');
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), null)$$,
                    '42501', 'an actor is required');
select tests.throws($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_b'), tests.fx('u_owner_a'))$$,
                    'P0002', 'another shop''s customer: P0002');

-- ============================================================ no client DELETE
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501',
                    'owners cannot delete a customer directly (no DELETE policy; no DELETE privilege since 0132)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501', 'nor managers');
select tests.ok(not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customers' and cmd = 'DELETE'),
                'customers has no DELETE policy');
select tests.throws($$update public.customers set erased_at = now() where id = tests.fx('cust_a3')$$, '42501',
                    'erased_at is not client-writable');

-- ============================================================ 'deleted'
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make, model, vin) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'Ford', 'Transit', '1FTBR1C82MKA00001')
  returning tests.fx_set('veh_a3', id);
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'outbound', 'sms', '+12055550177', 'Hello fleet', 'sent');
update public.customers set email = 'fleet@example.com' where id = tests.fx('cust_a3');
select public.comms_suppress(tests.fx('shop_a'), 'email', 'fleet@example.com');
select tests.as_service();
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_admin_a'), true),
                jsonb_build_object('dry_run', true, 'mode', 'deleted', 'erased', false, 'membership_active', false,
                                   'payments_in_progress', 0, 'open_checkouts', 0, 'saved_cards', 0),
                'dry run: would delete, nothing in the way');
select tests.ok(exists (select 1 from public.customers where id = tests.fx('cust_a3')), 'dry run changes nothing');
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_admin_a')),
                '{"mode": "deleted"}'::jsonb, 'admins may erase: no records -> deleted');
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.customers where id = tests.fx('cust_a3')), 'the row is gone');
select tests.ok(not exists (select 1 from public.vehicles where id = tests.fx('veh_a3')), 'vehicles cascade');
select tests.ok(not exists (select 1 from public.messages where customer_id = tests.fx('cust_a3')), 'messages cascade');
select tests.ok(exists (select 1 from public.storage_purge_requests
                         where bucket_id = 'documents'
                           and path = tests.fx('shop_a')::text || '/customers/' || tests.fx('cust_a3')::text || '/'),
                'the customer''s file folder is queued for the storage purge');
select tests.ok(exists (select 1 from public.comms_suppressions
                         where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'fleet@example.com'),
                'the address suppression outlives the deleted customer');
select tests.eq((select mode || '/' || (erased_by = tests.fx('u_admin_a'))::text from public.customer_erasures
                  where customer_id = tests.fx('cust_a3')), 'deleted/true', 'audit row (mode, erased_by)');
-- a re-created record with the same address is still opted out
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Fleet', 'fleet@example.com', true) returning tests.fx_set('cust_re', id);
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('cust_re')),
                're-created with the address: opted out, no marketing');

-- ============================================================ refusals
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count)
  values (tests.fx('shop_a'), 'Club', 2000, 'month', 1) returning tests.fx_set('plan', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'incomplete', null, null)
  returning tests.fx_set('mem', id);
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'membership_active', 'an incomplete membership: HINT membership_active');
select tests.as_superuser();
update public.memberships set status = 'active', current_period_end = now() + interval '3 days',
       started_at = now() - interval '27 days' where id = tests.fx('mem');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'membership_active', 'an active membership: HINT membership_active');
select tests.as_superuser();
update public.memberships set status = 'past_due' where id = tests.fx('mem');
select tests.as_service();
select tests.eq((public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'), true) ->> 'membership_active')::boolean,
                true, 'dry run reports the live membership');
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'membership_active', 'a past_due membership: HINT membership_active');
select tests.throws_like($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$,
                         '55000', '%membership%', '55000');
select tests.as_superuser();
update public.memberships set status = 'cancelled', cancelled_at = now() where id = tests.fx('mem');

-- a payment in flight
insert into public.payments (shop_id, invoice_id, customer_id, kind, method, status, amount_cents, stripe_payment_intent_id)
  values (tests.fx('shop_a'), tests.fx('inv'), tests.fx('cust_a'), 'payment', 'card', 'processing', 1000, 'pi_EraseTest1')
  returning tests.fx_set('pay_proc', id);
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'payment_in_progress', 'a processing payment: HINT payment_in_progress');
select tests.as_superuser();
update public.payments set status = 'pending', created_at = now() - interval '5 minutes' where id = tests.fx('pay_proc');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'payment_in_progress', 'a pending payment: HINT payment_in_progress');
select tests.as_superuser();
update public.payments set status = 'failed' where id = tests.fx('pay_proc');

-- an open pay page (job hold, then invoice hold)
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_E1', true)
  on conflict (shop_id) do nothing;
insert into public.job_checkout_holds (stripe_checkout_session_id, shop_id, job_id, expires_at)
  values ('cs_test_erase1', tests.fx('shop_a'), tests.fx('job_a'), now() + interval '30 minutes');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'checkout_open', 'a live job pay page: HINT checkout_open');
select tests.as_superuser();
delete from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_erase1';
insert into public.invoice_checkout_holds (stripe_checkout_session_id, shop_id, invoice_id, expires_at)
  values ('cs_test_erase2', tests.fx('shop_a'), tests.fx('inv'), now() + interval '30 minutes');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'checkout_open', 'a live invoice pay page: HINT checkout_open');
select tests.as_superuser();
update public.invoice_checkout_holds set expires_at = now() - interval '1 minute' where stripe_checkout_session_id = 'cs_test_erase2';

-- saved cards
insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id, brand, last4)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'pm_Erase1', 'visa', '4242');
select tests.as_service();
select tests.eq((public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'), true) ->> 'saved_cards')::int,
                1, 'dry run counts the saved cards');
select tests.eq(pg_temp.hint_of($$select public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'))$$),
                'saved_cards', 'saved cards: HINT saved_cards (the edge detaches them in Stripe first)');
select tests.as_superuser();
delete from public.customer_payment_methods where customer_id = tests.fx('cust_a');
select tests.ok((select first_name = 'Alice' and erased_at is null from public.customers where id = tests.fx('cust_a')),
                'every refusal left the customer untouched');

-- ============================================================ 'anonymised'
select tests.as_service();
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a'), true) ->> 'mode',
                'anonymised', 'dry run: jobs and money reference the customer -> anonymised');
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a')),
                '{"mode": "anonymised"}'::jsonb, 'erased: anonymised');
select tests.as_superuser();
select tests.eq((select jsonb_build_object('first_name', first_name, 'last_name', last_name, 'email', email, 'phone', phone,
                                           'address_line1', address_line1, 'city', city, 'notes', notes, 'tags', tags,
                                           'custom_data', custom_data, 'email_opt_in', email_opt_in, 'sms_opt_in', sms_opt_in,
                                           'portal_user_id', portal_user_id, 'stripe_customer_id', stripe_customer_id,
                                           'archived', archived_at is not null, 'erased', erased_at is not null)
                   from public.customers where id = tests.fx('cust_a')),
                jsonb_build_object('first_name', 'Deleted', 'last_name', 'customer', 'email', null, 'phone', null,
                                   'address_line1', null, 'city', null, 'notes', null, 'tags', '[]'::jsonb,
                                   'custom_data', '{}'::jsonb, 'email_opt_in', false, 'sms_opt_in', false,
                                   'portal_user_id', null, 'stripe_customer_id', null, 'archived', true, 'erased', true),
                'the customer is anonymised');
select tests.eq((select jsonb_build_object('vin', vin, 'plate', license_plate, 'notes', notes, 'make', make, 'model', model)
                   from public.vehicles where id = tests.fx('veh_a')),
                (select jsonb_build_object('vin', null, 'plate', null, 'notes', null, 'make', make, 'model', model)
                   from public.vehicles where id = tests.fx('veh_a')),
                'vehicle: vin / plate / notes gone, make and model kept');
select tests.ok((select make is not null from public.vehicles where id = tests.fx('veh_a')), 'the vehicle keeps its make');
select tests.eq((select jsonb_build_object('notes', notes, 'internal', internal_notes, 'addr', service_address_line1)
                   from public.jobs where id = tests.fx('job_a')),
                '{"notes": null, "internal": null, "addr": null}'::jsonb, 'job free text and service address scrubbed');
select tests.eq((select notes from public.invoices where id = tests.fx('inv')), null::text, 'invoice notes scrubbed');
select tests.eq((select note from public.payments where id = tests.fx('pay')), null::text, 'payment note scrubbed');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_a')), 0::bigint, 'messages deleted');
select tests.ok(not exists (select 1 from public.documents where id = tests.fx('doc')), 'documents deleted');
select tests.ok(exists (select 1 from public.storage_purge_requests
                         where bucket_id = 'documents'
                           and path = tests.fx('shop_a')::text || '/customers/' || tests.fx('cust_a')::text || '/'),
                'their file folder is queued for the storage purge');
select tests.eq((select count(*) from public.notifications where customer_id = tests.fx('cust_a')), 0::bigint,
                'staff notifications about them deleted');
select tests.ok(exists (select 1 from public.comms_suppressions
                         where shop_id = tests.fx('shop_a') and channel = 'email' and address = 'alice@example.com'),
                'the email suppression is kept');
select tests.ok(exists (select 1 from public.comms_unsubscribe_tokens
                         where shop_id = tests.fx('shop_a') and address = 'alice@example.com'),
                'unsubscribe tokens are kept');
select tests.ok(not exists (select 1 from public.customers where id = tests.fx('dup_a')), 'the merged duplicate is erased too (deleted)');
select tests.eq((select array_agg(mode order by mode) from public.customer_erasures
                  where customer_id in (tests.fx('cust_a'), tests.fx('dup_a'))), array['anonymised', 'deleted'],
                'one audit row per erased record');
select tests.eq((select count(*) from public.customer_erasures e
                  where e.shop_id = tests.fx('shop_a')
                    and (to_jsonb(e)::text ilike '%alice%' or to_jsonb(e)::text ilike '%anders%')), 0::bigint,
                'the audit holds no personal data');

-- money unchanged
select tests.eq((select jsonb_agg(to_jsonb(j) - 'updated_at' order by j.id) from (
                   select id, number, status, subtotal_cents, discount_cents, tax_cents, total_cents, deposit_required_cents, scheduled_start
                     from public.jobs where shop_id = tests.fx('shop_a')) j),
                (select jobs from money_before), 'job money unchanged');
select tests.eq((select jsonb_agg(to_jsonb(i) order by i.id) from (
                   select id, number, status, total_cents, amount_paid_cents, balance_cents, issued_at, due_at
                     from public.invoices where shop_id = tests.fx('shop_a')) i),
                (select invoices from money_before), 'invoices unchanged');
select tests.eq((select jsonb_agg(to_jsonb(p) order by p.id) from (
                   select id, kind, method, status, amount_cents, tip_cents, refunded_cents, paid_at, created_at
                     from public.payments where shop_id = tests.fx('shop_a') and id <> tests.fx('pay_proc')) p),
                (select jsonb_agg(x order by x ->> 'id') from money_before, jsonb_array_elements(payments) x),
                'payments unchanged');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select jsonb_agg(to_jsonb(r)) from public.report_revenue_totals(tests.fx('shop_a'), current_date - 30, current_date + 1) r),
                (select revenue from reports_before), 'report_revenue_totals unchanged');
select tests.eq((select jsonb_agg(to_jsonb(r)) from public.report_payments(tests.fx('shop_a'), current_date - 30, current_date + 1) r),
                (select payments from reports_before), 'report_payments unchanged');
select tests.eq((select jsonb_agg(to_jsonb(r) order by r.service_id) from public.report_sales_by_service(tests.fx('shop_a'), current_date - 30, current_date + 1) r),
                (select sales from reports_before), 'report_sales_by_service unchanged');
select tests.eq(public.report_outstanding(tests.fx('shop_a'), now()) -> 'total_cents', (select outstanding from reports_before),
                'report_outstanding unchanged');

-- ============================================================ an erased record stays erased
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.customers set first_name = 'Alice' where id = tests.fx('cust_a')$$,
                         '55000', '%erased%', 'staff cannot edit an erased customer back');
select tests.eq(pg_temp.hint_of($$update public.customers set email = 'alice@example.com' where id = tests.fx('cust_a')$$),
                'customer_erased', 'HINT customer_erased');
select tests.throws($$update public.customers set archived_at = null where id = tests.fx('cust_a')$$, '55000',
                    'nor un-archive it');
select tests.throws($$insert into public.jobs (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$,
                    '55000', 'no new job for an erased customer');
select tests.throws($$insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Kia')$$,
                    '55000', 'no new vehicle');
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a') where id = tests.fx('job_a2')$$,
                    '55000', 'no job moved onto it');
select tests.as_superuser();
select tests.throws($$update public.customers set portal_user_id = tests.fx('u_outsider') where id = tests.fx('cust_a')$$,
                    '55000', 'no portal re-link, even by trusted code');
select tests.throws($$update public.customers set erased_at = null where id = tests.fx('cust_a')$$,
                    '55000', 'erased_at cannot be cleared');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.merge_customers(tests.fx('cust_a2'), tests.fx('cust_a'))$$, null,
                    'nothing can be merged into an erased customer');
select tests.as_service();
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('u_owner_a')),
                '{"mode": "anonymised"}'::jsonb, 'erasing again is a no-op');
select tests.eq((select count(*) from public.customer_erasures where customer_id = tests.fx('cust_a')), 1::bigint,
                'and adds no audit row');

-- ============================================================ audit table access
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select count(*) from public.customer_erasures where shop_id = tests.fx('shop_a')), 3::bigint, 'admins read the audit');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.customer_erasures), 0::bigint, 'managers do not');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select count(*) from public.customer_erasures), 0::bigint, 'nor another shop');
select tests.throws($$insert into public.customer_erasures (shop_id, customer_id, mode) values (tests.fx('shop_b'), gen_random_uuid(), 'deleted')$$,
                    '42501', 'clients cannot write the audit');
