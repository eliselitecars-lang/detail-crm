-- 80 comms: CSV import / export (P-5, 0081/0087) — import_customers (dry
-- run writes nothing, email then phone matching, never overwrite, tags /
-- notes / lifecycle rules, consent only on an explicit yes, opt-outs and
-- suppressions win, archived customers not matched, duplicates within the
-- file, vehicles by VIN / make-model-year, per-row errors, 1000-row cap,
-- batches accumulated across chunks), import_services (categories created,
-- prices only from the file and never overwritten, per-shop vehicle sizes),
-- export_jobs (shop-local dates, range limit) and role / shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Phoebe', '+12055550130')
  returning tests.fx_set('cust_phone', id);
insert into public.customers (shop_id, first_name, email, archived_at)
  values (tests.fx('shop_a'), 'Old', 'arch@example.com', now()) returning tests.fx_set('cust_arch', id);
insert into public.customers (shop_id, first_name, email, lifecycle) values (tests.fx('shop_a'), 'Leah', 'leah@example.com', 'lead')
  returning tests.fx_set('cust_lead', id);
insert into public.customers (shop_id, first_name, email, phone, sms_opted_out_at)
  values (tests.fx('shop_a'), 'Otto', 'otto@example.com', '+12055550131', now()) returning tests.fx_set('cust_out', id);
select public.comms_suppress(tests.fx('shop_a'), 'sms', '+12055550140');
insert into public.vehicle_categories (shop_id, name) values (tests.fx('shop_b'), 'Limo');
select count(*) as n_cust_before from public.customers where shop_id = tests.fx('shop_a') \gset

-- ============================================================ access
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.import_customers(tests.fx('shop_a'), '[]')$$, '42501', 'technicians cannot import');
select tests.throws($$select public.import_services(tests.fx('shop_a'), '[]')$$, '42501', 'nor services');
select tests.throws($$select * from public.export_jobs(tests.fx('shop_a'), '2025-06-01', '2025-06-30')$$, '42501', 'nor export');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.import_customers(tests.fx('shop_a'), '[]')$$, '42501', 'not into another shop');
select tests.throws($$select * from public.export_jobs(tests.fx('shop_a'), '2025-06-01', '2025-06-30')$$, '42501',
                    'nor export another shop''s jobs');
select tests.as_anon();
select tests.throws($$select public.import_customers(tests.fx('shop_a'), '[]')$$, '42501', 'anon cannot');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.import_customers(tests.fx('shop_a'), '{}')$$, '22023', 'rows must be a list');
select tests.throws_like($$select public.import_customers(tests.fx('shop_a'),
                            (select jsonb_agg(jsonb_build_object('first_name', 'N' || i)) from generate_series(1, 1001) i))$$,
                         '22023', '%1000 rows%', 'at most 1000 rows per call');
select tests.throws($$select public.import_customers(tests.fx('shop_a'), '[]', false, gen_random_uuid())$$, 'P0002',
                    'unknown batch');

