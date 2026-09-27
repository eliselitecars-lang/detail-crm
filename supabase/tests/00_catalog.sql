-- 00 foundation: service_categories, services, service_prices, package_items,
-- service_addons, coupons, service_price_for.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.services (shop_id, name, kind, duration_minutes) values
  (tests.fx('shop_a'), 'Ceramic Package', 'package', 480) returning tests.fx_set('pkg_a', id);
insert into public.services (shop_id, name, kind, duration_minutes) values
  (tests.fx('shop_a'), 'Engine Bay', 'addon', 30) returning tests.fx_set('addon_a', id);
insert into public.services (shop_id, name, kind, duration_minutes) values
  (tests.fx('shop_b'), 'Pet Hair', 'addon', 30) returning tests.fx_set('addon_b', id);

-- ------------------------------------------------------------ roles
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.services'), 3::bigint, 'technician reads own catalog');
select tests.eq(tests.row_count('select * from public.service_prices'), 1::bigint, 'technician reads own prices');
select tests.throws($$insert into public.services (shop_id, name) values (tests.fx('shop_a'), 'Tech svc')$$, '42501', 'technician cannot add services');
select tests.eq(tests.row_count($$update public.services set name = 'x'$$), 0::bigint, 'technician cannot edit services');
select tests.throws($$insert into public.service_categories (shop_id, name) values (tests.fx('shop_a'), 'Tech cat')$$, '42501',
                    'technician cannot add categories');
select tests.throws($$insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('addon_a'), 1)$$,
                    '42501', 'technician cannot set prices');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.service_categories (shop_id, name, sort) values (tests.fx('shop_a'), 'Interior', 2)$$,
                   'manager adds a service category');
select tests.throws($$insert into public.service_categories (shop_id, name) values (tests.fx('shop_a'), 'INTERIOR')$$, '23505',
                    'category names unique per shop');
select tests.lives($$insert into public.services (shop_id, category_id, name, kind, duration_minutes, taxable, online_bookable)
                     values (tests.fx('shop_a'), tests.fx('svc_cat_a'), 'Wax', 'service', 45, false, true)$$, 'manager adds a service');
select tests.throws($$insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Long', 1441)$$, '23514',
                    'duration bounds');
select tests.throws($$insert into public.services (shop_id, category_id, name) values (tests.fx('shop_a'), gen_random_uuid(), 'Orphan')$$,
                    '23503', 'unknown category');
select tests.throws($$insert into public.services (shop_id, name) values (tests.fx('shop_b'), 'Injected')$$, '42501',
                    'manager of A cannot add services to B');
select tests.as_superuser();
insert into public.service_categories (shop_id, name) values (tests.fx('shop_b'), 'B Category') returning tests.fx_set('svc_cat_b', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.services (shop_id, category_id, name) values (tests.fx('shop_a'), tests.fx('svc_cat_b'), 'Cross')$$,
                    '23503', 'composite FK: a service cannot use another shop''s category');
select tests.throws($$update public.services set category_id = tests.fx('svc_cat_b') where id = tests.fx('svc_a')$$,
                    '23503', 'composite FK: cannot re-point a service to another shop''s category');
select tests.eq(tests.row_count($$update public.service_categories set name = 'Hacked' where id = tests.fx('svc_cat_b')$$), 0::bigint,
                'manager of A cannot rename B''s service categories');
select tests.eq(tests.row_count($$update public.services set active = false where id = tests.fx('svc_b')$$), 0::bigint,
                'manager of A cannot deactivate B''s service');
select tests.eq(tests.row_count($$delete from public.services where id = tests.fx('svc_b')$$), 0::bigint,
                'manager of A cannot delete B''s service');
select tests.eq(tests.row_count($$select * from public.services where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'manager of A cannot read B''s services');

-- ------------------------------------------------------------ service_prices
select tests.lives($$insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents, duration_minutes)
                     values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_a'), 18000, 90)$$, 'category price');
select tests.throws($$insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), null, 1)$$, '23505',
                    'only one base price per service (NULLS NOT DISTINCT)');
select tests.throws($$insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_a'), 1)$$, '23505',
                    'one price per category');
select tests.throws($$insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('addon_a'), -1)$$,
                    '23514', 'non-negative price');
select tests.throws($$insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('svc_b'), 100)$$,
                    '23503', 'composite FK: cannot price another shop''s service');
select tests.throws($$insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
                      values (tests.fx('shop_a'), tests.fx('addon_a'), tests.fx('cat_car_b'), 100)$$, '23503',
                    'composite FK: cannot use another shop''s category');

-- service_price_for
select tests.eq((select price_cents from public.service_price_for(tests.fx('svc_a'), tests.fx('cat_car_a'))), 18000::bigint,
                'category price wins');
select tests.eq((select duration_minutes from public.service_price_for(tests.fx('svc_a'), tests.fx('cat_car_a'))), 90,
                'category duration override');
select tests.eq((select price_cents from public.service_price_for(tests.fx('svc_a'), null)), 20000::bigint, 'base price when no category');
select tests.eq((select duration_minutes from public.service_price_for(tests.fx('svc_a'), null)), 120, 'service duration fallback');
select tests.fx_set('cat_suv_a', (select id from public.vehicle_categories where shop_id = tests.fx('shop_a') and name = 'Small SUV'));
select tests.eq((select price_cents from public.service_price_for(tests.fx('svc_a'), tests.fx('cat_suv_a'))), 20000::bigint,
                'base price for categories without an override');
select tests.eq((select price_cents::text || '/' || duration_minutes from public.service_price_for(tests.fx('addon_a'), null)), null,
                'no price row: price is null');
