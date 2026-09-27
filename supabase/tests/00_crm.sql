-- 00 foundation: customers & vehicles — manager+ CRUD, technician read-only
-- visibility limited to assigned jobs, guard columns, isolation, search.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ manager+ access
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.customers'), 3::bigint, 'manager sees all own-shop customers');
select tests.eq(tests.row_count('select * from public.vehicles'), 2::bigint, 'manager sees all own-shop vehicles');
select tests.lives($$insert into public.customers (shop_id, first_name, email, phone, tags)
                     values (tests.fx('shop_a'), 'Cara', 'Cara@Example.com', '+14155550100', '{vip,fleet}')$$, 'manager creates a customer');
select tests.throws($$insert into public.customers (shop_id, email) values (tests.fx('shop_a'), 'noname@example.com')$$, '23514',
                    'a customer needs a first/last or company name');
select tests.throws($$insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'P', '2055550100')$$, '23514',
                    'phone must be E.164');
select tests.throws($$insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'E', 'bad@')$$, '23514',
                    'email format');
select tests.throws($$insert into public.customers (shop_id, first_name, tags) values (tests.fx('shop_a'), 'T', '{a,NULL}')$$, '23514',
                    'no null tags');
select tests.throws($$insert into public.customers (shop_id, first_name, lat) values (tests.fx('shop_a'), 'L', 33.5)$$, '23514',
                    'lat requires lng');
select tests.throws($$insert into public.customers (shop_id, first_name, portal_user_id) values (tests.fx('shop_a'), 'P', auth.uid())$$,
                    '42501', 'staff cannot link portal users directly');
select tests.throws($$insert into public.customers (shop_id, first_name, stripe_customer_id) values (tests.fx('shop_a'), 'S', 'cus_123')$$,
                    '42501', 'staff cannot set stripe_customer_id');
select tests.throws($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_b'), 'Injected')$$, '42501',
                    'manager of A cannot create customers in B');
select tests.eq(tests.row_count($$update public.customers set notes = 'x' where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'manager of A cannot update B''s customers');
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_b')$$), 0::bigint,
                'manager of A cannot delete B''s customers');
select tests.eq(tests.row_count($$select * from public.customers where id = tests.fx('cust_b')$$), 0::bigint,
                'manager of A cannot read B''s customers');
-- search haystack & citext
select tests.eq((select first_name from public.customers where email = 'cara@example.COM'), 'Cara', 'email is case-insensitive');
select tests.eq((select count(*) from public.customers where search_text like '%anders%'), 1::bigint, 'search_text includes last name');
select tests.eq((select count(*) from public.customers where search_text like '%+12055550101%'), 1::bigint, 'search_text includes phone');
select tests.throws($$update public.customers set search_text = 'x'$$, '428C9', 'search_text is generated');
-- portal/stripe guard on update
select tests.as_superuser();
update public.customers set portal_user_id = tests.fx('u_outsider'), stripe_customer_id = 'cus_ABC' where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.customers set portal_user_id = tests.fx('u_tech_a') where id = tests.fx('cust_a')$$, '42501',
                    'staff cannot re-point a portal link');
select tests.throws($$update public.customers set stripe_customer_id = 'cus_OTHER' where id = tests.fx('cust_a')$$, '42501',
                    'staff cannot change stripe_customer_id');
select tests.lives($$update public.customers set portal_user_id = null where id = tests.fx('cust_a')$$, 'staff may unlink a portal user');
select tests.lives($$update public.customers set notes = 'Prefers mornings', archived_at = now() where id = tests.fx('cust_a3')$$,
                   'staff edits and archives');
select tests.throws($$update public.customers set shop_id = tests.fx('shop_b') where id = tests.fx('cust_a3')$$, '42501',
                    'customers cannot move shops');
select tests.throws($$delete from public.customers where id = tests.fx('cust_a')$$, '23503', 'customers with jobs cannot be hard-deleted');
select tests.lives($$delete from public.customers where id = tests.fx('cust_a3')$$, 'customer without jobs can be deleted');
select tests.as_service();
select tests.lives($$update public.customers set stripe_customer_id = 'cus_SERVICE' where id = tests.fx('cust_a')$$,
                   'service_role manages stripe_customer_id');

