-- 60 money: report_member_earnings (0065) follows the customers RLS for
-- customer_label (SPEC §3). A technician who SOLD a job they are not assigned
-- to keeps its money row (sales commission, job number, completion time) but
-- not the customer's name, unless that customer is on another job assigned
-- to them (exactly what RLS lets them read). Owners / admins / managers see
-- every label. Two-shop isolation as before.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.member_compensation (shop_id, member_id, hourly_rate_cents, commission_bps, sales_commission_bps) values
  (tests.fx('shop_a'), tests.fx('m_tech_a'), 0, 1000, 500),
  (tests.fx('shop_a'), tests.fx('m_manager_a'), 0, 0, 1000);

-- sold by tech_a, assigned to tech2 only; the customer (Aaron) is on no job of tech_a
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, sold_by_member_id)
values (tests.fx('shop_a'), tests.fx('cust_a2'), 'completed', '2025-03-11 14:00Z', '2025-03-11 16:00Z', '2025-03-11 16:00Z',
        tests.fx('m_tech_a')) returning tests.fx_set('j_sold', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j_sold'), 'Coating', 30000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j_sold'), tests.fx('m_tech2_a'));
-- sold by tech_a, assigned to tech2 only; the customer (Alice) is on job_a, assigned to tech_a
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, sold_by_member_id)
values (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-03-12 14:00Z', '2025-03-12 16:00Z', '2025-03-12 16:00Z',
        tests.fx('m_tech_a')) returning tests.fx_set('j_sold_known', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j_sold_known'), 'Wash', 10000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j_sold_known'), tests.fx('m_tech2_a'));
-- assigned to tech_a (Fleet Co), sold by the manager
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, sold_by_member_id)
values (tests.fx('shop_a'), tests.fx('cust_a3'), 'completed', '2025-03-13 14:00Z', '2025-03-13 16:00Z', '2025-03-13 16:00Z',
        tests.fx('m_manager_a')) returning tests.fx_set('j_worked', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j_worked'), 'Detail', 20000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j_worked'), tests.fx('m_tech_a'));

create function pg_temp.label(p_member uuid, p_job uuid) returns text language sql as $$
  select coalesce(e.customer_label, '<null>')
    from public.report_member_earnings(tests.fx('shop_a'), p_member, '2025-03-01', '2025-03-31') e
   where e.job_id = p_job
$$;
grant execute on function pg_temp.label(uuid, uuid) to authenticated;

-- ============================================================ the technician who sold the job
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.customers where id = tests.fx('cust_a2')), 0::bigint,
                'RLS: tech_a cannot read Aaron (not on a job assigned to them)');
select tests.eq((select count(*) from public.jobs where id = tests.fx('j_sold')), 0::bigint, 'RLS: tech_a cannot read the job');
select tests.eq((select count(*) from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')
                  where job_id = tests.fx('j_sold') and customer_label is not null), 0::bigint,
                'a technician does not read the customer of a job that is not assigned to them');
select tests.eq((select concat_ws('/', job_number is not null, completed_at, sales_commission_cents, revenue_share_cents, commission_cents)
                   from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')
                  where job_id = tests.fx('j_sold')),
                concat_ws('/', true, '2025-03-11 16:00Z'::timestamptz, 1500, 0, 0),
                'the seller keeps the sale''s money row (5% of 30000) with its number and date');
select tests.eq(pg_temp.label(tests.fx('m_tech_a'), tests.fx('j_worked')), 'Fleet Co', 'the label of a job assigned to them');
select tests.eq((select count(*) from public.customers where id = tests.fx('cust_a')), 1::bigint,
                'RLS: tech_a reads Alice (job_a is assigned to them)');
select tests.eq(pg_temp.label(tests.fx('m_tech_a'), tests.fx('j_sold_known')), 'Alice Anders',
                'a sold job''s customer they may read through another assigned job: shown, as RLS allows');
select tests.eq((select sum(sales_commission_cents) from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')),
                (select sales_commission_cents from public.report_team(tests.fx('shop_a'), '2025-03-01', '2025-03-31') where member_id = tests.fx('m_tech_a')),
                'the rows still add up to report_team');

-- ============================================================ the assignee and staff see the label
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(pg_temp.label(tests.fx('m_tech2_a'), tests.fx('j_sold')), 'Aaron Other', 'the assigned technician sees it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.label(tests.fx('m_tech_a'), tests.fx('j_sold')), 'Aaron Other', 'an owner sees it on the seller''s drill-down');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(pg_temp.label(tests.fx('m_tech_a'), tests.fx('j_sold')), 'Aaron Other', 'an admin too');
select tests.as_superuser();
update public.jobs set sold_by_member_id = tests.fx('m_manager_a') where id = tests.fx('j_worked');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at, sold_by_member_id)
values (tests.fx('shop_a'), tests.fx('cust_a2'), 'completed', '2025-03-14 14:00Z', '2025-03-14 16:00Z', '2025-03-14 16:00Z',
        tests.fx('m_manager_a')) returning tests.fx_set('j_mgr_sold', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j_mgr_sold'), 'Wash', 5000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.label(tests.fx('m_manager_a'), tests.fx('j_mgr_sold')), 'Aaron Other',
                'a manager reads every customer, so their own sold jobs keep the label');

-- ============================================================ isolation
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'another shop''s manager reads nothing');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.report_member_earnings(tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-03-01', '2025-03-31')$$,
                    '42501', 'a technician reads only their own earnings');
select tests.reset();
