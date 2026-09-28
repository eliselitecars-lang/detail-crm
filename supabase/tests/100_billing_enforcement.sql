-- 100 billing: PT402 on new business records of a lapsed shop — every
-- guarded insert (customers, jobs, quotes, invoices, campaigns, job_series,
-- staff-written outbound messages) directly and through the staff RPCs,
-- for signed-in members only: service_role is never blocked by the guard,
-- other shops / trialing / past due / comped / paid-through shops are
-- unaffected, billing off changes nothing. What a lapsed shop keeps doing:
-- reads, edits, finishing existing jobs (status texts still queue),
-- collecting money on an existing invoice.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 3000);

-- while billing is off: an invoice to collect on later, a draft campaign
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_a', (public.create_invoice_from_job(tests.fx('job_a'))).id);
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Spring', 'sms', 'Spring sale this week')
  returning tests.fx_set('camp_a', id);

-- billing on: A lapsed (never subscribed, no trial), B active
select tests.as_service();
select public.set_billing_config(true, 0);
update public.shop_billing set status = 'active', current_period_end = now() + interval '20 days'
 where shop_id = tests.fx('shop_b');

create function pg_temp.pt402(p_sql text, p_msg text) returns void language sql as $$
  select tests.throws_like(p_sql, 'PT402', 'This shop''s subscription is inactive, so new records can''t be created right now.', p_msg)
$$;
grant execute on function pg_temp.pt402(text, text) to authenticated, service_role;

-- ============================================================ direct inserts (manager of the lapsed shop)
select tests.authenticate_as(tests.fx('u_manager_a'));
select pg_temp.pt402($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'New')$$, 'customers: PT402');
select pg_temp.pt402($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')$$, 'jobs: PT402');
select pg_temp.pt402($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, 'quotes: PT402');
select pg_temp.pt402($$insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Fall', 'sms', 'Hi')$$,
                     'campaigns: PT402');
select tests.authenticate_as(tests.fx('u_owner_a'));
select pg_temp.pt402($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'New')$$, 'the owner too');

-- ============================================================ through the staff RPCs
select tests.authenticate_as(tests.fx('u_manager_a'));
select pg_temp.pt402($$select public.create_invoice_from_job(tests.fx('job_a2'))$$, 'invoices: PT402 (create_invoice_from_job)');
select pg_temp.pt402($$select public.create_job_series(tests.fx('shop_a'), jsonb_build_object(
                         'customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week', 'local_start', '09:00',
                         'start_date', '2025-06-02', 'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a')))))$$,
                     'job series: PT402 (create_job_series)');
select pg_temp.pt402($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Hello', 'A note')$$,
                     'outbound staff message: PT402 (queue_message)');
select pg_temp.pt402($$select public.launch_campaign(tests.fx('camp_a'))$$, 'launching an existing draft campaign: PT402');
select tests.authenticate_as(tests.fx('u_tech_a'));
select pg_temp.pt402($$select public.enqueue_template_message(tests.fx('job_a'), 'on_the_way')$$,
                     'a technician''s hand-sent template: PT402');
select tests.as_superuser();
select tests.ok((select status = 'draft' from public.campaigns where id = tests.fx('camp_a')), 'the campaign is still a draft');
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a')), 0::bigint, 'nothing was queued');
select tests.eq((select count(*) from public.invoices where shop_id = tests.fx('shop_a')), 1::bigint, 'no second invoice');

-- ============================================================ a lapsed shop keeps working on what exists
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.customers where shop_id = tests.fx('shop_a')$$), 3::bigint, 'reads work');
select tests.eq(tests.row_count($$update public.customers set notes = 'VIP' where id = tests.fx('cust_a')$$), 1::bigint, 'edits work');
select tests.lives($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
                     values (tests.fx('shop_a'), tests.fx('job_a2'), 'Extra', 1000)$$, 'lines on an existing job');
select tests.eq((select concat_ws('/', status, amount_cents)
                   from public.record_manual_payment(tests.fx('inv_a'), 5000, 'cash')), 'succeeded/5000',
                'collecting money on an existing invoice works');
