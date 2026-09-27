-- 45 reports: dashboard_summary — shop-timezone day/week/month boundaries
-- (incl. midnight-UTC and DST edges), role scopes (shop vs technician own),
-- tips/refunds handling, cross-shop isolation. Data and hand computations:
-- see fixtures/45_reports_seed.psql. p_now = 2025-03-05 16:00Z.
\ir fixtures/45_reports_seed.psql

-- =========================================================== owner, shop A
select tests.authenticate_as(tests.fx('ru_owner_a'));
select public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 16:00+00') as d \gset

select tests.eq(:'d'::jsonb ->> 'scope', 'shop', 'owner gets the shop-wide scope');
select tests.eq(:'d'::jsonb ->> 'timezone', 'America/Chicago', 'shop time zone reported');
-- 16:00Z = 10:00 CST on Wed 2025-03-05
select tests.eq(:'d'::jsonb ->> 'today', '2025-03-05', 'today is the shop-local date');
select tests.eq(:'d'::jsonb ->> 'week_start', '2025-03-03', 'weeks start on Monday');
select tests.eq(:'d'::jsonb ->> 'month_start', '2025-03-01', 'month start');
select tests.eq((:'d'::jsonb ->> 'as_of')::timestamptz, '2025-03-05 16:00+00'::timestamptz, 'as_of echoes p_now');

-- jobs today = overlapping [03-05 06:00Z, 03-06 06:00Z):
--   1004 confirmed, 1005 in_progress, 1006 scheduled (01:00Z on 03-06 is still 03-05 locally),
--   1008 cancelled; 1003 (ends 05:00Z) and 1007 (06:30Z) are outside.
select tests.eq((:'d'::jsonb -> 'jobs_today' ->> 'total')::int, 3, 'jobs today exclude cancelled / no-show');
select tests.eq(:'d'::jsonb -> 'jobs_today' -> 'by_status',
                '{"requested":0,"scheduled":1,"confirmed":1,"en_route":0,"in_progress":1,"completed":0,"cancelled":1,"no_show":0}'::jsonb,
                'jobs today by status (every status present)');
-- this week [03-03 06:00Z, 03-10 05:00Z): 1002 1003 1004 1005 1006 1007 1011 = 7
-- (1012 starts 03-10 05:00Z = Monday 00:00 CDT: next week; 1008 cancelled; 1010 next week)
select tests.eq((:'d'::jsonb ->> 'jobs_this_week')::int, 7, 'jobs this week use the DST-shifted week end');
-- next job: earliest scheduled/confirmed/en_route ending after p_now = 1004 at 17:00Z
select tests.eq((:'d'::jsonb -> 'next_job' ->> 'number')::bigint, 1004::bigint, 'next job is 1004');
select tests.eq((:'d'::jsonb -> 'next_job' ->> 'id')::uuid, tests.fx('rj_1004'), 'next job id');
select tests.eq(:'d'::jsonb -> 'next_job' ->> 'customer_name', 'Ann_Marie Smith', 'next job customer name');
select tests.eq(:'d'::jsonb -> 'next_job' ->> 'vehicle_label', '2020 Tesla Model 3', 'next job vehicle label');
select tests.eq(:'d'::jsonb -> 'next_job' -> 'assigned_member_ids', jsonb_build_array(tests.fx('rm_tech2_a')),
                'next job assignees');
select tests.eq((:'d'::jsonb -> 'next_job' ->> 'scheduled_start')::timestamptz, '2025-03-05 17:00+00'::timestamptz,
                'next job start');
