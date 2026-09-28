-- 60 money: tips per technician, service / sales commissions, sold-by and
-- the earnings drill-down (P-12, 0065) — report_team v2 columns, even
-- splits with remainders, tips net of refunds and never revenue, grouped
-- invoice tip split by job totals, service percent / flat commissions
-- replacing the member commission, sales commission to the seller,
-- report_member_earnings summing to report_team, role visibility, sold_by
-- defaults and guards, service commission settings (owners/admins only).
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.member_compensation (shop_id, member_id, hourly_rate_cents, commission_bps, sales_commission_bps) values
  (tests.fx('shop_a'), tests.fx('m_tech_a'), 2000, 1000, 500),
  (tests.fx('shop_a'), tests.fx('m_tech2_a'), 0, 750, 0),
  (tests.fx('shop_a'), tests.fx('m_manager_a'), 0, 0, 1000);
insert into public.services (shop_id, name, commission_kind, commission_value) values
  (tests.fx('shop_a'), 'Ceramic', 'percent', 2000) returning tests.fx_set('svc_ceramic', id);
insert into public.services (shop_id, name, commission_kind, commission_value) values
  (tests.fx('shop_a'), 'Tint', 'flat', 1500) returning tests.fx_set('svc_tint', id);

-- J1 (cust_a): assigned tech (first) + tech2, sold by the manager. Full Detail 20000, Ceramic 10001,
-- Tint 2 x 3000; $10 off. Discount allocated in line order: 556 / 277 / 167 -> nets 19444 / 9724 / 5833.
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, discount_kind, discount_value, sold_by_member_id)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-03-10 14:00Z', '2025-03-10 16:00Z', '2025-03-10 16:00Z',
          'fixed', 1000, tests.fx('m_manager_a')) returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, quantity, unit_price_cents, sort) values
  (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_a'), 'Full Detail', 1, 20000, 1),
  (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_ceramic'), 'Ceramic', 1, 10001, 2),
  (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_tint'), 'Tint', 2, 3000, 3);
insert into public.job_assignments (shop_id, job_id, member_id, created_at) values
  (tests.fx('shop_a'), tests.fx('j1'), tests.fx('m_tech_a'), '2025-03-01Z'),
  (tests.fx('shop_a'), tests.fx('j1'), tests.fx('m_tech2_a'), '2025-03-02Z');
-- J2 (Fleet Co): tech only, sold by tech; J3 (Fleet Co): tech2 only, no seller
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, sold_by_member_id)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'completed', '2025-03-11 14:00Z', '2025-03-11 16:00Z', '2025-03-11 16:00Z',
          tests.fx('m_tech_a')) returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('j2'), tests.fx('svc_a'), 'Full Detail', 10000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j2'), tests.fx('m_tech_a'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'completed', '2025-03-12 14:00Z', '2025-03-12 16:00Z', '2025-03-12 16:00Z')
  returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'Coating', 30000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j3'), tests.fx('m_tech2_a'));
-- time: tech worked 2 h on J1
insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in, clock_out, source)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), tests.fx('j1'), 'job', '2025-03-10 14:00Z', '2025-03-10 16:00Z', 'manual');