select tests.eq((select balance_cents from public.invoices where id = tests.fx('inv_a')),
                (select total_cents - 5000 from public.invoices where id = tests.fx('inv_a')), 'and lowers its balance');
-- finishing an existing job: its status texts (system messages) still queue
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.jobs set status = 'en_route' where id = tests.fx('job_a')$$), 1::bigint,
                'the assigned technician heads out');
select tests.eq(tests.row_count($$update public.jobs set status = 'in_progress' where id = tests.fx('job_a')$$), 1::bigint, 'starts');
select tests.eq(tests.row_count($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$), 1::bigint, 'and completes it');
select tests.as_superuser();
select tests.eq((select array_agg(distinct template_key::text) from public.messages
                  where job_id = tests.fx('job_a') and direction = 'outbound' and status = 'queued'),
                array['job_completed', 'on_the_way', 'payment_receipt'],
                'the payment receipt, on-the-way and completion messages still go out');
select tests.ok((select bool_and(sent_by is null) from public.messages where shop_id = tests.fx('shop_a')),
                'all of them system messages');

-- ============================================================ service_role is never blocked by the guard
select tests.as_service();
select tests.lives($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'From the webhook')$$,
                   'service_role: customers');
select tests.lives($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')$$, 'jobs');
select tests.lives($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, 'quotes');
select tests.lives($$insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Svc', 'sms', 'Hi')$$,
                   'campaigns');
select tests.lives($$insert into public.invoices (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2'))$$, 'invoices');
select tests.lives($$insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status, sent_by)
                     values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', 'Svc note', 'queued',
                             tests.fx('u_manager_a'))$$, 'outbound messages');
select tests.lives($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'review_request', 'sms')$$,
                   'a system template (no sender) is not refused');
select pg_temp.pt402($$select public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'review_request', 'sms',
                                                              null, null, null, tests.fx('u_manager_a'))$$,
                     'but a template the service role queues for a person (p_sent_by) is');

-- ============================================================ other standings can write
-- another shop (B, active)
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.lives($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_b'), 'New')$$, 'an active shop is unaffected');
-- a member of B cannot plant rows in A: RLS answers first (42501, not PT402)
select tests.throws($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Planted')$$, '42501',
                    'a member of another shop gets 42501');
select tests.as_service();
create temp table standings (label text, status text, trial timestamptz, period timestamptz, comp timestamptz);
insert into standings values
  ('in-app trial',              'none',     now() + interval '1 day', null, null),
  ('past due',                  'past_due', null, now() - interval '1 day', null),
  ('comped',                    'none',     null, null, 'infinity'),
  ('canceled, period remaining','canceled', null, now() + interval '1 day', null),
  ('Stripe trial',              'trialing', now() + interval '3 days', now() + interval '3 days', null);
do $$
declare
  r record;
begin
  for r in select * from standings loop
    perform tests.as_service();
    update public.shop_billing set status = r.status, trial_ends_at = r.trial, current_period_end = r.period, comp_until = r.comp
     where shop_id = tests.fx('shop_a');
    perform tests.authenticate_as(tests.fx('u_manager_a'));
    perform tests.lives(format('insert into public.customers (shop_id, first_name) values (%L, %L)', tests.fx('shop_a'), r.label),
                        r.label || ': can create customers');
  end loop;
end
$$;
select tests.as_service();
update public.shop_billing set status = 'none', trial_ends_at = null, current_period_end = null, comp_until = null
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select pg_temp.pt402($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Again')$$, 'lapsed again: PT402');

-- ============================================================ billing off changes nothing
select tests.as_service();
select public.set_billing_config(false, 0);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Off')$$, 'billing off: customers');
select tests.lives($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')$$, 'jobs');
select tests.lives($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, 'quotes');
select tests.lives($$select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Hello', 'A note')$$, 'messages');
select tests.lives($$select public.launch_campaign(tests.fx('camp_a'))$$, 'campaign launch');