-- only 1009 is an online booking still requested (1010 is a staff request)
select tests.eq((:'d'::jsonb ->> 'pending_booking_requests')::int, 1, 'pending online booking requests');
-- 1001 sent (no expiry) + 1003 viewed valid through 03-05 local; 1002 expired by date; draft/approved excluded
select tests.eq((:'d'::jsonb ->> 'quotes_awaiting_response')::int, 2, 'quotes awaiting response honour valid_until');
-- open: 1003 58000 + 1004 10000 + 1005 30000 + 1006 7500 + 1007 4000 = 109500 (draft/void/paid excluded)
select tests.eq(:'d'::jsonb -> 'open_invoices', '{"count":5,"balance_cents":109500}'::jsonb, 'open invoices');
-- overdue: all but 1003 (due 03-19): 10000 + 30000 + 7500 + 4000 = 51500
select tests.eq(:'d'::jsonb -> 'overdue_invoices', '{"count":4,"balance_cents":51500}'::jsonb, 'overdue invoices');
-- today: P9 net 10000−4000 = 6000; P10 fully refunded (0, tip 0); P11 at 05:59Z on 03-06 (= 23:59 local)
--   amount fully refunded (0) + tip 1000−500 = 500.  P4 (03:00Z = 03-04 21:00 local) is yesterday.
select tests.eq(:'d'::jsonb -> 'revenue' -> 'today', '{"net_cents":6000,"tips_cents":500,"payments_count":3}'::jsonb,
                'revenue today: net of refunds, tips separate');
-- week: P3 21749 + P4 50000 + 6000 + 0 + 0 + P14 1000 (03-10 04:30Z = Sun 23:30 CDT) = 78749;
--   tips 3000 + 500; P15 (03-10 05:30Z = Mon 00:30 CDT) is next week; P2 (Feb 28 local) excluded
select tests.eq(:'d'::jsonb -> 'revenue' -> 'week', '{"net_cents":78749,"tips_cents":3500,"payments_count":6}'::jsonb,
                'revenue this week');
-- month: week + P15 2000 = 80749 (P2 at 03-01 05:30Z is Feb 28 23:30 CST)
select tests.eq(:'d'::jsonb -> 'revenue' -> 'month', '{"net_cents":80749,"tips_cents":3500,"payments_count":7}'::jsonb,
                'revenue this month');
select tests.eq((:'d'::jsonb ->> 'unread_inbound_messages')::int, 2, 'unread inbound messages');
-- clocked in at p_now: tech1 (shift 13:30, job 1005 14:00) and manager (14:30); tech2 clocked out 15:00;
-- admin's entry starts 17:00 (after p_now)
select tests.eq((:'d'::jsonb -> 'clocked_in' ->> 'count')::int, 2, 'two members on the clock');
select tests.eq((:'d'::jsonb -> 'clocked_in' -> 'members' -> 0 ->> 'member_id')::uuid, tests.fx('rm_tech1_a'),
                'earliest clock-in first');
select tests.eq((:'d'::jsonb -> 'clocked_in' -> 'members' -> 0 ->> 'since')::timestamptz, '2025-03-05 13:30+00'::timestamptz,
                'since = earliest open entry');
select tests.eq((:'d'::jsonb -> 'clocked_in' -> 'members' -> 0 ->> 'job_id')::uuid, tests.fx('rj_1005'),
                'current job of the clocked-in technician');
select tests.eq((:'d'::jsonb -> 'clocked_in' -> 'members' -> 1 ->> 'member_id')::uuid, tests.fx('rm_manager_a'),
                'manager on the clock');
select tests.ok(:'d'::jsonb -> 'clocked_in' -> 'members' -> 1 -> 'job_id' = 'null'::jsonb, 'manager has no job clock');

-- ---------------------------------------------------------- manager / admin see the same shop scope
select tests.authenticate_as(tests.fx('ru_manager_a'));
select tests.eq(public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 16:00+00'), :'d'::jsonb,
                'manager dashboard equals the owner dashboard');
select tests.authenticate_as(tests.fx('ru_admin_a'));
select tests.eq(public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 16:00+00'), :'d'::jsonb,
                'admin dashboard equals the owner dashboard');

