-- 10 money: a job's quote (jobs.quote_id) is always a quote of the job's
-- customer. The job's messages render {{quote_link}} from it, so a job of
-- Aaron linked to Alice's quote would text Aaron a working /q link to Alice's
-- quote (her name, vehicle, prices, approval). Enforced on the job side
-- (jobs_quote_validate: linking, inserting, moving the job) and on the quote
-- side (quotes_validate: moving a linked quote), in every context.
-- The {{quote_link}} checks run only when the comms migrations (0030-0039)
-- are applied (scripts/test_db.sh --ranges).
\ir fixtures/two_shops.psql

select to_regprocedure('public.template_vars_for_job(uuid)') is not null as has_comms \gset

\if :has_comms
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
\endif

-- Alice's quote, approved and converted to a job
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'))
  returning tests.fx_set('q', id), tests.fx_set('q_tok', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('q'), 'Ceramic coating', 150000);
select public.mark_quote_sent(tests.fx('q'));
update public.quotes set status = 'approved', approved_by_name = 'Alice Anders' where id = tests.fx('q');
select tests.fx_set('qjob', (public.convert_quote_to_job(tests.fx('q'))).id);
select tests.eq((select quote_id from public.jobs where id = tests.fx('qjob')), tests.fx('q'), 'the converted job links its quote');
select tests.eq((select customer_id from public.jobs where id = tests.fx('qjob')), tests.fx('cust_a'), 'for the quote''s customer');

-- ============================================================ repro (#4 path 1): a manager links Aaron's job to Alice's quote
select tests.throws_like($$update public.jobs set quote_id = tests.fx('q') where id = tests.fx('job_a2')$$, '23514',
                         '%belongs to another customer%', 'a job cannot link another customer''s quote');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, quote_id)
                           values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('q'))$$, '23514',
                         '%belongs to another customer%', 'nor be created with one');
select tests.eq((select quote_id from public.jobs where id = tests.fx('job_a2')), null::uuid, 'Aaron''s job has no quote');
\if :has_comms
select tests.ok(coalesce(public.template_vars_for_job(tests.fx('job_a2')) ->> 'quote_link', '') not like '%' || tests.fx('q_tok') || '%',
                'Aaron''s job renders no link to Alice''s quote');
\endif

-- ============================================================ repro (#1 / #4 path 2): the converted job moves to Aaron
update public.job_line_items set vehicle_id = null where job_id = tests.fx('qjob');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('qjob')$$,
                         '23514', '%unlink the quote%', 'a job created from a quote cannot silently move to another customer');
select tests.ok((select customer_id = tests.fx('cust_a') and quote_id = tests.fx('q') from public.jobs where id = tests.fx('qjob')),
                'the refused move changed nothing');
\if :has_comms
select tests.ok(public.template_vars_for_job(tests.fx('qjob')) ->> 'quote_link' like '%/q/' || tests.fx('q_tok') || '%',
                'Alice''s own job still links her quote');
\endif

-- unlinking in the same write moves it
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null, quote_id = null
                     where id = tests.fx('qjob')$$, 'moving and unlinking together is allowed');
select tests.ok((select customer_id = tests.fx('cust_a2') and quote_id is null from public.jobs where id = tests.fx('qjob')),
                'the job is Aaron''s and has no quote');
\if :has_comms
select tests.ok(coalesce(public.template_vars_for_job(tests.fx('qjob')) ->> 'quote_link', '') not like '%' || tests.fx('q_tok') || '%',
                'Aaron''s job no longer renders Alice''s quote link (repro #1)');
\endif
select tests.as_superuser();
select tests.eq(public.public_get_quote(tests.fx('q_tok')) #>> '{customer,first_name}', 'Alice', 'Alice''s quote page is unchanged');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set quote_id = tests.fx('q') where id = tests.fx('qjob')$$, '23514',
                         '%belongs to another customer%', 'and it cannot be linked back while it is Aaron''s');

-- ============================================================ a job of the quote's customer can link it
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2'))
  returning tests.fx_set('q_aaron', id);
select tests.lives($$update public.jobs set quote_id = tests.fx('q_aaron') where id = tests.fx('job_a2')$$,
                   'Aaron''s job links Aaron''s quote');
select tests.lives($$insert into public.jobs (shop_id, customer_id, status, quote_id)
                     values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('q_aaron'))$$,
                   'a new job of the quote''s customer can link it');
select tests.lives($$update public.jobs set internal_notes = 'linked' where id = tests.fx('job_a2')$$, 'other edits are unaffected');

-- ============================================================ the quote side: a linked quote cannot move to another customer
select tests.throws_like($$update public.quotes set customer_id = tests.fx('cust_a3') where id = tests.fx('q_aaron')$$, '23514',
                         '%linked to job #%', 'a quote linked to jobs keeps its customer');
update public.jobs set quote_id = null where quote_id = tests.fx('q_aaron');
select tests.lives($$update public.quotes set customer_id = tests.fx('cust_a3') where id = tests.fx('q_aaron')$$,
                   'once unlinked, the draft quote can move');

-- ============================================================ every context (trusted code too)
select tests.as_superuser();
select tests.throws_like($$update public.jobs set quote_id = tests.fx('q') where id = tests.fx('job_a2')$$, '23514',
                         '%another customer%', 'trusted writes are held to the same rule');
select tests.as_service();
select tests.throws_like($$update public.jobs set quote_id = tests.fx('q') where id = tests.fx('job_a2')$$, '23514',
                         '%another customer%', 'service_role too');

-- ============================================================ roles and isolation
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$update public.jobs set quote_id = tests.fx('q_aaron') where id = tests.fx('job_a2')$$, '42501',
                    'technicians cannot link quotes');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set quote_id = null where id = tests.fx('qjob')$$), 0::bigint,
                'shop B cannot touch A''s jobs');
select tests.throws($$update public.jobs set quote_id = tests.fx('q') where id = tests.fx('job_b')$$, '23503',
                    'another shop''s quote cannot be linked (composite FK)');
select tests.as_superuser();
select tests.eq((select quote_id from public.jobs where id = tests.fx('job_b')), null::uuid, 'shop B''s job is unchanged');

-- the trigger function is not callable
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.jobs_quote_validate()$$, '42501', 'staff cannot execute the trigger function');