-- ============================================================ customers: dry run
create temp table rows_c (j jsonb);
grant select on rows_c to authenticated;
insert into rows_c values ('[
  {"first_name": "Other", "last_name": "Anders", "email": "ALICE@example.com", "city": "Hoover", "tags": "vip; fleet ;vip",
   "notes": "Prefers mornings", "sms_opt_in": "yes", "vehicle": {"make": "honda", "model": "civic", "year": "2021", "color": "Red"}},
  {"first_name": "Nora", "email": "nora@example.com", "phone": "(205) 555-0141", "sms_opt_in": "Y", "email_opt_in": "sure",
   "tags": ["new"], "vehicle": {"make": "Kia", "model": "Soul", "vin": "kndjn2a2 3j7123456", "category": "small suv"}},
  {"first_name": "Nora", "last_name": "Again", "email": "Nora@Example.com", "notes": "Second visit",
   "vehicle": {"make": "Ford", "model": "Focus", "vin": "KNDJN2A23J7123456"}},
  {"company": "Phone Only Co", "phone": "205-555-0130", "email_opt_in": true},
  {"first_name": "Sam", "phone": "205.555.0101", "email": "sam@example.com"},
  {"first_name": "Stop", "phone": "+12055550140", "sms_opt_in": "1"},
  {"first_name": "Otto", "email": "otto@example.com", "sms_opt_in": "yes"},
  {"first_name": "Back", "email": "arch@example.com"},
  {"first_name": "Leah", "email": "leah@example.com", "lifecycle": "Customer"},
  {"first_name": "Bad", "email": "not-an-email"},
  {"first_name": "Bad", "phone": "12345"},
  {"email": "noname@example.com"},
  {"first_name": "X", "favourite_color": "blue"},
  {"first_name": "Van", "vehicle": {"make": "Ford", "model": "Transit", "category": "Spaceship"}},
  {"first_name": "Other shop size", "vehicle": {"make": "Ford", "model": "Escape", "category": "Limo"}}
]');
create temp table dry1 as
  select public.import_customers(tests.fx('shop_a'), (select j from rows_c), true, null, 'customers.csv') as r;
select tests.eq((select jsonb_build_array(r -> 'dry_run', r -> 'counts', r -> 'batch_id') from dry1),
                '[true, {"created": 4, "updated": 4, "skipped": 1, "errors": 6}, null]'::jsonb, 'dry-run counts');
select tests.eq((select array_agg(e ->> 'action' order by (e ->> 'row')::int) from dry1, jsonb_array_elements(r -> 'rows') e),
                array['update', 'create', 'update', 'update', 'create', 'create', 'skip', 'create', 'update', 'error', 'error', 'error',
                      'error', 'error', 'error'], 'per-row actions (exact, duplicates within the file included)');
select tests.eq((select jsonb_agg(e -> 'message' order by (e ->> 'row')::int) filter (where e ->> 'action' = 'error')
                   from dry1, jsonb_array_elements(r -> 'rows') e),
                '["email \"not-an-email\" is not a valid address", "phone \"12345\" is not a valid number",
                  "a first name, last name or company is required", "unknown column(s): favourite_color",
                  "unknown vehicle size \"Spaceship\"", "unknown vehicle size \"Limo\""]'::jsonb,
                'row errors say why (another shop''s vehicle size is unknown here)');
select tests.ok((select bool_and((e -> 'customer_id') = 'null'::jsonb) from dry1, jsonb_array_elements(r -> 'rows') e
                  where e ->> 'action' = 'create'), 'a dry run hands out no ids for new customers');
select tests.eq((select e -> 'customer_id' from dry1, jsonb_array_elements(r -> 'rows') e where (e ->> 'row')::int = 1),
                to_jsonb(tests.fx('cust_a')), 'the matched customer''s id');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a')), :'n_cust_before'::bigint,
                'the dry run wrote nothing');
select tests.eq((select count(*) from public.import_batches), 0::bigint, 'no batch either');
select tests.ok((select city is null and tags = '{}' from public.customers where id = tests.fx('cust_a')), 'Alice untouched');

-- ============================================================ customers: commit
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table run1 as
  select public.import_customers(tests.fx('shop_a'), (select j from rows_c), false, null, 'customers.csv') as r;
select tests.eq((select jsonb_build_array(r -> 'dry_run', r -> 'counts') from run1),
                '[false, {"created": 4, "updated": 4, "skipped": 1, "errors": 6}]'::jsonb, 'committed with the same result');
select tests.as_superuser();
select tests.fx_set('batch', ((select r from run1) ->> 'batch_id')::uuid);
select tests.eq((select array[kind, status, file_name, row_count::text, created_count::text, updated_count::text, skipped_count::text,
                              error_count::text, jsonb_array_length(errors)::text, (created_by = tests.fx('u_manager_a'))::text]
                   from public.import_batches where id = tests.fx('batch')),
                array['customers', 'committed', 'customers.csv', '15', '4', '4', '1', '6', '6', 'true'], 'the batch row');
