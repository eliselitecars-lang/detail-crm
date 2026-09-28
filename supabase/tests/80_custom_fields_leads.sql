-- 80 comms: custom fields, booking questions and lead forms (P-9,
-- 0081/0088) — definitions (RLS: every member reads, admins write;
-- CHECKs), value validation per type on customers / jobs, archived keys
-- kept, identity guards (no delete / key / type change with values),
-- required and location-scoped booking questions through
-- create_online_booking, public_booking_questions, lead forms (field
-- rules, token), public_get_lead_form / public_submit_lead (new vs
-- matched — a matched customer is never modified —, consent only as
-- ticked, honeypot, PT429 limits incl. per client IP, notification with the
-- customer, the auto-reply: emailed, texted only to a verified phone, never
-- carrying the visitor's text), submissions RLS, the customer-merge follow-up and
-- cross-shop isolation.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
update public.notifications set pushed_at = now() where pushed_at is null;

-- ============================================================ definitions
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.custom_fields (shop_id, entity, key, label, type, help_text, sort)
  values (tests.fx('shop_a'), 'customer', 'referred_by', '  Referred by  ', 'text', '  Who sent you?  ', 1)
  returning tests.fx_set('f_ref', id);
insert into public.custom_fields (shop_id, entity, key, label, type, options, required, show_in_lead_form, sort)
  values (tests.fx('shop_a'), 'customer', 'interest', 'Interested in', 'select', '{Ceramic coating,Paint correction,Detail}', true, true, 2)
  returning tests.fx_set('f_int', id);
insert into public.custom_fields (shop_id, entity, key, label, type, options, sort)
  values (tests.fx('shop_a'), 'customer', 'extras', 'Extras', 'multiselect', '{Wax,Tint,PPF}', 3) returning tests.fx_set('f_ext', id);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'fleet_size', 'Fleet size', 'number', 4) returning tests.fx_set('f_num', id);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'has_garage', 'Has a garage', 'checkbox', 5) returning tests.fx_set('f_chk', id);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'birthday', 'Birthday', 'date', 6) returning tests.fx_set('f_date', id);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'customer', 'notes_long', 'Long notes', 'textarea', 7) returning tests.fx_set('f_ta', id);
insert into public.custom_fields (shop_id, entity, key, label, type, required, show_in_booking, sort)
  values (tests.fx('shop_a'), 'job', 'gate_code', 'Gate code', 'text', true, true, 1) returning tests.fx_set('q_gate', id);
insert into public.custom_fields (shop_id, entity, key, label, type, required, show_in_booking, location_scope, sort)
  values (tests.fx('shop_a'), 'job', 'parking', 'Where can we park?', 'text', true, true, 'mobile', 2) returning tests.fx_set('q_park', id);
insert into public.custom_fields (shop_id, entity, key, label, type, show_in_booking, sort)
  values (tests.fx('shop_a'), 'job', 'pets', 'Pets at home', 'checkbox', true, 3) returning tests.fx_set('q_pets', id);
insert into public.custom_fields (shop_id, entity, key, label, type, sort)
  values (tests.fx('shop_a'), 'job', 'damage_notes', 'Damage notes (internal)', 'textarea', 9) returning tests.fx_set('q_int', id);
select tests.eq((select array[label, help_text] from public.custom_fields where id = tests.fx('f_ref')),
                array['Referred by', 'Who sent you?'], 'label and help text trimmed');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'customer', 'Bad Key', 'x', 'text')$$,
                    '23514', 'keys are snake_case');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'customer', 'referred_by', 'x', 'text')$$,
                    '23505', 'one key per entity');
select tests.lives($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'job', 'referred_by', 'x', 'text')$$,
                   'the same key on another entity');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'customer', 'k1', 'x', 'select')$$,
                    '23514', 'select needs options');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type, options) values (tests.fx('shop_a'), 'customer', 'k2', 'x', 'select', '{a,a}')$$,
                    '23514', 'options are distinct');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type, options) values (tests.fx('shop_a'), 'customer', 'k3', 'x', 'text', '{a}')$$,
                    '23514', 'only choice fields have options');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type, show_in_booking) values (tests.fx('shop_a'), 'customer', 'k4', 'x', 'text', true)$$,
                    '23514', 'booking questions are job fields');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type, show_in_lead_form) values (tests.fx('shop_a'), 'job', 'k5', 'x', 'text', true)$$,
                    '23514', 'lead form fields are customer fields');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type, location_scope) values (tests.fx('shop_a'), 'customer', 'k6', 'x', 'text', 'mobile')$$,
                    '23514', 'location scope only for job fields');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'customer', 'k7', 'x', 'text')$$,
                    '42501', 'managers cannot define fields');
