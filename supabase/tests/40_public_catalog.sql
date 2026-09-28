-- 40 integration: public_shop_profile, public_booking_catalog and
-- public_validate_coupon — curated keys (nothing internal), what is bookable,
-- prices per vehicle category, add-on relations, coupon rules, the request
-- clock, anon access and cross-shop isolation.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- ------------------------------------------------------------ public_shop_profile
select tests.as_anon();
select tests.eq(pg_temp.keys(public.public_shop_profile('shop-a')),
                'booking,brand_color,business_type,city,country,currency,logo_path,name,phone,region,slug,tax_rate_bps,timezone,tracking,website',
                'profile keys are curated (no email, street address, SMS number, Stripe, terms; tracking ids: comms 0088)');
select tests.eq(pg_temp.keys(public.public_shop_profile('shop-a') -> 'booking'),
                'allow_client_cancel_hours,auto_confirm,booking_message,cancellation_policy,deposit_type,deposit_value,enabled,lead_time_minutes,max_days_ahead,require_deposit,service_area_limited,slot_interval_minutes',
                'booking keys are curated (no postal code list)');
select tests.eq(public.public_shop_profile('SHOP-A') ->> 'name', 'Shop A', 'slug is case-insensitive');
select tests.eq(public.public_shop_profile('shop-a') #>> '{booking,enabled}', 'true', 'booking enabled');
select tests.eq(public.public_shop_profile('shop-a') #>> '{booking,cancellation_policy}', 'Cancel 24 hours ahead', 'cancellation policy');
select tests.eq(public.public_shop_profile('shop-a') ->> 'city', 'Birmingham', 'city');
select tests.eq(public.public_shop_profile('shop-a') ->> 'business_type', 'both', 'business type');
select tests.ok(public.public_shop_profile('shop-a') -> 'booking' -> 'deposit_type' = 'null'::jsonb, 'no deposit: no deposit terms');
select tests.throws($$select public.public_shop_profile('nope')$$, 'PT404', 'unknown shop');
select tests.throws($$select public.public_shop_profile(null)$$, 'PT404', 'null slug');
select tests.as_superuser();
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_b');
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 2500,
                                   service_area_postal_codes = array['35203'] where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-b') #>> '{booking,enabled}', 'false',
                'profile still loads while booking is disabled');
select tests.eq(public.public_shop_profile('shop-a') #>> '{booking,deposit_value}', '2500', 'deposit terms when required');
select tests.eq(public.public_shop_profile('shop-a') #>> '{booking,service_area_limited}', 'true', 'service area flag');

-- ------------------------------------------------------------ public_booking_catalog
select tests.throws_like($$select public.public_booking_catalog('shop-b')$$, '55000', '%not enabled%', 'disabled booking');
select tests.throws($$select public.public_booking_catalog('nope')$$, 'PT404', 'unknown shop');
create temp table cat as select public.public_booking_catalog('shop-a') as c;
grant select on cat to anon;
select tests.eq(pg_temp.keys((select c from cat)), 'addons,service_categories,services,vehicle_categories', 'catalog keys');
select tests.eq((select jsonb_agg(e ->> 'name' order by o) from cat, jsonb_array_elements(c -> 'services') with ordinality t(e, o)),
                '["Full Detail", "Van Interior", "Exterior Wash", "Showroom Package"]'::jsonb,
                'bookable services/packages only (not hidden, inactive, add-ons or products), by sort then name');
select tests.eq((select jsonb_agg(e ->> 'name' order by o) from cat, jsonb_array_elements(c -> 'addons') with ordinality t(e, o)),
                '["Engine Bay", "Pet Hair"]'::jsonb, 'bookable add-ons');
select tests.eq((select pg_temp.keys(e) from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Full Detail'),
                'addon_ids,base_price_cents,category_id,description,duration_minutes,id,image_path,includes,kind,name,prices',
                'service keys are curated');
select tests.eq((select pg_temp.keys(e) from cat, jsonb_array_elements(c -> 'addons') e where e ->> 'name' = 'Engine Bay'),
                'base_price_cents,category_id,description,duration_minutes,id,image_path,kind,name,prices', 'add-on keys');
select tests.eq((select e -> 'prices' from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Full Detail'),
                jsonb_build_array(
                  jsonb_build_object('vehicle_category_id', tests.fx('cat_car_a'), 'price_cents', 20000, 'duration_minutes', 120),
                  jsonb_build_object('vehicle_category_id', tests.fx('cat_suv_a'), 'price_cents', 20000, 'duration_minutes', 120),
                  jsonb_build_object('vehicle_category_id', tests.fx('cat_truck_a'), 'price_cents', 25000, 'duration_minutes', 180),
                  jsonb_build_object('vehicle_category_id', tests.fx('cat_van_a'), 'price_cents', 20000, 'duration_minutes', 120)),
                'prices resolved per category (category price, else base)');
select tests.eq((select (e ->> 'base_price_cents')::bigint from cat, jsonb_array_elements(c -> 'services') e
                  where e ->> 'name' = 'Full Detail'), 20000::bigint, 'base price');
select tests.eq((select e -> 'prices' from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Van Interior'),
                jsonb_build_array(jsonb_build_object('vehicle_category_id', tests.fx('cat_van_a'), 'price_cents', 9000,
                                                     'duration_minutes', 60)),
                'a category-only service lists only that category');
select tests.ok((select e -> 'base_price_cents' = 'null'::jsonb from cat, jsonb_array_elements(c -> 'services') e
                  where e ->> 'name' = 'Van Interior'), 'no base price');
select tests.eq((select e -> 'addon_ids' from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Exterior Wash'),
                jsonb_build_array(tests.fx('addon_engine')), 'explicit add-on links');
select tests.eq((select e -> 'addon_ids' from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Full Detail'),
                jsonb_build_array(tests.fx('addon_engine'), tests.fx('addon_pet')), 'no links: every bookable add-on');
select tests.eq((select e -> 'includes' from cat, jsonb_array_elements(c -> 'services') e where e ->> 'name' = 'Showroom Package'),
                '["Full Detail", "Exterior Wash"]'::jsonb, 'package contents by name');
select tests.eq((select c -> 'service_categories' from cat),
                jsonb_build_array(jsonb_build_object('id', tests.fx('svc_cat_a'), 'name', 'Exterior',
                                                     'bookable_weekdays', null)),
                'only categories that have bookable services (bookable_weekdays null = every day, 0053)');
select tests.eq((select jsonb_array_length(c -> 'vehicle_categories') from cat), 4, 'all vehicle categories');
select tests.ok((select not (c::text like '%' || tests.fx('svc_b')::text || '%') from cat), 'no shop B services');
drop table cat;
select tests.as_superuser();
update public.services set archived_at = now() where id = tests.fx('svc_van');
select tests.as_anon();
select tests.ok(not (public.public_booking_catalog('shop-a')::text like '%Van Interior%'), 'archived services disappear');

-- ------------------------------------------------------------ public_validate_coupon
-- Full Detail (20000, taxable) + Pet Hair (4000, not taxable); tax 10%
select tests.as_service();
create temp table v as
  select public.public_validate_coupon('shop-a', 'save10', array[tests.fx('svc_a'), tests.fx('addon_pet')],
                                       tests.fx('cat_car_a'), '2025-06-01 12:00Z') as r;
grant select on v to anon, authenticated;
select tests.eq((select r from v),
                jsonb_build_object('valid', true, 'message', null, 'code', 'SAVE10', 'kind', 'percent', 'value', 1000,
                                   'description', null, 'subtotal_cents', 24000, 'discount_cents', 2400,
                                   'tax_cents', 1800, 'total_cents', 23400,
                                   'eligible_service_ids', jsonb_build_array(tests.fx('svc_a'), tests.fx('addon_pet')),
                                   'restrictions_text', null),
                'valid percent coupon (case-insensitive code): 10% off, tax on the discounted taxable part');
drop table v;
select tests.eq(public.public_validate_coupon('shop-a', 'FIXED25', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z')
                  - array['message', 'code', 'kind', 'value', 'valid', 'eligible_service_ids', 'restrictions_text'],
                '{"description": "$25 off", "subtotal_cents": 5000, "discount_cents": 2500, "tax_cents": 250, "total_cents": 2750}'::jsonb,
                'fixed coupon');
select tests.eq(public.public_validate_coupon('shop-a', 'nope', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z'),
                jsonb_build_object('valid', false, 'message', 'this coupon code is not valid', 'code', 'nope', 'kind', null,
                                   'value', null, 'description', null, 'subtotal_cents', 5000, 'discount_cents', 0,
                                   'tax_cents', 500, 'total_cents', 5500, 'eligible_service_ids', '[]'::jsonb,
                                   'restrictions_text', null),
                'unknown code: an answer, not an error, with undiscounted totals');
select tests.eq(public.public_validate_coupon('shop-a', 'EXPIRED', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z') ->> 'message',
                'this coupon has expired', 'expired');
select tests.eq(public.public_validate_coupon('shop-a', 'EXPIRED', array[tests.fx('svc_wash')], null, '2024-12-31 12:00Z') ->> 'valid',
                'true', 'before its end it was valid (p_now honoured for trusted callers)');
select tests.eq(public.public_validate_coupon('shop-a', 'FUTURE', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z') ->> 'message',
                'this coupon is not active yet', 'not started');
select tests.eq(public.public_validate_coupon('shop-a', 'OFF', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z') ->> 'message',
                'this coupon is no longer active', 'inactive');
select tests.as_superuser();
update public.coupons set redemptions = 1 where id = tests.fx('cp_limited');
select tests.as_service();
select tests.eq(public.public_validate_coupon('shop-a', 'LIMITED', array[tests.fx('svc_wash')], null, '2025-06-01 12:00Z') ->> 'message',
                'this coupon has been fully redeemed', 'redemption limit reached');
select tests.eq(public.public_validate_coupon('shop-a', 'bad code!', array[tests.fx('svc_wash')], null) ->> 'valid', 'false',
                'malformed code');
select tests.eq(public.public_validate_coupon('shop-a', null, array[tests.fx('svc_wash')], null) ->> 'valid', 'false', 'null code');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_hidden')], null)$$, '22023',
                         '%not available for online booking%', 'services must be bookable');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('prod_a')], null)$$, '22023',
                         '%not available for online booking%', 'products are not bookable');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_b')], null)$$, '22023',
                         '%not available for online booking%', 'another shop''s service');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_a')], tests.fx('cat_car_b'))$$, '22023',
                         '%category%', 'another shop''s vehicle category');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', '{}', null)$$, '22023', '%at least one%', 'no services');
select tests.throws($$select public.public_validate_coupon('shop-b', 'SAVE10', array[tests.fx('svc_b')], null)$$, '55000',
                    'booking disabled');
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_b');
select tests.as_anon();
select tests.eq(public.public_validate_coupon('shop-b', 'save10', array[tests.fx('svc_b')], null) ->> 'discount_cents', '500',
                'each shop''s codes apply only to that shop (B has its own SAVE10)');
select tests.eq(public.public_validate_coupon('shop-b', 'FIXED25', array[tests.fx('svc_b')], null) ->> 'valid', 'false',
                'shop A codes are unknown in shop B');

-- anon: the caller's clock is ignored
select tests.eq(public.public_validate_coupon('shop-a', 'EXPIRED', array[tests.fx('svc_wash')], null, '2024-12-31 12:00Z') ->> 'valid',
                'false', 'anon cannot rewind the clock to use an expired coupon');
select tests.eq(public.public_validate_coupon('shop-a', 'FUTURE', array[tests.fx('svc_wash')], null, '3000-01-01Z') ->> 'valid',
                'false', 'anon cannot fast-forward to use a coupon early');
select tests.eq(public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_wash')], null) ->> 'valid', 'true',
                'anon may validate');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_wash')], null) ->> 'valid', 'true',
                'signed-in visitors may validate');
select tests.eq(pg_temp.keys(public.public_booking_catalog('shop-a')), 'addons,service_categories,services,vehicle_categories',
                'signed-in visitors may read the catalog');
select tests.as_superuser();
