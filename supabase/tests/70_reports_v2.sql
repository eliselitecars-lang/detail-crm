-- 70 ops: reports v2 (P-28 job / service profit, P-33 lead sources and quote
-- conversion) — the math on a small data set, shop-local date and month
-- bucketing (a late-evening completion / quote / sign-up in Chicago belongs
-- to the local day), pay data (labor) for owners/admins only, technicians /
-- other shops / anon refused, range validation, two-shop isolation.
\ir fixtures/two_shops.psql

-- ============================================================ fixture (shop A, America/Chicago)
select tests.as_superuser();
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Wax job', 60) returning tests.fx_set('svc_wax', id);
insert into public.products (shop_id, name, unit, unit_cost_cents) values (tests.fx('shop_a'), 'Soap', 'oz', 50) returning tests.fx_set('soap', id);
insert into public.products (shop_id, name, unit, unit_cost_cents) values (tests.fx('shop_a'), 'Wax', 'oz', 200) returning tests.fx_set('wax', id);
insert into public.service_consumables (shop_id, service_id, product_id, quantity) values
  (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('soap'), 4),
  (tests.fx('shop_a'), tests.fx('svc_wax'), tests.fx('wax'), 2);
insert into public.member_compensation (shop_id, member_id, hourly_rate_cents) values (tests.fx('shop_a'), tests.fx('m_tech_a'), 3000);

-- J1 = job_a (cust_a): Full Detail 20000 + Wax job 10000, fixed discount 3000, completed Mar 10
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort, taxable)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('svc_wax'), 'Wax job', 10000, 1, true);
update public.jobs set discount_kind = 'fixed', discount_value = 3000 where id = tests.fx('job_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
update public.jobs set completed_at = '2025-03-10 18:00Z' where id = tests.fx('job_a');
insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in, clock_out, source)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), tests.fx('job_a'), 'job', '2025-03-10 14:00Z', '2025-03-10 16:00Z', 'manual');

-- customers created in March (and around its edges)
insert into public.customers (shop_id, first_name, source, lifecycle) values
  (tests.fx('shop_a'), 'Lead', 'google', 'lead') returning tests.fx_set('c_lead', id);
insert into public.customers (shop_id, first_name, source, lifecycle) values
  (tests.fx('shop_a'), 'Won', 'google', 'lead') returning tests.fx_set('c_won', id);
insert into public.customers (shop_id, first_name, source, lifecycle) values
  (tests.fx('shop_a'), 'Referred', 'referral', 'customer') returning tests.fx_set('c_ref', id);
insert into public.customers (shop_id, first_name, source, lifecycle) values
  (tests.fx('shop_a'), 'April', 'google', 'lead') returning tests.fx_set('c_april', id);
insert into public.customers (shop_id, first_name, source, lifecycle) values
  (tests.fx('shop_a'), 'Dupe', 'google', 'lead') returning tests.fx_set('c_dupe', id);
update public.customers set created_at = '2025-03-05 15:00Z' where id = tests.fx('c_lead');
update public.customers set created_at = '2025-03-06 15:00Z' where id in (tests.fx('c_won'), tests.fx('c_dupe'));
update public.customers set created_at = '2025-04-01 04:00Z' where id = tests.fx('c_ref');     -- Mar 31, 23:00 CDT
update public.customers set created_at = '2025-04-01 06:00Z' where id = tests.fx('c_april');   -- Apr 1, 01:00 CDT
update public.customers set archived_at = now(), merged_into_id = tests.fx('c_won') where id = tests.fx('c_dupe');

-- J2 (c_won): a custom line, completed Mar 31 23:30 CDT; J3 (c_won) completed in April
insert into public.jobs (shop_id, customer_id, status, cancel_reason) values (tests.fx('shop_a'), tests.fx('c_won'), 'requested', null)
  returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable) values (tests.fx('shop_a'), tests.fx('j2'), 'Custom', 5000, false);
