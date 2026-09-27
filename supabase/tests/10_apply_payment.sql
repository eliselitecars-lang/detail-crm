-- 10 money: apply_payment_to_invoice — money that is not paying anything
-- (received for a void invoice, for a deleted document, or an overpayment)
-- can be put on another of the customer's invoices, so the customer never
-- owes it twice.
\ir fixtures/two_shops.psql

create function pg_temp.inv(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, amount_paid_cents, balance_cents, tip_cents) from public.invoices where id = p_id
$$;
create function pg_temp.pay(p_pi text) returns public.payments language sql as $$
  select * from public.payments where stripe_payment_intent_id = p_pi
$$;

-- ============================================================ the repro: late payment for a void invoice
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv1', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')));
select public.mark_invoice_sent(tests.fx('inv1'));
select public.void_invoice(tests.fx('inv1'), 'wrong amount');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late', 'succeeded', 10000, 500, 'payment', 'card', tests.fx('inv1'));
select tests.ok((select note like 'Received for void invoice #%apply it to another invoice or refund it' from public.payments where stripe_payment_intent_id = 'pi_late'),
                'staff are told to apply it');
select tests.ok((select invoice_id is null and job_id is null and customer_id = tests.fx('cust_a3') from pg_temp.pay('pi_late')),
                'it is an unapplied payment of the customer');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')));
select public.mark_invoice_sent(tests.fx('inv2'));
select tests.throws($$update public.payments set invoice_id = tests.fx('inv2') where stripe_payment_intent_id = 'pi_late'$$, '42501',
                    'payments stay read-only for direct writes');
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv2'))$$,
                   'owner applies the unapplied payment to the replacement invoice');
select tests.eq(pg_temp.inv(tests.fx('inv2')), 'paid/10000/0/500', 'the customer does not owe the money twice (the tip follows, never counts)');
select tests.ok((select invoice_id = tests.fx('inv2') and job_id is null and kind = 'payment'
                        and note like E'Received for void invoice #%\nApplied to invoice #' || (select number from public.invoices where id = tests.fx('inv2'))
                   from pg_temp.pay('pi_late')),
                'the payment now pays the invoice and its note records where it went');
select tests.eq(pg_temp.inv(tests.fx('inv1')), 'void/0/10000/0', 'the void invoice is untouched');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv2'))$$, '22023', '%already applied%',
                         'applying twice is refused');

-- a later Stripe refund reopens the invoice it was applied to
select tests.as_service();
select public.apply_stripe_refund('pi_late', 4000);
select tests.eq(pg_temp.inv(tests.fx('inv2')), 'partially_paid/6000/4000/500', 'refunds follow the applied payment');

-- ============================================================ overpayment credit (two links paid for one invoice)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_x', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Interior","unit_price_cents":8000}]')));
select public.mark_invoice_sent(tests.fx('inv_x'));
select tests.fx_set('inv_y', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Exterior","unit_price_cents":9000}]')));
select public.mark_invoice_sent(tests.fx('inv_y'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x1', 'succeeded', 8000, 0, 'payment', 'card', tests.fx('inv_x'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_x2', 'succeeded', 8000, 0, 'payment', 'card', tests.fx('inv_x'));
select tests.eq(pg_temp.inv(tests.fx('inv_x')), 'paid/16000/-8000/0', 'the invoice is overpaid (a customer credit)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_x2')).id, tests.fx('inv_y'))$$,
                   'a manager moves the surplus payment to the customer''s other invoice');
select tests.eq(concat_ws(' ', pg_temp.inv(tests.fx('inv_x')), pg_temp.inv(tests.fx('inv_y'))), 'paid/8000/0/0 partially_paid/8000/1000/0',
                'the credit is used; the first invoice stays paid');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_x1')).id, tests.fx('inv_y'))$$, '22023', '%needs this payment%',
                         'a payment the invoice needs cannot move');
select tests.eq(pg_temp.inv(tests.fx('inv_x')), 'paid/8000/0/0', 'refused moves change nothing');

-- ============================================================ what cannot be applied
-- more than the balance due
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_big', 'succeeded', 5000, 0, 'payment', 'card', null, null, tests.fx('cust_a3'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_big')).id, tests.fx('inv_y'))$$, '22023', '%exceeds the balance%',
                         'never creates a new overpayment');
-- card payments in flight on the target count
select tests.fx_set('inv_z', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Coating","unit_price_cents":9000}]')));
select public.mark_invoice_sent(tests.fx('inv_z'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sheet', 'pending', 5000, 0, 'payment', 'card', tests.fx('inv_z'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_big')).id, tests.fx('inv_z'))$$, '22023', '%in progress%',
                         'a card payment being confirmed on the target is reserved');
select tests.as_superuser();
update public.payments set created_at = now() - interval '2 hours' where stripe_payment_intent_id = 'pi_sheet';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_big')).id, tests.fx('inv_z'))$$,
                   'an abandoned (1h+) intent no longer reserves the balance');
select tests.eq(pg_temp.inv(tests.fx('inv_z')), 'partially_paid/5000/4000/0', 'applied');

