-- 10 money: payments — deposits, invoice attachment, manual payments,
-- overpayment rejection, balance / tip / refund math, status automation,
-- Stripe webhook helpers (idempotency, ordering), stripe_events,
-- job_payment_summary, RLS and isolation.
\ir fixtures/two_shops.psql

create function pg_temp.bal(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, total_cents, amount_paid_cents, balance_cents, tip_cents) from public.invoices where id = p_id
$$;
create function pg_temp.pay(p_pi text) returns text language sql as $$
  select concat_ws('/', status, amount_cents, tip_cents, refunded_cents) from public.payments where stripe_payment_intent_id = p_pi
$$;

-- job_a: Full Detail 20000, no tax (fixture), deposit 5000 required
select tests.as_superuser();
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_a');

-- ------------------------------------------------------------ webhook helpers are service-only
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x', 'succeeded', 100, p_job_id => tests.fx('job_a'))$$,
                    '42501', 'owners cannot write card payments');
select tests.throws($$select public.apply_stripe_refund('pi_x', 1)$$, '42501', 'owners cannot apply refunds directly');
select tests.throws($$select public.record_stripe_event('evt_1', 'x')$$, '42501', 'owners cannot touch the event ledger');
select tests.as_anon();
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x', 'succeeded', 100, p_job_id => tests.fx('job_a'))$$,
                    '42501', 'anon cannot write card payments');

-- ------------------------------------------------------------ deposit before the invoice (Stripe)
select tests.as_service();
select tests.eq((select concat_ws('/', status, kind, method, customer_id = tests.fx('cust_a'), invoice_id is null, paid_at is null)
                   from public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'pending', 5000, 0, 'deposit',
                                                     p_job_id => tests.fx('job_a'), p_checkout_session_id => 'cs_test_1')),
                'pending/deposit/card/t/t/t', 'pending deposit row created; customer derived from the job');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'pending', 5000, 0, 'deposit', p_job_id => tests.fx('job_a'))$$);
select tests.eq((select count(*) from public.payments where stripe_payment_intent_id = 'pi_dep1'), 1::bigint, 'replay: still one row');
select tests.eq((select concat_ws('/', status, paid_at, stripe_charge_id, card_brand, card_last4, stripe_checkout_session_id)
                   from public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5000, 0, 'deposit',
                                                     p_job_id => tests.fx('job_a'), p_charge_id => 'ch_1', p_card_brand => ' Visa ',
                                                     p_card_last4 => '4242', p_paid_at => '2025-06-01 12:00Z')),
                'succeeded/2025-06-01 12:00:00+00/ch_1/visa/4242/cs_test_1', 'succeeded: paid_at, charge and card details recorded');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5000, 0, 'deposit',
                     p_job_id => tests.fx('job_a'), p_paid_at => '2025-06-09 12:00Z')$$, 'succeeded replayed');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'pending', 9999, 0, 'deposit', p_job_id => tests.fx('job_a'))$$,
                   'late pending event after success');
select tests.eq((select concat_ws('/', status, amount_cents, paid_at) from public.payments where stripe_payment_intent_id = 'pi_dep1'),
                'succeeded/5000/2025-06-01 12:00:00+00', 'received money is never downgraded or re-dated by replays');
-- linkage cannot be moved by a later call
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5000, 0, 'payment',
                     p_job_id => tests.fx('job_a2'))$$);
select tests.ok((select job_id = tests.fx('job_a') and kind = 'deposit' from public.payments where stripe_payment_intent_id = 'pi_dep1'),
                'linkage fixed by the first call');
-- validation
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_dep1', 'succeeded', 5000, p_customer_id => tests.fx('cust_b'))$$,
                         '22023', '%another shop%', 'a payment intent cannot switch shops');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_r', 'refunded', 5000, p_job_id => tests.fx('job_a'))$$,
                         '22023', '%apply_stripe_refund%', 'refund states come from apply_stripe_refund');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_c', 'succeeded', 5000, p_method => 'cash', p_job_id => tests.fx('job_a'))$$,
                    '22023', 'Stripe rows are card rows');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_z', 'succeeded', 0, 0, p_job_id => tests.fx('job_a'))$$,
                    '22023', 'zero payments rejected');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_z', 'succeeded', 100)$$, '22023', 'payments need a parent');
