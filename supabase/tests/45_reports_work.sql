-- 45 reports: report_sales_by_service, report_team, report_customers —
-- completed-job (accrual) basis in shop time, discount allocation, even
-- revenue splits with remainders, hours from clipped/unioned time entries,
-- compensation visibility per role (manager: no pay; technician: own row),
-- validation and isolation. Data: fixtures/45_reports_seed.psql.
\ir fixtures/45_reports_seed.psql

-- ============================================================ report_sales_by_service
select tests.authenticate_as(tests.fx('ru_manager_a'));
-- March completed jobs: 1002 (03-03) and 1003 (03-05 05:30Z = 03-04 23:30 CST).
-- 1002 fixed discount 2900 over subtotal 28000, allocated cumulatively in line order:
--   Full Detail 20000: round(2900·20000/28000) = 2071            -> net 17929
--   Pet Hair    5000:  round(2900·25000/28000) = 2589 − 2071 = 518 -> net 4482
--   Headlight   1500×2 = 3000: 2900 − 2589 = 311                -> net 2689
-- 1003 Ceramic 100000, no discount.
select tests.eq(
  (select jsonb_agg(jsonb_build_object('service_id', r.service_id, 'name', r.service_name, 'kind', r.service_kind,
                                       'category_id', r.category_id, 'category', r.category_name,
                                       'qty', r.quantity, 'jobs', r.jobs_count, 'gross', r.gross_cents,
                                       'discount', r.discount_cents, 'net', r.net_cents) order by ord)
     from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-01', '2025-03-31') with ordinality as r (
            service_id, service_name, service_kind, category_id, category_name, quantity, jobs_count,
            gross_cents, discount_cents, net_cents, ord)),
  jsonb_build_array(
    jsonb_build_object('service_id', tests.fx('rs_ceramic'), 'name', 'Ceramic Coating', 'kind', 'service',
                       'category_id', tests.fx('rcat_pro'), 'category', 'Protection',
                       'qty', 1.00, 'jobs', 1, 'gross', 100000, 'discount', 0, 'net', 100000),
    jsonb_build_object('service_id', tests.fx('rs_full'), 'name', 'Full Detail', 'kind', 'service',
                       'category_id', tests.fx('rcat_ext'), 'category', 'Exterior',
                       'qty', 1.00, 'jobs', 1, 'gross', 20000, 'discount', 2071, 'net', 17929),
    jsonb_build_object('service_id', tests.fx('rs_pet'), 'name', 'Pet Hair Removal', 'kind', 'addon',
                       'category_id', null, 'category', null,
                       'qty', 1.00, 'jobs', 1, 'gross', 5000, 'discount', 518, 'net', 4482),
    jsonb_build_object('service_id', null, 'name', 'Headlight Polish', 'kind', null,
                       'category_id', null, 'category', null,
                       'qty', 2.00, 'jobs', 1, 'gross', 3000, 'discount', 311, 'net', 2689)),
  'March sales by service, ordered by net, custom lines by name');
