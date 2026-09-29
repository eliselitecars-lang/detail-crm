-- 00 foundation: profiles, create_shop (validation + seeding), shops RLS.

-- ---------------------------------------------------------------- profiles
select tests.fx_set('u_new', tests.create_user('new-user@test.local', true, '{"full_name":"  New User  "}'));
select tests.eq((select full_name from public.profiles where id = tests.fx('u_new')), 'New User',
                'profile auto-created from auth.users with trimmed full_name');
select tests.fx_set('u_noname', tests.create_user('noname@test.local'));
select tests.ok(exists (select 1 from public.profiles where id = tests.fx('u_noname') and full_name is null),
                'profile created even without metadata');

\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_new'));
select tests.eq(tests.row_count('select * from public.profiles'), 1::bigint, 'a user with no shops sees only their own profile');
select tests.lives($$update public.profiles set full_name = 'Renamed', phone = '+12055550199' where id = auth.uid()$$,
                   'user updates own profile');
select tests.eq((select full_name from public.profiles where id = auth.uid()), 'Renamed', 'own profile updated');
select tests.throws($$update public.profiles set phone = '205-555-0199' where id = auth.uid()$$, '23514',
                    'profile phone must be E.164');
select tests.eq(tests.row_count($$update public.profiles set full_name = 'Hacked' where id = tests.fx('u_owner_a')$$),
                0::bigint, 'cannot update someone else''s profile');
select tests.throws($$insert into public.profiles (id) values (gen_random_uuid())$$, '42501', 'no direct profile inserts');
select tests.throws($$delete from public.profiles where id = auth.uid()$$, '42501', 'no direct profile deletes');

-- managers+ read co-members' profiles; technicians do not
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(exists (select 1 from public.profiles where id = tests.fx('u_tech_a')), 'manager reads a co-member profile');
select tests.ok(not exists (select 1 from public.profiles where id = tests.fx('u_tech_b')), 'manager cannot read another shop''s member profile');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.profiles'), 1::bigint, 'technician reads only their own profile');

-- ------------------------------------------------------------- create_shop
select tests.authenticate_as(tests.fx('u_new'));
select tests.fx_set('shop_new', (public.create_shop('  Gloss Bros  ', 'Gloss-Bros', 'America/Chicago', 'mobile',
                                                    'Hello@GlossBros.test', '+12055550100')).id);
select tests.eq((select name from public.shops where id = tests.fx('shop_new')), 'Gloss Bros', 'name trimmed');
select tests.eq((select slug from public.shops where id = tests.fx('shop_new')), 'gloss-bros', 'slug lower-cased');
select tests.eq((select business_type::text from public.shops where id = tests.fx('shop_new')), 'mobile', 'business_type stored');
select tests.eq((select created_by from public.shops where id = tests.fx('shop_new')), tests.fx('u_new'), 'created_by = caller');
select tests.eq((select currency from public.shops where id = tests.fx('shop_new')), 'usd', 'currency defaults to usd');
select tests.eq((select role::text from public.shop_members where shop_id = tests.fx('shop_new') and user_id = auth.uid()),
                'owner', 'creator becomes owner');
select tests.eq((select display_name from public.shop_members where shop_id = tests.fx('shop_new') and user_id = auth.uid()),
                'Renamed', 'owner display name comes from profile');
select tests.eq(public.shop_role_of(tests.fx('shop_new'))::text, 'owner', 'shop_role_of(owner)');
select tests.ok(public.is_shop_member(tests.fx('shop_new')), 'is_shop_member(owner)');
select tests.ok(public.has_shop_role(tests.fx('shop_new'), 'owner', 'admin'), 'has_shop_role variadic');
select tests.ok(not public.has_shop_role(tests.fx('shop_new'), 'technician'), 'has_shop_role negative');
-- seeded defaults
select tests.eq((select array_agg(name order by sort) from public.vehicle_categories where shop_id = tests.fx('shop_new')),
                array['Car', 'Small SUV', 'Large SUV / Truck', 'Van'], 'default vehicle categories seeded (names only)');
select tests.eq((select enabled from public.booking_settings where shop_id = tests.fx('shop_new')), false,
                'booking_settings seeded disabled');