-- ------------------------------------------------------------ vehicles
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.vehicles (shop_id, customer_id, year, make, model, trim, vin, license_plate)
                     values (tests.fx('shop_a'), tests.fx('cust_a'), 2023, 'BMW', 'M3', 'Competition', ' wbs 83ab0-1pf123456 ', ' abc 123 ')$$,
                   'manager adds a vehicle');
select tests.eq((select vin || '|' || license_plate from public.vehicles where make = 'BMW'), 'WBS83AB01PF123456|ABC 123',
                'VIN and plate normalized');
select tests.eq((select count(*) from public.vehicles where search_text like '%competition%'), 1::bigint, 'vehicle search_text');
select tests.throws($$insert into public.vehicles (shop_id, customer_id, vin) values (tests.fx('shop_a'), tests.fx('cust_a'), 'BAD!')$$,
                    '23514', 'VIN format');
select tests.throws($$insert into public.vehicles (shop_id, customer_id, year) values (tests.fx('shop_a'), tests.fx('cust_a'), 1700)$$,
                    '23514', 'year range');
select tests.throws($$insert into public.vehicles (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_b'))$$, '23503',
                    'composite FK: cannot attach a vehicle to another shop''s customer');
select tests.throws($$insert into public.vehicles (shop_id, customer_id, category_id)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cat_car_b'))$$, '23503',
                    'composite FK: cannot use another shop''s vehicle category');
select tests.throws($$insert into public.vehicles (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b'))$$, '42501',
                    'manager of A cannot add vehicles in B');
select tests.eq(tests.row_count($$update public.vehicles set color = 'Red' where id = tests.fx('veh_b')$$), 0::bigint,
                'manager of A cannot update B''s vehicles');
select tests.throws($$update public.vehicles set customer_id = tests.fx('cust_b') where id = tests.fx('veh_a')$$, '23503',
                    'cannot re-point a vehicle to another shop''s customer');

-- ------------------------------------------------------------ technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(id) from public.customers), array[tests.fx('cust_a')],
                'technician sees only customers on assigned jobs');
select tests.eq((select array_agg(id) from public.vehicles), array[tests.fx('veh_a')],
                'technician sees only vehicles on assigned jobs');
select tests.eq(tests.row_count($$update public.customers set notes = 'tech edit' where id = tests.fx('cust_a')$$), 0::bigint,
                'technician cannot edit customers');
select tests.throws($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Tech')$$, '42501',
                    'technician cannot create customers');
select tests.eq(tests.row_count($$delete from public.vehicles where id = tests.fx('veh_a')$$), 0::bigint, 'technician cannot delete vehicles');
select tests.throws($$insert into public.vehicles (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, '42501',
                    'technician cannot add vehicles');
-- a vehicle only referenced by a line item on an assigned job is visible too
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Second Car')
  returning tests.fx_set('veh_a_second', id);
insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a_second'), 'Interior', 5000);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok(exists (select 1 from public.vehicles where id = tests.fx('veh_a_second')),
                'technician sees vehicles on assigned job line items');
-- unassigning removes visibility
select tests.as_superuser();
delete from public.job_assignments where job_id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.customers'), 0::bigint, 'unassigned technician loses customer visibility');
select tests.eq(tests.row_count('select * from public.vehicles'), 0::bigint, 'unassigned technician loses vehicle visibility');
-- a deactivated assigned technician sees nothing
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count('select * from public.customers'), 0::bigint, 'inactive member sees no customers');

select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq((select array_agg(id) from public.customers), array[tests.fx('cust_b')], 'tech B sees only B''s assigned customer');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count('select * from public.customers'), 0::bigint, 'outsider sees no customers');
select tests.eq(tests.row_count('select * from public.vehicles'), 0::bigint, 'outsider sees no vehicles');