-- ---------------------------------------------------------- technician: own scope
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 16:00+00') as t \gset
select tests.eq(:'t'::jsonb ->> 'scope', 'own', 'technician gets the own scope');
-- tech1 is assigned 1001 1002 1003 1005 1007: today only 1005
select tests.eq((:'t'::jsonb -> 'jobs_today' ->> 'total')::int, 1, 'technician: own jobs today');
select tests.eq((:'t'::jsonb -> 'jobs_today' -> 'by_status' ->> 'in_progress')::int, 1, 'technician: 1005 in progress');
select tests.eq((:'t'::jsonb -> 'jobs_today' -> 'by_status' ->> 'cancelled')::int, 0, 'technician: no foreign cancelled job');
select tests.eq((:'t'::jsonb ->> 'jobs_this_week')::int, 4, 'technician: 1002 1003 1005 1007 this week');
-- 1005 is in progress, so the next not-started assigned job is 1007
select tests.eq((:'t'::jsonb -> 'next_job' ->> 'number')::bigint, 1007::bigint, 'technician: own next job');
select tests.eq((:'t'::jsonb -> 'clocked_in' ->> 'count')::int, 1, 'technician sees only their own clock');
select tests.eq((:'t'::jsonb -> 'clocked_in' -> 'members' -> 0 ->> 'member_id')::uuid, tests.fx('rm_tech1_a'),
                'technician clock row is their own');
select tests.ok(:'t'::jsonb -> 'revenue' = 'null'::jsonb, 'technician: no revenue');
select tests.ok(:'t'::jsonb -> 'open_invoices' = 'null'::jsonb, 'technician: no invoices');
select tests.ok(:'t'::jsonb -> 'overdue_invoices' = 'null'::jsonb, 'technician: no overdue invoices');
select tests.ok(:'t'::jsonb -> 'quotes_awaiting_response' = 'null'::jsonb, 'technician: no quotes');
select tests.ok(:'t'::jsonb -> 'pending_booking_requests' = 'null'::jsonb, 'technician: no booking requests');
select tests.ok(:'t'::jsonb -> 'unread_inbound_messages' = 'null'::jsonb, 'technician: no inbox count');

select tests.authenticate_as(tests.fx('ru_tech2_a'));
select public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 16:00+00') as t2 \gset
select tests.eq((:'t2'::jsonb -> 'next_job' ->> 'number')::bigint, 1004::bigint, 'tech2 next job is 1004');
select tests.eq((:'t2'::jsonb ->> 'jobs_this_week')::int, 3, 'tech2: 1002 1003 1004 this week');
select tests.eq((:'t2'::jsonb -> 'clocked_in' ->> 'count')::int, 0, 'tech2 is not on the clock at p_now');
select tests.eq(:'t2'::jsonb -> 'clocked_in' -> 'members', '[]'::jsonb, 'empty clock list');
-- a moment earlier tech2's shift (12:00-15:00Z) spans p_now
select tests.eq((public.dashboard_summary(tests.fx('rshop_a'), '2025-03-05 14:00+00') -> 'clocked_in' ->> 'count')::int, 1,
                'clock status follows p_now (closed entry spanning it)');

-- ---------------------------------------------------------- DST: first local day after the change
-- p_now 03-10 05:30Z = Mon 03-10 00:30 CDT: today/week start 03-10 05:00Z.
select tests.authenticate_as(tests.fx('ru_owner_a'));
select public.dashboard_summary(tests.fx('rshop_a'), '2025-03-10 05:30+00') as dst \gset
select tests.eq(:'dst'::jsonb ->> 'today', '2025-03-10', 'DST: local date');
select tests.eq(:'dst'::jsonb ->> 'week_start', '2025-03-10', 'DST: new week');
-- 1012 (05:00-06:00Z) is today; 1011 (04:00-05:00Z = Sunday) is not
select tests.eq((:'dst'::jsonb -> 'jobs_today' ->> 'total')::int, 1, 'DST: only 1012 today');
select tests.eq(:'dst'::jsonb -> 'revenue' -> 'today', '{"net_cents":2000,"tips_cents":0,"payments_count":1}'::jsonb,
                'DST: P15 today, P14 (Sunday 23:30 CDT) not');
select tests.eq(:'dst'::jsonb -> 'revenue' -> 'week', '{"net_cents":2000,"tips_cents":0,"payments_count":1}'::jsonb,
                'DST: week revenue');
select tests.eq((:'dst'::jsonb -> 'revenue' -> 'month' ->> 'net_cents')::bigint, 80749::bigint, 'DST: same month');
-- 1012 has not started (ends 06:00Z): it is the next job; 1011 is over
select tests.eq((:'dst'::jsonb -> 'next_job' ->> 'number')::bigint, 1012::bigint, 'DST: next job');