select tests.eq((select duration_minutes from public.service_price_for(tests.fx('addon_a'), null)), 30, 'no price row: service duration');
select tests.eq(tests.row_count($$select * from public.service_price_for(tests.fx('svc_b'), null)$$), 0::bigint,
                'service_price_for respects RLS (other shop''s service invisible)');
select tests.as_anon();
select tests.throws($$select * from public.service_price_for(tests.fx('svc_a'), null)$$, '42501', 'anon cannot call service_price_for');

-- ------------------------------------------------------------ package_items / service_addons
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('svc_a'))$$,
                   'package includes a service');
select tests.throws($$insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('svc_a'))$$,
                    '23505', 'no duplicate package items');
select tests.throws_like($$insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('addon_a'))$$,
                         '23514', '%kind package%', 'package_id must be a package');
select tests.throws($$insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('pkg_a'))$$,
                    '23514', 'package cannot include itself');
select tests.throws($$insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('svc_b'))$$,
                    '23503', 'composite FK: package cannot include another shop''s service');
select tests.lives($$insert into public.service_addons (shop_id, service_id, addon_id) values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('addon_a'))$$,
                   'service offers an add-on');
select tests.throws_like($$insert into public.service_addons (shop_id, service_id, addon_id) values (tests.fx('shop_a'), tests.fx('addon_a'), tests.fx('svc_a'))$$,
                         '23514', '%kind addon%', 'addon_id must be an add-on');
select tests.throws($$insert into public.service_addons (shop_id, service_id, addon_id) values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('addon_b'))$$,
                    '23503', 'composite FK: cannot offer another shop''s add-on');
select tests.throws_like($$update public.services set kind = 'service' where id = tests.fx('addon_a')$$, '23514', '%add-on%',
                         'an add-on in use keeps its kind');
select tests.throws_like($$update public.services set kind = 'service' where id = tests.fx('pkg_a')$$, '23514', '%package items%',
                         'a package with items keeps its kind');
select tests.throws_like($$update public.services set kind = 'package' where id = tests.fx('svc_a')$$, '23514', '%included in a package%',
                         'a service inside a package cannot become a package');
select tests.as_superuser();
insert into public.service_addons (shop_id, service_id, addon_id) values (tests.fx('shop_b'), tests.fx('svc_b'), tests.fx('addon_b'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.service_addons'), 1::bigint, 'add-on links isolated per shop');
select tests.eq(tests.row_count($$delete from public.service_addons where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'manager of A cannot delete B''s add-on links');
-- deleting a service cascades its price rows and links
select tests.lives($$delete from public.services where id = tests.fx('pkg_a')$$, 'manager deletes a package');
select tests.eq((select count(*) from public.package_items where package_id = tests.fx('pkg_a')), 0::bigint, 'package items cascade');

-- ------------------------------------------------------------ coupons (manager+ read, admin+ write)
-- Coupon codes are a shop setting (SPEC §3 row 1, §6): technicians cannot
-- list them (not even public, active ones), nor write them.
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.coupons where shop_id = tests.fx('shop_a')), 0::bigint,
                'technicians cannot list the shop''s coupon codes');
select tests.eq(tests.row_count('select * from public.coupons'), 0::bigint, 'technician sees no coupons at all');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'TECH', 'fixed', 500)$$, '42501',
                    'technician cannot create coupons');
select tests.eq(tests.row_count($$update public.coupons set value = 1 where id = tests.fx('coupon_a')$$), 0::bigint,
                'technician cannot edit coupons');
select tests.eq(tests.row_count($$delete from public.coupons where id = tests.fx('coupon_a')$$), 0::bigint,
                'technician cannot delete coupons');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.coupons'), 1::bigint, 'manager reads own coupons');
select tests.eq((select id from public.coupons), tests.fx('coupon_a'), 'manager of A sees only A''s coupon (not B''s)');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'MGR', 'fixed', 500)$$, '42501',
                    'manager cannot create coupons');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'save10', 'fixed', 500)$$, '23505',
                    'coupon code unique per shop, case-insensitive');
select tests.lives($$insert into public.coupons (shop_id, code, kind, value, redemptions, max_redemptions, starts_at, ends_at)
                     values (tests.fx('shop_a'), 'Spring-25', 'fixed', 2500, 99, 100, '2025-03-01', '2025-04-01')$$, 'admin creates coupon');
select tests.eq((select redemptions from public.coupons where code = 'SPRING-25'), 0, 'client cannot seed redemptions');
select tests.lives($$update public.coupons set redemptions = 50, active = false where code = 'spring-25'$$);
select tests.eq((select redemptions::text || '/' || active from public.coupons where code = 'spring-25'), '0/false',
                'redemptions is server-maintained; other fields editable');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'BIG', 'percent', 10001)$$, '23514',
                    'percent coupon <= 100%');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'ZERO', 'fixed', 0)$$, '23514',
                    'coupon value > 0');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'a b', 'fixed', 1)$$, '23514',
                    'coupon code format');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value, starts_at, ends_at)
                      values (tests.fx('shop_a'), 'BACK', 'fixed', 1, '2025-02-01', '2025-01-01')$$, '23514', 'coupon window order');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_b'), 'INJ', 'fixed', 1)$$, '42501',
                    'admin of A cannot create coupons in B');
select tests.eq(tests.row_count($$update public.coupons set value = 1 where id = tests.fx('coupon_b')$$), 0::bigint,
                'admin of A cannot update B''s coupon');
select tests.as_service();
select tests.lives($$update public.coupons set redemptions = redemptions + 1 where id = tests.fx('coupon_a')$$);
select tests.eq((select redemptions from public.coupons where id = tests.fx('coupon_a')), 1, 'service_role maintains redemptions');
