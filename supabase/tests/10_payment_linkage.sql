-- 10 money: where money lands and what counts as "in flight".
--   * a payment recorded for (or completing on) a void invoice is re-routed:
--     job payments to the job's current invoice / the job, ad-hoc ones to the
--     customer as a flagged unapplied payment — never left on the void doc
--   * manual payments cannot cover what a card payment in flight already covers
--   * pending intents older than an hour (abandoned PaymentSheets) stop
--     freezing the invoice
\ir fixtures/two_shops.psql

create function pg_temp.bal(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;
create function pg_temp.link(p_pi text) returns text language sql as $$
  select concat_ws('/', status, coalesce(invoice_id::text, '-'), coalesce(job_id::text, '-'), customer_id)
    from public.payments where stripe_payment_intent_id = p_pi
$$;

-- ============================================================ payment_in_flight
select tests.ok(public.payment_in_flight('pending', '2025-06-01 11:01Z', '2025-06-01 12:00Z'), 'pending, 59 minutes old: in flight');
select tests.ok(not public.payment_in_flight('pending', '2025-06-01 11:00Z', '2025-06-01 12:00Z'), 'pending, an hour old: abandoned');
select tests.ok(not public.payment_in_flight('succeeded', '2025-06-01 12:00Z', '2025-06-01 12:00Z'), 'received money is not in flight');
select tests.ok(not public.payment_in_flight('failed', '2025-06-01 12:00Z', '2025-06-01 12:00Z'), 'failed is not in flight');
select tests.as_anon();
select tests.throws($$select public.payment_in_flight('pending', now())$$, '42501', 'anon cannot call money helpers');

-- ============================================================ late card money for a void job invoice (the repro)
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv1', (select id from public.create_invoice_from_job(tests.fx('job_a'))));
select public.void_invoice(tests.fx('inv1'), 'redo');
select tests.fx_set('inv2', (select id from public.create_invoice_from_job(tests.fx('job_a'))));
select tests.as_service();
-- a Checkout Session opened on inv1 before the void completes now
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late1', 'succeeded', 20000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('inv1'), p_job_id => tests.fx('job_a'), p_customer_id => tests.fx('cust_a'),
         p_paid_at => '2025-06-01 12:00Z');
select tests.as_superuser();
select tests.eq((select concat_ws('/', status, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('inv2')),
                'paid/20000/0', 'money received for the job counts on its current invoice');
select tests.eq(pg_temp.bal(tests.fx('inv1')), 'void/20000/0/20000', 'the void invoice holds no money');
select tests.eq(pg_temp.link('pi_late1'), concat_ws('/', 'succeeded', tests.fx('inv2'), tests.fx('job_a'), tests.fx('cust_a')),
                'payment linked to the current invoice, its job and customer');
select tests.eq((select note from public.payments where stripe_payment_intent_id = 'pi_late1'), null::text, 'no flag needed');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select concat_ws('/', invoice_id = tests.fx('inv2'), paid_cents, balance_cents) from public.job_payment_summary(tests.fx('job_a'))),
                't/20000/0', 'job summary is consistent: paid and balance agree');
select tests.throws_like($$select public.create_invoice_from_job(tests.fx('job_a'))$$, '23505', '%already has invoice%',
                         'still one live invoice for the job');
select tests.as_service();
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late1', 'succeeded', 20000, 0, 'payment', 'card',
                      p_invoice_id => tests.fx('inv1'), p_job_id => tests.fx('job_a'))$$, 'webhook replay');
select tests.eq(pg_temp.link('pi_late1'), concat_ws('/', 'succeeded', tests.fx('inv2'), tests.fx('job_a'), tests.fx('cust_a')),
                'a replay does not move the money back');
-- contradictions are still rejected, void or not
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_bad1', 'succeeded', 100, 0, 'payment', 'card',
                      p_invoice_id => tests.fx('inv1'), p_job_id => tests.fx('job_a2'))$$, '23514',
                    'a job that is not the void invoice''s job is rejected');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_bad2', 'succeeded', 100, 0, 'payment', 'card',
                      p_invoice_id => tests.fx('inv1'), p_customer_id => tests.fx('cust_a2'))$$, '23514',
                    'a customer that is not the void invoice''s customer is rejected');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_bad3', 'succeeded', 100, 0, 'payment', 'card',
                      p_invoice_id => tests.fx('inv1'), p_customer_id => tests.fx('cust_b'))$$, '23503',
                    'another shop cannot attach money to A''s (void) invoice');
