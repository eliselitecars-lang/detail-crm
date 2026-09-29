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
select tests.throws($$delete from public.customers where id = tests.fx('cust_b')$$, '42501',
                    'manager of A cannot delete B''s customers (no client DELETE at all, 0132)');
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
-- 0125 / 0132: no client DELETE (erase_customer, through the payments edge, only)
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501',
                    'staff cannot delete customers directly');
select tests.as_service();
select tests.throws($$delete from public.customers where id = tests.fx('cust_a')$$, '23503', 'customers with jobs cannot be hard-deleted');
select tests.lives($$delete from public.customers where id = tests.fx('cust_a3')$$, 'customer without jobs can be deleted (service role)');
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

-- ------------------------------------------------------------ vehicle ownership keeps document history
-- Every document requires its vehicle to belong to its customer, so a
-- referenced vehicle cannot change customer (a sold car becomes a new
-- vehicle record for the new owner).
select tests.throws_like($$update public.vehicles set customer_id = tests.fx('cust_a2') where id = tests.fx('veh_a')$$, '23514',
                         '%referenced by jobs%new vehicle for the new owner%',
                         'a vehicle on a job cannot move to another customer');
select tests.eq((select count(*) from public.jobs j join public.vehicles v on v.id = j.vehicle_id
                  where j.shop_id = tests.fx('shop_a') and v.customer_id <> j.customer_id), 0::bigint,
                'no job points at a vehicle owned by a different customer');
select tests.eq((select customer_id from public.vehicles where id = tests.fx('veh_a')), tests.fx('cust_a'), 'vehicle keeps its owner');
select tests.lives($$update public.vehicles set color = 'Blue', customer_id = tests.fx('cust_a') where id = tests.fx('veh_a')$$,
                   'other edits of a referenced vehicle (same customer) still work');
-- a line-item reference counts too
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Line Car')
  returning tests.fx_set('veh_line', id);
insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_line'), 'Wax', 3000);
select tests.throws_like($$update public.vehicles set customer_id = tests.fx('cust_a2') where id = tests.fx('veh_line')$$, '23514',
                         '%referenced by job line items%', 'a vehicle on a job line cannot move to another customer');
delete from public.job_line_items where vehicle_id = tests.fx('veh_line');
-- tables added by later migrations are discovered from the catalog
select tests.as_superuser();
create table public.zz_vehicle_refs (
  shop_id uuid not null, vehicle_id uuid not null,
  foreign key (shop_id, vehicle_id) references public.vehicles (shop_id, id));
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Ref Car')
  returning tests.fx_set('veh_ref', id);
insert into public.zz_vehicle_refs values (tests.fx('shop_a'), tests.fx('veh_ref'));
select tests.as_service();
select tests.throws_like($$update public.vehicles set customer_id = tests.fx('cust_a2') where id = tests.fx('veh_ref')$$, '23514',
                         '%referenced by zz vehicle refs%', 'any referencing table blocks the move, in every context');
select tests.as_superuser();
drop table public.zz_vehicle_refs;
-- an unreferenced vehicle can still be corrected to the right customer
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Wrong Owner')
  returning tests.fx_set('veh_free', id);
select tests.eq(tests.row_count($$update public.vehicles set customer_id = tests.fx('cust_a2') where id = tests.fx('veh_free')$$), 1::bigint,
                'an unreferenced vehicle moves to another customer');
select tests.eq((select customer_id from public.vehicles where id = tests.fx('veh_free')), tests.fx('cust_a2'), 'owner corrected');
-- cross-shop: the owner of B cannot move A's vehicles at all
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$update public.vehicles set customer_id = tests.fx('cust_a') where id = tests.fx('veh_free')$$), 0::bigint,
                'owner of B cannot re-assign A''s vehicles');
select tests.authenticate_as(tests.fx('u_manager_a'));

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

-- ------------------------------------------------------------ sort_name (list order)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, company) values (tests.fx('shop_a'), '  Acme Fleet ')
  returning tests.fx_set('cust_sort_co', id);
insert into public.customers (shop_id, first_name, last_name) values (tests.fx('shop_a'), 'Zed', 'Adams')
  returning tests.fx_set('cust_sort_adams', id);
insert into public.customers (shop_id, first_name, last_name, company) values (tests.fx('shop_a'), 'Bo', ' ', 'Zulu Co')
  returning tests.fx_set('cust_sort_blank_last', id);
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Cy')
  returning tests.fx_set('cust_sort_first', id);
select tests.eq((select sort_name from public.customers where id = tests.fx('cust_sort_co')), 'acme fleet ',
                'a company-only customer sorts by company');
select tests.eq((select sort_name from public.customers where id = tests.fx('cust_sort_adams')), 'adams zed',
                'last name first, then first name');
select tests.eq((select sort_name from public.customers where id = tests.fx('cust_sort_blank_last')), 'zulu co bo',
                'a blank last name falls back to the company');
select tests.eq((select sort_name from public.customers where id = tests.fx('cust_sort_first')), 'cy cy',
                'a first-name-only customer sorts by first name');
select tests.eq((select array_agg(id order by sort_name, id) from public.customers
                  where id in (tests.fx('cust_sort_co'), tests.fx('cust_sort_adams'), tests.fx('cust_sort_blank_last'), tests.fx('cust_sort_first'))),
                array[tests.fx('cust_sort_co'), tests.fx('cust_sort_adams'), tests.fx('cust_sort_first'), tests.fx('cust_sort_blank_last')],
                'ordering by sort_name interleaves people and companies');
select tests.throws($$update public.customers set sort_name = 'x' where id = tests.fx('cust_sort_co')$$, '428C9',
                    'sort_name is generated');
update public.customers set last_name = 'Brown' where id = tests.fx('cust_sort_co');
select tests.eq((select sort_name from public.customers where id = tests.fx('cust_sort_co')), 'brown ',
                'sort_name follows edits');
select tests.as_superuser();
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'customers_shop_sort_name_idx'
                          and indexdef like '%(shop_id, sort_name, id)%'), 'sort_name is indexed per shop');
