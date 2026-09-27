-- 00 foundation: vehicle_categories, business_hours, blocked_times, resources,
-- booking_settings — role matrix, constraints, cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ reads
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.vehicle_categories'), 4::bigint, 'technician reads own shop categories only');
select tests.eq(tests.row_count('select * from public.resources'), 1::bigint, 'technician reads own resources only');
select tests.eq(tests.row_count('select * from public.booking_settings'), 1::bigint, 'technician reads own booking settings only');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count('select * from public.vehicle_categories'), 0::bigint, 'outsider reads no categories');
select tests.eq(tests.row_count('select * from public.booking_settings'), 0::bigint, 'outsider reads no booking settings');

-- ------------------------------------------------------------ vehicle_categories (admin+ write)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.vehicle_categories (shop_id, name) values (tests.fx('shop_a'), 'Boat')$$, '42501',
                    'manager cannot add categories');
select tests.eq(tests.row_count($$update public.vehicle_categories set name = 'Sedan' where id = tests.fx('cat_car_a')$$), 0::bigint,
                'manager cannot rename categories');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.vehicle_categories where id = tests.fx('cat_car_a')$$), 0::bigint,
                'technician cannot delete categories');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$insert into public.vehicle_categories (shop_id, name, sort) values (tests.fx('shop_a'), 'Boat', 5)$$,
                   'admin adds a category');
select tests.throws($$insert into public.vehicle_categories (shop_id, name) values (tests.fx('shop_a'), 'BOAT')$$, '23505',
                    'category names unique per shop (case-insensitive)');
select tests.throws($$insert into public.vehicle_categories (shop_id, name) values (tests.fx('shop_a'), '  ')$$, '23514', 'blank name');
select tests.lives($$update public.vehicle_categories set name = 'Sedan' where id = tests.fx('cat_car_a')$$, 'admin renames');
select tests.throws($$insert into public.vehicle_categories (shop_id, name) values (tests.fx('shop_b'), 'Hack')$$, '42501',
                    'admin of A cannot insert into B');
select tests.eq(tests.row_count($$update public.vehicle_categories set name = 'Hack' where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'admin of A cannot update B''s categories');
select tests.eq(tests.row_count($$delete from public.vehicle_categories where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'admin of A cannot delete B''s categories');
select tests.throws($$update public.vehicle_categories set shop_id = tests.fx('shop_b') where id = tests.fx('cat_car_a')$$, '42501',
                    'rows cannot move to another shop');
-- deleting a category clears it from vehicles (FK SET NULL on the id column only)
select tests.lives($$delete from public.vehicle_categories where id = tests.fx('cat_car_a')$$, 'admin deletes a category');
select tests.as_superuser();
select tests.ok((select category_id is null and shop_id = tests.fx('shop_a') from public.vehicles where id = tests.fx('veh_a')),
                'vehicle keeps shop_id, loses category');

-- ------------------------------------------------------------ business_hours (admin+ write)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 1, '08:00', '17:00')$$,
                    '42501', 'manager cannot edit hours');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
                     (tests.fx('shop_a'), 1, '08:00', '12:00'), (tests.fx('shop_a'), 1, '13:00', '17:00'),
                     (tests.fx('shop_a'), 5, '20:00', '24:00')$$, 'admin adds split hours and a midnight close');
select tests.throws($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 1, '11:00', '14:00')$$,
                    '23P01', 'overlapping hours rejected');
select tests.lives($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 1, '12:00', '13:00')$$,
                   'adjacent (touching) hours allowed');
select tests.throws($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 2, '17:00', '08:00')$$,
                    '23514', 'close must be after open');
select tests.throws($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 7, '08:00', '17:00')$$,
                    '23514', 'weekday 0..6');
select tests.throws($$insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_b'), 1, '08:00', '17:00')$$,
                    '42501', 'admin of A cannot add B''s hours');
select tests.as_superuser();
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_b'), 1, '11:00', '14:00');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count('select * from public.business_hours'), 4::bigint, 'hours isolated per shop (and B''s overlap-free per shop)');
select tests.eq(tests.row_count($$delete from public.business_hours where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'admin of A cannot delete B''s hours');

-- ------------------------------------------------------------ blocked_times (manager+ write)
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.blocked_times (shop_id, starts_at, ends_at) values (tests.fx('shop_a'), '2025-06-01 10:00Z', '2025-06-01 11:00Z')$$,
                    '42501', 'technician cannot block time');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, reason, created_by)
                     values (tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-06-01 10:00Z', '2025-06-01 11:00Z', 'Dentist', tests.fx('u_owner_a'))$$,
                   'manager blocks a member''s time');
