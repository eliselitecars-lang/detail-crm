-- 60 money: a self-scheduled quote's /q page (money_public_quote_json, 0067)
-- hands out the converted job's booking token, deposit and payment state
-- only while that job still belongs to the quote's customer. Staff may
-- unlink the quote and move the job to another customer; the job then gets
-- a new booking token (jobs_customer_change) that the previous customer's
-- quote link must never reveal.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- a day a month ahead (shop-local), so the server clock anon callers use
-- never makes it the past
select ((now() at time zone 'America/Chicago')::date + 30)::text as d \gset

select tests.as_superuser();
update public.booking_settings
   set quote_self_schedule = true, require_deposit = true, deposit_type = 'percent', deposit_value = 5000
 where shop_id = tests.fx('shop_a');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents, duration_minutes)
values (tests.fx('shop_a'), tests.fx('q'), tests.fx('svc_a'), 'Work', 10000, 60);
select public.mark_quote_sent(tests.fx('q'));
select tests.as_superuser();
select tests.fx_set('qtok', (select public_token from public.quotes where id = tests.fx('q')));

select tests.as_anon();
select public.public_respond_quote(tests.fx('qtok'), 'approve', 'Cust A', null, null, null);
select (public.public_schedule_quote(tests.fx('qtok'), :'d' || 'T09:00:00') ->> 'job_token') as old_tok \gset
select tests.as_superuser();
select tests.fx_set('job', (select converted_job_id from public.quotes where id = tests.fx('q')));

-- ============================================================ control: the customer's own job
select tests.as_anon();
select tests.eq(public.public_get_quote(tests.fx('qtok')) -> 'self_schedule' ->> 'job_token', :'old_tok',
                'the quote the customer scheduled links its booking page');
select tests.eq((public.public_get_quote(tests.fx('qtok')) -> 'self_schedule' ->> 'deposit_due_cents')::bigint, 5500::bigint,
                'with the deposit still due (50% of 11000)');

-- ============================================================ staff move the job to another customer
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job')$$, '23514',
                         '%unlink the quote%', 'a job linked to the quote keeps the quote''s customer');
update public.jobs set quote_id = null, vehicle_id = null where id = tests.fx('job');
update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job');
select tests.as_superuser();
select tests.fx_set('new_tok', (select public_token from public.jobs where id = tests.fx('job')));
select tests.ok(tests.fx('new_tok') <> :'old_tok'::uuid, 'the new customer got a fresh booking token');
select tests.eq((select converted_job_id from public.quotes where id = tests.fx('q')), tests.fx('job'),
                'the quote still records the job it was converted to');

select tests.as_anon();
select tests.ok((public.public_get_quote(tests.fx('qtok')) -> 'self_schedule' ->> 'job_token') is distinct from tests.fx('new_tok')::text,
                'the old quote link does not leak the new customer''s /booking token');
select tests.eq(public.public_get_quote(tests.fx('qtok')) -> 'self_schedule',
                jsonb_build_object('available', false, 'converted', true, 'job_token', null,
                                   'deposit_due_cents', null, 'payment_pending', null),
                'nor its deposit or payment state (the quote still reads as converted)');
select tests.ok(position(tests.fx('new_tok')::text in public.public_get_quote(tests.fx('qtok'))::text) = 0,
                'the new token appears nowhere in the quote document');
select tests.throws(format('select public.public_get_booking(%L::uuid)', :'old_tok'), 'PT404',
                    'the old booking token opens nothing');

-- ============================================================ moved back: the customer's job again
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a') where id = tests.fx('job');
select tests.as_superuser();
select tests.fx_set('back_tok', (select public_token from public.jobs where id = tests.fx('job')));
select tests.as_anon();
select tests.eq(public.public_get_quote(tests.fx('qtok')) -> 'self_schedule' ->> 'job_token', tests.fx('back_tok')::text,
                'once the job is the quote customer''s again, its (current) booking link is shown');

-- ============================================================ another shop's quote is untouched
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.quotes q where q.shop_id = tests.fx('shop_b') and q.converted_job_id = tests.fx('job')),
                'no quote of shop B points at shop A''s job');
