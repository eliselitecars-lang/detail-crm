-- 45 reports: report_revenue, report_payments, report_outstanding —
-- exact hand-computed numbers, shop-tz bucketing across midnight UTC and
-- DST, empty buckets, refunds/tips handling, validation, role denial and
-- cross-shop isolation. Data: fixtures/45_reports_seed.psql.
\ir fixtures/45_reports_seed.psql

select tests.authenticate_as(tests.fx('ru_owner_a'));

-- ============================================================ report_revenue — day buckets
-- Mar 3: P3 21749 (+tip 3000)
-- Mar 4: P4 50000 (03-05 03:00Z = 21:00 CST on the 4th)
-- Mar 5: P9 10000 refunded 4000; P10 3000+tip 500 fully refunded (amount part 3000);
--        P11 2000+tip 1000 refunded 2500 (amount 2000, tip 500) at 03-06 05:59Z = 23:59 CST
--        gross 15000, refunds 9000, net 6000, tips 500, 3 payments
-- Mar 6-8: empty
-- Mar 9: P14 1000 (03-10 04:30Z = 23:30 CDT, after the DST change)
-- Mar 10: P15 2000 (03-10 05:30Z = 00:30 CDT)
select tests.eq(
  (select jsonb_agg(to_jsonb(r) order by r.bucket_start)
     from public.report_revenue(tests.fx('rshop_a'), '2025-03-03', '2025-03-10', 'day') r),
  '[{"bucket_start":"2025-03-03","gross_cents":21749,"refunds_cents":0,"net_cents":21749,"tips_cents":3000,"payments_count":1},
    {"bucket_start":"2025-03-04","gross_cents":50000,"refunds_cents":0,"net_cents":50000,"tips_cents":0,"payments_count":1},
    {"bucket_start":"2025-03-05","gross_cents":15000,"refunds_cents":9000,"net_cents":6000,"tips_cents":500,"payments_count":3},
    {"bucket_start":"2025-03-06","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-03-07","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-03-08","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-03-09","gross_cents":1000,"refunds_cents":0,"net_cents":1000,"tips_cents":0,"payments_count":1},
    {"bucket_start":"2025-03-10","gross_cents":2000,"refunds_cents":0,"net_cents":2000,"tips_cents":0,"payments_count":1}]'::jsonb,
  'daily revenue in shop time (midnight-UTC and DST edges, empty days included)');

-- a single day: 2025-02-28 holds P2 (03-01 05:30Z = 23:30 CST), 03-01 holds nothing
select tests.eq((select net_cents from public.report_revenue(tests.fx('rshop_a'), '2025-02-28', '2025-02-28', 'day')),
                5000::bigint, 'P2 belongs to Feb 28 locally');
select tests.eq((select payments_count from public.report_revenue(tests.fx('rshop_a'), '2025-03-01', '2025-03-01', 'day')),
                0::bigint, 'nothing on Mar 1 locally');

-- ------------------------------------------------------------ week buckets (Monday starts)
-- from Wed 02-26: buckets start Mon 02-24; P1 (02-20) is outside the range
select tests.eq(
  (select jsonb_agg(to_jsonb(r) order by r.bucket_start)
     from public.report_revenue(tests.fx('rshop_a'), '2025-02-26', '2025-03-16', 'week') r),
  '[{"bucket_start":"2025-02-24","gross_cents":5000,"refunds_cents":0,"net_cents":5000,"tips_cents":0,"payments_count":1},
    {"bucket_start":"2025-03-03","gross_cents":87749,"refunds_cents":9000,"net_cents":78749,"tips_cents":3500,"payments_count":6},
    {"bucket_start":"2025-03-10","gross_cents":2000,"refunds_cents":0,"net_cents":2000,"tips_cents":0,"payments_count":1}]'::jsonb,
  'weekly revenue (week of 03-03 ends at Monday 00:00 CDT)');
-- a week bucket only counts payments inside the requested range
select tests.eq((select gross_cents from public.report_revenue(tests.fx('rshop_a'), '2025-03-05', '2025-03-05', 'week')),
                15000::bigint, 'partial week counts only the requested days');
select tests.eq((select bucket_start from public.report_revenue(tests.fx('rshop_a'), '2025-03-05', '2025-03-05', 'week')),
                '2025-03-03'::date, 'bucket labelled with its Monday');