select tests.as_superuser();
select tests.eq((select count(*) from public.payments where stripe_payment_intent_id in ('pi_bad1', 'pi_bad2', 'pi_bad3')), 0::bigint,
                'rejected payments were not recorded');

-- ============================================================ void job invoice, no replacement yet: money waits on the job
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Interior', 8000, false);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv3', (select id from public.create_invoice_from_job(tests.fx('job_a2'))));
select public.void_invoice(tests.fx('inv3'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late2', 'succeeded', 8000, 500, 'payment', 'card',
         p_invoice_id => tests.fx('inv3'), p_paid_at => '2025-06-01 12:00Z');
select tests.as_superuser();
select tests.eq(pg_temp.link('pi_late2'), concat_ws('/', 'succeeded', '-', tests.fx('job_a2'), tests.fx('cust_a2')),
                'no live invoice: the payment is kept on the job');
select tests.eq(pg_temp.bal(tests.fx('inv3')), 'void/8000/0/8000', 'the void invoice holds no money');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv4', (select id from public.create_invoice_from_job(tests.fx('job_a2'))));
select tests.eq((select concat_ws('/', status, amount_paid_cents, balance_cents, tip_cents) from public.invoices where id = tests.fx('inv4')),
                'paid/8000/0/500', 'the replacement invoice picks it up: nothing is charged twice');

-- ============================================================ ad-hoc invoices: money stays with the customer, flagged
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('adhoc1', (select id from public.create_invoice(tests.fx('cust_a3'),
                                 '[{"name":"Tint","unit_price_cents":12000,"taxable":false}]')));
select public.mark_invoice_sent(tests.fx('adhoc1'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('adhoc1'), 'duplicate');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late3', 'succeeded', 12000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('adhoc1'), p_customer_id => tests.fx('cust_a3'), p_paid_at => '2025-06-01 12:00Z');
select tests.as_superuser();
select tests.eq(pg_temp.link('pi_late3'), concat_ws('/', 'succeeded', '-', '-', tests.fx('cust_a3')),
                'ad-hoc: recorded as an unapplied payment of the invoice''s customer');
select tests.eq((select note from public.payments where stripe_payment_intent_id = 'pi_late3'),
                format('Received for void invoice #%s: apply it to another invoice or refund it',
                       (select number from public.invoices where id = tests.fx('adhoc1'))),
                'flagged for staff');
select tests.eq(pg_temp.bal(tests.fx('adhoc1')), 'void/12000/0/12000', 'the void invoice holds no money');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.payments where stripe_payment_intent_id = 'pi_late3'$$), 1::bigint,
                'staff can see the unapplied payment');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.payments where stripe_payment_intent_id = 'pi_late3'$$), 0::bigint,
                'shop B cannot');

-- a job invoice whose job has since moved to another customer: the money is
-- the invoice customer's, not the new customer's
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Dana') returning tests.fx_set('cust_d', id);
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')
  returning tests.fx_set('job_m', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_m'), 'Wash', 3000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_m', (select id from public.create_invoice_from_job(tests.fx('job_m'))));
select public.void_invoice(tests.fx('inv_m'));
update public.jobs set customer_id = tests.fx('cust_d') where id = tests.fx('job_m');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late4', 'succeeded', 3000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('inv_m'), p_job_id => tests.fx('job_m'), p_paid_at => '2025-06-01 12:00Z');
select tests.as_superuser();
select tests.eq(pg_temp.link('pi_late4'), concat_ws('/', 'succeeded', '-', '-', tests.fx('cust_a')),
                'kept with the customer who paid, off the reassigned job');

-- ============================================================ manual payments vs. card payments in flight
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv5', (select id from public.create_invoice(tests.fx('cust_a'),
                               '[{"name":"Coat","unit_price_cents":20000,"taxable":false}]')));
select public.mark_invoice_sent(tests.fx('inv5'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inflight', 'pending', 20000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('inv5'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv5'), 20000, 'cash')$$, '22023', '%in progress%',
                         'a manual payment must not exceed the balance still uncovered by in-flight payments');
select tests.throws($$select public.record_manual_payment(tests.fx('inv5'), 1, 'cash')$$, '22023',
                    'nothing is left to collect while the card covers the balance');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inflight', 'pending', 15000, 0, 'payment', 'card');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv5'), 5001, 'cash')$$, '22023',
                    'only the part the card does not cover can be collected');
select tests.lives($$select public.record_manual_payment(tests.fx('inv5'), 5000, 'cash', 700)$$,
                   'the uncovered part can (tips never count)');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inflight', 'succeeded', 15000, 0, 'payment', 'card');
