-- 100 (0109): cash, checks, gift cards and store credit wait for the
-- invoice's open Stripe pay pages (and the deposit pages of the jobs it
-- bills): while one can still be paid they fail with 55000 HINT
-- checkout_open, so the customer can never pay the same balance twice.
-- invoice_checkout_holds covers pay links the job holds do not (completed
-- jobs, grouped invoices); holds are released by the edge, by a completed
-- session, or by expiring.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.fx_set('credit', (public.issue_gift_card(tests.fx('shop_a'), 3000, '{}', null, 'credit', tests.fx('cust_a')) ->> 'gift_card_id')::uuid);
select public.issue_gift_card(tests.fx('shop_a'), 3000) ->> 'code' as gift_code \gset
select set_config('x.gift_code', :'gift_code', false);
select tests.as_superuser();
select tests.fx_set('inv_tok', (select public_token from public.invoices where id = tests.fx('inv')));

-- the hold RPCs are the edge's
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_x', now() + interval '1 hour')$$,
                    '42501', 'staff cannot hold');
select tests.throws($$select public.payments_release_invoice_checkouts(tests.fx('shop_a'), tests.fx('inv'))$$, '42501', 'nor release');
select tests.as_anon();
select tests.throws($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_x', now() + interval '1 hour')$$,
                    '42501', 'anon cannot hold');

-- ============================================================ the /i page of an open job (a job hold, 0106)
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_inv1', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 20000, 'cash')$$, '55000',
                         'a card payment page for this invoice is still open (until %); cancel the open payments first, or wait until then',
                         'cash waits for the open pay page');
select tests.throws_like($$select public.redeem_customer_credit(tests.fx('inv'), tests.fx('credit'))$$, '55000', '%still open%',
                         'so does store credit');
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv'), current_setting('x.gift_code'))$$, '55000', '%still open%',
                         'and a gift card');
select tests.as_anon();
select tests.throws_like($$select public.public_redeem_gift_card(tests.fx('inv_tok'), current_setting('x.gift_code'))$$, '55000',
                         '%still open%', 'also on /i itself');
-- the hint lets the apps tell this apart (they cancel the open payments, then retry)
select tests.authenticate_as(tests.fx('u_manager_a'));
create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end
$$;
select tests.eq(pg_temp.hint_of($$select public.record_manual_payment(tests.fx('inv'), 20000, 'cash')$$), 'checkout_open', 'HINT checkout_open');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(status, amount_paid_cents) from public.invoices where id = tests.fx('inv')),
                '["open", 0]'::jsonb, 'nothing was recorded');

-- the edge expires the session and releases it (cancel_open_payments): cash goes through
select tests.as_service();
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'), array['cs_test_inv1']), 1, 'released');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 5000, 'cash')$$, 'cash once no page is open');

-- ============================================================ invoice holds (completed jobs, grouped invoices)
select tests.as_service();
select tests.lives($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv2',
                                                                 now() + interval '35 minutes', 15000)$$, 'the edge holds the /i link');
select tests.lives($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv2',
                                                                 now() + interval '30 minutes', 15000)$$, 'idempotent per session');
select tests.throws_like($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_inv3', now() + interval '1 hour')$$,
                         'P0002', '%invoice not found%', 'unknown invoice');
select tests.throws_like($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'pi_nope', now() + interval '1 hour')$$,
                         '22023', '%invalid Checkout Session%', 'session id format');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 1000, 'check')$$, '55000', '%still open%',
                         'an invoice hold blocks manual payments too');
-- a hold for a session with a stale amount (more than is still due) is refused
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv4',
                                                                               now() + interval '35 minutes', 20000)$$),
                'balance_changed', 'a pay link for more than is due is not held (the edge expires it)');
-- releasing by session through the job (the edge's cancel_open_payments) also releases the invoice hold
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'), array['cs_test_inv2']), 0,
                'no job hold of that session');
select tests.eq((select count(*) from public.invoice_checkout_holds where invoice_id = tests.fx('inv')), 0::bigint,
                'but its invoice hold is gone');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 1000, 'check')$$, 'manual payment again');

-- a completed session releases its hold by itself
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv5', now() + interval '35 minutes', 14000);
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_testDone1', 'succeeded', 4000, 0, 'payment', 'card',
        tests.fx('inv'), tests.fx('job_a'), tests.fx('cust_a'), null, 'ch_testDone1', 'cs_test_inv5');
select tests.eq((select count(*) from public.invoice_checkout_holds where invoice_id = tests.fx('inv')), 0::bigint,
                'a paid session no longer holds the invoice');
-- an expired session never blocks
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv6', now() - interval '1 minute');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.redeem_customer_credit(tests.fx('inv'), tests.fx('credit'))$$, 'an expired page does not block');
select tests.as_service();
select tests.eq(public.payments_release_invoice_checkouts(tests.fx('shop_a'), tests.fx('inv')), 1, 'release all of an invoice''s holds');

-- a paid invoice takes no new hold
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('inv'), (select balance_cents from public.invoices where id = tests.fx('inv')), 'cash');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_inv7',
                                                                               now() + interval '35 minutes')$$),
                'invoice_closed', 'a paid invoice is not held (the edge expires the page)');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('inv')),
                '["paid", 20000, 20000, 0]'::jsonb, 'never overpaid');

-- ============================================================ a deposit page of a job on a grouped invoice
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end, deposit_required_cents)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '3 days', now() + interval '3 days 2 hours', 5000),
         (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '4 days', now() + interval '4 days 2 hours', 0);
select tests.fx_set('job_g1', (select id from public.jobs where customer_id = tests.fx('cust_a') and scheduled_start = now() + interval '3 days'));
select tests.fx_set('job_g2', (select id from public.jobs where customer_id = tests.fx('cust_a') and scheduled_start = now() + interval '4 days'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_g1'), tests.fx('svc_a'), 'Full Detail', 20000),
         (tests.fx('shop_a'), tests.fx('job_g2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_g', (public.create_invoice_from_jobs(tests.fx('cust_a'), array[tests.fx('job_g1'), tests.fx('job_g2')])).id);
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_g1'), 'cs_test_dep1', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv_g'), 40000, 'cash')$$, '55000', '%still open%',
                         'an open deposit page of a billed job blocks the grouped invoice''s cash');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.record_manual_payment(tests.fx('inv_g'), 40000, 'cash')$$, 'P0002', 'another shop still sees nothing');
