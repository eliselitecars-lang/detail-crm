-- 60 money: a job's deposit due is capped by its live invoice's balance on
-- every surface — job_payment_summary (0063, staff web / iOS MoneyCard) and
-- the /q page's self_schedule block (money_public_quote_json, 0067) —
-- agreeing with the /booking page (booking_public_json, 0064) and the
-- deposit reminders (comms_deposit_due_cents, 0085). A grouped (fleet)
-- invoice's payments carry no job_id, so without the cap a job of a paid
-- fleet invoice still asked for its deposit. Partial payment, technicians,
-- void, roles and isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');

create function pg_temp.dep(p_job uuid) returns text language sql as $$
  select concat_ws('/', deposit_due_cents, balance_cents, invoice_job_count) from public.job_payment_summary(p_job)
$$;
grant execute on function pg_temp.dep(uuid) to authenticated;
-- the three other surfaces, as their callers see them: {booking, comms}
create function pg_temp.others(p_job uuid) returns jsonb language sql security definer as $$
  select jsonb_build_object('booking', (public.booking_public_json(p_job, now()) -> 'deposit' ->> 'due_cents')::bigint,
                            'comms', public.comms_deposit_due_cents(p_job))
$$;
grant execute on function pg_temp.others(uuid) to authenticated;

-- ============================================================ repro: a paid grouped invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), now() + interval '3 days', now() + interval '3 days 2 hours') returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j1'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), now() + interval '4 days', now() + interval '4 days 2 hours') returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j2'), 'Wash', 10000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('m_tech_a'));
select tests.as_superuser();
update public.jobs set deposit_required_cents = 5000 where id in (tests.fx('j1'), tests.fx('j2'));
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.dep(tests.fx('j1')), '5000/10000/0', 'before invoicing: the deposit is due');
select tests.eq(pg_temp.others(tests.fx('j1')), '{"booking": 5000, "comms": 5000}'::jsonb, 'on every surface');

select tests.fx_set('inv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])).id);
select tests.eq(pg_temp.dep(tests.fx('j1')), '5000/20000/2', 'on the unpaid fleet invoice the deposit is still due');
select tests.eq(pg_temp.others(tests.fx('j1')), '{"booking": 5000, "comms": 5000}'::jsonb, 'everywhere');

-- partly paid: never a deposit beyond what the invoice still owes
select public.record_manual_payment(tests.fx('inv'), 17000, 'check');
select tests.eq(concat_ws(' ', pg_temp.dep(tests.fx('j1')), pg_temp.dep(tests.fx('j2'))), '3000/3000/2 3000/3000/2',
                'the fleet invoice owes 30.00: each job''s deposit due is capped at 30.00');
select tests.eq(pg_temp.others(tests.fx('j1')), '{"booking": 3000, "comms": 3000}'::jsonb, 'the same on the other surfaces');

select public.record_manual_payment(tests.fx('inv'), 3000, 'check');
select tests.eq((select status::text from public.invoices where id = tests.fx('inv')), 'paid', 'grouped invoice paid in full');
select tests.eq(pg_temp.dep(tests.fx('j1')), '0/0/2', 'job_payment_summary: no deposit due on a job whose grouped invoice is paid in full');
select tests.eq(pg_temp.dep(tests.fx('j2')), '0/0/2', 'nor on its other job');
select tests.eq(pg_temp.others(tests.fx('j1')), '{"booking": 0, "comms": 0}'::jsonb, 'agreeing with the booking page and reminders');
select tests.eq((select deposit_paid_cents from public.job_payment_summary(tests.fx('j1'))), 0::bigint,
                '(no deposit was paid on the job itself)');

-- a technician on the job sees it billed, and no deposit to collect
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(pg_temp.dep(tests.fx('j1')), '0/0/2', 'technician: billed, nothing due');
select tests.eq((select invoice_id from public.job_payment_summary(tests.fx('j1'))), null::uuid, 'without the grouped invoice''s details');

-- ============================================================ single-job invoice: capped at its balance too
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), now() + interval '5 days', now() + interval '5 days 2 hours') returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'Wash', 10000);
select tests.as_superuser();
update public.jobs set deposit_required_cents = 8000 where id = tests.fx('j3');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv3', (public.create_invoice_from_job(tests.fx('j3'))).id);
-- the invoice is discounted at billing: it owes less than the job's deposit
update public.invoices set discount_kind = 'fixed', discount_value = 5000 where id = tests.fx('inv3');
select tests.eq(pg_temp.dep(tests.fx('j3')), '5000/5000/1', 'the deposit is capped at the invoice total');
select tests.eq(pg_temp.others(tests.fx('j3')), '{"booking": 5000, "comms": 5000}'::jsonb, 'everywhere');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv3'), 'Re-billing');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.dep(tests.fx('j3')), '8000/10000/0', 'after the void, the job''s own deposit applies again');