-- a month boundary crossing a week: p_now Mon 2025-03-31 15:00Z. The week runs to Sun 04-06,
-- the month ends 04-01 05:00Z; week revenue uses its own window.
select public.dashboard_summary(tests.fx('rshop_a'), '2025-03-31 15:00+00') as mw \gset
select tests.eq(:'mw'::jsonb ->> 'week_start', '2025-03-31', 'week spanning two months');
select tests.eq(:'mw'::jsonb -> 'revenue' -> 'week', '{"net_cents":0,"tips_cents":0,"payments_count":0}'::jsonb,
                'no payments in that week');
select tests.eq((:'mw'::jsonb -> 'revenue' -> 'month' ->> 'net_cents')::bigint, 80749::bigint, 'still March revenue');
select tests.ok(:'mw'::jsonb -> 'next_job' = 'null'::jsonb, 'no upcoming job -> null');

-- ============================================================ shop B (Asia/Tokyo), same instant
select tests.authenticate_as(tests.fx('ru_owner_b'));
select public.dashboard_summary(tests.fx('rshop_b'), '2025-03-05 16:00+00') as b \gset
-- 16:00Z = Thu 03-06 01:00 JST
select tests.eq(:'b'::jsonb ->> 'today', '2025-03-06', 'Tokyo shop is already on 03-06');
select tests.eq(:'b'::jsonb ->> 'week_start', '2025-03-03', 'Tokyo week start');
select tests.eq((:'b'::jsonb -> 'jobs_today' ->> 'total')::int, 1, 'Tokyo job today (09:00 JST)');
select tests.eq((:'b'::jsonb -> 'next_job' ->> 'id')::uuid, tests.fx('rj_b1'), 'Tokyo next job');
-- 15:30Z = 00:30 JST 03-06 (today); 14:00Z = 23:00 JST 03-05 (yesterday, same week)
select tests.eq(:'b'::jsonb -> 'revenue' -> 'today', '{"net_cents":7000,"tips_cents":0,"payments_count":1}'::jsonb,
                'Tokyo revenue today');
select tests.eq(:'b'::jsonb -> 'revenue' -> 'week', '{"net_cents":11000,"tips_cents":0,"payments_count":2}'::jsonb,
                'Tokyo revenue this week');
select tests.eq(:'b'::jsonb -> 'open_invoices', '{"count":0,"balance_cents":0}'::jsonb, 'shop B has no open invoices');
select tests.eq((:'b'::jsonb ->> 'quotes_awaiting_response')::int, 0, 'shop B quotes isolated');
select tests.eq((:'b'::jsonb ->> 'pending_booking_requests')::int, 0, 'shop B requests isolated');
select tests.eq((:'b'::jsonb ->> 'unread_inbound_messages')::int, 1, 'shop B unread isolated');
select tests.eq((:'b'::jsonb -> 'clocked_in' ->> 'count')::int, 0, 'shop B clock isolated');

-- ============================================================ denials
select tests.throws(format('select public.dashboard_summary(%L::uuid, %L)', tests.fx('rshop_a'), '2025-03-05 16:00+00'),
                    '42501', 'owner of B cannot read shop A dashboard');
select tests.authenticate_as(tests.fx('ru_tech_b'));
select tests.throws(format('select public.dashboard_summary(%L::uuid)', tests.fx('rshop_a')),
                    '42501', 'technician of B cannot read shop A dashboard');
select tests.authenticate_as(tests.fx('ru_outsider'));
select tests.throws(format('select public.dashboard_summary(%L::uuid)', tests.fx('rshop_a')),
                    '42501', 'non-member denied');
select tests.throws('select public.dashboard_summary(gen_random_uuid())', '42501', 'unknown shop looks like no access');
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.throws(format('select public.dashboard_summary(%L::uuid, null)', tests.fx('rshop_a')),
                    '22023', 'p_now cannot be null');
select tests.as_anon();
select tests.throws(format('select public.dashboard_summary(%L::uuid)', tests.fx('rshop_a')),
                    '42501', 'anon cannot execute dashboard_summary');
select tests.as_superuser();
