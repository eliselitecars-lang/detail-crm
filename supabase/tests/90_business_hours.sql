-- 90 integration: replace_business_hours — atomic save of a shop's weekly
-- hours (owner/admin): validation with readable 22023 messages, overlap /
-- order violations roll the whole call back (the old hours stay), 24:00,
-- empty = closed all week, role matrix and cross-shop isolation.
\ir fixtures/two_shops.psql

create function pg_temp.hours(p_shop uuid) returns text language sql as $$
  select coalesce(string_agg(weekday || ' ' || to_char(opens_at, 'HH24:MI') || '-'
                             || case when closes_at = '24:00' then '24:00' else to_char(closes_at, 'HH24:MI') end,
                             ', ' order by weekday, opens_at), '')
    from public.business_hours where shop_id = p_shop
$$;
grant execute on function pg_temp.hours(uuid) to authenticated;
create temp table b_before as select pg_temp.hours(tests.fx('shop_b')) as h;
grant select on b_before to authenticated;

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(weekday, opens_at, closes_at))
                   from public.replace_business_hours(tests.fx('shop_a'),
                          '[{"weekday": 2, "opens_at": "13:00", "closes_at": "17:30"},
                            {"weekday": 1, "opens_at": "08:00:00", "closes_at": "12:00"},
                            {"weekday": 2, "opens_at": "08:00", "closes_at": "12:00"},
                            {"weekday": 6, "opens_at": "20:00", "closes_at": "24:00"}]')),
                '[[1, "08:00:00", "12:00:00"], [2, "08:00:00", "12:00:00"], [2, "13:00:00", "17:30:00"], [6, "20:00:00", "24:00:00"]]'::jsonb,
                'stored rows come back ordered by weekday, opens_at (24:00 allowed)');
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '1 08:00-12:00, 2 08:00-12:00, 2 13:00-17:30, 6 20:00-24:00',
                'the old hours were replaced');

-- ------------------------------------------------------------ atomicity: a bad set keeps the previous hours
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'),
                      '[{"weekday": 3, "opens_at": "09:00", "closes_at": "17:00"},
                        {"weekday": 3, "opens_at": "16:00", "closes_at": "18:00"}]')$$, '23P01',
                    'overlapping intervals on a day are refused');
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '1 08:00-12:00, 2 08:00-12:00, 2 13:00-17:30, 6 20:00-24:00',
                'the previous hours are still there after the failed save');
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'),
                      '[{"weekday": 4, "opens_at": "17:00", "closes_at": "09:00"}]')$$, '23514', 'closing before opening');
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'),
                      '[{"weekday": 4, "opens_at": "24:00", "closes_at": "24:00"}]')$$, '23514', 'an empty interval');
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '1 08:00-12:00, 2 08:00-12:00, 2 13:00-17:30, 6 20:00-24:00',
                'still unchanged');
select tests.lives($$select * from public.replace_business_hours(tests.fx('shop_a'),
                     '[{"weekday": 5, "opens_at": "09:00", "closes_at": "12:00"},
                       {"weekday": 5, "opens_at": "12:00", "closes_at": "15:00"}]')$$,
                   'back-to-back intervals do not overlap');

-- ------------------------------------------------------------ validation (22023, readable)
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'), '{"weekday": 1}')$$, '22023', '%JSON array%',
                         'an object is not an array');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'), null)$$, '22023', '%JSON array%', 'null');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           (select jsonb_agg(jsonb_build_object('weekday', 0, 'opens_at', lpad(h::text, 2, '0') || ':00',
                                                                'closes_at', lpad(h::text, 2, '0') || ':30'))
                              from generate_series(0, 22) h)
                           || (select jsonb_agg(jsonb_build_object('weekday', 1, 'opens_at', lpad(h::text, 2, '0') || ':00',
                                                                   'closes_at', lpad(h::text, 2, '0') || ':30'))
                                 from generate_series(0, 22) h)
                           || (select jsonb_agg(jsonb_build_object('weekday', 2, 'opens_at', lpad(h::text, 2, '0') || ':00',
                                                                   'closes_at', lpad(h::text, 2, '0') || ':30'))
                                 from generate_series(0, 4) h))$$, '22023', '%at most 50%', '51 intervals are too many');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'), '[1]')$$, '22023', '%row 1 must be an object%',
                         'rows must be objects');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 7, "opens_at": "09:00", "closes_at": "10:00"}]')$$, '22023', '%row 1: weekday%', 'weekday 0-6');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 1.5, "opens_at": "09:00", "closes_at": "10:00"}]')$$, '22023', '%weekday%', 'whole numbers');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": "1", "opens_at": "09:00", "closes_at": "10:00"}]')$$, '22023', '%weekday%', 'numbers, not strings');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 1, "opens_at": "9am", "closes_at": "10:00"}]')$$, '22023', '%opens_at%', 'HH:MM');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 1, "opens_at": "09:00", "closes_at": "24:30"}]')$$, '22023', '%closes_at%', 'nothing after 24:00');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 1, "opens_at": "09:00"}]')$$, '22023', '%closes_at%', 'closes_at required');
select tests.throws_like($$select * from public.replace_business_hours(tests.fx('shop_a'),
                           '[{"weekday": 1, "opens_at": "09:00", "closes_at": "10:00", "shop_id": "x"}]')$$, '22023',
                         '%may only have%', 'no other keys (e.g. a shop id)');
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '5 09:00-12:00, 5 12:00-15:00', 'refused calls changed nothing');

-- ------------------------------------------------------------ closed all week
select tests.eq((select count(*) from public.replace_business_hours(tests.fx('shop_a'), '[]')), 0::bigint, 'an empty array');
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '', 'means closed all week');

-- ------------------------------------------------------------ roles and isolation
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select count(*) from public.replace_business_hours(tests.fx('shop_a'),
                   '[{"weekday": 1, "opens_at": "09:00", "closes_at": "17:00"}]')), 1::bigint, 'owners save hours');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'), '[]')$$, '42501', 'managers cannot');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'), '[]')$$, '42501', 'technicians cannot');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'), '[]')$$, '42501', 'another shop''s admin cannot');
select tests.throws($$select * from public.replace_business_hours(null, '[]')$$, '42501', 'a shop is required');
select tests.as_anon();
select tests.throws($$select * from public.replace_business_hours(tests.fx('shop_a'), '[]')$$, '42501', 'anon cannot');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(pg_temp.hours(tests.fx('shop_a')), '1 09:00-17:00', 'the refused calls changed nothing');
select tests.as_superuser();
select tests.eq(pg_temp.hours(tests.fx('shop_b')), (select h from b_before), 'shop B''s hours were never touched');