select tests.eq(tests.row_count($$update public.custom_fields set label = 'x'$$), 0::bigint, 'nor edit them');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.custom_fields$$), 12::bigint, 'technicians read the definitions');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_a'), 'job', 'k8', 'x', 'text')$$,
                    '42501', 'but cannot write them');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$select 1 from public.custom_fields$$), 0::bigint, 'another shop sees none');
select tests.eq(tests.row_count($$delete from public.custom_fields$$), 0::bigint, 'nor deletes any');

-- ============================================================ validation (customers)
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set custom_data = jsonb_build_object(
    'referred_by', '  Dana  ', 'interest', 'Detail', 'extras', jsonb_build_array('Wax', 'PPF'), 'fleet_size', 3,
    'has_garage', true, 'birthday', '1990-02-28', 'notes_long', repeat('n', 5000), 'blank', null)
 where id = tests.fx('cust_a');
select tests.eq((select custom_data - 'notes_long' from public.customers where id = tests.fx('cust_a')),
                '{"referred_by": "Dana", "interest": "Detail", "extras": ["Wax", "PPF"], "fleet_size": 3, "has_garage": true, "birthday": "1990-02-28"}'::jsonb,
                'valid values stored (text trimmed, nulls dropped)');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"referred_by": 5}' where id = tests.fx('cust_a')$$,
                         '22023', 'Referred by must be text%', 'text must be text');
select tests.throws_like($$update public.customers set custom_data = custom_data || jsonb_build_object('referred_by', repeat('x', 2001))
                           where id = tests.fx('cust_a')$$, '22023', '%too long%', 'text at most 2000');
select tests.throws_like($$update public.customers set custom_data = custom_data || jsonb_build_object('notes_long', repeat('x', 10001))
                           where id = tests.fx('cust_a')$$, '22023', 'Long notes is too long%', 'textarea at most 10000');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"fleet_size": "3"}' where id = tests.fx('cust_a')$$,
                         '22023', 'Fleet size must be a number', 'numbers are JSON numbers');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"interest": "Wheels"}' where id = tests.fx('cust_a')$$,
                         '22023', 'Interested in must be one of the options', 'select: one option');
select tests.throws($$update public.customers set custom_data = custom_data || '{"extras": ["Wax", "Wax"]}' where id = tests.fx('cust_a')$$,
                    '22023', 'multiselect: distinct');
select tests.throws($$update public.customers set custom_data = custom_data || '{"extras": ["Gold"]}' where id = tests.fx('cust_a')$$,
                    '22023', 'multiselect: options only');
select tests.throws($$update public.customers set custom_data = custom_data || '{"has_garage": "yes"}' where id = tests.fx('cust_a')$$,
                    '22023', 'checkbox: true / false');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"birthday": "2025-02-30"}' where id = tests.fx('cust_a')$$,
                         '22023', 'Birthday must be a date%', 'dates must exist');
select tests.throws($$update public.customers set custom_data = custom_data || '{"birthday": "02/28/1990"}' where id = tests.fx('cust_a')$$,
                    '22023', 'dates are YYYY-MM-DD');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"nope": 1}' where id = tests.fx('cust_a')$$,
                         '22023', 'unknown customer field%', 'unknown keys');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"gate_code": "1"}' where id = tests.fx('cust_a')$$,
                         '22023', 'unknown customer field%', 'job fields are not customer fields');
select tests.throws($$update public.customers set custom_data = '[]' where id = tests.fx('cust_a')$$, '23514', 'always an object');
-- archived fields: existing values are kept, new values refused
select tests.as_superuser();
update public.custom_fields set archived_at = now() where id = tests.fx('f_ref');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.customers set custom_data = custom_data || '{"fleet_size": 4}' where id = tests.fx('cust_a')$$,
                   'other values still change');
select tests.eq((select custom_data ->> 'referred_by' from public.customers where id = tests.fx('cust_a')), 'Dana', 'the archived value is kept');
select tests.throws_like($$update public.customers set custom_data = custom_data || '{"referred_by": "Eve"}' where id = tests.fx('cust_a')$$,
                         '22023', '%archived%', 'an archived field takes no new value');
select tests.throws_like($$update public.customers set custom_data = '{"referred_by": "Dana2"}' where id = tests.fx('cust_a2')$$,
                         '22023', '%archived%', 'nor on another customer');