select tests.throws($$select public.upsert_stripe_payment(gen_random_uuid(), 'pi_z', 'succeeded', 100, p_customer_id => tests.fx('cust_a'))$$,
                    'P0002', 'unknown shop');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'bad_id', 'succeeded', 100, p_job_id => tests.fx('job_a'))$$,
                    '23514', 'payment intent ids are validated');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_m', 'succeeded', 100, p_job_id => tests.fx('job_a'),
                                                              p_customer_id => tests.fx('cust_a2'))$$,
                         '23514', '%job''s customer%', 'customer must match the job');
-- links that do not exist in the shop (another shop's rows, deleted rows)
-- are dropped: the money is recorded against what remains, never across shops
select tests.eq((select concat_ws('/', job_id is null, invoice_id is null, customer_id = tests.fx('cust_a'), status)
                   from public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x1', 'succeeded', 100, p_job_id => tests.fx('job_b'),
                                                     p_customer_id => tests.fx('cust_a'))),
                't/t/t/succeeded', 'another shop''s job is never attached; the money stays with the customer');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x2', 'succeeded', 100, p_customer_id => tests.fx('cust_b'))$$,
                         'P0002', '%exists in this shop%', 'another shop''s customer alone leaves nothing to record against');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x4', 'succeeded', 100, p_invoice_id => gen_random_uuid(),
                                                         p_job_id => gen_random_uuid(), p_membership_id => gen_random_uuid(), p_kind => 'membership')$$,
                    'P0002', 'only deleted links: P0002');
select tests.eq((select count(*) from public.payments where stripe_payment_intent_id in ('pi_x2', 'pi_x4')), 0::bigint,
                'nothing recorded for them');
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x3', 'succeeded', 100, p_kind => 'membership', p_customer_id => tests.fx('cust_a'))$$,
                    '23514', 'membership payments need a membership');

-- ------------------------------------------------------------ job_payment_summary before invoicing
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select concat_ws('/', invoice_id is null, total_cents, deposit_required_cents, deposit_paid_cents, deposit_due_cents,
                                  paid_cents, tip_cents, refunded_cents, pending_cents, balance_cents)
                   from public.job_payment_summary(tests.fx('job_a'))),
                't/20000/5000/5000/0/5000/0/0/0/15000', 'summary: deposit paid, balance from the job total');
select tests.eq((select deposit_due_cents from public.job_payment_summary(tests.fx('job_a2'))), 0::bigint, 'no deposit required -> none due');
select tests.throws($$select * from public.job_payment_summary(tests.fx('job_b'))$$, 'P0002', 'summary of another shop''s job: not found');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.job_payment_summary(tests.fx('job_a'))$$, '42501', 'technicians need collecting enabled');
select tests.eq(tests.row_count($$select * from public.payments$$), 0::bigint, 'collecting disabled: technicians see no payments');

-- ------------------------------------------------------------ invoice attaches the deposit
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/5000/15000/0', 'earlier deposit attached: partially paid');
select tests.eq((select invoice_id from public.payments where stripe_payment_intent_id = 'pi_dep1'), tests.fx('inv'), 'deposit linked to the invoice');

-- ------------------------------------------------------------ manual payments
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 15001, 'cash')$$, '22023', '%exceeds the balance%',
                         'overpayment rejected');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 0, 'cash')$$, '22023', 'zero amount rejected');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), -5, 'cash')$$, '22023', 'negative amount rejected');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'cash', -1)$$, '22023', 'negative tip rejected');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 100, 'card')$$, '22023', '%Stripe%', 'cards go through Stripe');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'card_present')$$, '22023', 'card_present goes through Stripe');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'cash', 0, repeat('x', 1001))$$, '22023', 'note length');
