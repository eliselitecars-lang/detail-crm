-- 10 money: a declined PaymentSheet attempt is still money in flight. Stripe
-- returns the declined intent to requires_payment_method and the sheet still
-- on the device can confirm it with another card, so upsert_stripe_payment
-- keeps it 'pending' and every in-flight guard (record_manual_payment,
-- apply_payment_to_invoice, line / pricing guards, void_invoice) counts it
-- until it succeeds or is cancelled. Attempts that cannot be confirmed again
-- (saved-card charges, Checkout Sessions, membership invoices) fail as reported.
\ir fixtures/two_shops.psql

create function pg_temp.pay(p_pi text) returns text language sql as $$
  select concat_ws('/', status, amount_cents, tip_cents) from public.payments where stripe_payment_intent_id = p_pi
$$;
create function pg_temp.inv(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;

-- ============================================================ the repro
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet', 'pending', 20000, 0, 'payment', p_invoice_id => tests.fx('inv'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet', 'failed', 20000, 0, 'payment', p_invoice_id => tests.fx('inv'));
select tests.eq(pg_temp.pay('pi_sheet'), 'pending/20000/0', 'the declined sheet stays open');
select tests.eq(pg_temp.inv(tests.fx('inv')), 'open/20000/0/20000', 'nothing received yet');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 20000, 'cash')$$, '22023',
                    'cash cannot cover what the still-confirmable card sheet covers');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 1, 'check')$$, '22023', '%in progress%',
                         'not even part of it');
select tests.throws_like($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('inv'), 'Extra', 500)$$, '23514', '%in progress%',
                         'lines cannot change under the open sheet');
select tests.throws_like($$update public.invoices set discount_kind = 'fixed', discount_value = 1000 where id = tests.fx('inv')$$,
                         '23514', '%in progress%', 'nor pricing');

-- an unapplied credit of the same customer cannot be applied over it either
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_credit', 'succeeded', 5000, 0, 'payment', 'card',
                                    p_customer_id => tests.fx('cust_a'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.apply_payment_to_invoice(
                             (select id from public.payments where stripe_payment_intent_id = 'pi_credit'), tests.fx('inv'))$$,
                         '22023', '%in progress%', 'apply_payment_to_invoice counts the declined sheet');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('inv'))$$, '22023', '%in progress%',
                         'the invoice cannot be voided under the open sheet');

-- the customer confirms the sheet with a second card: paid exactly once
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet', 'succeeded', 20000, 0, 'payment',
                                    p_invoice_id => tests.fx('inv'), p_card_brand => 'visa', p_card_last4 => '4242');
select tests.eq(pg_temp.inv(tests.fx('inv')), 'paid/20000/20000/0', 'paid once, no overpayment');
select tests.eq((select count(*) from public.payments where invoice_id = tests.fx('inv')), 1::bigint, 'one payment on the invoice');

-- ============================================================ released sheets free the balance
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 10000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet2', 'pending', 10000, 500, 'payment', p_invoice_id => tests.fx('inv2'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet2', 'failed', 10000, 500, 'payment', p_invoice_id => tests.fx('inv2'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet2', 'failed', 10000, 500, 'payment', p_invoice_id => tests.fx('inv2'));
select tests.eq(pg_temp.pay('pi_sheet2'), 'pending/10000/500', 'a replayed decline keeps it open');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv2'), 10000, 'cash')$$, '22023', 'blocked while open');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet2', 'cancelled', 10000, 500, 'payment', p_invoice_id => tests.fx('inv2'));
select tests.eq(pg_temp.pay('pi_sheet2'), 'cancelled/10000/500', 'cancel_open_payments / the sweep cancel it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv2'), 10000, 'cash')$$, 'then cash can pay the balance');
select tests.eq(pg_temp.inv(tests.fx('inv2')), 'paid/10000/10000/0', 'paid by cash');

-- an open attempt stops blocking once it is stale (an hour), like any pending one
select tests.ok(public.payment_in_flight('pending', '2025-06-01 11:01Z', '2025-06-01 12:00Z'), 'a recent attempt is in flight');
select tests.ok(not public.payment_in_flight('pending', '2025-06-01 11:00Z', '2025-06-01 12:00Z'), 'a stale one is not');

-- ============================================================ attempts that cannot be confirmed again fail as reported
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_c', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_c'), 'Tint', 30000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv3', (public.create_invoice_from_job(tests.fx('job_c'))).id);
select tests.as_service();
-- a saved-card charge still processing, then declined (card recorded up front; confirmed server-side only)
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_saved', 'pending', 30000, 0, 'payment', p_invoice_id => tests.fx('inv3'),
                                    p_card_brand => 'visa', p_card_last4 => '4242');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_saved', 'failed', 30000, 0, 'payment', p_invoice_id => tests.fx('inv3'));
select tests.eq(pg_temp.pay('pi_saved'), 'failed/30000/0', 'a declined saved-card charge fails');
-- a synchronous saved-card decline (recorded failed at once)
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_saved2', 'failed', 30000, 0, 'payment', p_invoice_id => tests.fx('inv3'),
                                    p_card_brand => 'visa', p_card_last4 => '4242');
select tests.eq(pg_temp.pay('pi_saved2'), 'failed/30000/0', 'recorded failed');
-- a Checkout Session payment
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs', 'pending', 30000, 0, 'payment', p_invoice_id => tests.fx('inv3'),
                                    p_checkout_session_id => 'cs_test_decl');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs', 'failed', 30000, 0, 'payment', p_invoice_id => tests.fx('inv3'));
select tests.eq(pg_temp.pay('pi_cs'), 'failed/30000/0', 'a failed Checkout payment fails');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv3'), 30000, 'cash')$$,
                   'after those declines the customer can pay cash at once');

-- membership invoices (Stripe Billing retries them) fail as reported
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Gold', 9900) returning tests.fx_set('plan', id);
insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a2'))
  returning tests.fx_set('mem', id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_mem', 'pending', 9900, 0, 'membership', p_membership_id => tests.fx('mem'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_mem', 'failed', 9900, 0, 'membership', p_membership_id => tests.fx('mem'));
select tests.eq(pg_temp.pay('pi_mem'), 'failed/9900/0', 'a membership payment fails');

-- ============================================================ isolation and privileges
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_sheet', 'failed', 20000)$$, '22023',
                    'another shop cannot report on shop A''s intent');
select tests.eq(pg_temp.pay('pi_sheet'), 'succeeded/20000/0', 'shop A''s payment is unchanged');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x', 'failed', 100, p_invoice_id => tests.fx('inv3'))$$,
                    '42501', 'staff cannot write card payments');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 1, 'cash')$$, 'P0002', 'shop B cannot see A''s invoice');
