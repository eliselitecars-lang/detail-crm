-- 60 money: asynchronous Stripe payments (P-31, 0064) — ACH debits and
-- buy-now-pay-later: payment method / status CHECKs, upsert_stripe_payment
-- v2 (processing state machine, method + stripe_method_type), 'processing'
-- as money in flight (manual payments, voids, line edits, shop deletion),
-- success / failure after processing, the public invoice document, the
-- booking page's deposit.payment_pending (a clearing deposit), manual
-- payment and refund refusals, report_payments grouping.
\ir fixtures/two_shops.psql

create function pg_temp.it(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;
grant execute on function pg_temp.it(uuid) to authenticated, anon, service_role;

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv1', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Coating","unit_price_cents":50000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv1'));
select tests.fx_set('inv2', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Wash","unit_price_cents":8000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv2'));
select tests.fx_set('inv3', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Tint","unit_price_cents":30000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv3'));

-- ============================================================ CHECKs (every context)
select tests.as_superuser();
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'ach_debit', 'pending', 100)$$, '23514',
                    'an ACH debit always comes from a PaymentIntent');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'bnpl', 'pending', 100)$$, '23514',
                    'so does pay-later');
select tests.throws($$insert into public.payments (shop_id, invoice_id, customer_id, method, status, amount_cents, paid_at, stripe_payment_intent_id)
                      values (tests.fx('shop_a'), tests.fx('inv1'), tests.fx('cust_a'), 'gift_card', 'succeeded', 100, now(), 'pi_gcx')$$,
                    '23514', 'a gift card redemption never has a PaymentIntent');
select tests.throws($$insert into public.payments (shop_id, invoice_id, customer_id, method, status, amount_cents, paid_at, card_last4)
                      values (tests.fx('shop_a'), tests.fx('inv1'), tests.fx('cust_a'), 'gift_card', 'succeeded', 100, now(), '4242')$$,
                    '23514', 'nor card data');
select tests.throws($$insert into public.payments (shop_id, invoice_id, customer_id, method, status, amount_cents, tip_cents, paid_at)
                      values (tests.fx('shop_a'), tests.fx('inv1'), tests.fx('cust_a'), 'gift_card', 'succeeded', 100, 10, now())$$,
                    '23514', 'nor a tip');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at, stripe_method_type)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'succeeded', 100, now(), 'card')$$, '23514',
                    'manual rows carry no Stripe method type');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at, stripe_payment_intent_id, stripe_method_type)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'ach_debit', 'succeeded', 100, now(), 'pi_badtype', 'US Bank')$$, '23514',
                    'stripe_method_type is a Stripe type name');
select tests.throws_like($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at)
                           values (tests.fx('shop_a'), tests.fx('cust_a'), 'gift_card', 'succeeded', 100, now())$$, '23514',
                         '%against an invoice%', 'gift card payments pay an invoice');

-- ============================================================ ACH: processing is in flight
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach1', 'processing', 50000, 0, 'payment', 'ach_debit',
                                    p_invoice_id => tests.fx('inv1'), p_stripe_method_type => 'us_bank_account') as p \gset
select tests.eq((select concat_ws('/', status, method, stripe_method_type, paid_at is null) from public.payments where stripe_payment_intent_id = 'pi_ach1'),
                'processing/ach_debit/us_bank_account/t', 'a clearing ACH debit: processing, method and Stripe type stored');
select tests.eq(pg_temp.it(tests.fx('inv1')), 'open/50000/0/50000', 'processing counts 0 toward the balance');
select tests.ok(public.payment_in_flight('processing', now() - interval '5 days'), 'processing is in flight however old it is');
select tests.ok(not public.payment_in_flight('pending', now() - interval '2 hours'), 'pending still stops blocking after an hour');
select tests.ok(public.payment_in_flight('pending', now() - interval '10 minutes'), 'a fresh pending payment is in flight');
select tests.as_superuser();
update public.payments set created_at = now() - interval '3 days' where stripe_payment_intent_id = 'pi_ach1';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv1'), 100, 'cash')$$, '22023', '%in progress%',
                         'cash cannot pay what a clearing bank payment covers (even days later)');
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 1 where invoice_id = tests.fx('inv1')$$, '23514',
                         '%in progress%', 'lines are frozen while it clears');
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_a'))), 0::bigint, 'unrelated job unaffected');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('inv1'))$$, '22023', '%in progress%', 'no void while it clears');
select public.invoice_link_token(tests.fx('inv1')) as tok1 \gset
select tests.as_anon();
select tests.eq((select concat_ws('/', d -> 'invoice' ->> 'processing_cents', d -> 'invoice' ->> 'payable')
                   from (select public.public_get_invoice(:'tok1') as d) x), '50000/false',
                'the /i page shows the clearing amount and is not payable while it covers the balance');