select tests.eq((select concat_ws('/', status, kind, method, amount_cents, tip_cents, recorded_by = tests.fx('u_manager_a'), paid_at = now(),
                                  note, job_id = tests.fx('job_a'), customer_id = tests.fx('cust_a'))
                   from public.record_manual_payment(tests.fx('inv'), 10000, 'cash', 500, '  paid at pickup ')),
                'succeeded/payment/cash/10000/500/t/t/paid at pickup/t/t', 'cash payment with tip recorded');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/15000/5000/500', 'tips never reduce the balance');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 5001, 'check', 1000)$$, '22023',
                    'the tip does not raise the allowed amount');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'cash')$$, '42501', 'collecting disabled: technician denied');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'cash')$$, 'P0002', 'manager of B: not found');
select tests.eq(tests.row_count($$select * from public.payments where shop_id = tests.fx('shop_a')$$), 0::bigint, 'B cannot read A''s payments');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 100, 'cash')$$, 'P0002', 'outsider: not found');
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select concat_ws('/', status, recorded_by = tests.fx('u_tech_a'))
                   from public.record_manual_payment(tests.fx('inv'), 5000, 'check')),
                'succeeded/t', 'collecting technician records the final payment on an assigned job');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'paid/20000/20000/0/500', 'fully paid');
select tests.eq((select paid_at from public.invoices where id = tests.fx('inv')), now(), 'paid_at = latest payment');
select tests.eq(tests.row_count($$select * from public.payments where job_id = tests.fx('job_a')$$), 3::bigint,
                'collecting technician reads payments of an assigned job');
select tests.eq((select concat_ws('/', paid_cents, tip_cents, balance_cents, deposit_due_cents) from public.job_payment_summary(tests.fx('job_a'))),
                '20000/500/0/0', 'technician reads the job summary');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 1, 'cash')$$, '22023', '%paid%', 'paid invoices take no more payments');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select * from public.payments where job_id = tests.fx('job_a')$$), 0::bigint,
                'other technicians cannot see those payments');
select tests.throws($$select public.record_manual_payment(tests.fx('inv'), 1, 'cash')$$, '42501',
                    'a technician not assigned to the job cannot collect');
select tests.throws($$select * from public.job_payment_summary(tests.fx('job_a'))$$, '42501', 'nor the summary');
-- no direct writes for any client role
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'succeeded', 100)$$, '42501', 'owners cannot insert payments');
select tests.throws($$update public.payments set amount_cents = 1 where invoice_id = tests.fx('inv')$$, '42501', 'owners cannot update payments');
select tests.throws($$delete from public.payments where invoice_id = tests.fx('inv')$$, '42501', 'owners cannot delete payments');
select tests.throws($$delete from public.customers where id = tests.fx('cust_a')$$, '23503', 'a customer with payments cannot be deleted');

-- ------------------------------------------------------------ refunds (Stripe, cumulative + monotonic)
select tests.as_service();
select tests.eq(pg_temp.pay('pi_dep1'), 'succeeded/5000/0/0', 'before refund');
select tests.eq((select status::text from public.apply_stripe_refund('pi_dep1', 2000)), 'partially_refunded', 'partial refund');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/18000/2000/500', 'refund reopens the invoice');
select tests.eq((select paid_at from public.invoices where id = tests.fx('inv')), null::timestamptz, 'paid_at cleared when reopened');
select tests.lives($$select public.apply_stripe_refund('pi_dep1', 2000)$$, 'same refund total replayed');
select tests.lives($$select public.apply_stripe_refund('pi_dep1', 1000)$$, 'stale (smaller) total delivered late');
select tests.eq(pg_temp.pay('pi_dep1'), 'partially_refunded/5000/0/2000', 'replays and stale events have no effect');
select tests.eq((select status::text from public.apply_stripe_refund('pi_dep1', 5000)), 'refunded', 'full refund');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/15000/5000/500', 'fully refunded deposit no longer counts');
select tests.throws($$select public.apply_stripe_refund('pi_dep1', 5001)$$, '22023', 'refund above the charge rejected');
select tests.throws($$select public.apply_stripe_refund('pi_dep1', -1)$$, '22023', 'negative refund rejected');
select tests.throws($$select public.apply_stripe_refund('pi_unknown', 1)$$, 'P0002', 'unknown payment intent');