update public.jobs set status = 'scheduled', scheduled_start = '2025-03-31 20:00Z', scheduled_end = '2025-03-31 21:00Z' where id = tests.fx('j2');
update public.jobs set status = 'completed' where id = tests.fx('j2');
update public.jobs set completed_at = '2025-04-01 04:30Z' where id = tests.fx('j2');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('c_won'), '2025-04-02 15:00Z', '2025-04-02 16:00Z') returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable) values (tests.fx('shop_a'), tests.fx('j3'), 'Custom', 7000, false);
update public.jobs set status = 'completed' where id = tests.fx('j3');
update public.jobs set completed_at = '2025-04-01 06:00Z' where id = tests.fx('j3');
insert into public.payments (shop_id, customer_id, method, status, amount_cents, tip_cents, refunded_cents, paid_at) values
  (tests.fx('shop_a'), tests.fx('c_won'), 'cash', 'partially_refunded', 4500, 500, 500, '2025-03-20 15:00Z'),
  (tests.fx('shop_a'), tests.fx('c_won'), 'cash', 'succeeded', 1000, 0, 0, '2025-04-05 15:00Z');

-- quotes sent Feb 28 (local) .. Apr 1 (local)
create temp table qs (key text, sent_at timestamptz, status public.quote_status, viewed_at timestamptz, approved_at timestamptz,
                      cents bigint);
insert into qs values
  ('q1', '2025-03-02 15:00Z', 'sent',      null,               null,               10000),
  ('q2', '2025-03-03 15:00Z', 'approved',  '2025-03-04 15:00Z', '2025-03-05 15:00Z', 20000),
  ('q3', '2025-03-10 15:00Z', 'converted', null,               '2025-03-11 15:00Z', 30000),
  ('q4', '2025-03-12 15:00Z', 'declined',  null,               null,                8000),
  ('q5', '2025-03-01 05:30Z', 'expired',   null,               null,                4000),   -- Feb 28, 23:30 CST
  ('q6', '2025-04-01 04:00Z', 'sent',      null,               null,                6000),   -- Mar 31, 23:00 CDT
  ('q7', '2025-04-01 06:00Z', 'sent',      null,               null,               99000),   -- Apr 1
  ('q8', null,                'draft',     null,               null,               99000);
do $$
declare
  r  record;
  v  uuid;
begin
  for r in select * from qs order by key loop
    insert into public.quotes (shop_id, customer_id, status, sent_at, viewed_at, approved_at, tax_rate_bps)
    values (tests.fx('shop_a'), tests.fx('cust_a'), r.status, r.sent_at, r.viewed_at, r.approved_at, 0)
    returning id into v;
    insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), v, 'Work', r.cents);
    perform tests.fx_set(r.key, v);
  end loop;
end
$$;
select tests.eq((select array_agg(total_cents order by sent_at nulls last) from public.quotes where shop_id = tests.fx('shop_a')),
                array[4000, 10000, 20000, 30000, 8000, 6000, 99000, 99000]::bigint[], 'quote fixture totals');

-- ============================================================ job profit
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(job_number = (select number from public.jobs where id = r.job_id), customer_label,
                                                    revenue_cents, materials_cents, labor_cents, profit_cents, margin_bps)
                                  order by completed_at)
                   from public.report_job_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31') r),
                '[[true, "Alice Anders", 27000, 600, 6000, 20400, 7556],
                  [true, "Won", 5000, 0, 0, 5000, 10000]]'::jsonb,
                'revenue net of the discount, materials at the cost when used, labor from job time (Mar 31 late evening is March)');
select tests.eq((select array_agg(job_id order by completed_at) from public.report_job_profit(tests.fx('shop_a'), '2025-04-01', '2025-04-30')),
                array[tests.fx('j3')], 'April holds only the April 1 (local) completion');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select labor_cents from public.report_job_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31') where job_id = tests.fx('job_a')),
                6000::bigint, 'admins see labor');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(revenue_cents, materials_cents, labor_cents, profit_cents, margin_bps) order by completed_at)
                   from public.report_job_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')),
                '[[27000, 600, null, null, null], [5000, 0, null, null, null]]'::jsonb,
                'managers get no pay data, so no profit either');