select tests.eq((select count(*) from public.services where shop_id = tests.fx('shop_new')), 0::bigint,
                'no services/prices are invented');
select tests.as_superuser();
select tests.eq((select array_agg(kind::text || '=' || next_value order by kind) from public.shop_counters
                  where shop_id = tests.fx('shop_new')),
                array['job=1001', 'quote=1001', 'invoice=1001'], 'counters seeded at 1001');
select tests.authenticate_as(tests.fx('u_new'));

-- validation
select tests.throws($$select public.create_shop('X', 'ab', 'America/Chicago')$$, '22023', 'slug too short');
select tests.throws($$select public.create_shop('X', repeat('a', 51), 'America/Chicago')$$, '22023', 'slug too long');
select tests.lives($$select public.create_shop('X', repeat('b', 50), 'America/Chicago')$$, '50-char slug accepted');
select tests.throws($$select public.create_shop('X', '-abc', 'America/Chicago')$$, '22023', 'leading hyphen rejected');
select tests.throws($$select public.create_shop('X', 'abc-', 'America/Chicago')$$, '22023', 'trailing hyphen rejected');
select tests.throws($$select public.create_shop('X', 'a_bc', 'America/Chicago')$$, '22023', 'underscore rejected');
select tests.throws($$select public.create_shop('X', 'a bc', 'America/Chicago')$$, '22023', 'space rejected');
select tests.throws_like($$select public.create_shop('X', 'admin', 'America/Chicago')$$, '22023', '%reserved%', 'reserved slug admin');
select tests.throws_like($$select public.create_shop('X', 'BOOK', 'America/Chicago')$$, '22023', '%reserved%', 'reserved slug book (case-insensitive)');
do $$
declare s text;
begin
  foreach s in array array['app','api','admin','book','booking','login','signup','portal','invite','www',
                           'support','help','static','assets','q','i','f'] loop
    perform tests.ok(public.is_reserved_slug(s), 'reserved: ' || s);
  end loop;
end $$;
select tests.throws_like($$select public.create_shop('X', 'gloss-bros', 'America/Chicago')$$, '23505', '%taken%', 'duplicate slug');
select tests.throws_like($$select public.create_shop('X', 'new-tz', 'America/Nowhere')$$, '22023', '%time zone%', 'bad timezone');
select tests.throws($$select public.create_shop('X', 'new-tz', null)$$, '22023', 'null timezone');
select tests.throws($$select public.create_shop('   ', 'blank-name', 'UTC')$$, '22023', 'blank name');
select tests.throws($$select public.create_shop('X', 'bad-email', 'UTC', 'fixed', 'not-an-email')$$, '22023', 'bad email');
select tests.throws($$select public.create_shop('X', 'bad-phone', 'UTC', 'fixed', null, '555-1234')$$, '22023', 'bad phone');
select tests.as_anon();
select tests.throws($$select public.create_shop('X', 'anon-shop', 'UTC')$$, '42501', 'anon cannot call create_shop');
select tests.as_superuser();
update auth.users set is_anonymous = true where id = tests.fx('u_noname');
select tests.authenticate_as(tests.fx('u_noname'));
select tests.throws_like($$select public.create_shop('X', 'anon-user-shop', 'UTC')$$, '42501', '%registered%',
                         'anonymous (guest) auth users cannot create shops');

-- direct inserts into shops are impossible
select tests.authenticate_as(tests.fx('u_new'));
select tests.throws($$insert into public.shops (name, slug, timezone) values ('Direct', 'direct-shop', 'UTC')$$, '42501',
                    'no direct shop inserts');

-- the owner invariant is enforced at commit for shops created by trusted code
select tests.as_superuser();
select tests.lives($$insert into public.shops (name, slug, timezone) values ('Ownerless', 'ownerless', 'UTC')$$);
select tests.throws_like('set constraints shops_require_owner immediate', '23514', '%without an owner%',
                         'a shop without an owner cannot commit');

