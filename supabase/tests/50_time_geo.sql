-- 50 sched: geostamped clock in / clock out (P-24, 0056) — location stored
-- on the opened / closed entry (and the job entry a shift clock-out
-- closes), both-or-neither and range validation, the geo columns are
-- evidence (no API writes, even by managers), technicians only their own
-- entries, cross-shop isolation, existing calls unchanged.
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.fx_set('te_shift', (public.clock_in(tests.fx('shop_a'), p_lat => 33.5207, p_lng => -86.8025, p_accuracy_m => 12.5)).id);
select tests.eq((select clock_in_lat::text || ',' || clock_in_lng::text || ',' || clock_in_accuracy_m::text
                   from public.time_entries where id = tests.fx('te_shift')), '33.5207,-86.8025,12.5', 'clock-in location stored');
select tests.fx_set('te_job', (public.clock_in(tests.fx('shop_a'), tests.fx('job_a'), p_lat => 33.6, p_lng => -86.7)).id);
select tests.ok((select clock_in_accuracy_m is null from public.time_entries where id = tests.fx('te_job')), 'accuracy is optional');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_lat => 33.5)$$, '22023', '%latitude and longitude%',
                         'both coordinates or neither');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_lat => 95, p_lng => 0)$$, '22023', '%latitude%', 'latitude range');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_lat => 0, p_lng => 190)$$, '22023', '%longitude%', 'longitude range');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_lat => 'NaN', p_lng => 0)$$, '22023', '%latitude%', 'NaN');
select tests.throws_like($$select public.clock_out(tests.fx('shop_a'), p_lat => 1, p_lng => 1, p_accuracy_m => -1)$$, '22023', '%accuracy%',
                         'accuracy range');
select tests.throws_like($$select public.clock_in(tests.fx('shop_a'), p_lat => 1, p_lng => 1, p_accuracy_m => 20000)$$, '22023', '%accuracy%',
                         'clock_in validates too');
select tests.eq((public.clock_out(tests.fx('shop_a'), p_lat => 33.51, p_lng => -86.81, p_accuracy_m => 8)).id, tests.fx('te_shift'),
                'clock out of the shift with a location');
select tests.ok((select clock_out_lat = 33.51 and clock_out_lng = -86.81 and clock_out_accuracy_m = 8
                   from public.time_entries where id = tests.fx('te_shift')), 'clock-out location stored');
select tests.ok((select clock_out is not null and clock_out_lat = 33.51 and clock_out_lng = -86.81
                   from public.time_entries where id = tests.fx('te_job')), 'the job entry closed with the shift gets the same stamp');
select tests.fx_set('te_plain', (public.clock_in(tests.fx('shop_a'))).id);
select tests.ok((select clock_in_lat is null and clock_in_lng is null from public.time_entries where id = tests.fx('te_plain')),
                'no location: nothing stored (existing callers unchanged)');
select tests.lives($$select public.clock_out(tests.fx('shop_a'), 'shift', null, 'done')$$, 'positional 4-argument call still works');

-- technicians: evidence is read-only, own entries only
select tests.eq(tests.row_count($$select * from public.time_entries where id = tests.fx('te_shift') and clock_in_lat is not null$$), 1::bigint,
                'the member reads their own locations');
select tests.fx_set('te_open', (public.clock_in(tests.fx('shop_a'), p_lat => 1, p_lng => 1)).id);
select tests.throws($$update public.time_entries set clock_in_lat = 2 where id = tests.fx('te_open')$$, '42501',
                    'a technician cannot move their own clock-in location');
select tests.eq(tests.row_count($$update public.time_entries set notes = 'on site' where id = tests.fx('te_open')$$), 1::bigint,
                'notes of the open entry stay editable');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select * from public.time_entries where id = tests.fx('te_shift')$$), 0::bigint,
                'other technicians cannot read it');

-- managers: edit times and notes, never locations
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.time_entries set clock_in = clock_in - interval '5 minutes', notes = 'fixed'
                                   where id = tests.fx('te_shift')$$), 1::bigint, 'managers still edit times and notes');
select tests.throws_like($$update public.time_entries set clock_out_lat = 0 where id = tests.fx('te_shift')$$, '42501', '%cannot be edited%',
                         'managers cannot edit a clock-out location');
select tests.throws($$update public.time_entries set clock_in_lat = null, clock_in_lng = null, clock_in_accuracy_m = null
                      where id = tests.fx('te_shift')$$, '42501', 'nor erase it');
select tests.throws_like($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out, clock_in_lat, clock_in_lng)
                           values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 13:00Z', '2025-06-01 14:00Z', 1, 1)$$,
                         '42501', '%recorded only by clock in%', 'manual entries carry no location');
select tests.lives($$insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out)
                      values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 13:00Z', '2025-06-01 14:00Z')$$,
                   'manual entries without a location are fine');
select tests.throws($$update public.time_entries set clock_in_lat = 1 where id = (select id from public.time_entries where member_id = tests.fx('m_tech2_a') limit 1)$$,
                    '42501', 'a location cannot be added afterwards either');
select tests.eq((select clock_in_lat from public.time_entries where id = tests.fx('te_shift')), 33.5207::double precision,
                'managers read locations');

-- service_role (edge functions / support) and constraints
select tests.as_service();
select tests.throws($$update public.time_entries set clock_in_lng = null where id = tests.fx('te_shift')$$, '23514',
                    'pair constraint holds even for trusted writers');
select tests.throws($$update public.time_entries set clock_in_accuracy_m = 5, clock_in_lat = null, clock_in_lng = null where id = tests.fx('te_shift')$$,
                    '23514', 'accuracy only with coordinates');

-- cross-shop
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$select * from public.time_entries where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B reads none of A''s entries (or locations)');
select tests.throws($$select public.clock_in(tests.fx('shop_a'), p_lat => 1, p_lng => 1)$$, '42501', 'shop B cannot clock in to A');
select tests.as_anon();
select tests.throws($$select public.clock_in(tests.fx('shop_a'), p_lat => 1, p_lng => 1)$$, '42501', 'anon cannot clock in');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.time_entry_check_geo(1, 1, 1)$$, '42501', 'the validator is internal');
select tests.ok(to_regprocedure('public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text)') is null
                and to_regprocedure('public.clock_out(uuid, public.time_entry_kind, timestamptz, text)') is null,
                'no stale overloads of clock_in / clock_out');
