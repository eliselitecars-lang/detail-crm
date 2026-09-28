-- 60 money: a job on a VOID grouped invoice keeps its customer, exactly like
-- a job whose single-job invoice was voided (jobs_money_guard, 0063; the
-- single case is jobs_customer_records_guard, 0023/0074). The void invoice
-- keeps its invoice_jobs rows and its /i page lists the jobs, so a job moved
-- to another customer would show that customer's vehicle on the previous
-- customer's invoice. Live grouped invoices, merges, re-invoicing after the
-- void, roles and shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, year, make, model)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 2020, 'Ford', 'Transit') returning tests.fx_set('vf1', id);
update public.vehicles set year = 2011, make = 'Secret', model = 'Car' where id = tests.fx('veh_a');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('vf1'), '2025-07-01 15:00Z', '2025-07-01 17:00Z')
  returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j1'), 'A', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-02 15:00Z', '2025-07-02 17:00Z') returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j2'), 'B', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-03 15:00Z', '2025-07-03 17:00Z') returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'C', 10000);
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])).id);
select tests.fx_set('sinv', (public.create_invoice_from_job(tests.fx('j3'))).id);
select public.invoice_link_token(tests.fx('ginv')) as gtok \gset

-- ============================================================ live grouped invoice (unchanged rule)
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('j1')$$,
                         '23514', '%invoice or payments%', 'a job on a live grouped invoice keeps its customer');

-- ============================================================ void grouped invoice
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('ginv'), 'x');
select public.void_invoice(tests.fx('sinv'), 'x');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('j3')$$,
                         '23514', '%void%', 'control: a job with a void single-job invoice keeps its customer');
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('j1')$$,
                    '23514', 'a job on a void grouped invoice keeps its customer like a single void invoice');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = null where id = tests.fx('j2')$$,
                         '23514', '%on invoice #% (void) issued to its customer%', 'naming the void invoice');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = null where id = tests.fx('j2')$$,
                    '23514', 'owner: refused as well');
select tests.as_service();
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = null where id = tests.fx('j2')$$,
                    '23514', 'service_role: refused as well');

select tests.as_anon();
select tests.eq((select jsonb_agg(e ->> 'vehicle_label' order by o)
                   from jsonb_array_elements(public.public_get_invoice(:'gtok') -> 'jobs') with ordinality as t(e, o)),
                '["2020 Ford Transit", null]'::jsonb,
                'the void invoice''s page still shows only its customer''s vehicles');
select tests.ok(position('Secret' in public.public_get_invoice(:'gtok')::text) = 0,
                'another customer''s vehicle never appears on it');

-- ============================================================ what stays possible
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set vehicle_id = null where id = tests.fx('j1')$$,
                   'other edits of the job are unaffected');
select tests.fx_set('ginv2', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])).id);
select tests.ok(tests.fx('ginv2') is not null, 'the released jobs can be invoiced again for their customer');
-- a customer merge (trusted context) moves the job and its invoices together
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('ginv2'), 'y');
select tests.as_superuser();
select set_config('detailcrm.customer_merge', 'on', true);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('j2')$$,
                   'during a customer merge the job moves (merge_customers moves the invoices next)');
select set_config('detailcrm.customer_merge', '', true);
-- a job never on a grouped invoice still moves freely
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested') returning tests.fx_set('j4', id);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('j4')$$,
                   'a job without invoices or money changes customer as before');

-- ============================================================ shop isolation
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_b') where id = tests.fx('j1')$$), 0::bigint,
                'shop B cannot touch shop A''s jobs');
select tests.lives($$update public.jobs set notes = 'ok' where id = tests.fx('job_b')$$, 'nor is shop B affected');