select tests.eq((select concat_ws('/', p ->> 'method', p ->> 'status', p ->> 'processing')
                   from (select public.public_get_invoice(:'tok1') -> 'payments' -> 0 as p) x), 'ach_debit/processing/true',
                'the clearing payment is listed as processing');
-- out of order: a late 'pending' never moves it back
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach1', 'pending', 50000, 0, 'payment', 'ach_debit');
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_ach1'), 'processing',
                'processing never regresses to pending');
-- settles
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach1', 'succeeded', 50000, 0, 'payment', 'ach_debit',
                                    p_charge_id => 'py_ach1', p_paid_at => '2025-06-10 12:00Z');
select tests.eq((select concat_ws('/', status, paid_at = '2025-06-10 12:00Z') from public.payments where stripe_payment_intent_id = 'pi_ach1'),
                'succeeded/t', 'the debit succeeds later');
select tests.eq(pg_temp.it(tests.fx('inv1')), 'paid/50000/50000/0', 'and pays the invoice');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach1', 'failed', 50000, 0, 'payment', 'ach_debit');
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_ach1'), 'succeeded',
                'received money is never downgraded');

-- ============================================================ ACH returned before it cleared
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach2', 'processing', 8000, 0, 'payment', 'ach_debit',
                                    p_invoice_id => tests.fx('inv2'), p_stripe_method_type => 'us_bank_account');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach2', 'failed', 8000, 0, 'payment', 'ach_debit');
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_ach2'), 'failed',
                'a failure after processing is final (the sheet rule does not keep it pending)');
select tests.eq(pg_temp.it(tests.fx('inv2')), 'open/8000/0/8000', 'the balance is simply still due');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach2', 'processing', 8000, 0, 'payment', 'ach_debit');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach2', 'pending', 8000, 0, 'payment', 'ach_debit');
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_ach2'), 'failed',
                'late processing / pending reports never reopen it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv2'), 8000, 'check')$$, 'the invoice can be paid another way');

-- ============================================================ pay later (BNPL) and method refinement
select tests.as_service();
-- a Checkout Session payment recorded before the customer's choice is known
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_bnpl', 'pending', 30000, 0, 'payment', 'card',
                                    p_invoice_id => tests.fx('inv3'), p_checkout_session_id => 'cs_test_bnpl');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_bnpl', 'succeeded', 30000, 0, 'payment', 'bnpl',
                                    p_stripe_method_type => 'klarna');
select tests.eq((select concat_ws('/', status, method, stripe_method_type) from public.payments where stripe_payment_intent_id = 'pi_bnpl'),
                'succeeded/bnpl/klarna', 'the method follows Stripe''s report until the money is received');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_bnpl', 'succeeded', 30000, 0, 'payment', 'card',
                                    p_stripe_method_type => 'card');
select tests.eq((select concat_ws('/', method, stripe_method_type) from public.payments where stripe_payment_intent_id = 'pi_bnpl'),
                'bnpl/klarna', 'and is fixed once received');
select tests.eq(pg_temp.it(tests.fx('inv3')), 'paid/30000/30000/0', 'pay-later pays the invoice at once');

-- ============================================================ argument validation
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_v1', 'pending', 100, 0, 'payment', 'cash', p_customer_id => tests.fx('cust_a'))$$,
                         '22023', '%card, card_present, ach_debit or bnpl%', 'manual methods are not Stripe payments');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_v2', 'pending', 100, 0, 'payment', 'gift_card', p_customer_id => tests.fx('cust_a'))$$,
                         '22023', '%card, card_present, ach_debit or bnpl%', 'nor gift cards');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_v3', 'refunded', 100, 0, 'payment', 'card', p_customer_id => tests.fx('cust_a'))$$,
                    '22023', 'refund states come from apply_stripe_refund');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_v4', 'pending', 100, 0, 'payment', 'card', p_customer_id => tests.fx('cust_a'), p_stripe_method_type => 'Card Brand!')$$,
                         '22023', '%method type%', 'invalid Stripe method type');
