-- 10 money: Stripe event order for declined attempts.
-- A 'pending' report that lands after a recorded decline (charge_saved_card
-- recording a 'processing' intent after its Stripe call returns, the
-- webhook's Checkout 'unpaid' path) must not reopen the failed row: the
-- decline would count as money in flight again and freeze the invoice
-- (manual payments, voiding, line edits) for up to an hour.
\ir fixtures/two_shops.psql

create function pg_temp.st(p_pi text) returns text language sql as $$
  select status::text from public.payments where stripe_payment_intent_id = p_pi
$$;

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);

-- ------------------------------------------------------------ saved card: decline, then a late pending
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sc1', 'failed', 20000, p_invoice_id => tests.fx('inv'),
                                    p_card_brand => 'visa', p_card_last4 => '4242');
select tests.eq(pg_temp.st('pi_sc1'), 'failed', 'a declined saved-card charge is recorded failed');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sc1', 'pending', 20000, p_invoice_id => tests.fx('inv'));
select tests.eq(pg_temp.st('pi_sc1'), 'failed', 'a late pending report must not reopen a failed charge');
select tests.ok(not public.payment_in_flight('failed', '2025-06-01 12:00Z', '2025-06-01 12:00Z'),
                'a failed row is never money in flight');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_a'))), 0::bigint,
                'the decline is not shown as pending money');
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 20000, 'cash')$$,
                   'cash can pay the balance the failed charge never covered');
select tests.eq((select concat_ws('/', status, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('inv')),
                'paid/20000/0', 'the invoice is paid by the cash alone');

-- ------------------------------------------------------------ Checkout Session: pending, decline, late unpaid
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs1', 'pending', 3000, p_job_id => tests.fx('job_a2'),
                                    p_checkout_session_id => 'cs_test_order1');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs1', 'failed', 3000, p_job_id => tests.fx('job_a2'));
select tests.eq(pg_temp.st('pi_cs1'), 'failed', 'a declined Checkout payment is recorded failed');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs1', 'pending', 3000, p_job_id => tests.fx('job_a2'),
                                    p_checkout_session_id => 'cs_test_order1');
select tests.eq(pg_temp.st('pi_cs1'), 'failed', 'the Checkout unpaid path arriving late keeps it failed');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_a2'))), 0::bigint,
                'nothing in flight on the job');
select tests.as_service();
-- failed still moves on to the states that are real
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs1', 'succeeded', 3000, p_job_id => tests.fx('job_a2'),
                                    p_paid_at => '2025-06-02 10:00Z');
select tests.eq(pg_temp.st('pi_cs1'), 'succeeded', 'money that moved still wins over a recorded decline');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs2', 'failed', 800, p_customer_id => tests.fx('cust_a3'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs2', 'cancelled', 800, p_customer_id => tests.fx('cust_a3'));
select tests.eq(pg_temp.st('pi_cs2'), 'cancelled', 'a failed intent can still be cancelled');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_cs2', 'pending', 800, p_customer_id => tests.fx('cust_a3'));
select tests.eq(pg_temp.st('pi_cs2'), 'cancelled', 'and stays cancelled for a late pending');

-- ------------------------------------------------------------ PaymentSheet decline still stays open
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ps1', 'pending', 900, p_customer_id => tests.fx('cust_a3'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ps1', 'failed', 900, p_customer_id => tests.fx('cust_a3'));
select tests.eq(pg_temp.st('pi_ps1'), 'pending', 'a declined PaymentSheet attempt with no card on record stays open');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ps1', 'pending', 900, p_customer_id => tests.fx('cust_a3'));
select tests.eq(pg_temp.st('pi_ps1'), 'pending', 'and pending replays keep it open');

-- ------------------------------------------------------------ denial: only service_role writes card payments
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sc1', 'pending', 20000, p_invoice_id => tests.fx('inv'))$$,
                    '42501', 'owners cannot report Stripe states');
select tests.as_anon();
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_sc1', 'pending', 20000, p_invoice_id => tests.fx('inv'))$$,
                    '42501', 'anon cannot report Stripe states');

-- ------------------------------------------------------------ cross-shop: another shop's report cannot touch the row
select tests.as_service();
select tests.throws($$select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_cs2', 'pending', 800, p_customer_id => tests.fx('cust_b'))$$,
                    '22023', 'a report for another shop''s intent is refused');
select tests.eq(pg_temp.st('pi_cs2'), 'cancelled', 'the row is unchanged');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select count(*) from public.payments where stripe_payment_intent_id in ('pi_sc1', 'pi_cs1', 'pi_cs2', 'pi_ps1')),
                0::bigint, 'shop B sees none of shop A''s card attempts');
