-- 110 (0118): a job's price and deposit wait for its open deposit pages; a
-- deposit page is held only while the deposit is still due (re-checked under
-- the job's invoice lock); an invoice line's discount eligibility waits like
-- its price. Each is an overpayment the customer's still-open Stripe page
-- (it charges what it was opened for) would otherwise cause.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare v_hint text; v_state text; v_msg text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint, v_state = returned_sqlstate, v_msg = message_text;
  return case when v_state = '55000' and v_hint <> '' then v_hint else v_state || ': ' || v_msg end;
end
$$;

select tests.as_superuser();
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
-- the shop takes full prepayment online
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 10000
 where shop_id = tests.fx('shop_a');

-- ============================================================ 1. the job side (repro: prepaid booking, price cut while the page is open)
select tests.as_service();
select tests.fx_set('tok', (public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z') ->> 'job_token')::uuid);
select tests.as_superuser();
select tests.fx_set('job', (select id from public.jobs where public_token = tests.fx('tok')));
select tests.fx_set('jline', (select id from public.job_line_items where job_id = tests.fx('job') order by sort, id limit 1));
select tests.eq((select jsonb_build_array(total_cents, deposit_required_cents) from public.jobs where id = tests.fx('job')),
                '[22000, 22000]'::jsonb, 'a $220 booking, fully prepaid online');

-- the customer opens Pay deposit: the edge holds the page
select tests.as_service();
select tests.lives($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job'), 'cs_test_dep1',
                                                             now() + interval '32 minutes', 22000)$$,
                   'the deposit page is held (the full deposit is due)');

-- a manager corrects the job while the page is open: every price cut waits
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.job_line_items set unit_price_cents = 5000 where id = tests.fx('jline')$$, '55000',
                         'a card payment page for this job is still open (until %); cancel the open payments first, or wait until then',
                         'a line''s price cannot be cut while the deposit page is open');
select tests.eq(pg_temp.hint_of($$update public.job_line_items set unit_price_cents = 5000 where id = tests.fx('jline')$$),
                'checkout_open', 'HINT checkout_open (the apps cancel the open payments, then retry)');
select tests.eq(pg_temp.hint_of($$update public.job_line_items set quantity = 0.5 where id = tests.fx('jline')$$),
                'checkout_open', 'nor its quantity');
select tests.eq(pg_temp.hint_of($$update public.job_line_items set discount_cents = 1000 where id = tests.fx('jline')$$),
                'checkout_open', 'nor its discount');
select tests.eq(pg_temp.hint_of($$update public.job_line_items set taxable = false where id = tests.fx('jline')$$),
                'checkout_open', 'nor whether it is taxed');
select tests.eq(pg_temp.hint_of($$delete from public.job_line_items where id = tests.fx('jline')$$),
                'checkout_open', 'a line cannot be deleted');
select tests.eq(pg_temp.hint_of($$update public.jobs set discount_kind = 'fixed', discount_value = 1000 where id = tests.fx('job')$$),
                'checkout_open', 'nor can the job get a discount');
select tests.eq(pg_temp.hint_of($$update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job')$$),
                'checkout_open', 'or a coupon');
select tests.eq(pg_temp.hint_of($$update public.jobs set tax_rate_bps = 0 where id = tests.fx('job')$$),
                'checkout_open', 'or a lower tax rate');
select tests.eq(pg_temp.hint_of($$update public.jobs set deposit_required_cents = 0 where id = tests.fx('job')$$),
                'checkout_open', 'and the deposit cannot be waived');
select tests.eq(pg_temp.hint_of($$update public.jobs set deposit_required_cents = 10000 where id = tests.fx('job')$$),
                'checkout_open', 'or lowered');
-- what cannot lower the total or the deposit still works
select tests.eq(tests.row_count($$update public.job_line_items set name = 'Full Detail (interior + exterior)', sort = 5
                                   where id = tests.fx('jline')$$), 1::bigint, 'renaming a line is fine');
select tests.eq(tests.row_count($$update public.jobs set notes = 'Gate code 1234' where id = tests.fx('job')$$), 1::bigint,
                'so are the job''s notes');
select tests.lives($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
                     values (tests.fx('shop_a'), tests.fx('job'), 'Tire shine', 1500)$$,
                   'and adding a line (it only raises the total)');
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 2000
                                   where job_id = tests.fx('job') and name = 'Tire shine'$$), 1::bigint,
                'raising a price is fine too');