-- ------------------------------------------------------------ month buckets
-- Dec: P5 6200; Jan: empty; Feb: P1 21600 (+2000 tip) + P2 5000;
-- Mar: 83749 card + 6000 cash gross, refunds 9000, net 80749, tips 3500, 7 payments
select tests.eq(
  (select jsonb_agg(to_jsonb(r) order by r.bucket_start)
     from public.report_revenue(tests.fx('rshop_a'), '2024-12-01', '2025-03-31', 'month') r),
  '[{"bucket_start":"2024-12-01","gross_cents":6200,"refunds_cents":0,"net_cents":6200,"tips_cents":0,"payments_count":1},
    {"bucket_start":"2025-01-01","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-02-01","gross_cents":26600,"refunds_cents":0,"net_cents":26600,"tips_cents":2000,"payments_count":2},
    {"bucket_start":"2025-03-01","gross_cents":89749,"refunds_cents":9000,"net_cents":80749,"tips_cents":3500,"payments_count":7}]'::jsonb,
  'monthly revenue');
-- bucket argument is case/space tolerant; pending (P12) and failed (P13) never count
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', ' Month ')),
                1::bigint, 'bucket name normalised');
-- consistency: Σ daily net over March = monthly net = dashboard month
select tests.eq((select sum(net_cents) from public.report_revenue(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', 'day')),
                80749::numeric, 'daily buckets add up to the month');
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')),
                31::bigint, 'default bucket is day; every day of March returned');

-- ------------------------------------------------------------ empty range
select tests.eq(
  (select jsonb_agg(to_jsonb(r) order by r.bucket_start)
     from public.report_revenue(tests.fx('rshop_a'), '2025-01-10', '2025-01-12', 'day') r),
  '[{"bucket_start":"2025-01-10","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-01-11","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0},
    {"bucket_start":"2025-01-12","gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"payments_count":0}]'::jsonb,
  'empty range still returns every bucket');

-- ------------------------------------------------------------ validation
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-02', '2025-03-01'),
                    '22023', 'end before start rejected');
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-02', 'year'),
                    '22023', 'unknown bucket rejected');
select tests.throws(format('select * from public.report_revenue(%L::uuid, null, %L)', tests.fx('rshop_a'), '2025-03-02'),
                    '22023', 'null date rejected');
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2010-01-01', '2025-01-01'),
                    '22023', 'ranges over 10 years rejected');

-- ------------------------------------------------------------ shop B (Asia/Tokyo)
select tests.authenticate_as(tests.fx('ru_owner_b'));
-- 14:00Z = 03-05 23:00 JST; 15:30Z = 03-06 00:30 JST (both are 03-05 in Chicago)
select tests.eq(
  (select jsonb_agg(jsonb_build_array(r.bucket_start, r.net_cents) order by r.bucket_start)
     from public.report_revenue(tests.fx('rshop_b'), '2025-03-05', '2025-03-06', 'day') r),
  '[["2025-03-05", 4000], ["2025-03-06", 7000]]'::jsonb,
  'Tokyo buckets split the same UTC evening across two local days');

