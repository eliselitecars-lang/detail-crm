-- 80 comms: a customer field's saved values include the answers kept on lead
-- submissions (0088 custom_fields_guard). A lead form matched to an existing
-- customer stores its answers ONLY in lead_submissions.answers
-- (public_submit_lead never changes that customer), keyed by the field key;
-- so while any submission holds an answer for a key, the field cannot be
-- deleted (archive it instead) nor change key / entity / type — otherwise
-- the key could be reused and the old answers read against another
-- definition. Labels, help text, flags and archiving stay free; job fields
-- and other shops are not affected; once the answers are gone the field can
-- be deleted.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.customers set email = 'alice@example.com' where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.custom_fields (shop_id, entity, key, label, type, options, show_in_lead_form)
  values (tests.fx('shop_a'), 'customer', 'interest', 'Interested in', 'select', '{Ceramic coating,Detail}', true)
  returning tests.fx_set('f_int', id);
-- a job field with the same key (another entity) and shop B's own 'interest'
insert into public.custom_fields (shop_id, entity, key, label, type)
  values (tests.fx('shop_a'), 'job', 'interest', 'Interest (job)', 'text') returning tests.fx_set('f_job', id);
insert into public.lead_forms (shop_id, name, field_ids) values (tests.fx('shop_a'), 'Inquiry', array[tests.fx('f_int')])
  returning tests.fx_set('form', id);
select tests.authenticate_as(tests.fx('u_admin_b'));
insert into public.custom_fields (shop_id, entity, key, label, type)
  values (tests.fx('shop_b'), 'customer', 'interest', 'Interest', 'text') returning tests.fx_set('f_b', id);
select tests.as_superuser();
select tests.fx_set('tok', (select token from public.lead_forms where id = tests.fx('form')));

-- the existing customer Alice answers the lead form
select tests.as_anon();
select public.public_submit_lead(tests.fx('tok'), jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com',
         'answers', jsonb_build_object('interest', 'Ceramic coating')));
select tests.as_superuser();
select tests.eq((select answers from public.lead_submissions where customer_id = tests.fx('cust_a')),
                '{"interest": "Ceramic coating"}'::jsonb, 'the answer is saved on the matched customer''s submission only');
select tests.eq((select custom_data ? 'interest' from public.customers where id = tests.fx('cust_a')), false,
                '(not on the customer)');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and custom_data ? 'interest'), 0::bigint,
                '(no customer holds a value for the key)');

-- ============================================================ identity guards
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$delete from public.custom_fields where id = tests.fx('f_int')$$, '23514', '%saved values%',
                         'a field whose only saved values are lead answers cannot be deleted (archive it instead)');
select tests.throws_like($$update public.custom_fields set key = 'topic' where id = tests.fx('f_int')$$, '23514', '%archive it instead%',
                         'nor re-keyed');
select tests.throws($$update public.custom_fields set type = 'number', options = '{}' where id = tests.fx('f_int')$$, '23514',
                    'nor re-typed (the answer would read as a number)');
select tests.throws($$update public.custom_fields set entity = 'job', show_in_lead_form = false where id = tests.fx('f_int')$$, '23514',
                    'nor moved to jobs');
select tests.lives($$update public.custom_fields set label = 'Interest', help_text = 'Pick one' where id = tests.fx('f_int')$$,
                   'labels and help text may change');
select tests.lives($$update public.custom_fields set archived_at = now() where id = tests.fx('f_int')$$, 'archiving is the way out');
select tests.eq((select array[key, type::text, label] from public.custom_fields where id = tests.fx('f_int')),
                array['interest', 'select', 'Interest'], 'the answers keep their definition');
select tests.throws($$insert into public.custom_fields (shop_id, entity, key, label, type)
                      values (tests.fx('shop_a'), 'customer', 'interest', 'Fleet size', 'number')$$, '23505',
                    'so the key cannot be reused by another field');

-- ============================================================ scope
select tests.eq(tests.row_count($$delete from public.custom_fields where id = tests.fx('f_job')$$), 1::bigint,
                'a JOB field with the same key is not held by lead answers (they are customer values)');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$delete from public.custom_fields where id = tests.fx('f_int')$$), 0::bigint,
                'shop B cannot touch shop A''s field');
select tests.eq(tests.row_count($$delete from public.custom_fields where id = tests.fx('f_b')$$), 1::bigint,
                'shop B''s own field of that key is not held by shop A''s answers');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.custom_fields where id = tests.fx('f_int')$$), 0::bigint,
                'managers do not delete fields (admins only)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.custom_fields set key = 'x' where id = tests.fx('f_int')$$), 0::bigint,
                'nor do technicians change them');

-- ============================================================ once the answers are gone
select tests.as_superuser();
delete from public.lead_submissions where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.custom_fields set type = 'text', options = '{}' where id = tests.fx('f_int')$$,
                   'without saved values the type may change');
select tests.eq(tests.row_count($$delete from public.custom_fields where id = tests.fx('f_int')$$), 1::bigint,
                'and the field may be deleted');
select tests.eq((select field_ids from public.lead_forms where id = tests.fx('form')), '{}'::uuid[],
                '(it left the lead form that asked it)');

-- the same holds in shop B, for an answer of its own
select tests.as_superuser();
insert into public.custom_fields (shop_id, entity, key, label, type)
  values (tests.fx('shop_b'), 'customer', 'budget', 'Budget', 'text') returning tests.fx_set('f_b2', id);
insert into public.lead_submissions (shop_id, customer_id, answers, matched_existing)
  values (tests.fx('shop_b'), tests.fx('cust_b'), '{"budget": "500"}', true);
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$delete from public.custom_fields where id = tests.fx('f_b2')$$, '23514', 'shop B''s answered field is held too');