-- ============================================================ service profit
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(service_name, jobs_count, revenue_cents, materials_cents, gross_profit_cents, margin_bps)
                                  order by gross_profit_cents desc)
                   from public.report_service_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')),
                '[["Full Detail", 1, 18000, 200, 17800, 9889], ["Wax job", 1, 9000, 400, 8600, 9556]]'::jsonb,
                'per service: the discount spread by line (2000 / 1000), materials by the allocation; custom lines left out');
select tests.eq((select sum(revenue_cents) from public.report_service_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')), 27000::numeric,
                'service revenue adds up to the job''s catalog lines');

-- ============================================================ lead sources
select tests.eq((select jsonb_agg(jsonb_build_array(source, customers_count, leads_count, converted_count, first_job_revenue_cents, revenue_cents)
                                  order by source)
                   from public.report_lead_sources(tests.fx('shop_a'), '2025-03-01', '2025-03-31')),
                '[["referral", 1, 0, 1, 0, 0], ["google", 2, 1, 1, 5000, 4000]]'::jsonb,
                'sign-ups by source: open leads, conversions (lifecycle or a completed job), first-job and received revenue (tips, refunds and later payments excluded; merged duplicates left out)');
select tests.eq((select jsonb_agg(jsonb_build_array(source, customers_count, converted_count, first_job_revenue_cents, revenue_cents))
                   from public.report_lead_sources(tests.fx('shop_a'), '2025-04-01', '2025-04-30')),
                '[["google", 1, 0, 0, 0]]'::jsonb, 'April: one open lead');

-- ============================================================ quote conversion
select tests.eq(public.report_quote_conversion(tests.fx('shop_a'), '2025-02-01', '2025-03-31'),
                '{"sent": 6, "viewed": 1, "approved": 2, "declined": 1, "expired": 1, "converted": 1,
                  "conversion_rate_bps": 3333, "average_quote_cents": 13000, "average_approved_cents": 25000,
                  "median_hours_to_approve": 36.00,
                  "by_month": [{"month": "2025-02", "sent": 1, "approved": 0, "approved_cents": 0},
                               {"month": "2025-03", "sent": 5, "approved": 2, "approved_cents": 50000}]}'::jsonb,
                'counts, rates, averages, median and shop-local months');
select tests.eq(public.report_quote_conversion(tests.fx('shop_a'), '2024-01-01', '2024-01-31'),
                '{"sent": 0, "viewed": 0, "approved": 0, "declined": 0, "expired": 0, "converted": 0, "conversion_rate_bps": null,
                  "average_quote_cents": null, "average_approved_cents": null, "median_hours_to_approve": null,
                  "by_month": [{"month": "2024-01", "sent": 0, "approved": 0, "approved_cents": 0}]}'::jsonb,
                'an empty period');

-- ============================================================ access and ranges
select tests.throws($$select * from public.report_job_profit(tests.fx('shop_a'), '2025-03-31', '2025-03-01')$$, '22023', 'end before start');
select tests.throws($$select public.report_quote_conversion(tests.fx('shop_a'), null, '2025-03-01')$$, '22023', 'dates required');
select tests.throws($$select * from public.report_lead_sources(tests.fx('shop_a'), '2000-01-01', '2025-03-01')$$, '22023', 'ten years at most');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.report_job_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'technicians: job profit');
select tests.throws($$select * from public.report_service_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'service profit');
select tests.throws($$select * from public.report_lead_sources(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'lead sources');
select tests.throws($$select public.report_quote_conversion(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'quote conversion');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.report_job_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'another shop');
select tests.throws($$select public.report_quote_conversion(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'another shop''s quotes');
select tests.eq((select count(*) from public.report_job_profit(tests.fx('shop_b'), '2025-03-01', '2025-03-31')), 0::bigint,
                'shop B''s own report holds none of A''s jobs');
select tests.eq((public.report_quote_conversion(tests.fx('shop_b'), '2025-02-01', '2025-03-31') ->> 'sent')::integer, 0,
                'nor A''s quotes');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.report_lead_sources(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'outsiders');
select tests.as_anon();
select tests.throws($$select * from public.report_service_profit(tests.fx('shop_a'), '2025-03-01', '2025-03-31')$$, '42501', 'anon');
