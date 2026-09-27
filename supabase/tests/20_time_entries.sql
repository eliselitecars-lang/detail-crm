-- 20 field ops: time_entries, clock_in / clock_out — own clock for every
-- member, job clocks need assignment, one open entry per member & kind, no
-- overlaps (exclusion), manager-only back-dating and editing, technicians
-- read own and cannot modify closed entries, cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ technician clock
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.clock_in(tests.fx('shop_a'), p_now => '2025-06-02 13:00Z')$$, '42501',
                         '%only managers%', 'technicians cannot choose their clock time');
select tests.fx_set('te_shift', (public.clock_in(tests.fx('shop_a'))).id);
select tests.ok((select kind = 'shift' and clock_in = now() and clock_out is null and source = 'app' and job_id is null
                        and member_id = tests.fx('m_tech_a') and created_by = tests.fx('u_tech_a')
                   from public.time_entries where id = tests.fx('te_shift')), 'shift clock-in at server time');
select tests.throws_like($$select public.clock_in(tests.fx('shop_a'))$$, '23505', '%already clocked in%',
                         'one open shift per member');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_a2'))$$, '42501',
                    'technicians clock in only to assigned jobs');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_b'))$$, 'P0002', 'jobs of another shop are not found');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), gen_random_uuid())$$, 'P0002', 'unknown job');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_a'), 'shift')$$, '22023', 'a shift does not take a job');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), null, 'job')$$, '22023', 'a job clock needs a job');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_a'), p_source => 'manual')$$, '22023',
                    'the clock RPC does not create manual entries');
select tests.fx_set('te_job', (public.clock_in(tests.fx('shop_a'), tests.fx('job_a'), p_source => 'web', p_notes => ' Started prep ')).id);
select tests.ok((select kind = 'job' and job_id = tests.fx('job_a') and source = 'web' and notes = 'Started prep'
                   from public.time_entries where id = tests.fx('te_job')), 'job clock-in: kind inferred from the job');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_a'))$$, '23505', 'one open job clock per member');

-- own entries only; notes on the open entry only
select tests.eq(tests.row_count($$select 1 from public.time_entries$$), 2::bigint, 'technicians read their own entries');
select tests.eq(tests.row_count($$update public.time_entries set notes = 'Waiting on customer' where id = tests.fx('te_shift')$$), 1::bigint,
                'technicians may annotate their open entry');
select tests.throws($$update public.time_entries set clock_in = clock_in - interval '2 hours' where id = tests.fx('te_shift')$$, '42501',
                    'technicians cannot move their clock-in');
select tests.throws($$update public.time_entries set clock_out = now() + interval '8 hours' where id = tests.fx('te_shift')$$, '42501',
                    'technicians cannot set a clock-out directly');
select tests.throws($$update public.time_entries set source = 'manual', member_id = tests.fx('m_tech2_a') where id = tests.fx('te_shift')$$,
                    '42501', 'technicians cannot reassign entries');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                      values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'shift', '2025-06-01 13:00Z', '2025-06-01 23:00Z')$$, '42501',
                    'technicians cannot add entries');
select tests.eq(tests.row_count($$delete from public.time_entries$$), 0::bigint, 'technicians cannot delete entries');

-- clocking out of the shift closes the job clock too
select tests.eq((public.clock_out(tests.fx('shop_a'), p_notes => 'Done for the day')).id, tests.fx('te_shift'), 'clock out of the shift');
select tests.ok((select bool_and(clock_out = now()) from public.time_entries where id in (tests.fx('te_shift'), tests.fx('te_job'))),
                'shift and job clocks are both closed');
select tests.eq((select notes from public.time_entries where id = tests.fx('te_shift')), 'Done for the day', 'clock-out note saved');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'))$$, 'P0002', '%not clocked in%', 'nothing left to clock out');
select tests.throws($$select public.clock_out(tests.fx('shop_a'), 'job')$$, 'P0002', 'no open job clock');
select tests.throws($$select public.clock_out(tests.fx('shop_a'), p_now => '2030-01-01Z')$$, '42501',
                    'technicians cannot choose their clock-out time');
