-- 50 sched: private booking links (P-17, 0050/0053/0054) — admin-only
-- management (managers read), server-issued immutable tokens, service
-- validation, public_booking_link, link-scoped slots and bookings
-- (non-online-bookable services only through a link), expiry / inactive /
-- other-shop tokens (PT404), booking answers stored in jobs.custom_data.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql
\ir fixtures/50_ranges.psql

-- ============================================================ management
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.booking_links (shop_id, name, service_ids, note, token)
  values (tests.fx('shop_a'), '  Fleet customers  ', array[tests.fx('svc_hidden'), tests.fx('svc_a'), tests.fx('svc_hidden')],
          'Fleet pricing on file', '00000000-0000-0000-0000-000000000001')
  returning tests.fx_set('link_a', id);
select tests.as_superuser();
select tests.fx_set('tok_a', (select token from public.booking_links where id = tests.fx('link_a')));
select tests.ok(tests.fx('tok_a') <> '00000000-0000-0000-0000-000000000001'::uuid, 'the token is server-issued (a client value is ignored)');
select tests.ok((select name = 'Fleet customers' and service_ids = array[tests.fx('svc_hidden'), tests.fx('svc_a')]
                   and created_by = tests.fx('u_admin_a') from public.booking_links where id = tests.fx('link_a')),
                'name trimmed, services de-duplicated in order, created_by stamped');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$update public.booking_links set token = gen_random_uuid() where id = tests.fx('link_a')$$, '42501',
                         '%token%', 'the token cannot be changed');
select tests.throws_like($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('prod_a')])$$,
                         '23514', '%services%', 'products cannot be booked through a link');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('svc_b')])$$,
                    '23514', 'another shop''s service');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('svc_inactive')])$$,
                    '23514', 'an inactive service');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'x', '{}')$$,
                    '23514', 'at least one service');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), ' ', array[tests.fx('svc_a')])$$,
                    '23514', 'a name is required');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids)
                      select tests.fx('shop_a'), 'x', array_agg(gen_random_uuid()) from generate_series(1, 51)$$,
                    '23514', 'at most 50 services');
-- (the BEFORE trigger reads services under the caller's RLS, so it refuses
-- before the WITH CHECK does; either way nothing is written)
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_b'), 'x', array[tests.fx('svc_b')])$$,
                    null, 'admins of A cannot create links for B');
select tests.as_superuser();
select tests.eq((select count(*) from public.booking_links where shop_id = tests.fx('shop_b')), 0::bigint, 'nothing written for B');
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.booking_links (shop_id, name, service_ids, expires_at)
  values (tests.fx('shop_a'), 'Expired promo', array[tests.fx('svc_hidden')], now() - interval '1 minute')
  returning tests.fx_set('link_expired', id);
insert into public.booking_links (shop_id, name, service_ids, active)
  values (tests.fx('shop_a'), 'Paused', array[tests.fx('svc_hidden')], false)
  returning tests.fx_set('link_off', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.booking_links where shop_id = tests.fx('shop_a')), 3::bigint, 'managers read links (to share them)');
select tests.throws($$insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('svc_a')])$$,
                    '42501', 'managers cannot create links');
select tests.eq(tests.row_count($$update public.booking_links set name = 'x' where id = tests.fx('link_a')$$), 0::bigint,
                'managers cannot edit links');
select tests.eq(tests.row_count($$delete from public.booking_links where id = tests.fx('link_off')$$), 0::bigint,
                'managers cannot delete links');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.booking_links'), 0::bigint, 'technicians read no links');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$select * from public.booking_links where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B reads none of A''s links');
select tests.eq(tests.row_count($$update public.booking_links set active = false where id = tests.fx('link_a')$$), 0::bigint,
                'shop B cannot edit A''s links');
select tests.as_anon();
select tests.throws($$select * from public.booking_links$$, '42501', 'anon has no table access');

-- ============================================================ public_booking_link
select tests.as_anon();
create temp table page as select public.public_booking_link(tests.fx('tok_a')) as p;
select tests.eq((select p ->> 'slug' from page), 'shop-a', 'slug');
select tests.eq((select p ->> 'name' || ' / ' || (p ->> 'note') from page), 'Fleet customers / Fleet pricing on file', 'name and note');
select tests.eq((select array_agg(e ->> 'name' order by e ->> 'name') from page, jsonb_array_elements(p -> 'catalog' -> 'services') e),
                array['Full Detail', 'Staff Only'], 'the catalog lists exactly the link''s services, non-bookable ones included');
