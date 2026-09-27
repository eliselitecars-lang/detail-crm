-- 00 foundation: canonical document totals (SPEC §4.5) — pure function edge
-- cases and the server-maintained job totals.

-- helper: totals as 'subtotal/discount/tax/total'
create function pg_temp.t(p_lines jsonb, p_kind public.discount_kind default 'none', p_value bigint default 0, p_bps integer default 0)
returns text language sql as $$
  select concat_ws('/', r.subtotal_cents, r.discount_cents, r.tax_cents, r.total_cents)
  from public.compute_document_totals(p_lines, p_kind, p_value, p_bps) r
$$;

-- ------------------------------------------------------------ line totals
select tests.eq(public.line_total_cents(1.5, 999, 0), 1499::bigint, '1.5 x 999 = 1498.5 rounds half up to 1499');
select tests.eq(public.line_total_cents(0.01, 50, 0), 1::bigint, '0.01 x 50 = 0.5 rounds to 1');
select tests.eq(public.line_total_cents(0.01, 49, 0), 0::bigint, '0.01 x 49 = 0.49 rounds to 0');
select tests.eq(public.line_total_cents(2.5, 333, 0), 833::bigint, '2.5 x 333 = 832.5 rounds to 833');
select tests.eq(public.line_total_cents(1, 100, 150), 0::bigint, 'line discount larger than the line clamps at 0');
select tests.eq(public.line_total_cents(3, 1000, 250), 2750::bigint, 'line discount subtracts after rounding');

-- ------------------------------------------------------------ document totals
select tests.eq(pg_temp.t('[]'), '0/0/0/0', 'no lines');
select tests.eq(pg_temp.t(null), '0/0/0/0', 'null lines treated as empty');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":10000}]', 'none', 0, 800), '10000/0/800/10800', 'simple taxable line');
select tests.eq(pg_temp.t('[{"unit_price_cents":10000}]'), '10000/0/0/10000', 'quantity defaults to 1, taxable to true, tax 0');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":10000,"taxable":true},
                            {"quantity":1,"unit_price_cents":5000,"taxable":false}]', 'percent', 1000, 825),
                '15000/1500/743/14243',
                'percent discount prorated to taxable lines; tax 742.5 rounds half up');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":5000}]', 'fixed', 99999, 1000), '5000/5000/0/0',
                'fixed discount capped at subtotal');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":5000}]', 'percent', 10000, 1000), '5000/5000/0/0', '100% discount');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":1005}]', 'percent', 5000, 0), '1005/503/0/502',
                'percent discount 502.5 rounds half up');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":3333,"taxable":true},
                            {"quantity":1,"unit_price_cents":3333,"taxable":false},
                            {"quantity":1,"unit_price_cents":3334,"taxable":true}]', 'fixed', 1001, 1000),
                '10000/1001/600/9599',
                'taxable discount = round(1001 x 6667 / 10000) = 667; tax on 6000');
select tests.eq((select taxable_subtotal_cents || '/' || taxable_discount_cents
                   from public.compute_document_totals('[{"quantity":1,"unit_price_cents":3333,"taxable":true},
                            {"quantity":1,"unit_price_cents":3333,"taxable":false},
                            {"quantity":1,"unit_price_cents":3334,"taxable":true}]', 'fixed', 1001, 1000)),
                '6667/667', 'taxable subtotal and prorated discount exposed');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":5,"taxable":true}]', 'none', 0, 1000), '5/0/1/6', 'tax 0.5 rounds up to 1');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":15}]', 'none', 0, 1000), '15/0/2/17', 'tax 1.5 rounds up to 2');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":14}]', 'none', 0, 1000), '14/0/1/15', 'tax 1.4 rounds down to 1');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":10000,"taxable":false}]', 'none', 0, 1000), '10000/0/0/10000',
                'non-taxable lines carry no tax');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":0}]', 'fixed', 500, 1000), '0/0/0/0',
                'zero subtotal: discount capped at 0, no division by zero');
select tests.eq(pg_temp.t('[{"quantity":2.5,"unit_price_cents":333,"discount_cents":33,"taxable":true},
                            {"quantity":0.75,"unit_price_cents":1999,"taxable":true}]', 'percent', 1250, 700),
                '2299/287/141/2153',
                'decimal quantities: (833-33) + 1499 = 2299; 12.5% = 287.375 -> 287; 7% of 2012 = 140.84 -> 141');
select tests.eq(pg_temp.t('[{"quantity":1,"unit_price_cents":1000}]', 'none', 700, 0), '1000/0/0/1000',
                'discount kind none ignores the value');