select tests.as_superuser();
select tests.eq(pg_temp.bal(tests.fx('inv5')), 'paid/20000/20000/0', 'card + cash settle the invoice exactly once');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv6', (select id from public.create_invoice(tests.fx('cust_a'),
                               '[{"name":"Coat","unit_price_cents":20000,"taxable":false}]')));
select public.mark_invoice_sent(tests.fx('inv6'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tipped', 'pending', 10000, 3000, 'payment', 'card',
         p_invoice_id => tests.fx('inv6'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv6'), 10001, 'cash')$$, '22023',
                    'the in-flight amount is reserved');
select tests.lives($$select public.record_manual_payment(tests.fx('inv6'), 10000, 'check')$$,
                   'the in-flight tip is not (tips never change balances)');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tipped', 'failed', 10000, 3000, 'payment', 'card');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv6'), 10000, 'cash')$$,
                   'once the card attempt failed its amount can be collected another way');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv6'), 1, 'cash')$$, 'P0002',
                    'shop B cannot collect on A''s invoice');

-- ============================================================ abandoned PaymentSheet (the repro)
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')
  returning tests.fx_set('job_s', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('job_s'), 'Full Detail', 20000, false);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv7', (select id from public.create_invoice_from_job(tests.fx('job_s'))));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_abandoned', 'pending', 20000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('inv7'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 15000 where invoice_id = tests.fx('inv7')$$,
                         '23514', '%in progress%', 'a fresh intent freezes the lines');
select tests.throws_like($$update public.invoices set discount_kind = 'fixed', discount_value = 100 where id = tests.fx('inv7')$$,
                         '23514', '%in progress%', 'and the pricing');
select tests.throws_like($$select public.void_invoice(tests.fx('inv7'))$$, '22023', '%in progress%', 'and voiding');
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_s'))), 20000::bigint, 'shown as in flight');

select tests.as_superuser();
update public.payments set created_at = now() - interval '30 days' where stripe_payment_intent_id = 'pi_abandoned';
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_s'))), 0::bigint, 'no longer in flight');
select tests.lives($$update public.invoice_line_items set unit_price_cents = 15000 where invoice_id = tests.fx('inv7')$$,
                   'an abandoned 30-day-old pending intent must not freeze the invoice lines forever');
select tests.lives($$update public.invoices set discount_kind = 'fixed', discount_value = 100 where id = tests.fx('inv7')$$,
                   'nor its pricing');
select tests.lives($$select public.void_invoice(tests.fx('inv7'), 'wrong customer')$$,
                   'an abandoned pending intent must not block voiding forever');
select tests.as_superuser();
select tests.eq(pg_temp.link('pi_abandoned'), concat_ws('/', 'pending', '-', tests.fx('job_s'), tests.fx('cust_a')),
                'the stale job intent went back to the job with the void');
-- should the abandoned intent still complete, the money follows the job
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_abandoned', 'succeeded', 20000, 0, 'payment', 'card',
         p_paid_at => '2025-06-01 12:00Z');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv8', (select id from public.create_invoice_from_job(tests.fx('job_s'))));
select tests.eq(pg_temp.bal(tests.fx('inv8')), 'paid/20000/20000/0', 'the late success settles the replacement invoice');

-- a stale ad-hoc intent stays on the void invoice while pending and is
-- re-routed when it completes
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('adhoc2', (select id from public.create_invoice(tests.fx('cust_a2'),
                                 '[{"name":"Tint","unit_price_cents":9000,"taxable":false}]')));
select public.mark_invoice_sent(tests.fx('adhoc2'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_staleadhoc', 'pending', 9000, 0, 'payment', 'card',
         p_invoice_id => tests.fx('adhoc2'));
select tests.as_superuser();
update public.payments set created_at = now() - interval '2 hours' where stripe_payment_intent_id = 'pi_staleadhoc';
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.void_invoice(tests.fx('adhoc2'))$$, 'stale ad-hoc intent does not block the void');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_staleadhoc', 'succeeded', 9000, 0, 'payment', 'card',
         p_paid_at => '2025-06-01 12:00Z');
select tests.as_superuser();
select tests.eq(pg_temp.link('pi_staleadhoc'), concat_ws('/', 'succeeded', '-', '-', tests.fx('cust_a2')),
                'completed on a void invoice: moved to the customer as unapplied money');
select tests.eq(pg_temp.bal(tests.fx('adhoc2')), 'void/9000/0/9000', 'the void invoice still holds no money');
select tests.ok((select note like 'Received for void invoice #%' from public.payments where stripe_payment_intent_id = 'pi_staleadhoc'),
                'flagged for staff');