-- ============================================================ report_payments (March, shop A)
select tests.authenticate_as(tests.fx('ru_manager_a'));
-- card: P3 21749/3000 tip, P4 50000, P9 10000 ref 4000, P11 2000/1000 tip ref 2500
--   gross 83749, refunds 4000+2000 = 6000, net 77749, tips 3000+500 = 3500, tip refunds 500,
--   collected 81249, deposits net P9 6000 + P11 0 = 6000
-- cash: P10 3000/500 tip fully refunded, P14 1000, P15 2000
--   gross 6000, refunds 3000, net 3000, tips 0, tip refunds 500, collected 3000, deposits 3000
-- check: P13 failed -> nothing; other methods empty
select tests.eq(
  (select jsonb_agg(to_jsonb(r) order by r.method)
     from public.report_payments(tests.fx('rshop_a'), '2025-03-01', '2025-03-31') r),
  '[{"method":"card","payments_count":4,"gross_cents":83749,"refunds_cents":6000,"net_cents":77749,"tips_cents":3500,"tip_refunds_cents":500,"collected_cents":81249,"deposits_cents":6000,"memberships_cents":0},
    {"method":"card_present","payments_count":0,"gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"tip_refunds_cents":0,"collected_cents":0,"deposits_cents":0,"memberships_cents":0},
    {"method":"cash","payments_count":3,"gross_cents":6000,"refunds_cents":3000,"net_cents":3000,"tips_cents":0,"tip_refunds_cents":500,"collected_cents":3000,"deposits_cents":3000,"memberships_cents":0},
    {"method":"check","payments_count":0,"gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"tip_refunds_cents":0,"collected_cents":0,"deposits_cents":0,"memberships_cents":0},
    {"method":"bank_transfer","payments_count":0,"gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"tip_refunds_cents":0,"collected_cents":0,"deposits_cents":0,"memberships_cents":0},
    {"method":"other","payments_count":0,"gross_cents":0,"refunds_cents":0,"net_cents":0,"tips_cents":0,"tip_refunds_cents":0,"collected_cents":0,"deposits_cents":0,"memberships_cents":0}]'::jsonb,
  'payments by method (refunds, tips, tip refunds, pending/failed excluded)');
select tests.eq((select sum(net_cents) from public.report_payments(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')),
                80749::numeric, 'payments report agrees with revenue');
-- February: P1 card 21600 + 2000 tip, P2 cash 5000 deposit (Feb 28 local)
select tests.eq(
  (select jsonb_object_agg(r.method, jsonb_build_array(r.payments_count, r.net_cents, r.tips_cents, r.deposits_cents))
     from public.report_payments(tests.fx('rshop_a'), '2025-02-01', '2025-02-28') r where r.payments_count > 0),
  '{"card":[1,21600,2000,0],"cash":[1,5000,0,5000]}'::jsonb,
  'February payments by method');
select tests.throws(format('select * from public.report_payments(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-31', '2025-03-01'),
                    '22023', 'payments: bad range rejected');

-- shop B in its own time zone: both cash payments are in March JST
select tests.authenticate_as(tests.fx('ru_owner_b'));
select tests.eq(
  (select jsonb_build_array(r.payments_count, r.net_cents)
     from public.report_payments(tests.fx('rshop_b'), '2025-03-01', '2025-03-31') r where r.method = 'cash'),
  '[2, 11000]'::jsonb, 'shop B payments only');
select tests.eq((select sum(payments_count) from public.report_payments(tests.fx('rshop_b'), '2025-03-01', '2025-03-31')),
                2::numeric, 'shop A payments never leak into shop B');

-- ============================================================ report_outstanding
select tests.authenticate_as(tests.fx('ru_admin_a'));
select public.report_outstanding(tests.fx('rshop_a'), '2025-03-05 16:00+00') as o \gset
-- local today 2025-03-05; days past due by local due date:
--   1003 due 03-19 02:00Z = 03-18 CDT -> not due (0)   58000  0-30
--   1006 due 02-03                     -> 30             7500  0-30 (overdue)
--   1007 due 02-02                     -> 31             4000  31-60
--   1004 due 2024-12-15                -> 80            10000  61-90
--   1005 due 2024-10-31 17:00Z (CDT)   -> 125           30000  90+
select tests.eq((:'o'::jsonb ->> 'count')::int, 5, 'five open invoices');
select tests.eq((:'o'::jsonb ->> 'balance_cents')::bigint, 109500::bigint, 'total outstanding');
select tests.eq((:'o'::jsonb ->> 'overdue_count')::int, 4, 'overdue count');
select tests.eq((:'o'::jsonb ->> 'overdue_balance_cents')::bigint, 51500::bigint, 'overdue balance');
select tests.eq(:'o'::jsonb -> 'buckets',
  '[{"bucket":"0-30","count":2,"balance_cents":65500},
    {"bucket":"31-60","count":1,"balance_cents":4000},
    {"bucket":"61-90","count":1,"balance_cents":10000},
    {"bucket":"90+","count":1,"balance_cents":30000}]'::jsonb,
  'aging buckets');
select tests.eq((select jsonb_agg(jsonb_build_array(e ->> 'number', e ->> 'days_past_due', e ->> 'bucket', e ->> 'overdue')
                                  order by ord)
                   from jsonb_array_elements(:'o'::jsonb -> 'invoices') with ordinality as x (e, ord)),
  '[["1005","125","90+","true"],["1004","80","61-90","true"],["1007","31","31-60","true"],
    ["1006","30","0-30","true"],["1003","0","0-30","false"]]'::jsonb,
  'invoices oldest due first with days past due and buckets');
select tests.eq((select e from jsonb_array_elements(:'o'::jsonb -> 'invoices') e where e ->> 'number' = '1004'),
  jsonb_build_object('invoice_id', tests.fx('ri_1004'), 'number', 1004, 'status', 'partially_paid',
                     'customer_id', tests.fx('rc_ann'), 'customer_name', 'Ann_Marie Smith', 'job_id', null,
                     'issued_at', '2024-12-01T18:00:00+00:00', 'due_at', '2024-12-15T18:00:00+00:00',
                     'total_cents', 16200, 'amount_paid_cents', 6200, 'balance_cents', 10000,
                     'days_past_due', 80, 'overdue', true, 'bucket', '61-90'),
  'invoice row detail');
select tests.ok(not exists (select 1 from jsonb_array_elements(:'o'::jsonb -> 'invoices') e
                            where (e ->> 'invoice_id')::uuid in (tests.fx('ri_1001'), tests.fx('ri_1002'),
                                                                 tests.fx('ri_1008'), tests.fx('ri_1009'))),
                'paid, draft and void invoices are not receivables');

-- 90 / 91 day boundary for 1004 (due Dec 15 local): Mar 15 = 90 days, Mar 16 = 91
select tests.eq((select e ->> 'bucket' from jsonb_array_elements(
                   public.report_outstanding(tests.fx('rshop_a'), '2025-03-15 17:00+00') -> 'invoices') e
                 where e ->> 'number' = '1004'), '61-90', '90 days past due is still 61-90');
select tests.eq((select e ->> 'bucket' from jsonb_array_elements(
                   public.report_outstanding(tests.fx('rshop_a'), '2025-03-16 17:00+00') -> 'invoices') e
                 where e ->> 'number' = '1004'), '90+', '91 days past due is 90+');
-- later as-of date re-ages everything: 04-20 -> 1003 33d, 1006 76d, 1007 77d, 1004 126d, 1005 171d
select tests.eq(public.report_outstanding(tests.fx('rshop_a'), '2025-04-20 17:00+00') -> 'buckets',
  '[{"bucket":"0-30","count":0,"balance_cents":0},
    {"bucket":"31-60","count":1,"balance_cents":58000},
    {"bucket":"61-90","count":2,"balance_cents":11500},
    {"bucket":"90+","count":2,"balance_cents":40000}]'::jsonb,
  'aging moves with p_now');
select tests.throws(format('select public.report_outstanding(%L::uuid, null)', tests.fx('rshop_a')),
                    '22023', 'outstanding: p_now required');

select tests.authenticate_as(tests.fx('ru_owner_b'));
select tests.eq(public.report_outstanding(tests.fx('rshop_b'), '2025-03-05 16:00+00') -> 'buckets',
  '[{"bucket":"0-30","count":0,"balance_cents":0},{"bucket":"31-60","count":0,"balance_cents":0},
    {"bucket":"61-90","count":0,"balance_cents":0},{"bucket":"90+","count":0,"balance_cents":0}]'::jsonb,
  'shop B: empty aging, every bucket present');
