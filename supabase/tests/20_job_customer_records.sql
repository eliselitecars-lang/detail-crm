-- 20 field ops: a job keeps its customer while it carries records issued to
-- or signed by that customer (jobs_customer_records_guard, 0023): a signed
-- form, any inspection (signed or not), any invoice including void ones.
-- Regressions:
--   * a job moved from Alice to Aaron kept Alice's signed waiver and signed
--     pre-inspection of her Civic: the inspection's vehicle no longer belonged
--     to the job's customer, Aaron's /booking page led to the waiver with her
--     name, and her /f link showed Aaron's appointment and truck;
--   * a void invoice's /i link showed the new customer's vehicle and schedule;
--   * the new customer could never be asked to sign an all_jobs waiver the
--     previous customer had already signed (one submission per template per
--     job, signed ones cannot be deleted): the job looked compliant.
-- A job with only unsigned forms still moves; its forms follow under new
-- tokens.
\ir fixtures/two_shops.psql

select to_regprocedure('public.public_get_booking(uuid, timestamptz)') is not null as has_booking \gset
select to_regprocedure('public.public_get_invoice(uuid)') is not null as has_public_invoice \gset

select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('signatures', tests.fx('shop_a') || '/inspections/sig-1.png', tests.fx('u_tech_a')),
  ('signatures', tests.fx('shop_a') || '/device/form.png', tests.fx('u_tech_a'));
insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_a'), 'Waiver', 'I agree', true, 'manual') returning tests.fx_set('tpl', id);
insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_a'), 'Terms', 'I accept the terms.', false, 'all_jobs') returning tests.fx_set('tpl_w', id);

-- ============================================================ the repro: signed inspection + signed form
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.inspections (shop_id, job_id, vehicle_id, kind, customer_signature_path, signed_by_name)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre',
          tests.fx('shop_a') || '/inspections/sig-1.png', 'Alice Anders')
  returning tests.fx_set('insp', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.form_submissions (shop_id, job_id, form_template_id)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('tpl')) returning tests.fx_set('sub', id);
select public.sign_form_submission(tests.fx('sub'), 'Alice Anders', tests.fx('shop_a') || '/device/form.png');
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                    '23514', 'a job carrying the customer''s signed inspection / signed form keeps its customer');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                         '23514', '%form signed by its customer%', 'the signed form is named as the reason');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                    '23514', 'owners cannot move it either');
select tests.as_service();
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                    '23514', 'nor can trusted code (every context)');
select tests.as_superuser();
select tests.eq((select customer_id from public.jobs where id = tests.fx('job_a')), tests.fx('cust_a'), 'job_a is still Alice''s');
select tests.ok(exists (select 1 from public.inspections i
                         join public.jobs j on j.id = i.job_id and j.shop_id = i.shop_id
                         join public.vehicles v on v.id = i.vehicle_id and v.shop_id = i.shop_id
                        where i.id = tests.fx('insp') and v.customer_id = j.customer_id),
                'the signed inspection''s vehicle still belongs to the job''s customer');

-- ------------------------------------------------------------ an inspection alone (unsigned, no vehicle) is enough
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2030-06-03 15:00Z', '2030-06-03 17:00Z') returning tests.fx_set('job_i', id);
insert into public.inspections (shop_id, job_id, kind, notes) values (tests.fx('shop_a'), tests.fx('job_i'), 'pre', 'Door ding')
  returning tests.fx_set('insp_i', id);
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_i')$$,
                         '23514', '%vehicle inspection%', 'an unsigned inspection also keeps the job''s customer');
-- deleting the inspection (managers may delete unsigned ones) frees the job
select tests.eq(tests.row_count($$delete from public.inspections where id = tests.fx('insp_i')$$), 1::bigint, 'unsigned inspection removed');
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_i')$$), 1::bigint,
                'with no customer records left, the job moves');

-- ============================================================ finding #2: all_jobs waiver signed by the previous customer
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2030-06-02 15:00Z', '2030-06-02 17:00Z') returning tests.fx_set('job_w', id);
select tests.as_superuser();
select tests.fx_set('tok_w', (select public_token from public.form_submissions
                               where job_id = tests.fx('job_w') and form_template_id = tests.fx('tpl_w')));