-- ============================================================ roles and isolation
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select * from public.job_payment_summary(tests.fx('j1'))$$, '42501', 'a technician not on the job cannot see it');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.job_payment_summary(tests.fx('j1'))$$, 'P0002', 'another shop: not found');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.job_payment_summary(tests.fx('j1'))$$, 'P0002', 'an outsider: not found');
select tests.as_anon();
select tests.throws($$select * from public.job_payment_summary(tests.fx('j1'))$$, '42501', 'anon: no execute');

-- ============================================================ the /q page of a self-scheduled quote
select tests.as_superuser();
\ir fixtures/40_booking_setup.psql
select ((now() at time zone 'America/Chicago')::date + 30)::text as d \gset
select tests.as_superuser();
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 5000, quote_self_schedule = true
 where shop_id = tests.fx('shop_a');
create function pg_temp.token(p_q uuid) returns uuid language sql security definer as $$
  select public_token from public.quotes where id = p_q
$$;
grant execute on function pg_temp.token(uuid) to anon, authenticated, service_role;
create function pg_temp.selfsched(p_q uuid) returns jsonb language sql security definer as $$
  select jsonb_build_object('due', d -> 'deposit_due_cents', 'pending', d -> 'payment_pending')
    from (select public.public_get_quote(pg_temp.token(p_q)) -> 'self_schedule' as d) x
$$;
grant execute on function pg_temp.selfsched(uuid) to anon;

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'))
  returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents, duration_minutes)
  values (tests.fx('shop_a'), tests.fx('q'), tests.fx('svc_a'), 'Full Detail', 20000, 120);
select public.mark_quote_sent(tests.fx('q'));
update public.quotes set status = 'approved', approved_by_name = 'Customer' where id = tests.fx('q');
select tests.as_anon();
select public.public_schedule_quote(pg_temp.token(tests.fx('q')), :'d' || 'T09:00:00') as r \gset
select tests.eq((:'r'::jsonb -> 'deposit_due_cents')::bigint, 11000::bigint, 'scheduled: 50% of 220.00 due');
select tests.as_superuser();
select tests.fx_set('jq', (select id from public.jobs where public_token = (:'r'::jsonb ->> 'job_token')::uuid));
-- staff bill it together with another job of the customer on a fleet invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), now() + interval '6 days', now() + interval '6 days 1 hour') returning tests.fx_set('jq2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('jq2'), 'Wash', 5000);
select tests.fx_set('invq', (public.create_invoice_from_jobs(tests.fx('cust_a'), array[tests.fx('jq'), tests.fx('jq2')])).id);
select tests.eq((select total_cents from public.invoices where id = tests.fx('invq')), 27500::bigint, 'fleet invoice 220.00 + 55.00');
select tests.as_anon();
select tests.eq(pg_temp.selfsched(tests.fx('q')), '{"due": 11000, "pending": false}'::jsonb, '/q: unpaid invoice, the deposit is still due');
-- a card payment of the whole invoice is on its way (no job_id): /q must not ask for the deposit
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fleetq1', 'pending', 27500, 0, 'payment', 'card',
                                    p_invoice_id => tests.fx('invq'), p_checkout_session_id => 'cs_fleetq1');
select tests.as_anon();
select tests.eq(pg_temp.selfsched(tests.fx('q')), '{"due": 11000, "pending": true}'::jsonb,
                '/q: a payment of the fleet invoice in flight counts as pending');
select tests.eq((public.public_get_booking((:'r'::jsonb ->> 'job_token')::uuid) -> 'deposit' -> 'payment_pending'), 'true'::jsonb,
                '(as on the booking page)');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fleetq1', 'failed', 27500, 0, 'payment', 'card',
                                    p_invoice_id => tests.fx('invq'), p_checkout_session_id => 'cs_fleetq1');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('invq'), 20000, 'check');
select tests.as_anon();
select tests.eq(pg_temp.selfsched(tests.fx('q')), '{"due": 7500, "pending": false}'::jsonb, '/q: capped at what the invoice still owes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('invq'), 7500, 'check');
select tests.as_anon();
select tests.eq(pg_temp.selfsched(tests.fx('q')), '{"due": 0, "pending": false}'::jsonb,
                '/q: no deposit due once the fleet invoice is paid in full');
select tests.eq((public.public_get_booking((:'r'::jsonb ->> 'job_token')::uuid) #>> '{deposit,due_cents}')::bigint, 0::bigint,
                'agreeing with the booking page it links');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.dep(tests.fx('jq')), '0/0/2', 'and with the staff summary');