-- money: J1 invoice paid by card with a 10.01 tip, plus cash 50.00 + 3.00 tip refunded 51.00 (net tip 2.00);
-- J2 + J3 on one grouped invoice, paid 10.00 + 10.01 tip for the whole invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv1', (public.create_invoice_from_job(tests.fx('j1'))).id);
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j2'), tests.fx('j3')])).id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tip1', 'succeeded', 20000, 1001, 'payment', 'card', p_invoice_id => tests.fx('inv1'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('cash1', (public.record_manual_payment(tests.fx('inv1'), 5000, 'cash', 300)).id);
select public.record_manual_payment(tests.fx('ginv'), 1000, 'cash', 1001);
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.refund_manual_payment(tests.fx('cash1'), 5100);

-- ============================================================ report_team v2 (owner)
select tests.authenticate_as(tests.fx('u_owner_a'));
create temp table rt as
  select * from public.report_team(tests.fx('shop_a'), '2025-03-01', '2025-03-31', '2025-04-01Z');
grant select on rt to authenticated;
select tests.eq((select jsonb_build_array(jobs_completed, revenue_cents, pre_tax_revenue_cents, commission_cents, service_commission_cents,
                                          sales_commission_cents, tips_cents, labor_cost_cents, total_earnings_cents)
                   from rt where member_id = tests.fx('m_tech_a')),
                '[2, 27501, 27501, 1972, 2473, 500, 851, 4000, 9796]'::jsonb,
                'tech: J1 half (+ the odd cents) and J2; member commission only on non-commissioned lines '
                || '(9722 + 10000) x 10%; service commission 20% x 9724 + 2 x 1500 halved; sales 5% of J2; '
                || 'tips 1201/2 + 250 (grouped tip split by job totals)');
select tests.eq((select jsonb_build_array(jobs_completed, revenue_cents, commission_cents, service_commission_cents,
                                          sales_commission_cents, tips_cents, total_earnings_cents)
                   from rt where member_id = tests.fx('m_tech2_a')),
                '[2, 47500, 2979, 2472, 0, 1351, 6802]'::jsonb,
                'tech2: (9722 + 30000) x 7.5% = 2979; tips 600 + 751 (the grouped tip''s odd cent goes to the larger job)');
select tests.eq((select jsonb_build_array(jobs_completed, revenue_cents, sales_commission_cents, tips_cents, total_earnings_cents)
                   from rt where member_id = tests.fx('m_manager_a')),
                '[0, 0, 3500, 0, 3500]'::jsonb, 'the seller of J1 earns 10% of its pre-tax revenue 35001 = 3500');
select tests.eq((select sum(revenue_cents) from rt), (select sum(total_cents) from public.jobs where id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'))),
                'tips are never revenue: attributed revenue = job totals');
select tests.eq((select sum(tips_cents) from rt), 2202::numeric,
                'all tips attributed: 1001 + (300 - 100 refunded) + 1001');
select tests.eq((select count(*) from rt where total_earnings_cents is distinct from
                   labor_cost_cents + commission_cents + service_commission_cents + sales_commission_cents + tips_cents), 0::bigint,
                'earnings add up');

-- ============================================================ report_member_earnings (drill-down)
select tests.eq((select jsonb_agg(jsonb_build_array(job_number, hours, revenue_share_cents, commission_cents, service_commission_cents,
                                                    sales_commission_cents, tips_cents) order by completed_at)
                   from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')),
                (select jsonb_build_array(jsonb_build_array((select number from public.jobs where id = tests.fx('j1')), 2.00, 17501, 972, 2473, 0, 601),
                                          jsonb_build_array((select number from public.jobs where id = tests.fx('j2')), 0, 10000, 1000, 0, 500, 250))),
                'per-job rows: the rounded commission is allocated cumulatively (972 + 1000 = 1972)');
select tests.ok((select bool_and(e.rev = r.pre_tax_revenue_cents and e.comm = r.commission_cents and e.svc = r.service_commission_cents
                                 and e.sales = r.sales_commission_cents and e.tips = r.tips_cents)
                 from rt r
                 cross join lateral (select coalesce(sum(x.revenue_share_cents), 0) as rev, coalesce(sum(x.commission_cents), 0) as comm,
                                            coalesce(sum(x.service_commission_cents), 0) as svc,
                                            coalesce(sum(x.sales_commission_cents), 0) as sales, coalesce(sum(x.tips_cents), 0) as tips
                                       from public.report_member_earnings(tests.fx('shop_a'), r.member_id, '2025-03-01', '2025-03-31') x) e),
                'every member''s drill-down adds up to their report_team row');
select tests.eq((select customer_label from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-03-01', '2025-03-31')
                  where job_id = tests.fx('j3')), 'Fleet Co', 'customer label');
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_b'), '2025-03-01', '2025-03-31')$$,
                    'P0002', 'another shop''s member: not found');
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-31', '2025-03-01')$$,
                    '22023', 'bad range');

-- ============================================================ visibility
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select total_earnings_cents from public.report_team(tests.fx('shop_a'), '2025-03-01', '2025-03-31', '2025-04-01Z')
                  where member_id = tests.fx('m_tech_a')), 9796::bigint, 'admins see pay');
select tests.eq((select count(*) from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-03-01', '2025-03-31')),
                2::bigint, 'admins drill into anyone');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.report_team(tests.fx('shop_a'), '2025-03-01', '2025-03-31', '2025-04-01Z')
                  where tips_cents is not null or service_commission_cents is not null or sales_commission_cents is not null
                     or total_earnings_cents is not null), 0::bigint, 'managers get no pay columns');
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'managers cannot drill into another member''s pay');
select tests.eq((select sum(sales_commission_cents) from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_manager_a'), '2025-03-01', '2025-03-31')),
                3500::numeric, 'but may see their own');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(member_id, tips_cents, total_earnings_cents))
                   from public.report_team(tests.fx('shop_a'), '2025-03-01', '2025-03-31', '2025-04-01Z')),
                jsonb_build_array(jsonb_build_array(tests.fx('m_tech_a'), 851, 9796)), 'technicians: own row with own pay');