-- not received / nothing left / wrong targets
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_failed', 'failed', 1000, 0, 'payment', 'card', null, null, tests.fx('cust_a3'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tiponly', 'succeeded', 0, 300, 'payment', 'card', null, null, tests.fx('cust_a3'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_refunded', 'succeeded', 1000, 0, 'payment', 'card', null, null, tests.fx('cust_a3'));
select public.apply_stripe_refund('pi_refunded', 1000);
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_small', 'succeeded', 1000, 0, 'deposit', 'card', null, null, tests.fx('cust_a3'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_other', 'succeeded', 1000, 0, 'payment', 'card', null, null, tests.fx('cust_a2'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep', 'succeeded', 1000, 0, 'deposit', 'card', null, tests.fx('job_a2'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_failed')).id, tests.fx('inv_y'))$$, '22023', '%only received%',
                         'failed payments cannot be applied');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_tiponly')).id, tests.fx('inv_y'))$$, '22023', '%nothing%',
                         'a tip alone pays no invoice');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_refunded')).id, tests.fx('inv_y'))$$, '22023', '%only received%',
                         'refunded money cannot be applied');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_other')).id, tests.fx('inv_y'))$$, '22023', '%another customer%',
                         'money stays with the customer who paid it');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_dep')).id, tests.fx('inv_y'))$$, '22023', '%belongs to job%',
                         'a job deposit waiting for its invoice is not unapplied');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_small')).id, tests.fx('inv1'))$$, '22023', '%void%',
                         'not onto a void invoice');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_small')).id, tests.fx('inv_x'))$$, '22023', '%paid%',
                         'not onto a paid invoice');
select tests.fx_set('inv_draft', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Tint","unit_price_cents":3000}]')));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_small')).id, tests.fx('inv_draft'))$$, '22023', '%draft%',
                         'not onto a draft (send it first)');
select tests.eq((select kind::text from pg_temp.pay('pi_small')), 'deposit', 'a deposit whose job no longer exists');
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_small')).id, tests.fx('inv_y'))$$, 'a small unapplied deposit fits');
select tests.eq((select concat_ws('/', kind, invoice_id = tests.fx('inv_y')) from pg_temp.pay('pi_small')), 'payment/t',
                'a moved deposit becomes a plain payment of the invoice');
select tests.eq(pg_temp.inv(tests.fx('inv_y')), 'paid/9000/0/0', 'which settles it');

-- membership payments belong to their membership
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Gold', 1000) returning tests.fx_set('plan', id);
select tests.as_service();
insert into public.memberships (shop_id, plan_id, customer_id, status, stripe_subscription_id)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a3'), 'active', 'sub_1') returning tests.fx_set('mem', id);
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_mem', 'succeeded', 1000, 0, 'membership', 'card', null, null, null, tests.fx('mem'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_mem')).id, tests.fx('inv_z'))$$, '22023', '%membership%',
                         'membership payments cannot be moved onto invoices');

-- ============================================================ roles + isolation
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.as_service();
select tests.fx_set('pay_left', (public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_left', 'succeeded', 1000, 0, 'payment', 'card',
                                                               null, null, tests.fx('cust_a3'))).id);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.apply_payment_to_invoice(tests.fx('pay_left'), tests.fx('inv_z'))$$,
                         '42501', '%owners, admins and managers%', 'technicians cannot apply payments, even when they may collect');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.apply_payment_to_invoice(tests.fx('pay_left'), tests.fx('inv_z'))$$,
                    'P0002', 'another shop''s payment is not found');
select tests.as_superuser();
insert into public.payments (shop_id, customer_id, method, status, amount_cents, paid_at)
  values (tests.fx('shop_b'), tests.fx('cust_b'), 'cash', 'succeeded', 1000, now()) returning tests.fx_set('pay_b', id);
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.apply_payment_to_invoice(tests.fx('pay_b'), tests.fx('inv_z'))$$,
                    'P0002', 'a shop B payment cannot be applied to a shop A invoice');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.apply_payment_to_invoice(tests.fx('pay_left'), tests.fx('pay_b'))$$,
                    'P0002', 'unknown invoice ids are not found');
select tests.as_anon();
select tests.throws($$select public.apply_payment_to_invoice(tests.fx('pay_left'), tests.fx('inv_z'))$$,
                    '42501', 'anon cannot apply payments');
select tests.as_superuser();
select tests.eq(pg_temp.inv(tests.fx('inv_z')), 'partially_paid/5000/4000/0', 'no denied call moved money');
select tests.ok((select invoice_id is null from pg_temp.pay('pi_left')), 'the payment is still unapplied');