select tests.lives($$update public.customers set custom_data = custom_data - 'referred_by' where id = tests.fx('cust_a')$$,
                   'an archived value can be removed');
-- options changed later: unchanged values stay valid
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.custom_fields set options = '{Ceramic coating,Paint correction}' where id = tests.fx('f_int');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.customers set custom_data = custom_data || '{"has_garage": false}' where id = tests.fx('cust_a')$$,
                   'a value whose option was removed stays as it was');
-- identity guards
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$delete from public.custom_fields where id = tests.fx('f_int')$$, '23514', '%archive it instead%',
                         'a field with values cannot be deleted');
select tests.throws($$update public.custom_fields set key = 'topic' where id = tests.fx('f_int')$$, '23514', 'nor re-keyed');
select tests.throws($$update public.custom_fields set type = 'text', options = '{}' where id = tests.fx('f_int')$$, '23514', 'nor re-typed');
select tests.lives($$update public.custom_fields set label = 'Interest', help_text = 'Pick one' where id = tests.fx('f_int')$$,
                   'labels and flags may change');

-- ============================================================ booking questions
select tests.as_anon();
select tests.eq((select jsonb_agg(q ->> 'key') from jsonb_array_elements(public.public_booking_questions('Shop-A')) q),
                '["gate_code", "parking", "pets"]'::jsonb, 'booking questions in order (internal fields left out)');
select tests.eq((select q from jsonb_array_elements(public.public_booking_questions('shop-a')) q where q ->> 'key' = 'parking'),
                '{"key": "parking", "label": "Where can we park?", "type": "text", "options": [], "help_text": null, "required": true, "location_scope": "mobile"}'::jsonb,
                'curated keys');
select tests.throws($$select public.public_booking_questions('nope')$$, 'PT404', 'unknown shop');
select tests.eq(public.public_booking_questions('shop-b'), '[]'::jsonb, 'a shop without questions');
-- bookings at a fixed clock (trusted caller; API callers always use the server clock)
select tests.as_superuser();
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z')$$,
                         '22023', 'Gate code is required', 'a required question must be answered');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('answers',
                             jsonb_build_object('gate_code', '42', 'damage_notes', 'x'))), '2025-06-01 12:00Z')$$,
                         '22023', '%unknown booking question "damage_notes"%', 'internal fields cannot be answered online');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('answers',
                             jsonb_build_object('gate_code', '42', 'parking', 'Driveway'))), '2025-06-01 12:00Z')$$,
                         '22023', '%unknown booking question "parking"%', 'a mobile-only question is not asked for a shop visit');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('answers',
                             jsonb_build_object('gate_code', '42', 'pets', 'yes'))), '2025-06-01 12:00Z')$$,
                         '22023', 'Pets at home must be true or false', 'answers are validated');
create temp table bk1 as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('answers',
           jsonb_build_object('gate_code', ' 1234 ', 'pets', true))), '2025-06-01 12:00Z') as r;
select tests.eq((select custom_data from public.jobs j join bk1 on j.number = (bk1.r ->> 'job_number')::bigint
                  where j.shop_id = tests.fx('shop_a')), '{"gate_code": "1234", "pets": true}'::jsonb, 'answers stored');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'starts_at', '2025-06-10T15:00:00Z',
                             'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Elm', 'city', 'Hoover', 'postal_code', '35216'),
                             'answers', jsonb_build_object('gate_code', '1'))), '2025-06-01 12:00Z')$$,
                         '22023', 'Where can we park? is required', 'the mobile-only question is required for mobile visits');
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                       'starts_at', '2025-06-10T15:00:00Z',
                       'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Elm', 'city', 'Hoover', 'postal_code', '35216'),
                       'answers', jsonb_build_object('gate_code', '1', 'parking', 'Driveway'))), '2025-06-01 12:00Z')$$,
                   'answered: booked');
-- staff may leave booking questions empty and fill internal fields
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set custom_data = '{"damage_notes": "Door ding"}' where id = tests.fx('job_a')$$,
                   'staff edit job fields (required booking questions are only for online bookings)');
select tests.throws($$update public.jobs set custom_data = '{"interest": "Detail"}' where id = tests.fx('job_a')$$, '22023',
                    'customer fields are not job fields');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set custom_data = '{}' where id = tests.fx('job_a')$$, '42501',
                    'technicians do not edit job fields');