-- manual refunds (owner/admin)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.refund_manual_payment((select id from public.payments where method = 'cash' and invoice_id = tests.fx('inv')), 100)$$,
                    '42501', 'managers cannot refund');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.refund_manual_payment((select id from public.payments where stripe_payment_intent_id = 'pi_dep1'), 100)$$,
                    'P0002', 'admin of B: not found (and cannot even see the row)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('cash_pay', (select id from public.payments where method = 'cash' and invoice_id = tests.fx('inv')));
select tests.throws_like($$select public.refund_manual_payment((select id from public.payments where stripe_payment_intent_id = 'pi_dep1'), 100)$$,
                         '22023', '%through Stripe%', 'card refunds go through Stripe');
select tests.throws($$select public.refund_manual_payment(tests.fx('cash_pay'), 0)$$, '22023', 'zero refund rejected');
select tests.throws($$select public.refund_manual_payment(tests.fx('cash_pay'), 10501)$$, '22023', 'refund above amount + tip rejected');
select tests.eq((select concat_ws('/', status, refunded_cents) from public.refund_manual_payment(tests.fx('cash_pay'), 10000)),
                'partially_refunded/10000', 'refund applies to the amount first');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/5000/15000/500', 'the tip survives an amount-only refund');
select tests.eq((select concat_ws('/', status, refunded_cents) from public.refund_manual_payment(tests.fx('cash_pay'), 500)),
                'refunded/10500', 'then the tip');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/5000/15000/0', 'tip refunded');
select tests.throws($$select public.refund_manual_payment(tests.fx('cash_pay'), 1)$$, '22023', 'fully refunded payments cannot be refunded again');

-- ------------------------------------------------------------ Stripe invoice payment with tip; refund past the amount
select tests.as_service();
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inv1', 'succeeded', 15000, 300,
                     p_invoice_id => tests.fx('inv'), p_charge_id => 'ch_2', p_card_last4 => '1111')$$);
select tests.ok((select job_id = tests.fx('job_a') and customer_id = tests.fx('cust_a') and kind = 'payment' from public.payments
                 where stripe_payment_intent_id = 'pi_inv1'), 'invoice payment takes the invoice''s job and customer');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'paid/20000/20000/0/300', 'card payment with tip pays the invoice');
select tests.lives($$select public.apply_stripe_refund('pi_inv1', 15100)$$);
select tests.eq(pg_temp.pay('pi_inv1'), 'partially_refunded/15000/300/15100', 'refund larger than the amount');
select tests.eq(pg_temp.bal(tests.fx('inv')), 'partially_paid/20000/5000/15000/200', 'amount refunded in full, 100 of the tip refunded');
-- two checkouts race: money that already moved is recorded, leaving a credit
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inv2', 'succeeded', 15000, p_invoice_id => tests.fx('inv'))$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_inv3', 'succeeded', 1000, p_invoice_id => tests.fx('inv'))$$);
select tests.eq(pg_temp.bal(tests.fx('inv')), 'paid/20000/21000/-1000/200', 'a Stripe overpayment is recorded as a credit (negative balance)');

-- ------------------------------------------------------------ failed / cancelled / amount changes
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_f', 'pending', 1000, p_job_id => tests.fx('job_a2'))$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_f', 'pending', 1500, p_job_id => tests.fx('job_a2'))$$);
select tests.eq(pg_temp.pay('pi_f'), 'pending/1500/0/0', 'amount follows the latest pending state');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_f', 'failed', 1500, p_job_id => tests.fx('job_a2'))$$);
select tests.eq(pg_temp.pay('pi_f'), 'pending/1500/0/0',
                'a declined PaymentSheet attempt (no card on record yet) stays open: the sheet can confirm it again');
select tests.eq((select sum(public.payment_net_amount(status, amount_cents, tip_cents, refunded_cents)) from public.payments
                  where job_id = tests.fx('job_a2')), 0::numeric, 'declined payments count nothing');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_f', 'succeeded', 1500, p_job_id => tests.fx('job_a2'),
                     p_paid_at => '2025-06-03 10:00Z')$$, 'retry succeeds on the same intent');