select tests.eq((select jsonb_array_length(p -> 'catalog' -> 'addons') from page), 0, 'no add-ons outside the link');
select tests.ok((select (p -> 'catalog') ?& array['vehicle_categories', 'service_categories', 'services', 'addons'] from page),
                'same catalog shape as public_booking_catalog');
select tests.throws_like($$select public.public_booking_link(tests.fx('link_expired'))$$, 'PT404', '%not found%', 'an id is not a token');
select tests.as_superuser();
select tests.fx_set('tok_expired', (select token from public.booking_links where id = tests.fx('link_expired')));
select tests.fx_set('tok_off', (select token from public.booking_links where id = tests.fx('link_off')));
select tests.as_anon();
select tests.throws($$select public.public_booking_link(tests.fx('tok_expired'))$$, 'PT404', 'expired link');
select tests.throws($$select public.public_booking_link(tests.fx('tok_off'))$$, 'PT404', 'inactive link');
select tests.throws($$select public.public_booking_link(gen_random_uuid())$$, 'PT404', 'unknown link');
select tests.throws($$select public.public_booking_link(null)$$, 'PT404', 'null token');
select tests.as_superuser();
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.throws($$select public.public_booking_link(tests.fx('tok_a'))$$, '55000', 'online booking off');
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

-- ============================================================ link-scoped slots
select tests.as_superuser();
select tests.eq((select count(*) from public.public_booking_slots('shop-a', array[tests.fx('svc_hidden')], '2025-06-09', '2025-06-09',
                   null, 'shop', tests.fx('tok_a'), '2025-06-01 12:00Z')), 9::bigint, 'a link opens a non-bookable service');
select tests.throws_like($$select * from public.public_booking_slots('shop-a', array[tests.fx('svc_hidden')], '2025-06-09', '2025-06-09',
                             null, 'shop', null, '2025-06-01 12:00Z')$$, '22023', '%not available%', 'not without the link');
select tests.throws_like($$select * from public.public_booking_slots('shop-a', array[tests.fx('svc_wash')], '2025-06-09', '2025-06-09',
                             null, 'shop', tests.fx('tok_a'), '2025-06-01 12:00Z')$$, '22023', '%not available%',
                         'a link offers only its own services');
select tests.throws($$select * from public.public_booking_slots('shop-b', array[tests.fx('svc_b')], '2025-06-09', '2025-06-09',
                        null, null, tests.fx('tok_a'), '2025-06-01 12:00Z')$$, 'PT404', 'another shop''s link token');
select tests.throws($$select * from public.public_booking_slots('shop-a', array[tests.fx('svc_hidden')], '2025-06-09', '2025-06-09',
                        null, null, tests.fx('tok_expired'), '2025-06-01 12:00Z')$$, 'PT404', 'expired link token');

-- booking_link_service_ids (internal)
select tests.as_service();
select tests.eq(public.booking_link_service_ids(tests.fx('shop_a'), tests.fx('tok_a')), array[tests.fx('svc_hidden'), tests.fx('svc_a')],
                'live link: its services in order');
select tests.eq(public.booking_link_service_ids(tests.fx('shop_b'), tests.fx('tok_a')), null::uuid[], 'another shop: null');
select tests.eq(public.booking_link_service_ids(tests.fx('shop_a'), tests.fx('tok_off')), null::uuid[], 'inactive: null');
select tests.eq(public.booking_link_service_ids(tests.fx('shop_a'), tests.fx('tok_expired')), null::uuid[], 'expired: null');
select tests.as_superuser();
update public.services set archived_at = now() where id = tests.fx('svc_a');
select tests.as_service();
select tests.eq(public.booking_link_service_ids(tests.fx('shop_a'), tests.fx('tok_a')), array[tests.fx('svc_hidden')],
                'archived services drop out of a live link');
select tests.as_superuser();
update public.services set archived_at = null where id = tests.fx('svc_a');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.booking_link_service_ids(tests.fx('shop_a'), tests.fx('tok_a'))$$, '42501',
                    'the helper is internal');

-- ============================================================ bookings through a link
select tests.as_superuser();
-- the answers are the shop's booking questions (validated by comms 0088;
-- without the comms range they are stored as given)
\if :has_comms
insert into public.custom_fields (shop_id, entity, key, label, type, show_in_booking) values
  (tests.fx('shop_a'), 'job', 'gate_code', 'Gate code', 'text', true),
  (tests.fx('shop_a'), 'job', 'pets', 'Pets at home', 'checkbox', true);