-- matched by email: only empty fields filled, never overwritten
select tests.eq((select array[first_name, last_name, city, array_to_string(tags, ','), notes, sms_opt_in::text]
                   from public.customers where id = tests.fx('cust_a')),
                array['Alice', 'Anders', 'Hoover', 'vip,fleet', 'Prefers mornings', 'false'],
                'names kept, empty city filled, tags added, notes set; the row''s text consent names no number, so Alice''s is not opted in');
select tests.eq((select e ->> 'message' from run1, jsonb_array_elements(r -> 'rows') e where (e ->> 'row')::int = 1),
                'text consent not applied: the row has no phone', 'the row says why its consent was not applied');
select tests.eq((select count(*) from public.vehicles where customer_id = tests.fx('cust_a')), 1::bigint,
                'the Honda Civic matched the existing vehicle');
select tests.eq((select color from public.vehicles where id = tests.fx('veh_a')), 'Red', 'its empty color filled');
-- new customers
select tests.eq((select array[source::text, lifecycle::text, phone, sms_opt_in::text, email_opt_in::text, array_to_string(tags, ','),
                              notes]
                   from public.customers where shop_id = tests.fx('shop_a') and email = 'nora@example.com'),
                array['import', 'customer', '+12055550141', 'true', 'false', 'new', 'Second visit'],
                'new: source import; consent only on an explicit yes ("sure" is not); the duplicate row added its note');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and lower(email::text) = 'nora@example.com'),
                1::bigint, 'the file''s duplicate merged into the earlier row');
select tests.eq((select array_agg(v.make || ' ' || v.model || ' ' || coalesce(v.vin, '-') || ' ' || coalesce(vc.name, '-') order by v.make)
                   from public.vehicles v join public.customers c on c.id = v.customer_id
                   left join public.vehicle_categories vc on vc.id = v.category_id
                  where c.email = 'nora@example.com'),
                array['Kia Soul KNDJN2A23J7123456 Small SUV'], 'VIN normalised; the same VIN matched the Kia; size by name');
select tests.eq((select concat_ws('/', email, email_opt_in::text) from public.customers where id = tests.fx('cust_phone')), 'false',
                'matched by phone among customers without an email; email consent without an email is not kept for a later one');
select tests.eq((select e ->> 'message' from run1, jsonb_array_elements(r -> 'rows') e where (e ->> 'row')::int = 4),
                'email consent not applied: the row has no email', '(the row says so)');
select tests.eq((select array[company, first_name] from public.customers where id = tests.fx('cust_phone')), array['Phone Only Co', 'Phoebe'],
                'an empty company filled');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and phone = '+12055550101'), 2::bigint,
                'a phone owned by a customer WITH an email is not matched (Sam is new)');
select tests.ok((select not sms_opt_in and sms_opted_out_at is not null from public.customers
                  where shop_id = tests.fx('shop_a') and first_name = 'Stop'), 'a suppressed number stays opted out');
select tests.ok((select not sms_opt_in and sms_opted_out_at is not null from public.customers where id = tests.fx('cust_out')),
                'an opted-out customer is not opted back in');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email = 'arch@example.com'), 2::bigint,
                'archived customers are not matched');
select tests.eq((select lifecycle::text from public.customers where id = tests.fx('cust_lead')), 'customer', 'a lead may become a customer');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and first_name = 'Other shop size'), 0::bigint,
                'a row with an error writes nothing');

-- a second chunk of the same file accumulates; a re-import of the same row is a skip
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table run2 as
  select public.import_customers(tests.fx('shop_a'),
           '[{"first_name": "Nora", "email": "nora@example.com", "tags": "new"}, {"first_name": "Zed", "notes": "walk-in"}]'::jsonb,
           false, tests.fx('batch')) as r;
select tests.eq((select jsonb_build_array(r -> 'batch_id', r -> 'counts') from run2),
                jsonb_build_array(tests.fx('batch'), '{"created": 1, "updated": 0, "skipped": 1, "errors": 0}'::jsonb),
                'same batch; nothing new about Nora');