select tests.eq(pg_temp.pay('pi_f'), 'succeeded/1500/0/0', 'declined -> succeeded');
-- attempts that cannot be confirmed again are recorded failed as reported
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fs', 'pending', 800, p_customer_id => tests.fx('cust_a3'),
                     p_card_brand => 'visa', p_card_last4 => '4242')$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fs', 'failed', 800, p_customer_id => tests.fx('cust_a3'))$$);
select tests.eq(pg_temp.pay('pi_fs'), 'failed/800/0/0', 'a saved-card charge (card recorded up front) fails');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fc', 'pending', 800, p_customer_id => tests.fx('cust_a3'),
                     p_checkout_session_id => 'cs_test_fc')$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fc', 'failed', 800, p_customer_id => tests.fx('cust_a3'))$$);
select tests.eq(pg_temp.pay('pi_fc'), 'failed/800/0/0', 'a Checkout Session payment fails');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fd', 'failed', 800, p_customer_id => tests.fx('cust_a3'))$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fd', 'failed', 800, p_customer_id => tests.fx('cust_a3'))$$);
select tests.eq(pg_temp.pay('pi_fd'), 'failed/800/0/0', 'a decline recorded without an open attempt stays failed (replays too)');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_fs', 'pending', 800, p_customer_id => tests.fx('cust_a3'))$$);
select tests.eq(pg_temp.pay('pi_fs'), 'failed/800/0/0', 'a late pending report does not reopen a recorded decline');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_f', 'succeeded', 9999, 50, p_job_id => tests.fx('job_a2'))$$);
select tests.eq(pg_temp.pay('pi_f'), 'succeeded/1500/0/0', 'amounts are frozen once received');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cx', 'pending', 700, p_job_id => tests.fx('job_a2'))$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cx', 'cancelled', 700, p_job_id => tests.fx('job_a2'))$$);
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cx', 'pending', 700, p_job_id => tests.fx('job_a2'))$$);
select tests.eq(pg_temp.pay('pi_cx'), 'cancelled/700/0/0', 'cancelled is terminal for late pending/failed events');
select tests.throws($$select public.apply_stripe_refund('pi_cx', 100)$$, '22023', 'cancelled payments cannot be refunded');
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cx', 'succeeded', 700, p_job_id => tests.fx('job_a2'))$$);
select tests.eq(pg_temp.pay('pi_cx'), 'succeeded/700/0/0', '... but money that moved wins');

-- ------------------------------------------------------------ pending payments freeze the invoice
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 4000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.eq(pg_temp.bal(tests.fx('inv2')), 'partially_paid/4000/2200/1800/0', 'both earlier card payments attached');
select tests.fx_set('inv_open', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Polish","unit_price_cents":1000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_open'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_p', 'pending', 1800, p_invoice_id => tests.fx('inv2'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_p2', 'pending', 1000, p_invoice_id => tests.fx('inv_open'));
select tests.eq(pg_temp.bal(tests.fx('inv_open')), 'open/1000/0/1000/0', 'pending money does not count');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 900 where invoice_id = tests.fx('inv_open')$$, '23514',
                         '%in progress%', 'lines frozen while a payment is in flight');
select tests.throws_like($$update public.invoices set tax_rate_bps = 500 where id = tests.fx('inv_open')$$, '23514', '%in progress%',
                         'pricing frozen while a payment is in flight');
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_a2'))), 1800::bigint, 'summary shows money in flight');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('inv2'))$$, '22023', '%in progress%', 'no voiding while a payment is in flight');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_p', 'succeeded', 1800, p_invoice_id => tests.fx('inv2'));
select tests.eq(pg_temp.bal(tests.fx('inv2')), 'paid/4000/4000/0/0', 'in-flight payment completes the invoice');

-- ------------------------------------------------------------ voiding hands job payments back to the job
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.void_invoice(tests.fx('inv2'), 'Re-issue with corrected lines')$$,
                   'a paid job invoice can be voided: its payments belong to the job');