-- deleting a field without values is fine; one with values is not
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$delete from public.custom_fields where id = tests.fx('q_int')$$, '23514', 'a job field with values stays');

-- ============================================================ lead forms
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.lead_forms (shop_id, name, headline, field_ids, default_source, success_message, token)
  values (tests.fx('shop_a'), '  Coating inquiry  ', 'Get a coating quote',
          array[tests.fx('f_int'), tests.fx('f_ext'), tests.fx('f_int'), tests.fx('f_num'), tests.fx('f_ref')], 'instagram',
          'Thanks, we will call you!', '00000000-0000-0000-0000-000000000001')
  returning tests.fx_set('form', id);
select tests.as_superuser();
select tests.fx_set('tok', (select token from public.lead_forms where id = tests.fx('form')));
select tests.eq((select array[name, (field_ids = array[tests.fx('f_int'), tests.fx('f_ext'), tests.fx('f_num'), tests.fx('f_ref')])::text]
                   from public.lead_forms where id = tests.fx('form')), array['Coating inquiry', 'true'], 'name trimmed, fields de-duplicated');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.lead_forms set token = gen_random_uuid() where id = tests.fx('form')$$, '42501', 'the token is fixed');
select tests.throws($$insert into public.lead_forms (shop_id, name, field_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('q_gate')])$$,
                    '22023', 'only customer fields');
select tests.as_superuser();
insert into public.custom_fields (shop_id, entity, key, label, type) values (tests.fx('shop_b'), 'customer', 'b_field', 'B', 'text')
  returning tests.fx_set('f_b', id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$insert into public.lead_forms (shop_id, name, field_ids) values (tests.fx('shop_a'), 'x', array[tests.fx('f_b')])$$,
                    '22023', 'not another shop''s fields');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.lead_forms$$), 1::bigint, 'managers read forms (to share the link)');
select tests.throws($$insert into public.lead_forms (shop_id, name) values (tests.fx('shop_a'), 'x')$$, '42501', 'admins manage them');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.lead_forms$$), 0::bigint, 'technicians do not see forms');

select tests.as_anon();
select tests.eq((select jsonb_build_array(r -> 'shop' ->> 'name', r -> 'form' ->> 'name', r -> 'form' ->> 'headline',
                                          jsonb_path_query_array(r -> 'fields', '$[*].key'))
                   from (select public.public_get_lead_form(tests.fx('tok')) as r) x),
                '["Shop A", "Coating inquiry", "Get a coating quote", ["interest", "extras", "fleet_size"]]'::jsonb,
                'the public form (archived fields hidden, the form''s order)');
select tests.eq((select jsonb_object_keys_agg from (select string_agg(k, ',' order by k) as jsonb_object_keys_agg
                  from jsonb_object_keys(public.public_get_lead_form(tests.fx('tok'))) k) x), 'fields,form,shop', 'curated keys');
select tests.throws($$select public.public_get_lead_form(gen_random_uuid())$$, 'PT404', 'unknown form');
select tests.throws($$select public.public_get_lead_form(null)$$, 'PT404', 'no token');

-- submit: a new customer
create function pg_temp.lead(p_overrides jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('first_name', 'Lena', 'last_name', 'Lead', 'email', 'lena@example.com', 'phone', '(205) 555-0161',
                            'sms_opt_in', true, 'vehicle', jsonb_build_object('year', 2022, 'make', 'Audi', 'model', 'Q5'),
                            'message', 'Looking for a coating', 'answers', jsonb_build_object('interest', 'Ceramic coating', 'extras', jsonb_build_array('PPF')))
         || p_overrides
$$;
grant execute on function pg_temp.lead(jsonb) to anon, authenticated;
select tests.eq(public.public_submit_lead(tests.fx('tok'), pg_temp.lead()), '{"ok": true, "message": "Thanks, we will call you!"}'::jsonb,
                'submitted');
select tests.as_superuser();
select tests.eq((select array[lifecycle::text, source::text, phone, sms_opt_in::text, email_opt_in::text, phone_unverified::text,
                              custom_data::text]
                   from public.customers where shop_id = tests.fx('shop_a') and email = 'lena@example.com'),
                array['lead', 'instagram', '+12055550161', 'true', 'false', 'true',
                      '{"extras": ["PPF"], "interest": "Ceramic coating"}'],
                'a new lead: the form''s source, consent only as ticked, answers as custom data, phone unverified');
select tests.eq((select array[matched_existing::text, message, vehicle_info::text, (vehicle_id is not null)::text]
                   from public.lead_submissions where lead_form_id = tests.fx('form')),
                array['false', 'Looking for a coating', '{"make": "Audi", "year": 2022, "model": "Q5"}', 'true'],
                'the submission (with the new customer''s first vehicle)');
select tests.eq((select array_agg(n.user_id order by n.user_id) from public.notifications n where n.kind = 'new_lead'),
                (select array_agg(u order by u) from unnest(array[tests.fx('u_owner_a'), tests.fx('u_admin_a'), tests.fx('u_manager_a')]) u),
                'owner, admin and manager are notified (not technicians)');
select tests.ok((select bool_and(title = 'New lead: Lena Lead' and body = 'Coating inquiry · Looking for a coating'
                                 and customer_id = (select id from public.customers where email = 'lena@example.com'))
                   from public.notifications where kind = 'new_lead'), 'with a deep link to the customer');
select tests.eq((select count(*) from public.messages where template_key = 'lead_received'), 0::bigint, 'no auto-reply unless enabled');

-- submit: an existing customer is never modified
select tests.as_superuser();
create temp table alice_before as select to_jsonb(c) - 'updated_at' as c from public.customers c where id = tests.fx('cust_a');
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object(
         'first_name', 'Mallory', 'email', 'ALICE@example.com', 'phone', '+12055550199', 'email_opt_in', true,
         'answers', jsonb_build_object('interest', 'Paint correction', 'fleet_size', 12))));