select tests.as_superuser();
select tests.eq((select count(*) from pg_proc where proname = 'upsert_stripe_payment'), 1::bigint, 'one signature (no leftover overload)');
select tests.ok(has_function_privilege('service_role', 'public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind, public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz, text)', 'execute')
                and not has_function_privilege('authenticated', 'public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind, public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz, text)', 'execute')
                and not has_function_privilege('anon', 'public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind, public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz, text)', 'execute'),
                'service_role only');

-- ============================================================ manual payments and refunds
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv4', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Polish","unit_price_cents":9000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv4'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv4'), 100, 'gift_card')$$, '22023', '%redeem_gift_card%',
                         'gift cards are redeemed, not recorded');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv4'), 100, 'ach_debit')$$, '22023', '%through Stripe%',
                         'bank debits go through Stripe');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv4'), 100, 'bnpl')$$, '22023', '%through Stripe%',
                         'pay-later goes through Stripe');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.refund_manual_payment((select id from public.payments where stripe_payment_intent_id = 'pi_ach1'), 100)$$,
                         '22023', '%refunded through Stripe%', 'an ACH payment is refunded through Stripe');
select tests.throws_like($$select public.refund_manual_payment((select id from public.payments where stripe_payment_intent_id = 'pi_bnpl'), 100)$$,
                         '22023', '%refunded through Stripe%', 'so is pay-later');

-- ============================================================ report_payments groups the new methods
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_object_agg(method, net_cents) filter (where method in ('ach_debit', 'bnpl', 'gift_card', 'check'))
                   from public.report_payments(tests.fx('shop_a'), '2025-06-01', (now() at time zone 'America/Chicago')::date)),
                '{"ach_debit": 50000, "bnpl": 30000, "gift_card": 0, "check": 8000}'::jsonb,
                'payments by method: ach_debit and bnpl rows (failed ACH excluded)');

-- ============================================================ a clearing payment blocks shop deletion
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_bach', 'processing', 100, 0, 'payment', 'ach_debit',
                                    p_customer_id => tests.fx('cust_b'));
select tests.as_superuser();
update public.payments set created_at = now() - interval '4 days' where stripe_payment_intent_id = 'pi_bach';
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', '%in progress%',
                         'a shop with a bank payment still clearing cannot be deleted');

-- ============================================================ booking page: a clearing deposit is in flight
-- booking_public_json (0042): deposit.payment_pending covers 'processing'
-- (ACH / pay-later, days) as well as a pending card attempt, so the payments
-- edge's booking_deposit_checkout (409 payment_in_progress) never opens a
-- second deposit Checkout while the first one clears.
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Detail', 20000);
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_a2');
select public_token as tok_a2 from public.jobs where id = tests.fx('job_a2') \gset
create function pg_temp.dep(p_tok uuid) returns text language sql as $$
  select concat_ws('/', d ->> 'status', d ->> 'due_cents', d ->> 'paid_cents', d ->> 'payment_pending')
    from (select public.public_get_booking(p_tok) -> 'deposit' as d) x
$$;
grant execute on function pg_temp.dep(uuid) to anon;
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'due/5000/0/false', 'a deposit is due, nothing on its way');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achdep1', 'processing', 5000, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job_a2'), null, null, null, 'cs_achdep1', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'due/5000/0/true',
                'an ACH deposit still processing is in flight: not received yet, but the page must not ask for it again');
select tests.as_superuser();
update public.payments set created_at = now() - interval '4 days' where stripe_payment_intent_id = 'pi_achdep1';
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'due/5000/0/true', 'days later it is still on its way (processing never expires)');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achdep1', 'succeeded', 5000, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job_a2'), null, null, null, 'cs_achdep1', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'paid/0/5000/false', 'cleared: the deposit is paid');
-- a return after processing (failed) is not on its way any more
select tests.as_superuser();
update public.jobs set deposit_required_cents = 8000 where id = tests.fx('job_a2');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achdep2', 'processing', 3000, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job_a2'), null, null, null, 'cs_achdep2', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'due/3000/5000/true', 'the rest of a raised deposit is clearing');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achdep2', 'failed', 3000, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job_a2'), null, null, null, 'cs_achdep2', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq(pg_temp.dep(:'tok_a2'), 'due/3000/5000/false', 'returned: it can be asked for again');