\endif
create temp table link_booking as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'service_ids', jsonb_build_array(tests.fx('svc_hidden')), 'link_token', tests.fx('tok_a'),
           'answers', jsonb_build_object('gate_code', '1234', 'pets', true))), '2025-06-01 12:00Z') as r;
select tests.fx_set('job_link', (select j.id from public.jobs j join link_booking b on j.number = (b.r ->> 'job_number')::bigint
                                   where j.shop_id = tests.fx('shop_a')));
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_link')), 1100::bigint,
                'priced from the catalog (1000 + 10% tax)');
select tests.eq((select custom_data from public.jobs where id = tests.fx('job_link')), '{"gate_code": "1234", "pets": true}'::jsonb,
                'answers stored in jobs.custom_data');
select tests.eq((select source::text from public.jobs where id = tests.fx('job_link')), 'online_booking', 'an online booking');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_hidden')), 'starts_at', '2025-06-09T17:00:00Z')),
                             '2025-06-01 12:00Z')$$, '22023', '%not available for online booking%',
                         'without the link the hidden service is refused');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'link_token', tests.fx('tok_a'),
                             'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$, '22023', '%not available%',
                         'with a link, only the link''s services');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'link_token', tests.fx('tok_a'), 'addon_ids', jsonb_build_array(tests.fx('addon_engine')),
                             'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$, '22023', '%add-ons%',
                         'with a link, only the link''s add-ons');
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                        'link_token', tests.fx('tok_expired'), 'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                    'PT404', 'an expired link books nothing');
select tests.throws($$select public.create_online_booking('shop-b', pg_temp.booking(jsonb_build_object(
                        'service_ids', jsonb_build_array(tests.fx('svc_b')), 'vehicle', jsonb_build_object('make', 'Kia', 'model', 'Rio'),
                        'link_token', tests.fx('tok_a'), 'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                    'PT404', 'a link of another shop books nothing');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'link_token', 'not-a-uuid', 'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                         '22023', '%booking link%', 'a malformed link token');

-- answers validation
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'answers', '[1]'::jsonb, 'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                         '22023', '%answers must be an object%', 'answers must be an object');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'answers', (select jsonb_object_agg('q' || i, i) from generate_series(1, 51) i),
                             'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                         '22023', '%too many answers%', 'at most 50 answers');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'answers', jsonb_build_object('Gate Code', 'x'), 'starts_at', '2025-06-09T17:00:00Z')), '2025-06-01 12:00Z')$$,
                         '22023', '%question keys%', 'answers are keyed by question keys');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'answers', jsonb_build_object('notes', repeat('x', 70000)), 'starts_at', '2025-06-09T17:00:00Z')),
                             '2025-06-01 12:00Z')$$,
                         '22023', '%too long%', 'answers are size-capped');
create temp table plain_booking as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'answers', null, 'starts_at', '2025-06-09T18:00:00Z')), '2025-06-01 12:00Z') as r;
select tests.eq((select custom_data from public.jobs j join plain_booking b on j.number = (b.r ->> 'job_number')::bigint
                  where j.shop_id = tests.fx('shop_a')), '{}'::jsonb, 'no answers: an empty object');
select tests.throws($$update public.jobs set custom_data = '[]' where id = tests.fx('job_link')$$, '23514',
                    'jobs.custom_data is always an object');
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'custom_data', 'SELECT'), 'custom_data granted to authenticated');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select custom_data from public.jobs where id = tests.fx('job_a')$$), 1::bigint,
                'technicians read the custom data of assigned jobs');
select tests.throws($$update public.jobs set custom_data = '{"x": 1}' where id = tests.fx('job_a')$$, '42501',
                    'technicians cannot change it');

-- anon through the API (server clock): a link booking works end to end
select tests.as_superuser();
create temp table link_slot as
  select min(s.starts_at) as starts_at
  from public.public_booking_slots('shop-a', array[tests.fx('svc_hidden')], (now() at time zone 'America/Chicago')::date + 3,
                                   (now() at time zone 'America/Chicago')::date + 3, null, 'shop', tests.fx('tok_a')) s;
grant select on link_slot to anon;
select tests.as_anon();
select tests.eq((public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                   'service_ids', jsonb_build_array(tests.fx('svc_hidden')), 'link_token', tests.fx('tok_a'),
                   'starts_at', (select to_char(starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') from link_slot))))
                 ->> 'total_cents'), '1100', 'anon books a link-only service');
