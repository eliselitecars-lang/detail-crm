-- 90 integration: set_stripe_refund_total (compare-and-set of a card
-- payment's cumulative refund, which may also go down when a refund fails)
-- and apply_stripe_dispute (lost / reversed card disputes on
-- payments.disputed_cents, informational: balances and revenue unchanged),
-- plus report_payments.disputes_lost_cents. service_role only.
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Coating","unit_price_cents":50000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_r1', 'succeeded', 50000, 5000, 'payment', 'card', tests.fx('inv'),
                                    p_charge_id => 'ch_r1', p_paid_at => '2025-06-10 15:00Z');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pend', 'pending', 1000, 0, 'payment', 'card', p_customer_id => tests.fx('cust_a2'));
select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_b', 'succeeded', 3000, 0, 'payment', 'card', p_customer_id => tests.fx('cust_b'),
                                    p_paid_at => '2025-06-10 15:00Z');

create function pg_temp.pay(p_pi text) returns text language sql as $$
  select concat_ws('/', status, refunded_cents, disputed_cents) from public.payments where stripe_payment_intent_id = p_pi
$$;
create function pg_temp.inv() returns text language sql as $$
  select concat_ws('/', status, amount_paid_cents, balance_cents, tip_cents) from public.invoices where id = tests.fx('inv')
$$;
grant execute on function pg_temp.pay(text), pg_temp.inv() to service_role;
select tests.eq(pg_temp.inv(), 'paid/50000/0/5000', 'paid in full with a 5000 tip');

-- ============================================================ set_stripe_refund_total
select tests.eq((select concat_ws('/', status, refunded_cents)
                   from public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 20000)), 'partially_refunded/20000',
                'a refund total is set when the expected total matches');
select tests.eq(pg_temp.inv(), 'partially_paid/30000/20000/5000', 'the invoice balance follows');
select tests.throws_like($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 25000)$$, '40001',
                         'refund total changed concurrently', 'a stale expected total is a serialization failure (Stripe redelivers)');
select tests.eq(pg_temp.pay('pi_r1'), 'partially_refunded/20000/0', 'and changes nothing');
-- a refund that failed at Stripe lowers the total again
select tests.eq((select concat_ws('/', status, refunded_cents)
                   from public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 20000, 5000)), 'partially_refunded/5000',
                'lowering is allowed');
select tests.eq(pg_temp.inv(), 'partially_paid/45000/5000/5000', 'money is back on the invoice');
select tests.eq((select concat_ws('/', status, refunded_cents)
                   from public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 5000, 0)), 'succeeded/0',
                'down to zero: succeeded again');
select tests.eq((select concat_ws('/', status, refunded_cents)
                   from public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 0)), 'succeeded/0', 'idempotent');
select tests.eq((select concat_ws('/', status, refunded_cents)
                   from public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 55000)), 'refunded/55000',
                'the whole charge (amount + tip) can be refunded');
select tests.eq(pg_temp.inv(), 'open/0/50000/0', 'a fully refunded payment reopens the invoice; its tip is gone too');
select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 55000, 0);
-- validation
select tests.throws_like($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 55001)$$, '22023',
                         '%between 0 and the charged amount%', 'not more than amount + tip');
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, -1)$$, '22023', 'not negative');
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, null)$$, '22023', 'a total is required');
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', null, 100)$$, '22023', 'an expected total is required');
select tests.throws_like($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_pend', 0, 100)$$, '22023', '%pending payment%',
                         'only received payments have refunds');
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_missing', 0, 100)$$, 'P0002', 'unknown intent');
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_b'), 'pi_r1', 0, 100)$$, 'P0002',
                    'another shop''s intent is not found');
select tests.eq(pg_temp.pay('pi_r1'), 'succeeded/0/0', 'refused calls changed nothing');

-- ============================================================ apply_stripe_dispute
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'needs_response', 55000)), 0::bigint,
                'an open dispute changes nothing');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', 30000)), 30000::bigint,
                'a lost dispute records the amount taken back');
select tests.eq(pg_temp.inv(), 'paid/50000/0/5000', 'balances and paid amounts are NOT changed (staff decide whether to re-bill)');
select tests.eq((select public.payment_net_amount(status, amount_cents, tip_cents, refunded_cents) from public.payments
                  where stripe_payment_intent_id = 'pi_r1'), 50000::bigint, 'net amount unchanged');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', 30000)), 30000::bigint,
                'replays are idempotent');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'funds_reinstated', 30000)), 0::bigint,
                'reinstated funds clear it');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', ' LOST ', 30000)), 30000::bigint,
                'status is case-insensitive');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'won', 30000)), 0::bigint, 'won clears it');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', 1)), 1::bigint, 'set again');
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'warning_closed', 0)), 0::bigint,
                'a closed inquiry clears it');
-- capped at what is left of the charge after refunds
select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 40000);
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', 55000)), 15000::bigint,
                'a lost dispute is capped at the charge minus refunds (55000 - 40000)');
select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 40000, 0);
select tests.eq((select disputed_cents from public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', 20000)), 20000::bigint,
                'no refunds: the disputed amount as reported');
-- validation
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', null)$$, '22023', 'a lost dispute needs an amount');
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'lost', -5)$$, '22023', 'not negative');
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', '  ', 5)$$, '22023', 'a status is required');
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_missing', 'lost', 5)$$, 'P0002', 'unknown intent');
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_b'), 'pi_r1', 'lost', 5)$$, 'P0002', 'another shop''s intent');
select tests.eq(pg_temp.pay('pi_r1'), 'succeeded/0/20000', 'refused calls changed nothing');
-- the table bound holds for every writer
select tests.as_superuser();
select tests.throws($$update public.payments set disputed_cents = 55001 where stripe_payment_intent_id = 'pi_r1'$$, '23514',
                    'disputed_cents <= amount + tip');
select tests.throws($$update public.payments set disputed_cents = -1 where stripe_payment_intent_id = 'pi_r1'$$, '23514', 'not negative');

-- ============================================================ report_payments: lost disputes per method
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_build_array(net_cents, disputes_lost_cents) from public.report_payments(tests.fx('shop_a'), '2025-06-01', '2025-06-30')
                  where method = 'card'), '[50000, 20000]'::jsonb, 'the report shows lost disputes next to (unchanged) net revenue');
select tests.eq((select sum(disputes_lost_cents) from public.report_payments(tests.fx('shop_a'), '2025-06-01', '2025-06-30')
                  where method <> 'card'), 0::numeric, 'other methods have none');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select sum(disputes_lost_cents) from public.report_payments(tests.fx('shop_b'), '2025-06-01', '2025-06-30')), 0::numeric,
                'shop B sees only its own');
select tests.ok((select disputed_cents = 20000 from public.payments where stripe_payment_intent_id = 'pi_r1') is null,
                'shop B cannot read shop A''s payment');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select disputed_cents from public.payments where stripe_payment_intent_id = 'pi_r1'), 20000::bigint,
                'managers read disputed_cents like the other payment columns');

-- ============================================================ service_role only
select tests.throws($$select public.set_stripe_refund_total(tests.fx('shop_a'), 'pi_r1', 0, 0)$$, '42501', 'staff cannot set refund totals');
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'won', 0)$$, '42501', 'staff cannot record disputes');
select tests.as_anon();
select tests.throws($$select public.apply_stripe_dispute(tests.fx('shop_a'), 'pi_r1', 'won', 0)$$, '42501', 'anon cannot');