-- allocated discounts add up exactly to the job discount; net = pre-tax revenue of the jobs
select tests.eq((select sum(discount_cents) from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')),
                2900::numeric, 'allocated discount equals the document discount');
select tests.eq((select sum(net_cents) from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')),
                (select sum(subtotal_cents - discount_cents) from public.jobs
                  where shop_id = tests.fx('rshop_a') and number in (1002, 1003))::numeric,
                'sales net = completed jobs pre-tax revenue (125100)');
-- Feb + March: Full Detail from 1001 (20000) and 1002 (17929)
select tests.eq(
  (select jsonb_build_array(r.quantity, r.jobs_count, r.gross_cents, r.discount_cents, r.net_cents)
     from public.report_sales_by_service(tests.fx('rshop_a'), '2025-02-01', '2025-03-31') r
    where r.service_id = tests.fx('rs_full')),
  '[2.00, 2, 40000, 2071, 37929]'::jsonb, 'Full Detail across two jobs');
-- the local day of 1003's completion is 03-04, not 03-05
select tests.eq((select count(*) from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-05', '2025-03-05')),
                0::bigint, 'nothing completed on 03-05 locally');
select tests.eq((select service_name from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-04', '2025-03-04')),
                'Ceramic Coating', '1003 completed on 03-04 locally');
-- in-progress / scheduled / cancelled jobs never count
select tests.eq((select count(*) from public.report_sales_by_service(tests.fx('rshop_a'), '2025-03-05', '2025-03-11')),
                0::bigint, 'only completed jobs count');
select tests.throws(format('select * from public.report_sales_by_service(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-02', '2025-03-01'),
                    '22023', 'sales: bad range rejected');

-- ============================================================ report_team
-- March (p_now 03-05 16:00Z caps open entries); see the seed for the entries.
--   tech1: 1h (03-01 06:00-07:00Z) + 8h + 2h (job without shift) + 2.5h (open) = 13.5h = 48600 s
--          jobs 1002 + 1003; revenue 26749/2 -> 13375 (first assignee gets the odd cent) + 108000/3 = 36000 -> 49375
--          pre-tax 25100/2 = 12550 + 100000/3 -> 33334 = 45884
--          commission 45884 × 10% = 4588.4 -> 4588; labor 48600 s × 2000/h = 27000
--   tech2: 3h + 3.5h = 6.5h = 23400 s; revenue 13374 + 36000 = 49374; pre-tax 12550 + 33333 = 45883
--          commission 45883 × 7.5% = 3441.225 -> 3441; labor 23400 × 2525 / 3600 = 16412.5 -> 16413 (half up)
--   manager: 1.5h = 5400 s; 1003 only: 36000 / 33333; commission 0; labor 5400 × 3000/3600 = 4500
--   admin (open entry after p_now) and owner: zeros; tech3 (inactive) 2h; tech4 (inactive, idle) omitted
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.eq(
  (select jsonb_agg(jsonb_build_array(r.display_name, r.role, r.active, r.worked_seconds, r.hours, r.jobs_completed,
                                      r.revenue_cents, r.pre_tax_revenue_cents, r.hourly_rate_cents, r.commission_bps,
                                      r.commission_cents, r.labor_cost_cents) order by ord)
     from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
          with ordinality as r (member_id, display_name, role, active, worked_seconds, hours, jobs_completed,
                                revenue_cents, pre_tax_revenue_cents, hourly_rate_cents, commission_bps,
                                commission_cents, labor_cost_cents, tips_cents, service_commission_cents,
                                sales_commission_cents, total_earnings_cents, ord)),
  '[["admin-ra",   "admin",      true,      0,  0.00, 0,     0,     0,    0,    0,    0,     0],
    ["manager-ra", "manager",    true,   5400,  1.50, 1, 36000, 33333, 3000,    0,    0,  4500],
    ["owner-ra",   "owner",      true,      0,  0.00, 0,     0,     0,    0,    0,    0,     0],
    ["tech1-ra",   "technician", true,  48600, 13.50, 2, 49375, 45884, 2000, 1000, 4588, 27000],
    ["tech2-ra",   "technician", true,  23400,  6.50, 2, 49374, 45883, 2525,  750, 3441, 16413],
    ["tech3-ra",   "technician", false,  7200,  2.00, 0,     0,     0,    0,    0,    0,     0]]'::jsonb,
  'team report for the owner (hours clipped and unioned, even splits, pay)');
select tests.eq((select member_id from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
                  where display_name = 'tech1-ra'), tests.fx('rm_tech1_a'), 'member ids returned');
-- 0065: earnings = labor + commission + service commission + sales commission + tips
select tests.eq((select count(*) from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
                  where total_earnings_cents is distinct from
                        labor_cost_cents + commission_cents + service_commission_cents + sales_commission_cents + tips_cents),
                0::bigint, 'total earnings add up for every member');

select tests.eq((select sum(pre_tax_revenue_cents) from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')),
                125100::numeric, 'attributed pre-tax revenue adds up to the completed jobs');
select tests.eq((select sum(revenue_cents) from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')),
                (26749 + 108000)::numeric, 'attributed revenue adds up to the completed job totals');
-- February: tech1 did 1001 (21600 / 20000 pre-tax); hours: shift 02-20 5h + 03-01 03:00-06:00Z (still Feb 28 CST) 3h
select tests.eq(
  (select jsonb_build_array(r.worked_seconds, r.jobs_completed, r.revenue_cents, r.pre_tax_revenue_cents,
                            r.commission_cents, r.labor_cost_cents)
     from public.report_team(tests.fx('rshop_a'), '2025-02-01', '2025-02-28', '2025-03-05 16:00+00') r
    where r.member_id = tests.fx('rm_tech1_a')),
  '[28800, 1, 21600, 20000, 2000, 16000]'::jsonb,
  'an entry crossing local midnight is split between months');
-- p_now caps open entries: at 15:00Z tech1 has 1.5h open (not 2.5h), manager 0.5h
select tests.eq(
  (select jsonb_object_agg(r.display_name, r.worked_seconds)
     from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 15:00+00') r
    where r.display_name in ('tech1-ra', 'manager-ra')),
  '{"tech1-ra": 45000, "manager-ra": 1800}'::jsonb, 'open entries run until p_now');
-- an idle range: every active member listed with zeros, inactive members omitted
select tests.eq((select count(*) from public.report_team(tests.fx('rshop_a'), '2025-01-01', '2025-01-31', '2025-03-05 16:00+00')),
                5::bigint, 'idle range: active members only');

-- admin sees pay like the owner
select tests.authenticate_as(tests.fx('ru_admin_a'));
select tests.eq((select jsonb_build_array(commission_cents, labor_cost_cents, hourly_rate_cents, commission_bps)
                   from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
                  where member_id = tests.fx('rm_tech2_a')),
                '[3441, 16413, 2525, 750]'::jsonb, 'admin sees compensation');

-- manager: every row, hours/jobs/revenue, but no compensation (SPEC §3)
select tests.authenticate_as(tests.fx('ru_manager_a'));
select tests.eq((select count(*) from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')),
                6::bigint, 'manager sees the whole team');
select tests.eq((select count(*) from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
                  where hourly_rate_cents is not null or commission_bps is not null
                     or commission_cents is not null or labor_cost_cents is not null
                     or tips_cents is not null or service_commission_cents is not null
                     or sales_commission_cents is not null or total_earnings_cents is not null),
                0::bigint, 'manager gets no pay columns (tips / commissions / earnings included), not even their own');
select tests.eq((select jsonb_build_array(worked_seconds, jobs_completed, revenue_cents, pre_tax_revenue_cents)
                   from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')
                  where member_id = tests.fx('rm_tech1_a')),
                '[48600, 2, 49375, 45884]'::jsonb, 'manager sees hours, jobs and revenue');

-- technician: only their own row, including their own pay
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.eq(
  (select jsonb_agg(jsonb_build_array(r.member_id, r.worked_seconds, r.jobs_completed, r.pre_tax_revenue_cents,
                                      r.commission_cents, r.labor_cost_cents))
     from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00') r),
  jsonb_build_array(jsonb_build_array(tests.fx('rm_tech1_a'), 48600, 2, 45884, 4588, 27000)),
  'technician sees exactly their own numbers');
select tests.authenticate_as(tests.fx('ru_tech2_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(r.member_id, r.labor_cost_cents))
                   from public.report_team(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00') r),
                jsonb_build_array(jsonb_build_array(tests.fx('rm_tech2_a'), 16413)), 'tech2 own row only');
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L, null)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '22023', 'team: p_now required');
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-31', '2025-03-01'),
                    '22023', 'team: bad range rejected');
-- shop B technician: own shop only
select tests.authenticate_as(tests.fx('ru_tech_b'));
select tests.eq((select count(*) from public.report_team(tests.fx('rshop_b'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00')),
                1::bigint, 'shop B technician sees one row');
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'shop B technician cannot read shop A team');

-- ============================================================ report_customers
select tests.authenticate_as(tests.fx('ru_owner_a'));
select public.report_customers(tests.fx('rshop_a'), '2025-03-01', '2025-03-31') as c \gset
-- served in March: Alice (1002; returning, 1001 in Feb) and Bob (1003; first job) -> 1 new, 1 returning
-- created in March: Larry (03-04) and 100% Detail Co (04-01 04:30Z = 03-31 23:30 CDT); Annie (04-01 05:30Z) is April
-- average ticket: (26749 + 108000) / 2 = 67374.5 -> 67375
-- lifetime net paid up to the end of March: Bob 50000 + 0 + 2000 = 52000;
--   Alice 21600 + 5000 + 21749 + 0 = 48349; Ann 6200 + 6000 + 1000 = 13200 (pending/failed excluded)
select tests.eq((:'c'::jsonb ->> 'customers_served')::int, 2, 'customers served');
select tests.eq((:'c'::jsonb ->> 'new_customers')::int, 1, 'new customers');
select tests.eq((:'c'::jsonb ->> 'returning_customers')::int, 1, 'returning customers');
select tests.eq((:'c'::jsonb ->> 'customers_created')::int, 2, 'customers created (local month end)');
select tests.eq((:'c'::jsonb ->> 'completed_jobs')::int, 2, 'completed jobs');
select tests.eq((:'c'::jsonb ->> 'average_ticket_cents')::bigint, 67375::bigint, 'average ticket rounds half up');
select tests.eq(:'c'::jsonb -> 'top_customers',
  jsonb_build_array(
    jsonb_build_object('customer_id', tests.fx('rc_bob'), 'name', 'Bob Brown', 'lifetime_net_cents', 52000,
                       'completed_jobs', 1, 'last_completed_at', '2025-03-05T05:30:00+00:00'),
    jsonb_build_object('customer_id', tests.fx('rc_alice'), 'name', 'Alice Anders', 'lifetime_net_cents', 48349,
                       'completed_jobs', 2, 'last_completed_at', '2025-03-03T20:00:00+00:00'),
    jsonb_build_object('customer_id', tests.fx('rc_ann'), 'name', 'Ann_Marie Smith', 'lifetime_net_cents', 13200,
                       'completed_jobs', 0, 'last_completed_at', null)),
  'top customers by lifetime net paid (tips excluded)');
select tests.eq(jsonb_array_length(public.report_customers(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', 2) -> 'top_customers'),
                2, 'top customer limit');
-- February: Alice's first completed job -> new; Bob created 02-25; lifetime up to Feb 28 local
--   Alice 21600 + P2 5000 (03-01 05:30Z is still Feb 28 CST) = 26600; Ann 6200
select public.report_customers(tests.fx('rshop_a'), '2025-02-01', '2025-02-28') as f \gset
select tests.eq(jsonb_build_array(:'f'::jsonb -> 'customers_served', :'f'::jsonb -> 'new_customers',
                                  :'f'::jsonb -> 'returning_customers', :'f'::jsonb -> 'customers_created',
                                  :'f'::jsonb -> 'average_ticket_cents'),
                '[1, 1, 0, 1, 21600]'::jsonb, 'February customer figures');
select tests.eq((select jsonb_agg(jsonb_build_array(e ->> 'name', (e ->> 'lifetime_net_cents')::bigint))
                   from jsonb_array_elements(:'f'::jsonb -> 'top_customers') e),
                '[["Alice Anders", 26600], ["Ann_Marie Smith", 6200]]'::jsonb, 'lifetime value as of the range end');
-- no activity: null average, empty list
select public.report_customers(tests.fx('rshop_a'), '2025-01-01', '2025-01-31') as j \gset
select tests.ok(:'j'::jsonb -> 'average_ticket_cents' = 'null'::jsonb, 'no jobs -> no average ticket');
select tests.eq((:'j'::jsonb ->> 'customers_served')::int, 0, 'no customers served in January');
select tests.throws(format('select public.report_customers(%L::uuid, %L, %L, 0)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '22023', 'limit must be positive');
select tests.throws(format('select public.report_customers(%L::uuid, %L, %L, 101)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '22023', 'limit capped at 100');

-- shop B sees only its own customer
select tests.authenticate_as(tests.fx('ru_owner_b'));
select tests.eq((select jsonb_agg(e ->> 'customer_id')
                   from jsonb_array_elements(public.report_customers(tests.fx('rshop_b'), '2025-03-01', '2025-03-31') -> 'top_customers') e),
                jsonb_build_array(tests.fx('rc_alice_b')), 'shop B top customers are its own');

-- ============================================================ denials
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.throws(format('select * from public.report_sales_by_service(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'technician cannot run sales by service');
select tests.throws(format('select public.report_customers(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'technician cannot run the customers report');
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.throws(format('select * from public.report_sales_by_service(%L::uuid, %L, %L)', tests.fx('rshop_b'), '2025-03-01', '2025-03-31'),
                    '42501', 'owner of A cannot read shop B sales');
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L)', tests.fx('rshop_b'), '2025-03-01', '2025-03-31'),
                    '42501', 'owner of A cannot read shop B team');
select tests.throws(format('select public.report_customers(%L::uuid, %L, %L)', tests.fx('rshop_b'), '2025-03-01', '2025-03-31'),
                    '42501', 'owner of A cannot read shop B customers');
select tests.authenticate_as(tests.fx('ru_outsider'));
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'non-member denied team');
select tests.as_anon();
select tests.throws(format('select * from public.report_sales_by_service(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'anon cannot execute report_sales_by_service');
select tests.throws(format('select * from public.report_team(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'anon cannot execute report_team');
select tests.throws(format('select public.report_customers(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'anon cannot execute report_customers');
select tests.as_superuser();
