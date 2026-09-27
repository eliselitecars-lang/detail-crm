-- 90 integration: report_revenue_totals (one row of range totals) and the
-- daily-bucket cap of report_revenue (at most 366 day buckets, under
-- PostgREST's max rows). Data: fixtures/45_reports_seed.psql.
\ir fixtures/45_reports_seed.psql

create function pg_temp.sum_buckets(p_shop uuid, p_from date, p_to date, p_bucket text) returns jsonb language sql as $$
  select jsonb_build_object('gross_cents', coalesce(sum(gross_cents), 0), 'refunds_cents', coalesce(sum(refunds_cents), 0),
                            'net_cents', coalesce(sum(net_cents), 0), 'tips_cents', coalesce(sum(tips_cents), 0),
                            'payments_count', coalesce(sum(payments_count), 0))
    from public.report_revenue(p_shop, p_from, p_to, p_bucket)
$$;
grant execute on function pg_temp.sum_buckets(uuid, date, date, text) to authenticated;

select tests.authenticate_as(tests.fx('ru_owner_a'));
-- ------------------------------------------------------------ totals = Σ buckets
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31') t),
                pg_temp.sum_buckets(tests.fx('rshop_a'), '2025-03-01', '2025-03-31', 'day'),
                'March totals equal the sum of the daily buckets');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-03', '2025-03-10') t),
                pg_temp.sum_buckets(tests.fx('rshop_a'), '2025-03-03', '2025-03-10', 'day'),
                'across the DST change (local days)');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2025-02-28', '2025-02-28') t),
                pg_temp.sum_buckets(tests.fx('rshop_a'), '2025-02-28', '2025-02-28', 'day'), 'a single day');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2024-06-01', '2025-05-31') t),
                pg_temp.sum_buckets(tests.fx('rshop_a'), '2024-06-01', '2025-05-31', 'month'),
                'a year: totals equal the sum of the monthly buckets');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2016-01-01', '2025-12-31') t),
                pg_temp.sum_buckets(tests.fx('rshop_a'), '2016-01-01', '2025-12-31', 'week'),
                'ten years: totals equal the sum of the weekly buckets');
select tests.ok((select net_cents > 0 and payments_count > 0 and gross_cents - refunds_cents = net_cents
                   from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')),
                'the March totals are not empty and net = gross - refunds');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_a'), '2030-01-01', '2030-01-31') t),
                '{"gross_cents": 0, "refunds_cents": 0, "net_cents": 0, "tips_cents": 0, "payments_count": 0}'::jsonb,
                'an empty range: one row of zeros');
select tests.eq((select count(*) from public.report_revenue_totals(tests.fx('rshop_a'), '2030-01-01', '2030-01-31')), 1::bigint,
                'always exactly one row');

-- ------------------------------------------------------------ the daily cap
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2024-03-01', '2025-02-28', 'day')), 365::bigint,
                '365 days of daily buckets');
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2024-01-01', '2024-12-31', 'day')), 366::bigint,
                '366 daily buckets (a leap year) are allowed');
select tests.throws_like($$select * from public.report_revenue(tests.fx('rshop_a'), '2024-01-01', '2025-01-01', 'day')$$, '22023',
                         'daily buckets cover at most 366 days; use weekly or monthly', '367 days of daily buckets are refused');
select tests.throws($$select * from public.report_revenue(tests.fx('rshop_a'), '2024-01-01', '2025-01-01')$$, '22023',
                    'day is the default bucket, so the cap applies there too');
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2016-01-01', '2025-12-31', 'week')) > 500, true,
                'weekly buckets over ten years are fine');
select tests.eq((select count(*) from public.report_revenue(tests.fx('rshop_a'), '2016-01-01', '2025-12-31', 'month')), 120::bigint,
                'monthly buckets over ten years');
select tests.throws_like($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-31', '2025-03-01')$$, '22023',
                         '%end date%', 'totals validate the range');
select tests.throws_like($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2010-01-01', '2025-12-31')$$, '22023',
                         '%10 years%', 'and its length');

-- ------------------------------------------------------------ roles and isolation
select tests.authenticate_as(tests.fx('ru_manager_a'));
select tests.lives($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')$$, 'managers');
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.throws($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')$$, '42501',
                    'technicians cannot');
select tests.authenticate_as(tests.fx('ru_owner_b'));
select tests.throws($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')$$, '42501',
                    'another shop cannot');
select tests.eq((select to_jsonb(t) from public.report_revenue_totals(tests.fx('rshop_b'), '2025-03-01', '2025-03-31') t),
                pg_temp.sum_buckets(tests.fx('rshop_b'), '2025-03-01', '2025-03-31', 'day'), 'shop B''s own totals');
select tests.authenticate_as(tests.fx('ru_outsider'));
select tests.throws($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')$$, '42501',
                    'non-members cannot');
select tests.as_anon();
select tests.throws($$select * from public.report_revenue_totals(tests.fx('rshop_a'), '2025-03-01', '2025-03-31')$$, '42501',
                    'anon cannot execute');