-- validation
select tests.throws($$select public.compute_document_totals('{"a":1}')$$, '22023', 'lines must be an array');
select tests.throws($$select public.compute_document_totals('[1]')$$, '22023', 'each line must be an object');
select tests.throws($$select public.compute_document_totals('[{"unit_price_cents":-1}]')$$, '22023', 'negative price');
select tests.throws($$select public.compute_document_totals('[{"quantity":1}]')$$, '22023', 'missing price');
select tests.throws($$select public.compute_document_totals('[{"quantity":0,"unit_price_cents":1}]')$$, '22023', 'zero quantity');
select tests.throws($$select public.compute_document_totals('[{"unit_price_cents":1,"discount_cents":-1}]')$$, '22023', 'negative line discount');
select tests.throws($$select public.compute_document_totals('[]', 'percent', 10001, 0)$$, '22023', 'percent over 100%');
select tests.throws($$select public.compute_document_totals('[]', 'fixed', -1, 0)$$, '22023', 'negative discount');
select tests.throws($$select public.compute_document_totals('[]', 'none', 0, 10001)$$, '22023', 'tax over 100%');
select tests.throws($$select public.compute_document_totals('[]', 'none', 0, -1)$$, '22023', 'negative tax');

-- ------------------------------------------------------------ job totals (server-maintained)
\ir fixtures/two_shops.psql
select tests.as_superuser();
update public.shops set tax_rate_bps = 825 where id = tests.fx('shop_a');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, subtotal_cents, total_cents, tax_cents)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-01 15:00Z', '2025-07-01 16:00Z', 999999, 999999, 5)
  returning tests.fx_set('job_t', id);
select tests.eq((select tax_rate_bps from public.jobs where id = tests.fx('job_t')), 825, 'new job tax rate defaults from the shop');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '0/0/0/0', 'client-sent totals are ignored on insert');

insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('job_t'), 'Paint correction', 1, 10000, true)
  returning tests.fx_set('lt1', id);
insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('job_t'), 'Tire shine', 1, 5000, false)
  returning tests.fx_set('lt2', id);
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '15000/0/825/15825', 'totals follow inserted lines');
select tests.eq((select total_cents from public.job_line_items where id = tests.fx('lt1')), 10000::bigint, 'line total_cents generated');

update public.jobs set discount_kind = 'percent', discount_value = 1000 where id = tests.fx('job_t');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '15000/1500/743/14243', 'document discount applied and prorated');

update public.job_line_items set quantity = 2 where id = tests.fx('lt2');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '20000/2000/743/18743', 'updating a line recomputes');

update public.jobs set subtotal_cents = 1, discount_cents = 0, tax_cents = 0, total_cents = 1 where id = tests.fx('job_t');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '20000/2000/743/18743', 'client writes to computed columns are overwritten');

update public.jobs set tax_rate_bps = 0 where id = tests.fx('job_t');
select tests.eq((select tax_cents from public.jobs where id = tests.fx('job_t')), 0::bigint, 'tax-exempt job (rate 0)');
update public.jobs set tax_rate_bps = 825, discount_kind = 'fixed', discount_value = 50000 where id = tests.fx('job_t');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '20000/20000/0/0', 'fixed discount capped at subtotal on jobs');

delete from public.job_line_items where id = tests.fx('lt2');
update public.jobs set discount_kind = 'none', discount_value = 0 where id = tests.fx('job_t');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_t')),
                '10000/0/825/10825', 'deleting a line recomputes');

-- moving a line to another job recomputes both
update public.job_line_items set job_id = tests.fx('job_a') where id = tests.fx('lt1');
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_t')), 0::bigint, 'source job recomputed after move');
select tests.eq((select subtotal_cents from public.jobs where id = tests.fx('job_a')), 30000::bigint, 'target job recomputed after move');

select tests.throws($$update public.jobs set discount_kind = 'none', discount_value = 5 where id = tests.fx('job_t')$$, '23514',
                    'discount value must be 0 when kind is none');
select tests.throws($$update public.jobs set discount_kind = 'percent', discount_value = 10001 where id = tests.fx('job_t')$$, '22023',
                    'percent discount <= 100% (rejected by the totals trigger before the CHECK)');
select tests.throws($$update public.jobs set tax_rate_bps = 10001 where id = tests.fx('job_t')$$, '22023', 'tax rate <= 100%');
select tests.throws($$update public.jobs set discount_kind = 'fixed', discount_value = -1 where id = tests.fx('job_t')$$, '22023',
                    'negative discount rejected');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('job_t'), 'Neg', 1, -5)$$, '23514', 'negative unit price rejected');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('job_t'), 'Zero qty', 0, 5)$$, '23514', 'zero quantity rejected');
select tests.throws($$update public.job_line_items set total_cents = 1 where id = tests.fx('lt1')$$, '428C9', 'line total is generated');

-- the computed values always equal the pure function over the job's lines
select tests.as_superuser();
select tests.ok((select bool_and(j.subtotal_cents = r.subtotal_cents and j.discount_cents = r.discount_cents
                                 and j.tax_cents = r.tax_cents and j.total_cents = r.total_cents)
                 from public.jobs j
                 cross join lateral public.compute_document_totals(
                   (select coalesce(jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                                 'discount_cents', li.discount_cents, 'taxable', li.taxable)), '[]')
                      from public.job_line_items li where li.job_id = j.id),
                   j.discount_kind, j.discount_value, j.tax_rate_bps) r),
                'every job''s stored totals match compute_document_totals');