select tests.eq((select created_by from public.blocked_times where reason = 'Dentist'), tests.fx('u_manager_a'),
                'created_by is the caller, not client-supplied');
select tests.throws($$insert into public.blocked_times (shop_id, starts_at, ends_at) values (tests.fx('shop_a'), '2025-06-01 11:00Z', '2025-06-01 10:00Z')$$,
                    '23514', 'ends_at after starts_at');
select tests.throws($$insert into public.blocked_times (shop_id, member_id, starts_at, ends_at)
                      values (tests.fx('shop_a'), tests.fx('m_tech_b'), '2025-06-01 10:00Z', '2025-06-01 11:00Z')$$,
                    '23503', 'composite FK blocks another shop''s member');
select tests.throws($$insert into public.blocked_times (shop_id, starts_at, ends_at) values (tests.fx('shop_b'), '2025-06-01 10:00Z', '2025-06-01 11:00Z')$$,
                    '42501', 'manager of A cannot block B''s time');
select tests.lives($$update public.blocked_times set reason = 'Doctor', created_by = null where reason = 'Dentist'$$, 'manager edits a block');
select tests.eq((select created_by from public.blocked_times where reason = 'Doctor'), tests.fx('u_manager_a'), 'created_by immutable');
select tests.as_superuser();
insert into public.blocked_times (shop_id, starts_at, ends_at, reason) values (tests.fx('shop_b'), '2025-06-01 10:00Z', '2025-06-01 11:00Z', 'B closed');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.blocked_times'), 1::bigint, 'manager sees only own shop''s blocks');
select tests.eq(tests.row_count($$delete from public.blocked_times where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'manager of A cannot delete B''s blocks');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.blocked_times'), 1::bigint, 'technician reads blocks (calendar)');
select tests.eq(tests.row_count($$update public.blocked_times set reason = 'x'$$), 0::bigint, 'technician cannot edit blocks');

-- ------------------------------------------------------------ resources (admin+ write)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.resources (shop_id, name) values (tests.fx('shop_a'), 'Van 1')$$, '42501', 'manager cannot add resources');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$insert into public.resources (shop_id, name, kind) values (tests.fx('shop_a'), 'Van 1', 'van')$$, 'admin adds a van');
select tests.throws($$insert into public.resources (shop_id, name, kind) values (tests.fx('shop_a'), 'Sub', 'submarine')$$, '22P02', 'kind enum');
select tests.eq(tests.row_count($$update public.resources set active = false where id = tests.fx('res_b')$$), 0::bigint,
                'admin of A cannot touch B''s resources');
select tests.lives($$delete from public.resources where id = tests.fx('res_a')$$, 'admin deletes a resource');

-- ------------------------------------------------------------ booking_settings (admin+ update)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.booking_settings set enabled = true$$), 0::bigint, 'manager cannot change booking settings');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.booking_settings set enabled = true, slot_interval_minutes = 15,
                                  service_area_postal_codes = '{35203,35205}'$$), 1::bigint, 'admin updates own booking settings only');
select tests.throws($$update public.booking_settings set deposit_type = 'percent', deposit_value = 10001$$, '23514', 'percent deposit <= 100%');
select tests.throws($$update public.booking_settings set require_deposit = true, deposit_value = 0$$, '23514', 'required deposit needs a value');
select tests.throws($$update public.booking_settings set slot_interval_minutes = 1$$, '23514', 'slot interval bounds');
select tests.throws($$update public.booking_settings set max_concurrent_jobs = 0$$, '23514', 'capacity >= 1');
select tests.throws($$update public.booking_settings set service_area_postal_codes = '{35203,NULL}'$$, '23514', 'no null postal codes');
select tests.throws($$insert into public.booking_settings (shop_id) values (tests.fx('shop_a'))$$, '42501', 'no direct inserts');
select tests.throws($$delete from public.booking_settings$$, '42501', 'no direct deletes');
select tests.as_superuser();
select tests.eq((select enabled from public.booking_settings where shop_id = tests.fx('shop_b')), false, 'B''s settings untouched');