select tests.eq((select e ->> 'message' from run2, jsonb_array_elements(r -> 'rows') e where (e ->> 'row')::int = 1),
                'already up to date', 'skip says why');
select tests.as_superuser();
select tests.eq((select array[row_count, created_count, updated_count, skipped_count, error_count] from public.import_batches
                  where id = tests.fx('batch')), array[17, 5, 4, 2, 6], 'counts accumulated');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.import_customers(tests.fx('shop_b'), '[]', false, tests.fx('batch'))$$, 'P0002',
                    'another shop''s batch');
select tests.eq(tests.row_count($$select 1 from public.import_batches where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'other shops do not see the batch');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.import_services(tests.fx('shop_a'), '[]', false, tests.fx('batch'))$$, 'P0002',
                    'a customers batch is not a services batch');
select tests.throws($$insert into public.import_batches (shop_id, kind, status) values (tests.fx('shop_a'), 'customers', 'committed')$$,
                    '42501', 'batches are server-written');
-- a chunk with nothing but errors records a failed batch
create temp table run3 as select public.import_customers(tests.fx('shop_a'), '[{"email": "x"}]', false) as r;
select tests.as_superuser();
select tests.eq((select status from public.import_batches where id = ((select r from run3) ->> 'batch_id')::uuid), 'failed',
                'nothing imported: failed');

-- ============================================================ services
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table svc_rows (j jsonb);
grant select on svc_rows to authenticated;
insert into svc_rows values ('[
  {"name": "Ceramic Coating", "category": "Protection", "kind": "Service", "description": "Two-year coating",
   "duration_minutes": "480", "taxable": "no", "online_bookable": "yes", "prices": {"base": "90000", "small suv": 110000}},
  {"name": "full detail", "description": "Inside and out", "prices": {"base": 99999, "Car": "25000"}},
  {"name": "Tire Shine", "category": "exterior", "kind": "addon"},
  {"name": "Bad price", "prices": {"base": "12.50"}},
  {"name": "Bad size", "prices": {"Spaceship": 100}},
  {"name": "Bad flag", "taxable": "maybe"},
  {"name": "Bad kind", "kind": "gadget"},
  {"category": "No name"}
]');
create temp table dry_s as select public.import_services(tests.fx('shop_a'), (select j from svc_rows)) as r;
select tests.eq((select r -> 'counts' from dry_s), '{"created": 2, "updated": 1, "skipped": 0, "errors": 5}'::jsonb, 'services dry run');
select tests.as_superuser();
select tests.eq((select count(*) from public.services where shop_id = tests.fx('shop_a')), 1::bigint, 'nothing written');
select tests.eq((select count(*) from public.service_categories where shop_id = tests.fx('shop_a') and name = 'Protection'), 0::bigint,
                'no category created by the dry run');
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table run_s as select public.import_services(tests.fx('shop_a'), (select j from svc_rows), false, null, 'services.csv') as r;
select tests.eq((select r -> 'counts' from run_s), '{"created": 2, "updated": 1, "skipped": 0, "errors": 5}'::jsonb, 'committed');
select tests.as_superuser();
select tests.eq((select array[s.kind::text, s.duration_minutes::text, s.taxable::text, s.online_bookable::text, sc.name, s.description]
                   from public.services s join public.service_categories sc on sc.id = s.category_id
                  where s.shop_id = tests.fx('shop_a') and s.name = 'Ceramic Coating'),
                array['service', '480', 'false', 'true', 'Protection', 'Two-year coating'], 'created with a new category');
select tests.eq((select array_agg(coalesce(vc.name, 'base') || '=' || sp.price_cents order by sp.price_cents)
                   from public.service_prices sp join public.services s on s.id = sp.service_id
                   left join public.vehicle_categories vc on vc.id = sp.vehicle_category_id
                  where s.shop_id = tests.fx('shop_a') and s.name = 'Ceramic Coating'),
                array['base=90000', 'Small SUV=110000'], 'prices exactly as in the file (vehicle size by name, this shop''s)');