select tests.eq(public.report_outstanding(tests.fx('rshop_b'), '2025-03-05 16:00+00') -> 'invoices', '[]'::jsonb,
                'shop B: no receivables from shop A');

-- ============================================================ denials
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'technician cannot run the revenue report');
select tests.throws(format('select * from public.report_payments(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'technician cannot run the payments report');
select tests.throws(format('select public.report_outstanding(%L::uuid)', tests.fx('rshop_a')),
                    '42501', 'technician cannot run the outstanding report');
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_b'), '2025-03-01', '2025-03-31'),
                    '42501', 'owner of A cannot read shop B revenue');
select tests.throws(format('select * from public.report_payments(%L::uuid, %L, %L)', tests.fx('rshop_b'), '2025-03-01', '2025-03-31'),
                    '42501', 'owner of A cannot read shop B payments');
select tests.throws(format('select public.report_outstanding(%L::uuid)', tests.fx('rshop_b')),
                    '42501', 'owner of A cannot read shop B receivables');
select tests.authenticate_as(tests.fx('ru_outsider'));
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'non-member denied revenue');
select tests.as_anon();
select tests.throws(format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'anon cannot execute report_revenue');
select tests.throws(format('select * from public.report_payments(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'),
                    '42501', 'anon cannot execute report_payments');
select tests.throws(format('select public.report_outstanding(%L::uuid)', tests.fx('rshop_a')),
                    '42501', 'anon cannot execute report_outstanding');
select tests.as_superuser();
