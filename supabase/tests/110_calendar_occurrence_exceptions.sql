-- 110 sched: one occurrence of a repeating calendar event can be skipped
-- (0115, P-17 "edit/delete occurrence vs series") — except_dates validation,
-- expansion without the skipped dates (count still counts them), capacity,
-- and the dates kept (shifted) when an update rewrites the rule without them.
\ir fixtures/two_shops.psql

select tests.as_superuser();
create function pg_temp.occ_starts(p_block uuid, p_from timestamptz, p_to timestamptz) returns text[]
language sql stable as $$
  select coalesce(array_agg(to_char(o.starts_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') order by o.starts_at), '{}')
  from public.blocked_time_occurrences(tests.fx('shop_a'), p_from, p_to) o where o.block_id = p_block
$$;

-- ============================================================ validation
select tests.ok(public.calendar_recurrence_valid('{"freq": "week", "except_dates": ["2025-06-09"]}'), 'one skipped date');
select tests.ok(public.calendar_recurrence_valid('{"freq": "week", "count": 5, "except_dates": []}'), 'an empty list');
select tests.ok(public.calendar_recurrence_valid('{"freq": "day", "except_dates": null}'), 'null');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "except_dates": "2025-06-09"}'), 'must be an array');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "except_dates": ["2025-02-30"]}'), 'real dates only');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "except_dates": ["6/9/2025"]}'), 'YYYY-MM-DD');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "except_dates": [20250609]}'), 'strings');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "except_dates": ["2025-06-09", "2025-06-09"]}'), 'distinct');
select tests.ok(not public.calendar_recurrence_valid(
                  jsonb_build_object('freq', 'day', 'except_dates',
                    (select jsonb_agg(to_char(date '2025-01-01' + g, 'YYYY-MM-DD')) from generate_series(0, 500) g))),
                'at most 500');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
                      values (tests.fx('shop_a'), 'meeting', '{"freq": "day", "except_dates": ["nope"]}',
                              '2025-06-02 14:00Z', '2025-06-02 15:00Z')$$,
                    '23514', 'the table CHECK refuses a bad list');

-- ============================================================ expansion
-- weekly Monday time off for a technician, 09:00-17:00 local, 4 times
insert into public.blocked_times (shop_id, member_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'time_off', '{"freq": "week", "count": 4}',
          '2025-06-02 14:00Z', '2025-06-02 22:00Z') returning tests.fx_set('bt_off', id);
select tests.as_superuser();
select tests.eq(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15'),
                array['2025-06-02 09:00', '2025-06-09 09:00', '2025-06-16 09:00', '2025-06-23 09:00'], 'four Mondays');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-09"]}'
 where id = tests.fx('bt_off');
select tests.as_superuser();
select tests.eq(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15'),
                array['2025-06-02 09:00', '2025-06-16 09:00', '2025-06-23 09:00'],
                'the skipped Monday is gone; it still counts towards the 4 (no 5th Monday)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-09', '2025-06-10') e
                  where e.id = tests.fx('bt_off')), 0::bigint, 'calendar_events leaves it out');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-16', '2025-06-17') e
                  where e.id = tests.fx('bt_off')), 1::bigint, '... and keeps the next one');
-- the original row's own date can be skipped too
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-02", "2025-06-09"]}'
 where id = tests.fx('bt_off');
select tests.as_superuser();
select tests.eq(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15'),
                array['2025-06-16 09:00', '2025-06-23 09:00'], 'the first occurrence can be skipped');
-- a skipped date that is not an occurrence changes nothing
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-10"]}'
 where id = tests.fx('bt_off');
select tests.as_superuser();
select tests.eq(cardinality(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15')), 4, 'not an occurrence: no effect');

-- ============================================================ kept on a rule rewrite
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-09"]}'
 where id = tests.fx('bt_off');
-- an app that predates except_dates saves the series (no key): the skip stays
update public.blocked_times set recurrence = '{"freq": "week", "count": 4}', reason = 'Class'
 where id = tests.fx('bt_off');
select tests.eq((select recurrence -> 'except_dates' from public.blocked_times where id = tests.fx('bt_off')),
                '["2025-06-09"]'::jsonb, 'an update without the key keeps the skipped dates');
-- a series-wide move by one day moves the skipped date with it
update public.blocked_times set starts_at = starts_at + interval '1 day', ends_at = ends_at + interval '1 day',
       recurrence = '{"freq": "week", "count": 4}'
 where id = tests.fx('bt_off');
select tests.eq((select recurrence -> 'except_dates' from public.blocked_times where id = tests.fx('bt_off')),
                '["2025-06-10"]'::jsonb, 'moved with the series');
select tests.as_superuser();
select tests.eq(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15'),
                array['2025-06-03 09:00', '2025-06-17 09:00', '2025-06-24 09:00'], 'still skipped after the move');
-- carried dates before the (new) start are dropped
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-05-27", "2025-06-10"]}'
 where id = tests.fx('bt_off');
update public.blocked_times set recurrence = '{"freq": "week", "count": 4}' where id = tests.fx('bt_off');
select tests.eq((select recurrence -> 'except_dates' from public.blocked_times where id = tests.fx('bt_off')),
                '["2025-06-10"]'::jsonb, 'a skipped date before the start is not carried');
-- an explicit empty list restores every occurrence
update public.blocked_times set starts_at = '2025-06-02 14:00Z', ends_at = '2025-06-02 22:00Z',
       recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-09"]}'
 where id = tests.fx('bt_off');
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": []}'
 where id = tests.fx('bt_off');
select tests.as_superuser();
select tests.eq(cardinality(pg_temp.occ_starts(tests.fx('bt_off'), '2025-06-01', '2025-07-15')), 4, 'restored with []');
-- and a rule cleared to "does not repeat" carries nothing
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-09"]}'
 where id = tests.fx('bt_off');
update public.blocked_times set recurrence = null where id = tests.fx('bt_off');
select tests.eq((select recurrence from public.blocked_times where id = tests.fx('bt_off')), null::jsonb,
                'no rule, nothing carried');

-- ============================================================ capacity
-- a skipped occurrence no longer takes the member's capacity that day
update public.blocked_times set recurrence = '{"freq": "week", "count": 4, "except_dates": ["2025-06-09"]}'
 where id = tests.fx('bt_off');
select tests.as_superuser();
select tests.eq((select count(*) from public.blocked_time_occurrences(tests.fx('shop_a'), '2025-06-09', '2025-06-10') o
                  where o.member_id = tests.fx('m_tech_a') and o.affects_capacity), 0::bigint,
                'no time off for the member on the skipped Monday (capacity reads blocked_time_occurrences)');