select tests.eq(pg_temp.bal(tests.fx('inv2')), 'void/4000/0/4000/0', 'void invoice keeps no money');
select tests.eq((select count(*) from public.payments where job_id = tests.fx('job_a2') and invoice_id is null), 3::bigint,
                'payments detached back to the job');
select tests.eq((select concat_ws('/', invoice_id is null, paid_cents, balance_cents) from public.job_payment_summary(tests.fx('job_a2'))),
                't/4000/0', 'job summary still shows the money');
select tests.fx_set('inv3', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.eq(pg_temp.bal(tests.fx('inv3')), 'paid/4000/4000/0/0', 'replacement invoice picks the payments up again');
select tests.as_service();
select tests.lives($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late', 'succeeded', 100, p_job_id => tests.fx('job_a2'))$$);
select tests.eq((select invoice_id from public.payments where stripe_payment_intent_id = 'pi_late'), tests.fx('inv3'),
                'a later job payment attaches to the job''s current (non-void) invoice');
select tests.eq(pg_temp.bal(tests.fx('inv3')), 'paid/4000/4100/-100/0', 'and counts there');

-- ------------------------------------------------------------ money received on a draft issues it
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_draft', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Clay bar","unit_price_cents":2000}]')).id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_d', 'succeeded', 500, p_invoice_id => tests.fx('inv_draft'));
select tests.ok((select status = 'partially_paid' and issued_at = now() and amount_paid_cents = 500
                        and due_at = (((now() at time zone 'America/Chicago')::date + coalesce((select invoice_due_days from public.shops where id = tests.fx('shop_a')), 0))::timestamp
                                      + time '23:59:59') at time zone 'America/Chicago'
                 from public.invoices where id = tests.fx('inv_draft')), 'a draft that receives money is issued automatically');

-- ------------------------------------------------------------ table constraints (trusted writers too)
select tests.as_superuser();
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at, card_last4)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'succeeded', 100, now(), '4242')$$, '23514',
                    'manual rows carry no card data');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'card', 'succeeded', 100, now())$$, '23514',
                    'card rows need a payment intent');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at, stripe_payment_intent_id)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'succeeded', 100, now(), 'pi_q')$$, '23514',
                    'manual rows have no payment intent');
select tests.throws_like($$insert into public.payments (shop_id, invoice_id, job_id, customer_id, method, status, amount_cents)
                           values (tests.fx('shop_a'), tests.fx('inv3'), tests.fx('job_a'), tests.fx('cust_a2'), 'cash', 'pending', 100)$$,
                         '23514', '%invoice''s job%', 'payment job must match the invoice');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, refunded_cents)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'pending', 100, 10)$$, '23514',
                    'refunded_cents requires a refund status');
select tests.throws($$insert into public.payments (shop_id, customer_id, method, status, amount_cents, refunded_cents, paid_at)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'cash', 'refunded', 100, 50, now())$$, '23514',
                    'refunded means fully refunded');
select tests.throws($$insert into public.payments (shop_id, invoice_id, customer_id, method, status, amount_cents)
                      values (tests.fx('shop_b'), tests.fx('inv3'), tests.fx('cust_b'), 'cash', 'pending', 100)$$, '23503',
                    'a B payment cannot point at A''s invoice');
select tests.throws($$delete from public.jobs where id = tests.fx('job_a2')$$, '23503', 'jobs with payments cannot be deleted');

-- ------------------------------------------------------------ technician visibility with collecting enabled
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select * from public.payments where job_id = tests.fx('job_a2')$$), 0::bigint,
                'a technician does not see payments of jobs assigned to others');
select tests.eq(tests.row_count($$select * from public.payments where job_id is null$$), 0::bigint,
                'nor payments without a job (ad-hoc invoices)');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select * from public.payments where job_id = tests.fx('job_a2')$$), 4::bigint,
                'the assigned technician does');

-- ------------------------------------------------------------ stripe_events (webhook idempotency)
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.stripe_events$$, '42501', 'clients cannot read the event ledger');
select tests.as_service();
select tests.eq(public.record_stripe_event('evt_1', 'payment_intent.succeeded', 'acct_123', '2025-06-01 12:00Z'), true, 'new event: process it');
select tests.eq(public.record_stripe_event('evt_1', 'payment_intent.succeeded', 'acct_123', '2025-06-01 12:00Z'), false,
                'same event again while in flight: skip');
