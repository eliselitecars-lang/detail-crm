-- 50 sched: the booking page (public_get_booking / booking_public_json, 0042)
-- for a job billed on a grouped invoice (P-7, money 0063) —
--   * the live invoice is found through invoice_jobs, so paid / balance come
--     from the grouped invoice (whose payments carry no job_id) and the
--     invoice block links it; a fully paid grouped invoice leaves nothing
--     to pay on either job's page;
--   * a deposit is never due beyond what the invoice still owes, and a
--     payment in flight on the grouped invoice shows as pending;
--   * a voided grouped invoice releases the job: the page falls back to the
--     job's own totals; single-job invoices keep working;
--   * the page is reachable only with the job's token; another shop's
--     booking is unaffected.
\ir fixtures/two_shops.psql
\ir fixtures/50_ranges.psql
-- grouped invoices are money's (0061-0063): with the scheduling range alone
-- (scripts/test_db.sh --ranges 0001-0059) there is nothing to test here
\if :has_money

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-01 15:00Z', '2025-07-01 17:00Z') returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j1'), 'A', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-02 15:00Z', '2025-07-02 17:00Z') returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j2'), 'B', 10000);
select tests.as_superuser();
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('j1');
select public_token as btok1 from public.jobs where id = tests.fx('j1') \gset
select public_token as btok2 from public.jobs where id = tests.fx('j2') \gset
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'deposit' ->> 'due_cents')::bigint, 5000::bigint,
                'before invoicing the deposit is due');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'invoice'), 'null'::jsonb, 'no invoice yet');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])).id);
select public.invoice_link_token(tests.fx('ginv')) as gtok \gset
select total_cents as gtotal, number as gnumber from public.invoices where id = tests.fx('ginv') \gset
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, :gtotal::bigint,
                'a job on an open grouped invoice shows the invoice''s balance');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'invoice' ->> 'token')::uuid, :'gtok'::uuid,
                'the invoice block links the grouped invoice');
select tests.eq(((public.public_get_booking(:'btok2'::uuid)) -> 'invoice' ->> 'number')::bigint,
                :gnumber::bigint, 'the other job links it too');

-- a payment in flight on the grouped invoice
select tests.as_superuser();
insert into public.payments (shop_id, invoice_id, customer_id, method, status, amount_cents, stripe_payment_intent_id)
  values (tests.fx('shop_a'), tests.fx('ginv'), tests.fx('cust_a3'), 'card', 'pending', 1000, 'pi_groupedOne1')
  returning tests.fx_set('pend', id);
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'deposit' ->> 'payment_pending')::boolean, true,
                'a payment in flight on the grouped invoice shows as pending (no second deposit charge)');
select tests.as_superuser();
delete from public.payments where id = tests.fx('pend');

-- a partial payment on the whole invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('ginv'), 4000, 'cash');
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'totals' ->> 'paid_cents')::bigint, 4000::bigint,
                'paid comes from the grouped invoice');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, :gtotal - 4000::bigint,
                'balance = invoice total - paid');

-- paid in full
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('ginv'), :gtotal - 4000, 'cash');
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, 0::bigint,
                'booking page: a job on a paid grouped invoice has nothing left to pay');
select tests.eq(((public.public_get_booking(:'btok2'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, 0::bigint,
                '... on either job''s page');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'deposit' ->> 'due_cents')::bigint, 0::bigint,
                'no deposit is due on a paid invoice');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'deposit' ->> 'status'), 'paid',
                'the deposit reads as settled');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'invoice' ->> 'status'), 'paid', 'the invoice is paid');
select tests.eq(((public.public_get_booking(:'btok1'::uuid)) -> 'totals' ->> 'total_cents')::bigint, 10000::bigint,
                'the page still shows the job''s own total');

-- ============================================================ a voided grouped invoice releases the job
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-03 15:00Z', '2025-07-03 17:00Z') returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'C', 7000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-04 15:00Z', '2025-07-04 17:00Z') returning tests.fx_set('j4', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j4'), 'D', 3000);
select tests.fx_set('ginv2', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j3'), tests.fx('j4')])).id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('ginv2'), 'billed separately');
select tests.as_superuser();
select public_token as btok3 from public.jobs where id = tests.fx('j3') \gset
select total_cents as j3total from public.jobs where id = tests.fx('j3') \gset
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok3'::uuid)) -> 'invoice'), 'null'::jsonb,
                'a voided grouped invoice is not linked');
select tests.eq(((public.public_get_booking(:'btok3'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, :j3total::bigint,
                'the released job shows its own total as due');

-- ============================================================ a single-job invoice still works
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('sinv', (public.create_invoice_from_job(tests.fx('j3'))).id);
select public.record_manual_payment(tests.fx('sinv'), 2000, 'cash');
select tests.as_anon();
select tests.as_superuser();
select balance_cents as sbal from public.invoices where id = tests.fx('sinv') \gset
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btok3'::uuid)) -> 'totals' ->> 'balance_cents')::bigint, :sbal::bigint,
                'a single-job invoice: the balance is the invoice''s');
select tests.eq(((public.public_get_booking(:'btok3'::uuid)) -> 'totals' ->> 'paid_cents')::bigint, 2000::bigint,
                'a single-job invoice: paid is the job''s payments');

-- ============================================================ isolation
select tests.throws($$select public.public_get_booking(gen_random_uuid())$$, 'PT404', 'unknown token');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.booking_public_json(tests.fx('j1'), now())$$, '42501',
                    'the page builder is internal');
select tests.as_superuser();
select public_token as btokb from public.jobs where id = tests.fx('job_b') \gset
select tests.as_anon();
select tests.eq(((public.public_get_booking(:'btokb'::uuid)) -> 'invoice'), 'null'::jsonb,
                'shop B''s booking knows nothing of shop A''s invoices');
\else
select tests.ok(not :'has_money'::boolean, 'SKIP (money range not applied): grouped-invoice booking pages');
\endif