select tests.as_anon();
select tests.lives($$select public.public_sign_form(tests.fx('tok_w'), 'Alice Anders')$$, 'Alice signs the waiver');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_w')$$,
                         '23514', '%form signed by its customer%',
                         'the job cannot pass to a customer who never signed its waiver');
select tests.eq((select count(*) from public.form_submissions where job_id = tests.fx('job_w') and customer_id = tests.fx('cust_a3')),
                0::bigint, 'no form of the job is attributed to the other customer');
select tests.as_anon();
select tests.eq(public.public_get_form(tests.fx('tok_w')) #>> '{form,signer_name}', 'Alice Anders',
                'Alice''s signed waiver link still shows her record');
select tests.eq(public.public_get_form(tests.fx('tok_w')) #>> '{job,scheduled_start}', '2030-06-02T15:00:00+00:00',
                '... and her own appointment');
\if :has_booking
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('btok_w', public.job_booking_token(tests.fx('job_w')));
select tests.as_anon();
select tests.eq((select jsonb_agg(jsonb_build_object('title', f ->> 'title', 'status', f ->> 'status'))
                   from jsonb_array_elements(public.public_get_booking(tests.fx('btok_w'), '2030-06-01 12:00Z') -> 'forms') f),
                '[{"title": "Terms", "status": "signed"}]'::jsonb,
                'the booking page of the (unmoved) job lists the waiver its own customer signed');
\endif

-- ------------------------------------------------------------ happy path: only unsigned forms -> the job moves, forms follow
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2030-06-04 15:00Z', '2030-06-04 17:00Z') returning tests.fx_set('job_u', id);
select tests.as_superuser();
select tests.fx_set('tok_u', (select public_token from public.form_submissions where job_id = tests.fx('job_u')));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_u')$$), 1::bigint,
                'a job with only unsigned forms moves');
select tests.as_superuser();
select tests.ok((select customer_id = tests.fx('cust_a3') and public_token <> tests.fx('tok_u')
                   from public.form_submissions where job_id = tests.fx('job_u')),
                'its unsigned waiver follows the new customer under a new token');
select tests.fx_set('tok_u2', (select public_token from public.form_submissions where job_id = tests.fx('job_u')));
select tests.as_anon();
select tests.throws($$select public.public_sign_form(tests.fx('tok_u'), 'Alice Anders')$$, 'P0002',
                    'the previous customer''s link can no longer sign it');
select tests.lives($$select public.public_sign_form(tests.fx('tok_u2'), 'Fleet Co')$$, 'the new customer is asked to sign');

-- ============================================================ void invoice
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Interior', 8000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select public.void_invoice(tests.fx('inv'), 'x');
select tests.as_superuser();
select tests.fx_set('inv_tok', (select public_token from public.invoices where id = tests.fx('inv')));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('job_a2')$$,
                         '23514', '%invoice (void)%', 'a job whose (void) invoice was issued to its customer keeps that customer');
select tests.as_superuser();
select tests.eq((select concat_ws('/', customer_id, vehicle_id) from public.jobs where id = tests.fx('job_a2')),
                concat_ws('/', tests.fx('cust_a2'), tests.fx('veh_a2')), 'job_a2 unchanged');
\if :has_public_invoice
select tests.as_anon();
select tests.eq(public.public_get_invoice(tests.fx('inv_tok')) #>> '{vehicle,model}', 'F-150',
                'the void invoice link still shows its own customer''s vehicle');
\endif

-- ============================================================ cross-shop isolation
-- shop B's records never block (or reach) shop A's jobs, and vice versa
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('job_a')$$), 0::bigint,
                'shop B cannot touch shop A''s job');
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('job_b')$$, '23503',
                    'shop B''s job cannot be given a shop A customer');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_a2'), 'pre')$$,
                    '42501', 'shop B staff cannot put an inspection on shop A''s job');
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_b'), 'Beth') returning tests.fx_set('cust_b2', id);
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_b2'), vehicle_id = null where id = tests.fx('job_b')$$),
                1::bigint, 'shop B''s job (no customer records) moves within shop B, unaffected by shop A''s records');

-- ============================================================ privileges
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.jobs_customer_records_guard()$$, '42501', 'the trigger function is not callable by users');
select tests.as_anon();
select tests.throws($$select public.jobs_customer_records_guard()$$, '42501', 'nor by anon');