-- ============================================================ a failed Stripe refund never puts money back on a void invoice
-- A job-less invoice can be voided once its card payment is fully refunded
-- (net 0); the payment row stays on it. If that refund then fails at Stripe
-- (refund.failed), the webhook lowers refunded_cents again with a direct
-- service_role update — the money is received again and must be re-routed.
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_rf1', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_rf1'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_rf1', 'succeeded', 10000, 0, 'payment', 'card', tests.fx('inv_rf1'));
select public.apply_stripe_refund('pi_rf1', 10000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv_rf1'), 'customer changed mind');
select tests.as_superuser();
select tests.ok((select invoice_id = tests.fx('inv_rf1') from pg_temp.pay('pi_rf1')), 'the refunded payment stays on the void invoice (net 0)');
-- refund.failed: the same write stripe-webhook's reverseRefund makes
select tests.as_service();
select tests.eq(tests.row_count($$update public.payments set refunded_cents = 0, status = 'succeeded'
                                  where stripe_payment_intent_id = 'pi_rf1' and refunded_cents = 10000 and status = 'refunded'$$),
                1::bigint, 'the failed refund is reversed');
select tests.as_superuser();
select tests.ok((select invoice_id is distinct from tests.fx('inv_rf1') from pg_temp.pay('pi_rf1')),
                'money that is received again never sits on a void invoice');
select tests.ok((select invoice_id is null and job_id is null and customer_id = tests.fx('cust_a3')
                        and note like 'Received for void invoice #%apply it to another invoice or refund it'
                   from pg_temp.pay('pi_rf1')),
                'it becomes an unapplied payment of the customer, flagged for staff');
select tests.eq(pg_temp.inv(tests.fx('inv_rf1')), 'void/0/10000/0', 'the void invoice shows no money paid');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_rf2', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_rf2'));
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.apply_payment_to_invoice((select id from public.payments where stripe_payment_intent_id = 'pi_rf1'), tests.fx('inv_rf2'))$$,
                    'P0002', 'another shop cannot apply it');
select tests.eq(tests.row_count($$select 1 from public.payments where stripe_payment_intent_id = 'pi_rf1'$$), 0::bigint, 'nor see it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.apply_payment_to_invoice((select id from public.payments where stripe_payment_intent_id = 'pi_rf1'), tests.fx('inv_rf2'))$$,
                   'the money can be applied to the replacement invoice');
select tests.as_superuser();
select tests.eq(pg_temp.inv(tests.fx('inv_rf2')), 'paid/10000/0/0', 'the replacement invoice is paid by it');

-- a partial refund failing (refunded -> partially_refunded) re-routes too
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_rf3', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":8000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_rf3'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_rf3', 'succeeded', 8000, 1000, 'payment', 'card', tests.fx('inv_rf3'));
select public.apply_stripe_refund('pi_rf3', 5000);
select public.apply_stripe_refund('pi_rf3', 9000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv_rf3'));
select tests.as_service();
update public.payments set refunded_cents = 5000, status = 'partially_refunded'
 where stripe_payment_intent_id = 'pi_rf3' and refunded_cents = 9000 and status = 'refunded';
select tests.as_superuser();
select tests.ok((select invoice_id is null and customer_id = tests.fx('cust_a3') and status = 'partially_refunded' from pg_temp.pay('pi_rf3')),
                'a partly reversed refund leaves the void invoice as well');
select tests.eq(pg_temp.inv(tests.fx('inv_rf3')), 'void/0/8000/0', 'nothing counts as paid on the void invoice');

-- a job payment whose refund fails goes back to its job (and so to the job's next invoice)
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')
  returning tests.fx_set('job_rf', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_rf'), 'Coat', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_rf4', (public.create_invoice_from_job(tests.fx('job_rf'))).id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_rf4', 'succeeded', 20000, 0, 'payment', 'card', tests.fx('inv_rf4'));
select tests.as_superuser();
-- a payment still on a void invoice of its job (a void from before job payments were detached)
update public.invoices set status = 'void', voided_at = now() where id = tests.fx('inv_rf4');
select tests.as_service();
select public.apply_stripe_refund('pi_rf4', 20000);
select tests.as_superuser();
select tests.ok((select invoice_id = tests.fx('inv_rf4') from pg_temp.pay('pi_rf4')), 'a refund (net falling) does not move the payment');
select tests.as_service();
update public.payments set refunded_cents = 0, status = 'succeeded' where stripe_payment_intent_id = 'pi_rf4';
select tests.as_superuser();
select tests.ok((select invoice_id is null and job_id = tests.fx('job_rf') and note is null from pg_temp.pay('pi_rf4')),
                'the reversed refund returns the payment to its job');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select concat_ws('/', status, amount_paid_cents, balance_cents) from public.create_invoice_from_job(tests.fx('job_rf'))),
                'paid/20000/0', 'the job''s replacement invoice picks it up');

-- a failed refund on a live invoice just puts the money back there
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_rf5', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":6000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_rf5'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_rf5', 'succeeded', 6000, 0, 'payment', 'card', tests.fx('inv_rf5'));
select public.apply_stripe_refund('pi_rf5', 6000);
update public.payments set refunded_cents = 0, status = 'succeeded' where stripe_payment_intent_id = 'pi_rf5';
select tests.as_superuser();
select tests.ok((select invoice_id = tests.fx('inv_rf5') and note is null from pg_temp.pay('pi_rf5')), 'it stays on its (non-void) invoice');
select tests.eq(pg_temp.inv(tests.fx('inv_rf5')), 'paid/6000/0/0', 'which is paid again');
