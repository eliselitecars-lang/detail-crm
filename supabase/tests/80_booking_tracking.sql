-- 80 comms: booking page tracking ids (P-10, 0081/0088) — Meta Pixel / GA4
-- id formats, admin-only writes, public_shop_profile's 'tracking' object
-- (only while online booking is on, only the slug's own shop, nothing else
-- added to the profile).
\ir fixtures/two_shops.psql

-- ============================================================ formats and roles
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.booking_settings set meta_pixel_id = 'abc123' where shop_id = tests.fx('shop_a')$$, '23514',
                    'a pixel id is digits');
select tests.throws($$update public.booking_settings set meta_pixel_id = '1234' where shop_id = tests.fx('shop_a')$$, '23514',
                    'at least 5 digits');
select tests.throws($$update public.booking_settings set ga4_measurement_id = 'UA-12345-1' where shop_id = tests.fx('shop_a')$$, '23514',
                    'GA4 ids start with G-');
select tests.throws($$update public.booking_settings set ga4_measurement_id = 'G-abc123' where shop_id = tests.fx('shop_a')$$, '23514',
                    'upper-case measurement ids');
select tests.throws($$update public.booking_settings set ga4_measurement_id = 'G-<script>' where shop_id = tests.fx('shop_a')$$, '23514',
                    'nothing that could inject markup');
select tests.eq(tests.row_count($$update public.booking_settings set meta_pixel_id = '123456789012345', ga4_measurement_id = 'G-ABC123XYZ'
                                   where shop_id = tests.fx('shop_a')$$), 1::bigint, 'admins set the ids');
select tests.eq(tests.row_count($$update public.booking_settings set meta_pixel_id = '99999' where shop_id = tests.fx('shop_b')$$),
                0::bigint, 'not for another shop');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.booking_settings set meta_pixel_id = '55555' where shop_id = tests.fx('shop_a')$$),
                0::bigint, 'managers cannot change them');
select tests.eq((select meta_pixel_id from public.booking_settings where shop_id = tests.fx('shop_a')), '123456789012345',
                'managers can read them');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.booking_settings set ga4_measurement_id = null$$), 0::bigint, 'technicians cannot');

-- ============================================================ public profile
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-a') -> 'tracking', '{"meta_pixel_id": null, "ga4_measurement_id": null}'::jsonb,
                'online booking off: no tracking ids');
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'));
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-a') -> 'tracking',
                '{"meta_pixel_id": "123456789012345", "ga4_measurement_id": "G-ABC123XYZ"}'::jsonb, 'the shop''s ids while booking is on');
select tests.eq(public.public_shop_profile('SHOP-B') -> 'tracking', '{"meta_pixel_id": null, "ga4_measurement_id": null}'::jsonb,
                'another shop''s profile never carries them');
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(public.public_shop_profile('shop-a')) k),
                'booking,brand_color,business_type,city,country,currency,logo_path,name,phone,region,slug,tax_rate_bps,timezone,tracking,website',
                'only the tracking key was added (no email, address or SMS number)');
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(public.public_shop_profile('shop-a') -> 'tracking') k),
                'ga4_measurement_id,meta_pixel_id', 'tracking holds the two ids only');
select tests.throws($$select public.public_shop_profile('no-such-shop')$$, 'PT404', 'unknown slug');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(public.public_shop_profile('shop-a') -> 'tracking' ->> 'ga4_measurement_id', 'G-ABC123XYZ',
                'signed-in visitors see the same public profile');