select tests.ok((select vc.shop_id = tests.fx('shop_a') from public.service_prices sp
                   join public.vehicle_categories vc on vc.id = sp.vehicle_category_id
                   join public.services s on s.id = sp.service_id where s.name = 'Ceramic Coating'), 'shop A''s size');
select tests.eq((select array_agg(coalesce(vc.name, 'base') || '=' || sp.price_cents order by sp.price_cents)
                   from public.service_prices sp left join public.vehicle_categories vc on vc.id = sp.vehicle_category_id
                  where sp.service_id = tests.fx('svc_a')),
                array['base=20000', 'Car=25000'], 'the existing base price is never overwritten; the missing size price added');
select tests.eq((select e ->> 'message' from run_s, jsonb_array_elements(r -> 'rows') e where (e ->> 'row')::int = 2),
                'existing price kept for: base', 'kept prices are reported');
select tests.eq((select description from public.services where id = tests.fx('svc_a')), 'Inside and out', 'an empty description filled');
select tests.eq((select array[kind::text, (category_id is not null)::text] from public.services where name = 'Tire Shine'),
                array['addon', 'true'], 'category matched case-insensitively (created once)');
select tests.eq((select count(*) from public.service_prices sp join public.services s on s.id = sp.service_id
                  where s.name = 'Tire Shine'), 0::bigint, 'no price in the file: no price invented');
select tests.eq((select count(*) from public.service_categories where shop_id = tests.fx('shop_a') and lower(name) = 'exterior'),
                1::bigint, 'the existing Exterior category was reused');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select public.import_services(tests.fx('shop_a'), (select jsonb_agg(e) from svc_rows, jsonb_array_elements(j) e
                                                                        where e ->> 'name' = 'full detail'), false) -> 'counts'),
                '{"created": 0, "updated": 0, "skipped": 1, "errors": 0}'::jsonb, 're-importing the same row changes nothing');

-- ============================================================ export_jobs
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end, location_type, service_address_line1, service_city,
                         service_postal_code)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-03 03:00Z', '2025-06-03 04:00Z', 'mobile', '1 Elm St', 'Hoover', '35216')
  returning tests.fx_set('job_late', id);
insert into public.payments (shop_id, customer_id, job_id, kind, method, status, amount_cents, paid_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_a'), 'deposit', 'cash', 'succeeded', 5000, now());
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select array_agg(number order by number) from public.export_jobs(tests.fx('shop_a'), '2025-06-02', '2025-06-02')),
                (select array_agg(number order by number) from public.jobs where id in (tests.fx('job_a'), tests.fx('job_a2'), tests.fx('job_late'))),
                'shop-local dates (22:00 CDT on June 2 is 03:00 UTC on June 3)');
select tests.eq((select count(*) from public.export_jobs(tests.fx('shop_a'), '2025-06-03', '2025-06-03')), 0::bigint,
                'nothing on the local June 3');
select tests.eq((select array[status::text, scheduled_local, customer_name, customer_email, customer_phone, vehicle, services,
                              location_type::text, total_cents::text, paid_cents::text, balance_cents::text, source::text]
                   from public.export_jobs(tests.fx('shop_a'), '2025-06-01', '2025-06-30') where number = (select number from public.jobs
                                                                                                           where id = tests.fx('job_a'))),
                array['scheduled', '2025-06-02 10:00', 'Alice Anders', 'alice@example.com', '+12055550101', '2021 Honda Civic',
                      'Full Detail', 'shop', '20000', '5000', '15000', 'staff'], 'the job row');
select tests.eq((select service_address from public.export_jobs(tests.fx('shop_a'), '2025-06-01', '2025-06-30')
                  where scheduled_local = '2025-06-02 22:00'), '1 Elm St, Hoover, 35216', 'mobile jobs carry their address');
select tests.eq((select count(*) from public.export_jobs(tests.fx('shop_a'), '2025-06-01', '2025-06-30') where number is null), 0::bigint,
                'only shop A jobs');
