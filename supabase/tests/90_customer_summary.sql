-- 90 integration: customer_summary — one row of money and visit totals for
-- a customer (payments net of refunds, tips, refunds, open / overdue
-- balances, completed / upcoming jobs, first / last visit, open quotes,
-- active memberships), manager+ only, isolated per shop.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ data for Alice (cust_a)
select tests.as_superuser();
update public.shops set invoice_due_days = 0 where id = tests.fx('shop_a');
-- jobs: two completed visits, two upcoming, one past-due scheduled, one cancelled future
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-01-10 15:00Z', '2025-01-10 17:00Z', '2025-01-10 17:05Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-03-05 15:00Z', '2025-03-05 17:00Z', '2025-03-05 16:55Z');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', now() + interval '3 days', now() + interval '3 days 2 hours'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'cancelled', now() + interval '1 day', now() + interval '1 day 2 hours');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', now() + interval '10 days', now() + interval '10 days 1 hour');
-- job_a (fixture) is scheduled in 2025: in the past, so not upcoming

-- money
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_job', (public.create_invoice_from_job(tests.fx('job_a'))).id);      -- 20000
select public.mark_invoice_sent(tests.fx('inv_job'));
select public.record_manual_payment(tests.fx('inv_job'), 5000, 'cash');                      -- balance 15000, due today
select tests.fx_set('inv_late', (public.create_invoice(tests.fx('cust_a'),
                                   '[{"name":"Ceramic","unit_price_cents":30000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv_late'));
select tests.as_superuser();
update public.invoices set issued_at = now() - interval '10 days', due_at = now() - interval '5 days' where id = tests.fx('inv_late');
select tests.as_service();
-- card 10000 + 1500 tip on the late invoice, then 11000 refunded (all of the amount, 1000 of the tip)
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs1', 'succeeded', 10000, 1500, 'payment', 'card', tests.fx('inv_late'));
select public.apply_stripe_refund('pi_cs1', 11000);
-- a declined attempt counts for nothing
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs2', 'failed', 7000, 0, 'payment', 'card', p_customer_id => tests.fx('cust_a'));
-- a draft invoice owes nothing yet
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.create_invoice(tests.fx('cust_a'), '[{"name":"Wax","unit_price_cents":9900}]');
-- quotes: sent + approved are open; draft and declined are not
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_sent', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_appr', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_decl', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'));
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents)
  select tests.fx('shop_a'), q, 'Tint', 30000 from unnest(array[tests.fx('q_sent'), tests.fx('q_appr'), tests.fx('q_decl')]) q;
select public.mark_quote_sent(q) from unnest(array[tests.fx('q_sent'), tests.fx('q_appr'), tests.fx('q_decl')]) q;
select public.staff_record_quote_response(tests.fx('q_appr'), 'approve');
select public.staff_record_quote_response(tests.fx('q_decl'), 'decline');
-- memberships: active + past_due count, cancelled does not
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Club', 4900) returning tests.fx_set('plan', id);
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make, model) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Mazda', 'CX-5')
  returning tests.fx_set('veh_a_2', id);
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, started_at) values
  (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), null, 'active', now()),
  (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), tests.fx('veh_a_2'), 'past_due', now());
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, started_at, cancelled_at)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), tests.fx('veh_a'), 'cancelled', now() - interval '60 days', now());
-- another customer's money never mixes in
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_other', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":8000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_other'));
select public.record_manual_payment(tests.fx('inv_other'), 8000, 'check', 700);

-- ------------------------------------------------------------ the numbers
select tests.eq((select to_jsonb(s) from public.customer_summary(tests.fx('cust_a')) s),
                jsonb_build_object(
                  'customer_id', tests.fx('cust_a'),
                  'lifetime_paid_cents', 5000,        -- cash 5000 + card 10000 − 10000 refunded
                  'tips_cents', 500,                  -- 1500 tip − 1000 refunded
                  'refunded_cents', 11000,
                  'open_balance_cents', 45000,        -- 15000 (due today) + 30000 (overdue)
                  'overdue_balance_cents', 30000,
                  'completed_jobs', 2,
                  'upcoming_jobs', 2,
                  'first_visit_at', '2025-01-10T17:05:00+00:00',
                  'last_visit_at', '2025-03-05T16:55:00+00:00',
                  'next_job_at', to_jsonb(now() + interval '3 days'),
                  'open_quotes', 2,
                  'active_memberships', 2),
                'money net of refunds, tips, balances, visits, quotes and memberships');
select tests.eq((select count(*) from public.customer_summary(tests.fx('cust_a'))), 1::bigint, 'exactly one row');
select tests.eq((select to_jsonb(s) - 'customer_id' from public.customer_summary(tests.fx('cust_a2')) s),
                '{"lifetime_paid_cents": 0, "tips_cents": 0, "refunded_cents": 0, "open_balance_cents": 0, "overdue_balance_cents": 0,
                  "completed_jobs": 0, "upcoming_jobs": 0, "first_visit_at": null, "last_visit_at": null, "next_job_at": null,
                  "open_quotes": 0, "active_memberships": 0}'::jsonb,
                'a customer with nothing yet: zeros and nulls, still one row');
select tests.eq((select jsonb_build_array(lifetime_paid_cents, tips_cents, open_balance_cents)
                   from public.customer_summary(tests.fx('cust_a3'))), '[8000, 700, 0]'::jsonb, 'the other customer''s totals');

-- ------------------------------------------------------------ roles and isolation
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select lifetime_paid_cents from public.customer_summary(tests.fx('cust_a'))), 5000::bigint, 'owners');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select open_quotes from public.customer_summary(tests.fx('cust_a'))), 2, 'admins');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.customer_summary(tests.fx('cust_a'))$$, '42501',
                    'technicians cannot see customer money (even of an assigned job''s customer)');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.customer_summary(tests.fx('cust_a'))$$, 'P0002', 'another shop''s customer is not found');
select tests.eq((select lifetime_paid_cents from public.customer_summary(tests.fx('cust_b'))), 0::bigint, 'B reads its own customer');
select tests.throws($$select * from public.customer_summary(gen_random_uuid())$$, 'P0002', 'unknown customer');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.customer_summary(tests.fx('cust_a'))$$, 'P0002', 'non-members find nothing');
select tests.as_anon();
select tests.throws($$select * from public.customer_summary(tests.fx('cust_a'))$$, '42501', 'anon cannot execute');
