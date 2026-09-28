-- 60 money: a billed job's price is frozen (0097).
-- Regression: once a job had a live invoice (single-job or grouped), managers
-- could still add, reprice and delete its lines and change its document
-- discount. The invoice kept the lines it copied, so work added after
-- invoicing was never billed (job_payment_summary: paid, balance 0;
-- unbilled_jobs: nothing) and report_team paid commission on the job's new
-- total (110000 revenue / 11000 commission vs 20000 billed).
--   * while the job has a live invoice (open, paid, draft; single or
--     grouped): no line inserted / deleted, no change to a line's quantity,
--     price, discount, taxable or job; no change to the job's discount or
--     tax rate — through PostgREST or RPCs (add_fee_line) — 23514
--   * names, descriptions, durations and sort order stay editable
--   * voiding (or deleting a draft) releases the job
--   * unbilled jobs, other shops and cascades are unaffected
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, sort)
  values (tests.fx('shop_a'), 'Travel', 2500, 'none', 1) returning tests.fx_set('fee_travel', id);

create function pg_temp.job_total(p_job uuid) returns bigint language sql security definer as $$
  select total_cents from public.jobs where id = p_job
$$;
grant execute on function pg_temp.job_total(uuid) to authenticated;

-- ============================================================ the reported case: a paid single-job invoice
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.record_manual_payment(tests.fx('inv'), 20000, 'cash');
select tests.as_superuser();
select tests.eq((select status::text || '/' || total_cents || '/' || balance_cents from public.invoices where id = tests.fx('inv')),
                'paid/20000/0', 'setup: the job''s invoice is paid in full');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('job_a'), 'Ceramic coating', 90000)$$,
                         '23514', '%billed on invoice #%', 'no line can be added to a billed job');
select tests.throws_like($$update public.job_line_items set unit_price_cents = unit_price_cents + 5000
                           where id = tests.fx('line_a')$$,
                         '23514', '%billed on invoice #%', 'its lines cannot be repriced');
select tests.throws($$update public.job_line_items set quantity = 2 where id = tests.fx('line_a')$$, '23514',
                    'nor their quantity');
select tests.throws($$update public.job_line_items set taxable = not taxable where id = tests.fx('line_a')$$, '23514',
                    'nor whether they are taxed');
select tests.throws($$update public.job_line_items set discount_cents = 1000 where id = tests.fx('line_a')$$, '23514',
                    'nor their line discount');
select tests.throws($$update public.job_line_items set job_id = tests.fx('job_a2') where id = tests.fx('line_a')$$, '23514',
                    'nor moved to another job');
select tests.throws($$delete from public.job_line_items where id = tests.fx('line_a')$$, '23514',
                    'nor deleted');
select tests.throws_like($$update public.jobs set discount_kind = 'percent', discount_value = 5000 where id = tests.fx('job_a')$$,
                         '23514', '%billed on invoice #%', 'the job''s discount cannot change');
select tests.throws($$update public.jobs set tax_rate_bps = 900 where id = tests.fx('job_a')$$, '23514',
                    'nor its tax rate');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('job_a'), tests.fx('fee_travel'))$$,
                         '23514', '%billed on invoice #%', 'nor can a fee be added through the RPC');
-- what does not change the price stays editable
select tests.eq(tests.row_count($$update public.job_line_items
                                   set name = 'Full Detail (interior focus)', description = 'Seats shampooed',
                                       duration_minutes = 150, sort = 3
                                 where id = tests.fx('line_a')$$), 1::bigint,
                'name, description, duration and sort order stay editable');
select tests.eq(tests.row_count($$update public.jobs set notes = 'Back gate', status = 'in_progress' where id = tests.fx('job_a')$$),
                1::bigint, 'as does the rest of the job');
select tests.as_superuser();
select tests.eq(pg_temp.job_total(tests.fx('job_a')), 20000::bigint, 'the job total still equals what was billed');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select total_cents || '/' || balance_cents || '/' || invoice_status::text
                   from public.job_payment_summary(tests.fx('job_a'))), '20000/0/paid',
                'and the job''s payment summary is that invoice');

-- the owner and admin are held to it too; a technician cannot write lines at all
select tests.throws($$delete from public.job_line_items where id = tests.fx('line_a')$$, '23514', 'the owner too');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 1 where id = tests.fx('line_a')$$),
                0::bigint, 'a technician cannot touch the lines (RLS)');
-- server code (service role) is held to it as well
select tests.as_service();
select tests.throws($$update public.job_line_items set unit_price_cents = 1 where id = tests.fx('line_a')$$, '23514',
                    'every writer, not only PostgREST');

-- ============================================================ open invoice: void releases the job
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 5000) returning tests.fx_set('line_a2', id);
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 6000 where id = tests.fx('line_a2')$$),
                1::bigint, 'an unbilled job''s lines are editable');
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.throws($$update public.job_line_items set unit_price_cents = 7000 where id = tests.fx('line_a2')$$, '23514',
                    'an open (unpaid) invoice freezes the job too');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv2'), 'Re-quote');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 7000 where id = tests.fx('line_a2')$$),
                1::bigint, 'voiding the invoice releases the job');
select tests.eq(tests.row_count($$update public.jobs set discount_kind = 'fixed', discount_value = 500 where id = tests.fx('job_a2')$$),
                1::bigint, 'including its discount');
select tests.eq(pg_temp.job_total(tests.fx('job_a2')), 6500::bigint, 'and the job reprices');

-- ============================================================ grouped invoice
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-01 15:00Z', '2025-07-01 16:00Z') returning tests.fx_set('g1', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-02 15:00Z', '2025-07-02 16:00Z') returning tests.fx_set('g2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('g1'), 'Fleet wash', 4000), (tests.fx('shop_a'), tests.fx('g2'), 'Fleet wash', 4000);
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('g1'), tests.fx('g2')])).id);
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('g2'), 'Tire shine', 1500)$$,
                         '23514', '%billed on invoice #%', 'a job on a grouped invoice is frozen');
select tests.throws($$update public.jobs set discount_kind = 'percent', discount_value = 1000 where id = tests.fx('g1')$$, '23514',
                    'every job of the group');
select tests.eq((select count(*) from public.unbilled_jobs(tests.fx('cust_a3'))), 0::bigint,
                'setup: both jobs are billed');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('ginv'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
                                  values (tests.fx('shop_a'), tests.fx('g2'), 'Tire shine', 1500)$$), 1::bigint,
                'voiding the grouped invoice releases its jobs');

-- ============================================================ isolation and cascades
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 5500 where id = tests.fx('line_b')$$),
                1::bigint, 'another shop''s unbilled job is unaffected');
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 1 where id = tests.fx('line_a')$$),
                0::bigint, 'and shop B cannot reach shop A''s lines');
-- deleting a shop removes its billed jobs' lines with it
select tests.as_superuser();
select tests.lives($$delete from public.shops where id = tests.fx('shop_a')$$,
                   'a cascade delete of the shop is not blocked by the freeze');
select tests.eq((select count(*) from public.job_line_items where shop_id = tests.fx('shop_a')), 0::bigint,
                'its lines are gone');