-- ------------------------------------------------------------------ shops RLS
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(slug) from public.shops), array['shop-a'], 'technician sees only own shop');
select tests.eq(tests.row_count($$update public.shops set name = 'Tech was here' where id = tests.fx('shop_a')$$), 0::bigint,
                'technician cannot update shop settings');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.shops set tax_rate_bps = 1 where id = tests.fx('shop_a')$$), 0::bigint,
                'manager cannot update shop settings (read only)');
select tests.throws($$delete from public.shops where id = tests.fx('shop_a')$$, '42501', 'manager cannot delete shop');
select tests.as_superuser();
-- the platform binds the shop's SMS number first (comms, 0033), when that range is applied
do $$ begin
  if to_regclass('public.shop_sms_numbers') is not null then
    execute format('insert into public.shop_sms_numbers (phone_number, shop_id) values (%L, %L)', '+12055550123', tests.fx('shop_a'));
  end if;
end $$;
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shops set tax_rate_bps = 900, brand_color = '#112233', sms_from_number = '+12055550123'
                                  where id = tests.fx('shop_a')$$), 1::bigint, 'admin updates shop settings');
select tests.throws($$update public.shops set tax_rate_bps = 10001 where id = tests.fx('shop_a')$$, '23514', 'tax rate capped at 100%');
select tests.throws($$update public.shops set brand_color = 'red' where id = tests.fx('shop_a')$$, '23514', 'brand_color must be hex');
select tests.throws($$update public.shops set slug = 'api' where id = tests.fx('shop_a')$$, '23514', 'reserved slug via update');
select tests.throws($$update public.shops set timezone = 'Mars/Base' where id = tests.fx('shop_a')$$, '22023', 'invalid timezone via update');
select tests.throws($$update public.shops set lat = 91, lng = 0 where id = tests.fx('shop_a')$$, '23514', 'lat range');
select tests.throws($$update public.shops set lat = 10 where id = tests.fx('shop_a')$$, '23514', 'lat without lng');
select tests.lives($$update public.shops set created_by = auth.uid() where id = tests.fx('shop_a')$$);
select tests.eq((select created_by from public.shops where id = tests.fx('shop_a')), tests.fx('u_owner_a'), 'created_by is immutable');
select tests.throws($$delete from public.shops where id = tests.fx('shop_a')$$, '42501', 'admin cannot delete shop');
select tests.eq(tests.row_count($$update public.shops set name = 'Pwned' where id = tests.fx('shop_b')$$), 0::bigint,
                'admin of A cannot update shop B');
select tests.eq(tests.row_count($$select 1 from public.shops where id = tests.fx('shop_b')$$), 0::bigint, 'admin of A cannot see shop B');

select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count('select * from public.shops'), 0::bigint, 'outsider sees no shops');
select tests.ok(not public.is_shop_member(tests.fx('shop_a')), 'outsider is not a member');
select tests.ok(public.shop_role_of(tests.fx('shop_a')) is null, 'outsider has no role');

-- 0117: not even the owner deletes the shop row directly (payments
-- delete_shop first stops the platform subscription and expires pay links,
-- then deletes as service_role); everything cascades
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$delete from public.shops where id = tests.fx('shop_b')$$, '42501',
                    'the owner cannot delete the shop through the API (only payments delete_shop)');
select tests.ok(not has_table_privilege('authenticated', 'public.shops', 'DELETE')
                and not has_table_privilege('anon', 'public.shops', 'DELETE'), 'clients have no DELETE on shops');
select tests.ok(not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shops' and cmd = 'DELETE'),
                'and no delete policy');
select tests.as_service();
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 1::bigint,
                'the payments edge (service role) deletes the shop');
select tests.as_superuser();
select tests.eq((select count(*) from public.shop_members where shop_id = tests.fx('shop_b')), 0::bigint, 'members cascade');
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b')), 0::bigint, 'jobs cascade');
select tests.eq((select count(*) from public.job_assignments where shop_id = tests.fx('shop_b')), 0::bigint,
                'assignments go with the shop (their member FK is NO ACTION, not RESTRICT)');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_b')), 0::bigint, 'customers cascade');
select tests.eq((select count(*) from public.shop_counters where shop_id = tests.fx('shop_b')), 0::bigint, 'counters cascade');
select tests.eq((select count(*) from public.shops where id = tests.fx('shop_a')), 1::bigint, 'other shop untouched');
