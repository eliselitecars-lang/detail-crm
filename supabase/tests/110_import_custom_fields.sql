-- 110 comms: customer CSV import takes custom fields (0114) — typed values
-- validated per row (dry run too), blank values dropped, unknown / archived
-- fields and bad types are row errors, a matched customer's value on file is
-- never overwritten (blank fields are filled), and export -> import round
-- trips.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'referred_by', 'Referred by', 'text', 1);
insert into public.custom_fields (shop_id, entity, key, label, type, options, sort)
  values (tests.fx('shop_a'), 'customer', 'interest', 'Interested in', 'select', '{Ceramic coating,Detail}', 2);
insert into public.custom_fields (shop_id, entity, key, label, type, options, sort)
  values (tests.fx('shop_a'), 'customer', 'extras', 'Extras', 'multiselect', '{Wax,Tint,PPF}', 3);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'fleet_size', 'Fleet size', 'number', 4);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'has_garage', 'Has a garage', 'checkbox', 5);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'birthday', 'Birthday', 'date', 6);
insert into public.custom_fields (shop_id, entity, key, label, type, sort, archived_at)
  values (tests.fx('shop_a'), 'customer', 'old_field', 'Old field', 'text', 7, now());
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'job', 'gate_code', 'Gate code', 'text', 1);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_b'), 'customer', 'b_only', 'B only', 'text', 1);
insert into public.customers (shop_id, first_name, email, custom_data)
  values (tests.fx('shop_a'), 'Mia', 'mia@example.com', '{"referred_by": "Google"}') returning tests.fx_set('cust_mia', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table rows_cf (j jsonb);
grant select on rows_cf to authenticated;
insert into rows_cf values ('[
  {"first_name": "Ann", "email": "ann@example.com",
   "custom_data": {"referred_by": "  Bob  ", "interest": "Detail", "extras": ["Wax", "PPF"], "fleet_size": 3,
                   "has_garage": true, "birthday": "1990-04-05"}},
  {"first_name": "Mia", "email": "mia@example.com", "custom_data": {"referred_by": "Yelp", "interest": "Ceramic coating", "fleet_size": null}},
  {"first_name": "Blank", "email": "blank@example.com", "custom_data": {"referred_by": "", "extras": []}},
  {"first_name": "Bad1", "email": "bad1@example.com", "custom_data": {"fleet_size": "three"}},
  {"first_name": "Bad2", "email": "bad2@example.com", "custom_data": {"interest": "Tint"}},
  {"first_name": "Bad3", "email": "bad3@example.com", "custom_data": {"nope": "x"}},
  {"first_name": "Bad4", "email": "bad4@example.com", "custom_data": {"old_field": "x"}},
  {"first_name": "Bad5", "email": "bad5@example.com", "custom_data": {"gate_code": "1234"}},
  {"first_name": "Bad6", "email": "bad6@example.com", "custom_data": {"b_only": "x"}},
  {"first_name": "Bad7", "email": "bad7@example.com", "custom_data": "referred_by=Bob"},
  {"first_name": "Bad8", "email": "bad8@example.com", "custom_data": {"birthday": "04/05/1990"}}
]');

-- ============================================================ dry run
select public.import_customers(tests.fx('shop_a'), (select j from rows_cf), true) as dry \gset
select tests.eq((:'dry'::jsonb) #>> '{counts,created}', '2', 'dry run: Ann and Blank would be created');
select tests.eq((:'dry'::jsonb) #>> '{counts,updated}', '1', 'Mia would be updated (a blank field filled)');
select tests.eq((:'dry'::jsonb) #>> '{counts,errors}', '8', 'every bad custom value is a row error in the dry run');
select tests.ok((:'dry'::jsonb) #>> '{rows,3,message}' like 'Fleet size must be a number%', 'wrong type, by label');
select tests.ok((:'dry'::jsonb) #>> '{rows,4,message}' like 'Interested in must be one of the options%', 'not an option');
select tests.ok((:'dry'::jsonb) #>> '{rows,5,message}' like 'unknown customer field "nope"%', 'unknown field');
select tests.ok((:'dry'::jsonb) #>> '{rows,6,message}' like '%archived%', 'archived field');
select tests.ok((:'dry'::jsonb) #>> '{rows,7,message}' like 'unknown customer field "gate_code"%', 'a job field is not a customer field');
select tests.ok((:'dry'::jsonb) #>> '{rows,8,message}' like 'unknown customer field "b_only"%', 'another shop''s field');
select tests.ok((:'dry'::jsonb) #>> '{rows,9,message}' like 'custom_data must be an object%', 'must be an object');
select tests.ok((:'dry'::jsonb) #>> '{rows,10,message}' like 'Birthday must be a date%', 'dates are YYYY-MM-DD');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email = 'ann@example.com'),
                0::bigint, 'the dry run writes nothing');

-- ============================================================ commit
select public.import_customers(tests.fx('shop_a'), (select j from rows_cf), false) as res \gset
select tests.eq((:'res'::jsonb) #>> '{counts,created}', '2', 'created');
select tests.eq((select custom_data from public.customers where shop_id = tests.fx('shop_a') and email = 'ann@example.com'),
                '{"referred_by": "Bob", "interest": "Detail", "extras": ["Wax", "PPF"], "fleet_size": 3, "has_garage": true, "birthday": "1990-04-05"}'::jsonb,
                'a new customer gets every value (text trimmed)');
select tests.eq((select custom_data from public.customers where id = tests.fx('cust_mia')),
                '{"referred_by": "Google", "interest": "Ceramic coating"}'::jsonb,
                'a matched customer keeps the value on file and gets the blank field filled');
select tests.eq((select custom_data from public.customers where shop_id = tests.fx('shop_a') and email = 'blank@example.com'),
                '{}'::jsonb, 'blank values are dropped');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email like 'bad_@example.com'),
                0::bigint, 'rows with bad custom values are not imported');

-- the same file again: nothing changes
select public.import_customers(tests.fx('shop_a'), (select j from rows_cf), false) as again \gset
select tests.eq((:'again'::jsonb) #>> '{rows,0,action}', 'skip', 'Ann is already up to date');
select tests.eq((:'again'::jsonb) #>> '{rows,1,action}', 'skip', 'Mia too (her value on file wins)');

-- rows without custom_data are unchanged behaviour
select public.import_customers(tests.fx('shop_a'), '[{"first_name": "Mia", "email": "mia@example.com"}]'::jsonb, false) as plain \gset
select tests.eq((select custom_data from public.customers where id = tests.fx('cust_mia')),
                '{"referred_by": "Google", "interest": "Ceramic coating"}'::jsonb, 'no custom_data: nothing touched');
select tests.eq((:'plain'::jsonb) #>> '{rows,0,action}', 'skip', '(skip)');
