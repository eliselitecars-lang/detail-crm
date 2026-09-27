-- 20 field ops: deactivating a member closes their open time entries.
--   A member deactivated by an admin, or leaving with leave_shop, while
--   clocked in must not keep an open punch: they can no longer clock out,
--   the dashboard hides inactive members, and reports would count the open
--   entry up to p_now (worked time and labor cost without end). Their open
--   entries are clocked out at the moment of deactivation.
\ir fixtures/two_shops.psql

insert into public.member_compensation (shop_id, member_id, hourly_rate_cents, commission_bps)
values (tests.fx('shop_a'), tests.fx('m_tech_a'), 2000, 0);

-- =================================================================== admin deactivation
-- the technician has been on a shift and a job for two hours
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.time_entries (shop_id, member_id, kind, clock_in)
values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'shift', now() - interval '2 hours');
insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in)
values (tests.fx('shop_a'), tests.fx('m_tech_a'), tests.fx('job_a'), 'job', now() - interval '1 hour');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shop_members set role = 'manager' where id = tests.fx('m_tech_a')$$), 1::bigint,
                'a role change of an active member');
select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_tech_a') and clock_out is null), 2::bigint,
                'does not touch their open entries');
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.shop_members set role = 'technician' where id = tests.fx('m_tech_a');
select tests.eq(tests.row_count($$update public.shop_members set active = false where id = tests.fx('m_tech_a')$$), 1::bigint,
                'the admin deactivates the clocked-in technician');

select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_tech_a') and clock_out is null), 0::bigint,
                'deactivation leaves no open entry behind');
select tests.eq((select array_agg(kind::text || ' ' || (clock_out = now())::text order by kind)
                   from public.time_entries where member_id = tests.fx('m_tech_a')),
                array['shift true', 'job true'],
                'the shift and the job clock are both closed at the moment of deactivation');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select worked_seconds from public.report_team(tests.fx('shop_a'), (now() at time zone 'America/Chicago')::date - 1,
                                                                 (now() at time zone 'America/Chicago')::date + 30,
                                                                 now() + interval '30 days')
                  where member_id = tests.fx('m_tech_a')), 7200::bigint,
                'a month later the report counts the two hours worked, not the month since');
select tests.eq((select labor_cost_cents from public.report_team(tests.fx('shop_a'), (now() at time zone 'America/Chicago')::date - 1,
                                                                   (now() at time zone 'America/Chicago')::date + 30,
                                                                   now() + interval '30 days')
                  where member_id = tests.fx('m_tech_a')), 4000::bigint,
                'and labor cost for those two hours only ($20/h)');
select tests.eq((public.dashboard_summary(tests.fx('shop_a'), now() + interval '1 hour') -> 'clocked_in' ->> 'count')::int, 0,
                'nobody is shown as clocked in');

-- re-invited later: they start a fresh shift instead of "already clocked in"
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.shop_members set active = true where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$select public.clock_in(tests.fx('shop_a'))$$, 'the reactivated member clocks in normally');
select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_tech_a')), 3::bigint,
                'as a new entry; the old shift is not stretched over the absence');

-- =================================================================== leave_shop
select tests.authenticate_as(tests.fx('u_tech2_a'));
select public.clock_in(tests.fx('shop_a'));
select public.clock_in(tests.fx('shop_a'), tests.fx('job_a2'));
select tests.lives($$select public.leave_shop(tests.fx('shop_a'))$$, 'the technician leaves while clocked in');
select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_tech2_a') and clock_out is null), 0::bigint,
                'leaving the shop clocks them out of the shift and the job');
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_tech2_a') and clock_out = clock_in), 2::bigint,
                'at the moment they left');

-- a clock-in a manager set ahead of the deactivation closes as a zero-length entry
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.clock_in(tests.fx('shop_a'), p_now => now() + interval '1 day');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set active = false where id = tests.fx('m_manager_a');
select tests.as_superuser();
select tests.eq((select clock_out = clock_in from public.time_entries
                  where member_id = tests.fx('m_manager_a') and clock_in = now() + interval '1 day'), true,
                'a future clock-in is closed without a negative duration');

-- =================================================================== closed entries and other shops are untouched
select tests.as_superuser();
select tests.fx_set('m_tech_a_in_b', tests.add_member(tests.fx('shop_b'), 'tech-a@test.local', 'technician'));
insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
values (tests.fx('shop_b'), tests.fx('m_tech_a_in_b'), 'shift', '2026-01-05 14:00Z', '2026-01-05 18:00Z');
select tests.authenticate_as(tests.fx('u_tech_a'));
select public.clock_out(tests.fx('shop_a'));
select public.clock_in(tests.fx('shop_a'), p_notes => 'shop A shift');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.lives($$select public.clock_in(tests.fx('shop_b'))$$, 'shop B''s manager is clocked in too');

select tests.authenticate_as(tests.fx('u_admin_b'));
update public.shop_members set active = false where id = tests.fx('m_tech_a_in_b');
select tests.as_superuser();
select tests.eq((select clock_out from public.time_entries where member_id = tests.fx('m_tech_a_in_b')),
                '2026-01-05 18:00Z'::timestamptz, 'a closed entry keeps its clock-out');
select tests.eq((select count(*) from public.time_entries
                  where member_id = tests.fx('m_tech_a') and notes = 'shop A shift' and clock_out is null), 1::bigint,
                'deactivation in shop B does not clock the same person out of shop A');
select tests.eq((select count(*) from public.time_entries
                  where member_id = tests.fx('m_manager_b') and clock_out is null), 1::bigint,
                'nor anyone else in shop B');

-- =================================================================== denial paths
-- a technician cannot deactivate themselves or anyone else to game the clock
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.shop_members set active = false where id = tests.fx('m_tech_a')$$, '42501',
                    'a member cannot change their own active status');
select tests.eq(tests.row_count($$update public.shop_members set active = false where id = tests.fx('m_manager_b')$$), 0::bigint,
                'nor another shop''s members');
select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where member_id = tests.fx('m_manager_b') and clock_out is null), 1::bigint,
                'so shop B''s open entry stays open');
select tests.ok(not has_function_privilege('authenticated', 'public.shop_members_close_time_entries()', 'execute')
                and not has_function_privilege('anon', 'public.shop_members_close_time_entries()', 'execute'),
                'the trigger function is not callable through the API');