-- also in trusted contexts (a direct session, server code)
select tests.as_superuser();
select tests.eq(pg_temp.hint_of($$update public.job_line_items set unit_price_cents = 100 where id = tests.fx('jline')$$),
                'checkout_open', 'nor cut from a direct session');
select tests.eq((select jsonb_build_array(total_cents, deposit_required_cents) from public.jobs where id = tests.fx('job')),
                '[24200, 22000]'::jsonb, 'the job still owes at least what the page charges');

-- the customer pays the page: the job is not overpaid
select tests.as_service();
select tests.eq((public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 22000, 0, 'deposit', 'card',
                                             null, tests.fx('job'), null, null, 'ch_1', 'cs_test_dep1', 'visa', '4242',
                                             '2025-06-01 12:06Z')).status::text, 'succeeded', 'the deposit is paid');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select jsonb_build_array(s.total_cents, s.paid_cents, s.balance_cents) from public.job_payment_summary(tests.fx('job')) s),
                '[24200, 22000, 2200]'::jsonb, 'no negative balance');
-- the paid page released its hold: the price can be corrected now (a refund is the staff's call)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.job_line_items where job_id = tests.fx('job') and name = 'Tire shine'$$),
                1::bigint, 'with no page open, lines can be deleted again');

-- an expired page no longer blocks
select tests.as_superuser();
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_a');
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_a1', now() + interval '32 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.hint_of($$update public.jobs set deposit_required_cents = 0 where id = tests.fx('job_a')$$),
                'checkout_open', 'job A''s deposit waits for its page');
select tests.as_superuser();
update public.job_checkout_holds set expires_at = now() - interval '1 second' where stripe_checkout_session_id = 'cs_test_a1';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.jobs set deposit_required_cents = 1000 where id = tests.fx('job_a')$$), 1::bigint,
                'the deposit can be lowered once the page expired');
-- a released page (cancel_open_payments) no longer blocks either
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_a2', now() + interval '32 minutes');
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'), array['cs_test_a2']), 1, 'released');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 15000 where id = tests.fx('line_a')$$), 1::bigint,
                'and the price can be cut once the page was cancelled');
-- another job's page does not block this one
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_a3', now() + interval '32 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.jobs set discount_kind = 'fixed', discount_value = 500 where id = tests.fx('job_a2')$$),
                1::bigint, 'job A2 has no open page');
select tests.as_superuser();
delete from public.job_checkout_holds where job_id = tests.fx('job_a');

-- ============================================================ 2. the deposit hold re-checks what is due (repro: cash meanwhile)
select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
update public.jobs set tax_rate_bps = 0, discount_kind = 'none', discount_value = 0, deposit_required_cents = 5000
 where id = tests.fx('job_a');
update public.job_line_items set unit_price_cents = 20000 where id = tests.fx('line_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.eq((select jsonb_build_array(s.deposit_due_cents, s.balance_cents) from public.job_payment_summary(tests.fx('job_a')) s),
                '[5000, 20000]'::jsonb, 't0: the edge reads $50 deposit due on a $200 invoice');
-- while the edge creates the Stripe session (no hold yet), staff take cash for the whole balance
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.record_manual_payment(tests.fx('inv'), 20000, 'cash')).status::text, 'succeeded', 'cash for the balance');
-- t1: the hold now refuses (the edge expires the session instead of handing out its URL)
select tests.as_service();
select tests.throws_like($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep2',
                                                                   now() + interval '32 minutes', 5000)$$,
                         '55000', 'no deposit is due for this booking any more', 'the deposit page is not held');
select tests.eq(pg_temp.hint_of($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep2',
                                                                          now() + interval '32 minutes')$$),
                'deposit_not_due', 'HINT deposit_not_due (also without the amount)');
select tests.eq((select count(*) from public.job_checkout_holds where job_id = tests.fx('job_a')), 0::bigint, 'no hold recorded');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('inv')),
                '["paid", 20000, 20000, 0]'::jsonb, 'the invoice is paid once, not overpaid');