select tests.eq((select count(*) from public.export_jobs(tests.fx('shop_a'), '2025-01-01', '2025-12-31')),
                (select count(*) from public.jobs where shop_id = tests.fx('shop_a')
                    and (coalesce(scheduled_start, created_at) at time zone 'America/Chicago')::date between '2025-01-01' and '2025-12-31'),
                'exactly shop A''s jobs in the range');
select tests.eq((select count(*) from public.export_jobs(tests.fx('shop_a'), '2025-01-01', '2025-12-31') where customer_name = 'Bob Burns'),
                0::bigint, 'no shop B job leaks');
select tests.throws($$select * from public.export_jobs(tests.fx('shop_a'), '2025-06-30', '2025-06-01')$$, '22023', 'from <= to');
select tests.throws($$select * from public.export_jobs(tests.fx('shop_a'), '2020-01-01', '2023-01-02')$$, '22023', 'at most 3 years');
select tests.lives($$select * from public.export_jobs(tests.fx('shop_a'), '2020-01-01', '2023-01-01')$$, 'exactly 3 years is fine');

-- ============================================================ lifecycle only when the file says so
-- A file without a lifecycle column (a mailing list, a tags-only
-- enrichment) or with a blank one never promotes a matched lead: matched
-- records are only filled, never overwritten. New customers still default
-- to 'customer'.
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, lifecycle, source)
  values (tests.fx('shop_a'), 'Lena', 'lena@example.com', 'lead', 'other') returning tests.fx_set('lead_l', id);
insert into public.customers (shop_id, first_name, email, lifecycle, source)
  values (tests.fx('shop_a'), 'Lars', 'lars@example.com', 'lead', 'other') returning tests.fx_set('lead_b', id);
insert into public.customers (shop_id, first_name, email, lifecycle, source)
  values (tests.fx('shop_a'), 'Lou', 'lou@example.com', 'lead', 'other') returning tests.fx_set('lead_x', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table run_life as
  select public.import_customers(tests.fx('shop_a'),
           '[{"email": "lena@example.com", "tags": "newsletter"},
             {"email": "lars@example.com", "lifecycle": "  ", "tags": "newsletter"},
             {"email": "lou@example.com", "lifecycle": "CUSTOMER"},
             {"first_name": "Nia", "email": "nia@example.com"},
             {"first_name": "Lyle", "email": "lyle@example.com", "lifecycle": "lead"}]'::jsonb, false) as r;
select tests.eq((select jsonb_agg(x -> 'action' order by (x ->> 'row')::int) from run_life, jsonb_array_elements(r -> 'rows') x),
                '["update", "update", "update", "create", "create"]'::jsonb, 'every row applied');
select tests.eq((select array[lifecycle::text, array_to_string(tags, ',')] from public.customers where id = tests.fx('lead_l')),
                array['lead', 'newsletter'],
                'no lifecycle column: the matched lead stays a lead (only the tag is added)');
select tests.eq((select lifecycle::text from public.customers where id = tests.fx('lead_b')), 'lead', 'a blank lifecycle: still a lead');
select tests.eq((select lifecycle::text from public.customers where id = tests.fx('lead_x')), 'customer',
                'an explicit "customer" promotes the lead');
select tests.eq((select lifecycle::text from public.customers where shop_id = tests.fx('shop_a') and email = 'nia@example.com'), 'customer',
                'a new customer without a lifecycle is a customer');
select tests.eq((select lifecycle::text from public.customers where shop_id = tests.fx('shop_a') and email = 'lyle@example.com'), 'lead',
                'a new row marked lead is a lead');
-- a dry run of the tags-only file reports no lifecycle change either
select tests.as_superuser();
update public.customers set lifecycle = 'lead' where id = tests.fx('lead_x');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select x -> 'action' from jsonb_array_elements(
                   public.import_customers(tests.fx('shop_a'), '[{"email": "lena@example.com", "tags": "newsletter"}]'::jsonb, true)
                   -> 'rows') x),
                '"skip"'::jsonb, 're-importing the tags-only row changes nothing (skip)');