select tests.as_superuser();
select tests.eq((select to_jsonb(c) - 'updated_at' from public.customers c where id = tests.fx('cust_a')), (select c from alice_before),
                'the matched customer is untouched');
select tests.eq((select array[matched_existing::text, answers::text, (vehicle_id is null)::text, vehicle_info ->> 'make']
                   from public.lead_submissions where customer_id = tests.fx('cust_a')),
                array['true', '{"interest": "Paint correction", "fleet_size": 12}', 'true', 'Audi'],
                'answers and vehicle stay on the submission');
-- matched by phone among customers without an email
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Pia', '+12055550162') returning tests.fx_set('cust_pia', id);
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('first_name', 'Pia', 'email', null, 'phone', '205-555-0162')));
select tests.as_superuser();
select tests.eq((select count(*) from public.lead_submissions where customer_id = tests.fx('cust_pia')), 1::bigint, 'matched by phone');

-- validation
select tests.as_anon();
select tests.throws_like($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('answers', '{}'::jsonb)))$$,
                         '22023', 'Interest is required', 'required questions');
select tests.throws_like($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('answers',
                             jsonb_build_object('interest', 'Paint correction', 'birthday', '2000-01-01'))))$$,
                         '22023', 'unknown question%', 'only the form''s questions');
select tests.throws_like($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('answers',
                             jsonb_build_object('interest', 'Paint correction', 'fleet_size', 'many'))))$$,
                         '22023', 'Fleet size must be a number', 'answers are validated');
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', null, 'phone', null)))$$,
                    '22023', 'an email or a phone');
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', 'nope')))$$,
                    '22023', 'a valid email');
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('first_name', ' ')))$$,
                    '22023', 'a first name');
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), '[]')$$, '22023', 'an object');
select tests.throws($$select public.public_submit_lead(gen_random_uuid(), pg_temp.lead())$$, 'PT404', 'unknown form');
-- honeypot: answered as a success, nothing written
select tests.eq(public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', 'bot@example.com',
                                                                                          'website', 'http://spam.test'))),
                '{"ok": true, "message": "Thanks, we will call you!"}'::jsonb, 'the honeypot looks like a success');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where email = 'bot@example.com'), 0::bigint, '… and writes nothing');

-- rate limits
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok'), pg_temp.lead());
select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', 'LENA@example.com')));
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('phone', null)))$$, 'PT429',
                    'at most 3 submissions per email and form in 24 hours');
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', 'other@example.com')))$$,
                    'PT429', '… or per phone');
select tests.as_superuser();
insert into public.lead_submissions (shop_id, lead_form_id, customer_id, matched_existing)
  select tests.fx('shop_a'), tests.fx('form'), tests.fx('cust_a3'), true from generate_series(1, 200);
select tests.as_anon();
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead(jsonb_build_object('email', 'fresh@example.com',
                                                                                                      'phone', null)))$$,
                    'PT429', 'at most 200 per form in 24 hours');
