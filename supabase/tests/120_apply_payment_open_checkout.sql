-- 120 (0121): applying an unapplied payment (or an overpayment) to an
-- invoice waits for the invoice's open card pay pages — its /i page and the
-- deposit pages of the jobs it bills — like cash, checks and gift cards
-- (0109): 55000 HINT checkout_open, so the customer can never pay the same
-- balance twice. Once the edge releases the page it goes through.
\ir fixtures/two_shops.psql

create function pg_temp.inv(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;
create function pg_temp.pay(p_pi text) returns public.payments language sql as $$
  select * from public.payments where stripe_payment_intent_id = p_pi
$$;
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

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);

-- ============================================================ the repro: unapplied money, an open /i page
-- a late card payment on a void invoice is unapplied money of cust_a3
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv1', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')));
select public.mark_invoice_sent(tests.fx('inv1'));
select public.void_invoice(tests.fx('inv1'), 'wrong amount');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_late', 'succeeded', 10000, 0, 'payment', 'card', tests.fx('inv1'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Fleet wash","unit_price_cents":10000}]')));
select public.mark_invoice_sent(tests.fx('inv2'));

-- the customer opens the replacement invoice's pay page
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv2'), 'cs_test_open', now() + interval '35 minutes', 10000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv2'), 10000, 'cash')$$, '55000', '%still open%',
                         'cash waits for the open page (0109)');
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv2'))$$, '55000',
                         'a card payment page for this invoice is still open (until %); cancel the open payments first, or wait until then',
                         'so does applying the unapplied payment');
select tests.eq(pg_temp.hint_of($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv2'))$$),
                'checkout_open', 'HINT checkout_open (the apps offer cancel open payments)');
select tests.ok((select invoice_id is null from pg_temp.pay('pi_late')), 'the payment stays unapplied');
select tests.eq(pg_temp.inv(tests.fx('inv2')), 'open/0/10000', 'the invoice still owes the page''s amount');

-- the customer pays the page: exactly paid, no overpayment
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_page', 'succeeded', 10000, 0, 'payment', 'card', tests.fx('inv2'),
                                    p_checkout_session_id => 'cs_test_open');
select tests.eq(pg_temp.inv(tests.fx('inv2')), 'paid/10000/0', 'paid once');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv2'))$$, '22023',
                         '%is paid and cannot take payments%', 'nothing left to apply to');

-- ============================================================ released page: applying goes through
select tests.fx_set('inv3', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Interior","unit_price_cents":10000}]')));
select public.mark_invoice_sent(tests.fx('inv3'));
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv3'), 'cs_test_inv3', now() + interval '35 minutes', 10000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv3'))$$, '55000',
                         '%still open%', 'a manager is refused too');
select tests.as_service();
select tests.eq(public.payments_release_invoice_checkouts(tests.fx('shop_a'), tests.fx('inv3')), 1, 'the edge expires and releases it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_late')).id, tests.fx('inv3'))$$,
                   'applied once no page is open');
select tests.eq(pg_temp.inv(tests.fx('inv3')), 'paid/10000/0', 'the invoice is paid by the applied money');

-- an expired hold does not block (wall clock)
select tests.fx_set('inv4', (select id from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Wax","unit_price_cents":5000}]')));
select public.mark_invoice_sent(tests.fx('inv4'));
select tests.as_superuser();
insert into public.invoice_checkout_holds (shop_id, invoice_id, stripe_checkout_session_id, expires_at)
values (tests.fx('shop_a'), tests.fx('inv4'), 'cs_test_old', now() - interval '1 minute');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_extra1', 'succeeded', 5000, 0, 'payment', 'card', tests.fx('inv3'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_extra1')).id, tests.fx('inv4'))$$,
                   'an overpayment moves while the old page is expired');
select tests.eq(concat_ws(' ', pg_temp.inv(tests.fx('inv3')), pg_temp.inv(tests.fx('inv4'))), 'paid/10000/0 paid/5000/0',
                'the surplus paid the other invoice');

-- ============================================================ a deposit page of a job the invoice bills
-- cust_a: unapplied money (a late payment on a void invoice) and job_a's invoice
select tests.fx_set('inv_v', (select id from public.create_invoice(tests.fx('cust_a'), '[{"name":"Tint","unit_price_cents":5000}]')));
select public.mark_invoice_sent(tests.fx('inv_v'));
select public.void_invoice(tests.fx('inv_v'), 'duplicate');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_lateA', 'succeeded', 5000, 0, 'payment', 'card', tests.fx('inv_v'));
select tests.as_superuser();
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv5', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv5'));
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.apply_payment_to_invoice((pg_temp.pay('pi_lateA')).id, tests.fx('inv5'))$$, '55000',
                         '%still open%', 'the job''s open deposit page blocks it as well');
select tests.as_service();
select public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.apply_payment_to_invoice((pg_temp.pay('pi_lateA')).id, tests.fx('inv5'))$$,
                   'and goes through once it is released');