-- partial payment: the page's amount must still fit what is left
select tests.as_superuser();
update public.jobs set tax_rate_bps = 0, discount_kind = 'none', discount_value = 0, deposit_required_cents = 5000 where id = tests.fx('job_a2');
delete from public.job_line_items where job_id = tests.fx('job_a2');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Full Detail', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select public.mark_invoice_sent(tests.fx('inv2'));
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv2')), 20000::bigint, 'a $200 invoice for job A2');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('inv2'), 18000, 'check');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a2'), 'cs_test_dep3',
                                                                          now() + interval '32 minutes', 5000)$$),
                'deposit_not_due', 'the check covered the deposit: nothing is due');
select tests.as_superuser();
update public.jobs set deposit_required_cents = 20000 where id = tests.fx('job_a2');
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a2'), 'cs_test_dep3',
                                                                          now() + interval '32 minutes', 5000)$$),
                'balance_changed', 'a $50 page when only $20 is left: HINT balance_changed');
select tests.lives($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a2'), 'cs_test_dep3',
                                                             now() + interval '32 minutes', 2000)$$,
                   'a page for what is left is held');
select tests.lives($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a2'), 'cs_test_dep3',
                                                             now() + interval '40 minutes', 2000)$$,
                   'holding the same session again only extends it');
select tests.eq((select count(*) from public.job_checkout_holds where job_id = tests.fx('job_a2')), 1::bigint, 'one hold');
-- the hold is seen by manual money: cash for the rest now waits
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.hint_of($$select public.record_manual_payment(tests.fx('inv2'), 2000, 'cash')$$), 'checkout_open',
                'cash for the rest waits for the held deposit page');
select tests.as_superuser();
delete from public.job_checkout_holds where job_id = tests.fx('job_a2');

-- an /i pay link of the job's invoice (held on the invoice first) is not a deposit page
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv2'), 'cs_test_inv9', now() + interval '32 minutes', 2000);
select tests.lives($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a2'), 'cs_test_inv9',
                                                             now() + interval '32 minutes')$$,
                   'the job hold of an invoice pay link skips the deposit check');
select tests.as_superuser();
delete from public.job_checkout_holds where job_id = tests.fx('job_a2');
delete from public.invoice_checkout_holds where invoice_id = tests.fx('inv2');

-- a closed job is still refused first; the RPC stays the edge's
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep4',
                                                                          now() + interval '32 minutes', 0)$$),
                '22023: amount must be greater than zero', 'a zero amount is refused');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_x',
                                                              now() + interval '1 hour', 1000)$$, '42501', 'staff cannot hold');
select tests.as_anon();
select tests.throws($$select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_x',
                                                              now() + interval '1 hour')$$, '42501', 'nor can anon');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.job_open_checkout_until(tests.fx('shop_a'), tests.fx('job_a'))$$, '42501',
                    'the holds stay internal');

-- ============================================================ 3. an invoice line's discount eligibility (repro)
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, tax_rate_bps)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'scheduled', '2025-07-01 15:00Z', '2025-07-01 16:00Z', 0)
  returning tests.fx_set('job_e', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_e'), 'Coating', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv3', (public.create_invoice_from_job(tests.fx('job_e'))).id);
select tests.as_superuser();
select tests.fx_set('iline', (select id from public.invoice_line_items where invoice_id = tests.fx('inv3') order by sort, id limit 1));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.invoice_line_items set discount_eligible = false where id = tests.fx('iline');
update public.invoices set discount_kind = 'percent', discount_value = 5000 where id = tests.fx('inv3');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.mark_invoice_sent(tests.fx('inv3'));
select tests.as_superuser();
select tests.eq((select jsonb_build_array(status, total_cents) from public.invoices where id = tests.fx('inv3')),
                '["open", 20000]'::jsonb, 'a 50% discount that covers no line: $200 due');
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv3'), 'cs_test_v1', now() + interval '35 minutes', 20000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set discount_eligible = true where id = tests.fx('iline')$$),
                'checkout_open', 'a line cannot be made discount-eligible while the $200 pay page is open');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(total_cents, balance_cents) from public.invoices where id = tests.fx('inv3')),
                '[20000, 20000]'::jsonb, 'nothing changed');
update public.invoice_checkout_holds set expires_at = now() - interval '1 second' where stripe_checkout_session_id = 'cs_test_v1';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.invoice_line_items set discount_eligible = true where id = tests.fx('iline')$$),
                1::bigint, 'it can once the page expired');
select tests.as_superuser();
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv3')), 10000::bigint, 'and the discount applies');