-- inactive / archived forms
select tests.as_superuser();
update public.lead_forms set active = false where id = tests.fx('form');
select tests.as_anon();
select tests.throws($$select public.public_get_lead_form(tests.fx('tok'))$$, 'PT404', 'an inactive form is not found');
select tests.as_superuser();
update public.lead_forms set active = true, archived_at = now() where id = tests.fx('form');
select tests.as_anon();
select tests.throws($$select public.public_submit_lead(tests.fx('tok'), pg_temp.lead())$$, 'PT404', 'an archived form is not found');

-- auto-reply (transactional lead_received)
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.lead_forms (shop_id, name, auto_reply, notify_staff, ask_vehicle, ask_message)
  values (tests.fx('shop_a'), 'Quick contact', true, false, false, false) returning tests.fx_set('form2', id);
select tests.as_superuser();
select tests.fx_set('tok2', (select token from public.lead_forms where id = tests.fx('form2')));
update public.notifications set pushed_at = now() where pushed_at is null;
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok2'), jsonb_build_object('first_name', 'Rita', 'email', 'rita@example.com',
                                                                      'phone', '2055550163', 'message', 'ignored',
                                                                      'vehicle', jsonb_build_object('make', 'Ford', 'model', 'F-150')));
select tests.as_superuser();
select tests.eq((select array_agg(channel::text order by channel) from public.messages m join public.customers c on c.id = m.customer_id
                  where m.template_key = 'lead_received' and c.email = 'rita@example.com'), array['email'],
                'the auto-reply is emailed (transactional: no opt-in needed) — never texted to a new lead''s unverified phone');
select tests.ok((select body like E'Hi there,\n\nThanks for reaching out to Shop A!%' from public.messages
                  where template_key = 'lead_received' and channel = 'email' and to_address = 'rita@example.com'),
                'lead_received wording: a neutral greeting, never the name the visitor typed');
select tests.eq((select array[coalesce(message, 'null'), coalesce(vehicle_info::text, 'null')] from public.lead_submissions
                  where lead_form_id = tests.fx('form2')), array['null', 'null'], 'fields the form does not ask are ignored');
select tests.eq((select count(*) from public.notifications where pushed_at is null and kind = 'new_lead'), 0::bigint,
                'notify_staff off: no notification');
select tests.eq((select count(*) from public.vehicles v join public.customers c on c.id = v.customer_id where c.email = 'rita@example.com'),
                0::bigint, 'no vehicle when the form does not ask for one');

-- matching skips a record whose phone is unverified (0042: it came from
-- someone else's public form) and differs from the submitted one — the
-- auto-reply would otherwise be texted to that stranger's phone
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, phone_unverified, source)
  values (tests.fx('shop_a'), 'Vic', 'vic@example.com', '+12055550177', true, 'online_booking')
  returning tests.fx_set('cust_v', id);
create temp table vic_before as select to_jsonb(c) - 'updated_at' as c from public.customers c where id = tests.fx('cust_v');
select tests.as_anon();
select tests.eq(public.public_submit_lead(tests.fx('tok2'),
                  '{"first_name": "Vic", "email": "vic@example.com", "phone": "+12055550188"}'::jsonb) -> 'ok', 'true'::jsonb,
                'the lead is accepted');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a') and template_key = 'lead_received'
                    and to_address = '+12055550177'), 0::bigint,
                'the auto-reply is not texted to the stranger''s unverified phone');
select tests.ok((select customer_id from public.lead_submissions
                  where lead_form_id = tests.fx('form2') order by created_at desc, id desc limit 1) is distinct from tests.fx('cust_v'),
                'like online booking, the lead is not attached to that record');
select tests.eq((select array[c.lifecycle::text, c.phone, c.phone_unverified::text, s.matched_existing::text]
                   from public.lead_submissions s join public.customers c on c.id = s.customer_id
                  where s.lead_form_id = tests.fx('form2') and c.email = 'vic@example.com' and c.id <> tests.fx('cust_v')),
                array['lead', '+12055550188', 'true', 'false'], 'a new lead with exactly what was entered');
select tests.eq((select array_agg(m.to_address order by m.channel) from public.messages m join public.customers c on c.id = m.customer_id
                  where m.template_key = 'lead_received' and c.email = 'vic@example.com'),
                array['vic@example.com'], 'the auto-reply reaches the email only (the submitted phone is unverified)');
select tests.eq((select to_jsonb(c) - 'updated_at' from public.customers c where id = tests.fx('cust_v')), (select c from vic_before),
                'the unverified record is untouched');