select tests.eq((select count(*) from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')),
                2::bigint, 'and their own drill-down');
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'never a colleague''s');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'other shops: not a member');
select tests.throws($$select * from public.report_team_job_rows(tests.fx('shop_a'), '2025-03-01Z', '2025-04-01Z')$$,
                    '42501', 'the row helper is internal');
select tests.as_anon();
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'anon cannot call it');

-- ============================================================ sold_by
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested')
  returning tests.fx_set('j_new', id);
select tests.eq((select sold_by_member_id from public.jobs where id = tests.fx('j_new')), tests.fx('m_manager_a'),
                'a staff-created job is sold by its creator');
insert into public.jobs (shop_id, customer_id, status, sold_by_member_id)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('m_tech2_a')) returning tests.fx_set('j_given', id);
select tests.eq((select sold_by_member_id from public.jobs where id = tests.fx('j_given')), tests.fx('m_tech2_a'),
                'an explicit seller is kept');
select tests.lives($$update public.jobs set sold_by_member_id = tests.fx('m_tech_a') where id = tests.fx('j_new')$$,
                   'managers may change the seller');
select tests.throws($$update public.jobs set sold_by_member_id = tests.fx('m_tech_b') where id = tests.fx('j_new')$$, '23503',
                    'composite FK: another shop''s member');
select tests.as_superuser();
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j_new'), tests.fx('m_tech_a'));
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set sold_by_member_id = tests.fx('m_tech2_a') where id = tests.fx('j_new')$$, '42501',
                    'technicians cannot change the seller');
select tests.as_service();
insert into public.jobs (shop_id, customer_id, status, source) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', 'online_booking')
  returning tests.fx_set('j_online', id);
select tests.eq((select sold_by_member_id from public.jobs where id = tests.fx('j_online')), null::uuid, 'online bookings have no seller');
-- a quote conversion credits the quote's creator
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q'), 'Wash', 3000);
select public.mark_quote_sent(tests.fx('q'));
update public.quotes set status = 'approved' where id = tests.fx('q');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.convert_quote_to_job(tests.fx('q'))).sold_by_member_id, tests.fx('m_manager_a'),
                'converting a quote credits the member who wrote it, not the converter');
select tests.as_superuser();
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'sold_by_member_id', 'select'), 'sold_by is readable by staff');

-- ============================================================ commission settings
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.services set commission_kind = 'percent', commission_value = 500 where id = tests.fx('svc_a')$$,
                         '42501', '%owners and admins%', 'managers edit services but not their commission');
select tests.throws($$insert into public.services (shop_id, name, commission_kind, commission_value)
                      values (tests.fx('shop_a'), 'Sneaky', 'flat', 100)$$, '42501', 'nor create one with a commission');
select tests.lives($$update public.services set name = 'Full Detail+' where id = tests.fx('svc_a')$$, 'other service edits still work');
select tests.eq(tests.row_count($$update public.member_compensation set sales_commission_bps = 100 where member_id = tests.fx('m_tech_a')$$),
                0::bigint, 'managers cannot set pay (compensation is owner/admin only)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.services set commission_kind = 'flat', commission_value = 250 where id = tests.fx('svc_a')$$,
                   'admins set service commissions');
select tests.throws($$update public.services set commission_kind = 'percent', commission_value = 10001 where id = tests.fx('svc_a')$$,
                    '23514', 'percent commission <= 100%');
select tests.throws($$update public.services set commission_kind = 'none', commission_value = 5 where id = tests.fx('svc_a')$$,
                    '23514', 'no value without a kind');
select tests.throws($$update public.services set commission_kind = 'flat', commission_value = -1 where id = tests.fx('svc_a')$$,
                    '23514', 'flat commission >= 0');
select tests.throws($$update public.member_compensation set sales_commission_bps = 10001 where member_id = tests.fx('m_tech_a')$$,
                    '23514', 'sales commission <= 100%');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select sales_commission_bps from public.member_compensation where member_id = tests.fx('m_tech_a')), 500,
                'technicians read their own sales commission rate');
select tests.eq((select count(*) from public.member_compensation where member_id = tests.fx('m_tech2_a')), 0::bigint,
                'not a colleague''s');