select tests.eq(tests.row_count($$update public.time_entries set notes = 'edit after close' where id = tests.fx('te_shift')$$), 0::bigint,
                'closed entries are read-only to technicians');
-- an immediate clock-out leaves a zero-length entry that never blocks the next clock-in
select tests.lives($$select public.clock_in(tests.fx('shop_a'))$$, 'clock in again right away');
select tests.eq(tests.row_count($$select 1 from public.time_entries where clock_out is null$$), 1::bigint, 'one open shift again');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.time_entries$$), 0::bigint, 'technicians cannot see colleagues'' entries');
select tests.eq(tests.row_count($$update public.time_entries set notes = 'x'$$), 0::bigint, 'or edit them');

-- ------------------------------------------------------------ manager: back-dated clocks, manual entries, edits
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('te_mgr', (public.clock_in(tests.fx('shop_a'), p_now => '2025-06-02 13:00Z')).id);
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_now => '2025-06-02 12:00Z')$$, '22023', '%before clock-in%',
                         'clock-out cannot precede clock-in');
select tests.eq((public.clock_out(tests.fx('shop_a'), p_now => '2025-06-02 21:00Z')).clock_out, '2025-06-02 21:00Z'::timestamptz,
                'managers may clock out at a given time');
select tests.throws_like($$select public.clock_in(tests.fx('shop_a'), p_now => '2025-06-02 20:00Z')$$, '23P01', '%overlaps%',
                         'a clock-in inside an existing entry is rejected');
select tests.lives($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_a2'), p_now => '2025-06-02 18:00Z')$$,
                   'managers clock in to any job of the shop (job time may run inside a shift)');
select tests.lives($$select public.clock_out(tests.fx('shop_a'), 'job', '2025-06-02 19:00Z')$$, 'job clock-out');

insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out, source, notes)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 14:00Z', '2025-06-01 22:00Z', 'app', 'Forgot to clock')
  returning tests.fx_set('te_manual', id);
select tests.ok((select source = 'manual' and created_by = tests.fx('u_manager_a') from public.time_entries where id = tests.fx('te_manual')),
                'manual entries are marked manual and attributed');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 21:00Z', '2025-06-01 23:00Z')$$, '23P01',
                    'overlapping shifts for the same member are rejected');
select tests.lives($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                     values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 22:00Z', '2025-06-01 23:00Z')$$,
                   'back-to-back entries do not overlap');
select tests.lives($$insert into public.time_entries (shop_id, member_id, kind, job_id, clock_in, clock_out)
                     values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'job', tests.fx('job_a2'), '2025-06-01 15:00Z', '2025-06-01 17:00Z')
                     returning tests.fx_set('te_manual_job', id)$$,
                   'job time may overlap the same member''s shift');
select tests.lives($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                     values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'shift', '2025-06-01 15:00Z', '2025-06-01 17:00Z')$$,
                   'different members may overlap');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'job', '2025-06-03 15:00Z')$$, '23514', 'job entries need a job');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, job_id, clock_in)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', tests.fx('job_a2'), '2025-06-03 15:00Z')$$, '23514',
                    'shift entries carry no job');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-03 15:00Z', '2025-06-03 14:00Z')$$, '23514',
                    'clock-out cannot precede clock-in');
-- open entries: at most one per member & kind (partial unique index backed by the exclusion constraint)
insert into public.time_entries (shop_id, member_id, kind, clock_in)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-04 13:00Z') returning tests.fx_set('te_open', id);
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-10 13:00Z')$$, null,
                    'a second open shift is rejected');
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'time_entries_one_open_key'
                          and indexdef like '%WHERE (clock_out IS NULL)%'), 'open-entry unique index exists');
select tests.throws($$update public.time_entries set clock_in = '2025-06-01 21:00Z' where id = tests.fx('te_open')$$, '23P01',
                    'edits are overlap-checked too');