-- the same unverified phone given again: that record matches
insert into public.customers (shop_id, first_name, email, phone, phone_unverified, source)
  values (tests.fx('shop_a'), 'Una', 'una@example.com', '+12055550178', true, 'online_booking')
  returning tests.fx_set('cust_u', id);
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Una", "email": "UNA@example.com", "phone": "205-555-0178"}'::jsonb);
select tests.as_superuser();
select tests.eq((select array[customer_id::text, matched_existing::text] from public.lead_submissions
                  where customer_id = tests.fx('cust_u')), array[tests.fx('cust_u')::text, 'true'],
                'same email and the same (unverified) phone: matched');
-- an email-only lead does not take over an unverified record either
insert into public.customers (shop_id, first_name, email, phone, phone_unverified, source)
  values (tests.fx('shop_a'), 'Wes', 'wes@example.com', '+12055550179', true, 'online_booking')
  returning tests.fx_set('cust_w', id);
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Wes", "email": "wes@example.com"}'::jsonb);
select tests.as_superuser();
select tests.eq((select count(*) from public.lead_submissions where customer_id = tests.fx('cust_w')), 0::bigint,
                'email only: not attached to the record with an unverified phone');
select tests.eq((select count(*) from public.messages where template_key = 'lead_received' and to_address = '+12055550179'), 0::bigint,
                'and nothing is texted to that phone');
-- a verified phone on file (entered by staff) still matches by email
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Val', 'val@example.com', '+12055550176') returning tests.fx_set('cust_val', id);
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Val", "email": "val@example.com", "phone": "+12055550175"}'::jsonb);
select tests.as_superuser();
select tests.eq((select count(*) from public.lead_submissions where customer_id = tests.fx('cust_val')), 1::bigint,
                'a verified record matches by email (never modified)');
select tests.eq((select phone from public.customers where id = tests.fx('cust_val')), '+12055550176', '(its phone is kept)');
select tests.eq((select array_agg(m.channel::text || ':' || m.to_address order by m.channel) from public.messages m
                  where m.template_key = 'lead_received' and m.customer_id = tests.fx('cust_val')),
                array['sms:+12055550176', 'email:val@example.com'],
                'a matched customer with a phone the shop verified is texted there (never at the submitted phone)');
select tests.ok((select bool_and(body like 'Hi there, thanks for reaching out to Shop A!%') from public.messages
                  where template_key = 'lead_received' and channel = 'sms'), 'lead_received SMS wording');

-- abuse: the public token cannot turn the auto-reply into an SMS / email
-- relay (premium-range numbers, phishing text in the name field)
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok2'),
         jsonb_build_object('first_name', 'Your card was charged $499. Dispute: https://evil.example/x', 'phone', '+88212345001'));
select public.public_submit_lead(tests.fx('tok2'),
         jsonb_build_object('first_name', 'Account locked, verify at https://evil.example/login', 'email', 'victim1@example.org',
                            'last_name', 'https://evil.example/2'));
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where to_address = '+88212345001'), 0::bigint,
                'nothing is texted to a foreign / premium-range number typed into the form');
select tests.eq((select count(*) from public.messages where template_key = 'lead_received' and channel = 'sms'
                    and to_address not in ('+12055550176')), 0::bigint,
                'no auto-reply SMS ever went to a phone typed into a public form');
select tests.ok((select body not like '%evil.example%' and body like E'Hi there,\n\n%' from public.messages
                  where template_key = 'lead_received' and to_address = 'victim1@example.org'),
                'the emailed auto-reply carries none of the visitor''s text');
select tests.eq((select count(*) from public.messages where template_key = 'lead_received' and body like '%evil.example%'), 0::bigint,
                'no auto-reply relays a link typed into the form');
select tests.eq((select count(*) from public.customers where phone = '+88212345001' and lifecycle = 'lead'), 1::bigint,
                '(the lead itself is still captured for staff)');

-- per client IP: at most 10 submissions per form in 24 hours
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.40"}', true);
select tests.eq((select count(*) from generate_series(1, 10) g
                  where public.public_submit_lead(tests.fx('tok2'),
                          jsonb_build_object('first_name', 'Ip', 'email', 'ip-' || g || '@example.com')) ->> 'ok' = 'true'),
                10::bigint, '10 leads from one connection are accepted');
select tests.throws_like($$select public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Ip", "email": "ip-11@example.com"}'::jsonb)$$,
                         'PT429', '%this connection%', 'the 11th from the same IP in 24 hours is refused');