select tests.eq(public.record_stripe_event('evt_1', 'payment_intent.succeeded', 'acct_123', '2025-06-01 12:04:59Z'), false,
                'still in flight within 5 minutes');
select tests.eq(public.record_stripe_event('evt_1', 'payment_intent.succeeded', 'acct_123', '2025-06-01 12:05Z'), true,
                'an attempt that never finished is reclaimed after 5 minutes');
select tests.eq((select attempts from public.stripe_events where id = 'evt_1'), 2, 'attempts counted');
select public.mark_stripe_event_processed('evt_1', null, '2025-06-01 12:06Z');
select tests.ok((select processed_at = '2025-06-01 12:06Z' and error is null from public.stripe_events where id = 'evt_1'), 'processed');
select tests.eq(public.record_stripe_event('evt_1', 'payment_intent.succeeded', 'acct_123', '2025-07-01Z'), false,
                'processed events are never processed again');
select tests.eq(public.record_stripe_event('evt_2', 'charge.refunded', null, '2025-06-01 12:00Z'), true, 'platform event (no account)');
select public.mark_stripe_event_processed('evt_2', 'payment not found', '2025-06-01 12:00:01Z');
select tests.ok((select processed_at is null and error = 'payment not found' from public.stripe_events where id = 'evt_2'), 'failure recorded');
select tests.eq(public.record_stripe_event('evt_2', 'charge.refunded', null, '2025-06-01 12:01Z'), true, 'a failed event is retried');
select tests.ok((select error is null and attempts = 2 from public.stripe_events where id = 'evt_2'), 'retry clears the error');
select tests.throws($$select public.mark_stripe_event_processed('evt_missing')$$, 'P0002', 'unknown event');
select tests.throws($$select public.record_stripe_event('not-an-event', 'x')$$, '23514', 'event ids are validated');
-- a webhook delivered twice has one effect
do $$
declare
  v_effects integer := 0;
begin
  for i in 1..2 loop
    if public.record_stripe_event('evt_3', 'charge.refunded', null, '2025-06-02 09:00Z') then
      perform public.apply_stripe_refund('pi_late', 100);
      perform public.mark_stripe_event_processed('evt_3', null, '2025-06-02 09:00Z');
      v_effects := v_effects + 1;
    end if;
  end loop;
  perform tests.eq(v_effects, 1, 'the second delivery is skipped');
end
$$;
select tests.eq(pg_temp.pay('pi_late'), 'refunded/100/0/100', 'refund applied once');
select tests.eq(pg_temp.bal(tests.fx('inv3')), 'paid/4000/4000/0/0', 'invoice reflects the refund once');

-- ------------------------------------------------------------ paid_at = the settling payment, ignoring refunded ones
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_pa', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Coating prep","unit_price_cents":1000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_pa'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pa1', 'succeeded', 500, p_invoice_id => tests.fx('inv_pa'), p_paid_at => '2025-06-05Z');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pa2', 'succeeded', 500, p_invoice_id => tests.fx('inv_pa'), p_paid_at => '2025-06-10Z');
select tests.eq((select concat_ws('/', status, paid_at) from public.invoices where id = tests.fx('inv_pa')), 'paid/2025-06-10 00:00:00+00',
                'paid_at is when the last payment arrived');
select public.apply_stripe_refund('pi_pa2', 500);
select tests.eq((select concat_ws('/', status, paid_at) from public.invoices where id = tests.fx('inv_pa')), 'partially_paid',
                'refund reopens and clears paid_at');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pa3', 'succeeded', 500, p_invoice_id => tests.fx('inv_pa'), p_paid_at => '2025-06-07Z');
select tests.eq((select concat_ws('/', status, paid_at) from public.invoices where id = tests.fx('inv_pa')), 'paid/2025-06-07 00:00:00+00',
                'the refunded later payment does not count as the settling payment');
