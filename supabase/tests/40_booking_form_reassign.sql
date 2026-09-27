-- 40 integration: the booking page lists only the CURRENT customer's forms.
--   Regression: booking_public_json listed every form of the job, so after a
--   job moved to another customer, the new customer's fresh /booking link led
--   to the previous customer's signed waiver and their typed full name. A job
--   carrying a signed form now keeps its customer (jobs_customer_records_guard,
--   0023), so that state can no longer arise; the booking page's filter stays
--   as defense in depth. This file checks the refusal from the booking side:
--   the page and form links stay the signer's, and other shops' forms never
--   appear.
\ir fixtures/two_shops.psql

insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_a'), 'Waiver', 'I agree.', false, 'manual') returning tests.fx_set('tpl_waiver', id);
insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_a'), 'Pickup', 'Keys left with me.', false, 'manual') returning tests.fx_set('tpl_pickup', id);
insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_b'), 'Waiver B', 'Shop B terms.', false, 'manual') returning tests.fx_set('tpl_b', id);

-- Alice's job gets a waiver (which she signs) and a pickup form (unsigned)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.form_submissions (shop_id, form_template_id, job_id)
  values (tests.fx('shop_a'), tests.fx('tpl_waiver'), tests.fx('job_a')) returning tests.fx_set('fs_waiver', id);
insert into public.form_submissions (shop_id, form_template_id, job_id)
  values (tests.fx('shop_a'), tests.fx('tpl_pickup'), tests.fx('job_a')) returning tests.fx_set('fs_pickup', id);
select tests.as_superuser();
select tests.fx_set('waiver_tok', (select public_token from public.form_submissions where id = tests.fx('fs_waiver')));
select tests.fx_set('pickup_tok_alice', (select public_token from public.form_submissions where id = tests.fx('fs_pickup')));
select tests.as_anon();
select tests.lives($$select public.public_sign_form(tests.fx('waiver_tok'), 'Alice Anders', null)$$, 'Alice signs the waiver');

-- shop B's job has a signed form of its own (never listed on shop A pages)
select tests.authenticate_as(tests.fx('u_owner_b'));
insert into public.form_submissions (shop_id, form_template_id, job_id)
  values (tests.fx('shop_b'), tests.fx('tpl_b'), tests.fx('job_b')) returning tests.fx_set('fs_b', id);
select tests.as_superuser();
select tests.fx_set('fs_b_tok', (select public_token from public.form_submissions where id = tests.fx('fs_b')));
select tests.as_anon();
select public.public_sign_form(tests.fx('fs_b_tok'), 'Bob Shop-B', null);

-- happy path before any move: Alice's own page lists both forms
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('btok_alice', public.job_booking_token(tests.fx('job_a')));
select tests.as_anon();
create temp table before_move as select public.public_get_booking(tests.fx('btok_alice')) as doc;
grant select on before_move to anon, authenticated;
select tests.eq((select jsonb_agg(f ->> 'title' order by f ->> 'title')
                   from before_move, jsonb_array_elements(doc -> 'forms') f),
                '["Pickup", "Waiver"]'::jsonb, 'Alice''s booking page lists her waiver and pickup form');
select tests.eq((select f ->> 'status' from before_move, jsonb_array_elements(doc -> 'forms') f where f ->> 'title' = 'Waiver'),
                'signed', 'her waiver shows as signed');

-- staff try to move the job to Aaron (no invoice or payments yet): refused,
-- because the job carries the waiver Alice signed (jobs_customer_records_guard,
-- 0023; see 20_job_customer_records.sql)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set vehicle_id = null, customer_id = tests.fx('cust_a2') where id = tests.fx('job_a')$$,
                         '23514', '%form signed by its customer%', 'a job with a signed form keeps its customer');
select tests.eq(public.job_booking_token(tests.fx('job_a')), tests.fx('btok_alice'),
                'the job (and its booking link) stays Alice''s');

select tests.as_anon();
create temp table after_move as select public.public_get_booking(tests.fx('btok_alice')) as doc;
grant select on after_move to anon, authenticated;
select tests.eq((select jsonb_agg(jsonb_build_object('title', f ->> 'title', 'status', f ->> 'status') order by f ->> 'title')
                   from after_move, jsonb_array_elements(doc -> 'forms') f),
                '[{"title": "Pickup", "status": "pending"}, {"title": "Waiver", "status": "signed"}]'::jsonb,
                'Alice''s page still lists her signed waiver and her pickup form');
select tests.ok((select bool_and((f ->> 'token')::uuid in (tests.fx('waiver_tok'), tests.fx('pickup_tok_alice')))
                   from after_move, jsonb_array_elements(doc -> 'forms') f),
                'with the tokens Alice already holds');
select tests.ok(not exists (select 1 from after_move, jsonb_array_elements(doc -> 'forms') f
                             where (f ->> 'token')::uuid = tests.fx('fs_b_tok') or f ->> 'title' = 'Waiver B'),
                'another shop''s forms are never listed');
select tests.eq(public.public_get_form(tests.fx('waiver_tok')) #>> '{form,signer_name}', 'Alice Anders',
                'the signed waiver itself is intact and reachable by the token Alice holds');
select tests.eq(public.public_get_form(tests.fx('waiver_tok')) #>> '{job,vehicle}', '2021 Honda Civic',
                '... and still shows her own vehicle');
select tests.as_superuser();
select tests.eq((select customer_id from public.form_submissions where id = tests.fx('fs_waiver')), tests.fx('cust_a'),
                'the signed waiver still belongs to Alice');

-- shop B's booking page lists its own signed form (cross-shop isolation both ways)
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.fx_set('btok_b', public.job_booking_token(tests.fx('job_b')));
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, 'P0002',
                    'shop B cannot mint shop A''s booking token');
select tests.as_anon();
select tests.eq((select jsonb_agg(f ->> 'title')
                   from jsonb_array_elements(public.public_get_booking(tests.fx('btok_b')) -> 'forms') f),
                '["Waiver B"]'::jsonb, 'shop B''s page lists only its own form');