select tests.as_superuser();
select tests.eq((select count(*) from public.lead_submissions where lead_form_id = tests.fx('form2') and signer_ip = '198.51.100.40'),
                10::bigint, 'submissions record the client IP');
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.41"}', true);
select tests.eq(public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Ip", "email": "ip-12@example.com"}'::jsonb) ->> 'ok', 'true',
                'another connection is unaffected');
select tests.as_superuser();
update public.lead_submissions set created_at = created_at - interval '25 hours' where signer_ip = '198.51.100.40';
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.40"}', true);
select tests.eq(public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Ip", "email": "ip-13@example.com"}'::jsonb) ->> 'ok',
                'true', 'the window is a rolling 24 hours');
-- 0105: an IPv6 client is one connection per /64 (it picks its own interface
-- id: each submission from a fresh address used to have a full allowance)
do $$ begin
  for g in 1 .. 10 loop
    perform set_config('request.headers', jsonb_build_object('x-forwarded-for', '2001:db8:40:1::' || to_hex(g))::text, true);
    perform public.public_submit_lead(tests.fx('tok2'), jsonb_build_object('first_name', 'Six', 'email', 'ip6-' || g || '@example.com'));
  end loop;
end $$;
select set_config('request.headers', '{"x-forwarded-for": "2001:db8:40:1:dead:beef:1:2"}', true);
select tests.throws_like($$select public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Six", "email": "ip6-11@example.com"}'::jsonb)$$,
                         'PT429', '%this connection%', 'the 11th from the same /64 is refused, whatever its interface id');
select set_config('request.headers', '{"x-forwarded-for": "2001:db8:40:2::1"}', true);
select tests.eq(public.public_submit_lead(tests.fx('tok2'), '{"first_name": "Six", "email": "ip6-12@example.com"}'::jsonb) ->> 'ok',
                'true', 'another /64 is another connection');
select tests.as_superuser();
select tests.eq((select count(distinct signer_ip) from public.lead_submissions
                  where lead_form_id = tests.fx('form2') and signer_ip << '2001:db8:40:1::/64'::inet),
                10::bigint, 'ten leads from ten addresses of one /64 were accepted, each with its exact address');
select tests.as_anon();
select set_config('request.headers', '', true);

-- ============================================================ submissions RLS
select tests.as_anon();
select tests.throws($$select 1 from public.lead_submissions$$, '42501', 'anon cannot read submissions');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.lead_submissions$$), 0::bigint, 'technicians cannot either');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(tests.row_count($$select 1 from public.lead_submissions$$) > 0, 'managers can');
select tests.throws($$insert into public.lead_submissions (shop_id, customer_id, matched_existing) values (tests.fx('shop_a'), tests.fx('cust_a'), false)$$,
                    '42501', 'submissions are server-written');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.lead_submissions where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'another shop sees none');
select tests.as_superuser();
select tests.throws($$insert into public.lead_submissions (shop_id, customer_id, matched_existing) values (tests.fx('shop_a'), tests.fx('cust_b'), false)$$,
                    '23503', 'composite FK: another shop''s customer');

-- ============================================================ merge follow-up
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, custom_data)
  values (tests.fx('shop_a'), 'Dup', 'dup@example.com', '{"fleet_size": 7, "interest": "Paint correction", "extras": ["Tint"]}')
  returning tests.fx_set('dup', id);
insert into public.customers (shop_id, first_name, email, custom_data)
  values (tests.fx('shop_a'), 'Keep', 'keep@example.com', '{"fleet_size": 2}') returning tests.fx_set('keep', id);
insert into public.lead_submissions (shop_id, lead_form_id, customer_id, matched_existing)
  values (tests.fx('shop_a'), tests.fx('form2'), tests.fx('dup'), false);
insert into public.tasks (shop_id, title, customer_id) values (tests.fx('shop_a'), 'Call the duplicate', tests.fx('dup'));
update public.custom_fields set archived_at = now() where id = tests.fx('f_ext');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('dup'), tests.fx('keep'));
select tests.as_superuser();
select tests.eq((select count(*) from public.lead_submissions where customer_id = tests.fx('dup')), 0::bigint, 'submissions moved');
select tests.eq((select count(*) from public.tasks where customer_id = tests.fx('keep') and title = 'Call the duplicate'), 1::bigint,
                'tasks moved');
select tests.eq((select custom_data from public.customers where id = tests.fx('keep')),
                '{"fleet_size": 2, "interest": "Paint correction"}'::jsonb,
                'missing custom data filled from the duplicate (the survivor''s own values win; archived fields are not copied)');