select tests.lives($$update public.time_entries set clock_out = '2025-06-04 20:00Z' where id = tests.fx('te_open')$$,
                   'managers close entries');
select tests.lives($$update public.time_entries set clock_in = '2025-06-01 13:30Z', notes = 'Adjusted' where id = tests.fx('te_manual')$$,
                   'managers edit closed entries');
select tests.throws($$update public.time_entries set member_id = tests.fx('m_tech_b') where id = tests.fx('te_manual')$$, '23503',
                    'entries cannot point at another shop''s member');
select tests.throws($$update public.time_entries set job_id = tests.fx('job_b') where id = tests.fx('te_manual_job')$$, '23503',
                    'entries cannot point at another shop''s job');
select tests.throws($$update public.time_entries set shop_id = tests.fx('shop_b') where id = tests.fx('te_manual')$$, '42501',
                    'entries never move between shops');
select tests.throws($$insert into public.time_entries (shop_id, member_id, kind, clock_in)
                      values (tests.fx('shop_b'), tests.fx('m_tech_b'), 'shift', '2025-06-01 13:00Z')$$, '42501',
                    'managers cannot add entries in another shop');
select tests.eq(tests.row_count($$delete from public.time_entries where id = tests.fx('te_open')$$), 1::bigint, 'managers delete entries');
select tests.eq(tests.row_count($$select 1 from public.time_entries$$), 9::bigint, 'managers read all entries of the shop');

-- ------------------------------------------------------------ job clock rules
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'cancelled')
  returning tests.fx_set('job_cancelled', id);
select tests.throws_like($$select public.clock_in(tests.fx('shop_a'), tests.fx('job_cancelled'))$$, '22023', '%cancelled%',
                         'no clock-in to cancelled jobs');
-- deleting a job keeps the hours
delete from public.jobs where id = tests.fx('job_a2');
select tests.ok((select job_id is null and kind = 'job' from public.time_entries where id = tests.fx('te_manual_job')),
                'deleting a job keeps its time entries, unlinked');

-- ------------------------------------------------------------ isolation & membership
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.fx_set('te_b', (public.clock_in(tests.fx('shop_b'))).id);
select tests.throws($$select public.clock_in(tests.fx('shop_a'))$$, '42501', 'members of B cannot clock in to A');
select tests.eq(tests.row_count($$select 1 from public.time_entries$$), 1::bigint, 'technician B sees only their own entry');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.time_entries where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B sees none of A''s entries');
select tests.eq(tests.row_count($$update public.time_entries set notes = 'x' where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B edits none of A''s entries');
select tests.eq(tests.row_count($$delete from public.time_entries where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B deletes none of A''s entries');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.clock_out(tests.fx('shop_b'))$$, '42501', 'members of A cannot clock out in B');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.clock_in(tests.fx('shop_a'))$$, '42501', 'outsiders cannot clock in');
select tests.as_anon();
select tests.throws($$select public.clock_in(tests.fx('shop_a'))$$, '42501', 'anon cannot call clock_in');
select tests.throws($$select public.clock_out(tests.fx('shop_a'))$$, '42501', 'anon cannot call clock_out');

-- deactivated members cannot clock and lose read access
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.clock_in(tests.fx('shop_a'))$$, '42501', 'inactive members cannot clock in');
select tests.eq(tests.row_count($$select 1 from public.time_entries$$), 0::bigint, 'inactive members read nothing');

-- members with time history are deactivated, not deleted; deleting the shop still works
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$delete from public.shop_members where id = tests.fx('m_tech2_a')$$, '23503',
                    'a member with time entries cannot be deleted');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 1::bigint, 'the owner deletes shop B');
select tests.as_superuser();
select tests.eq((select count(*) from public.time_entries where shop_id = tests.fx('shop_b')), 0::bigint, 'its time entries go with it');
select tests.ok(not has_table_privilege('anon', 'public.time_entries', 'select'), 'anon has no time entry access');
