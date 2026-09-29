-- 100 (0116): voiding an invoice, and cutting its price (line quantity /
-- price / discount / taxable, deleted lines, the invoice's discount or tax
-- rate), wait for its open Stripe pay pages (and the deposit pages of the
-- jobs it bills) like cash does since 0109: 55000 HINT checkout_open, so a
-- page the customer can still pay never lands on a void invoice (moved to
-- the job's replacement invoice: paid twice) or on an invoice cut below the
-- page's amount (overpaid).
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.as_superuser();
select tests.fx_set('line', (select id from public.invoice_line_items where invoice_id = tests.fx('inv') order by sort limit 1));
select tests.eq((select jsonb_build_array(status, total_cents) from public.invoices where id = tests.fx('inv')),
                '["open", 20000]'::jsonb, 'a sent $200 invoice');

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

-- ============================================================ the customer's /i page is open (an invoice hold)
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_v1', now() + interval '35 minutes', 20000);

-- void waits
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('inv'), 'wrong customer')$$, '55000',
                         'a card payment page for this invoice is still open (until %); cancel the open payments first, or wait until then',
                         'the owner cannot void an invoice whose pay page is open');
select tests.eq(pg_temp.hint_of($$select public.void_invoice(tests.fx('inv'))$$), 'checkout_open',
                'HINT checkout_open (the apps cancel the open payments, then retry)');

-- price cuts wait
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 12000 where id = tests.fx('line')$$, '55000',
                         '%still open%', 'a line''s price cannot be cut while the page is open');
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set quantity = 0.5 where id = tests.fx('line')$$), 'checkout_open',
                'nor its quantity');
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set discount_cents = 5000 where id = tests.fx('line')$$), 'checkout_open',
                'nor its discount');
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set taxable = not taxable where id = tests.fx('line')$$), 'checkout_open',
                'nor whether it is taxed');
select tests.eq(pg_temp.hint_of($$delete from public.invoice_line_items where id = tests.fx('line')$$), 'checkout_open',
                'a line cannot be deleted');
select tests.eq(pg_temp.hint_of($$update public.invoices set discount_kind = 'fixed', discount_value = 5000 where id = tests.fx('inv')$$),
                'checkout_open', 'nor can the invoice''s discount change');
select tests.eq(pg_temp.hint_of($$update public.invoices set tax_rate_bps = 100 where id = tests.fx('inv')$$),
                'checkout_open', 'nor its tax rate');
-- what cannot lower the balance still works
select tests.eq(tests.row_count($$update public.invoice_line_items set name = 'Full Detail (interior + exterior)', sort = 1
                                   where id = tests.fx('line')$$), 1::bigint, 'renaming a line is fine');
select tests.eq(tests.row_count($$update public.invoices set notes = 'Thanks!' where id = tests.fx('inv')$$), 1::bigint,
                'so are the invoice''s notes');
select tests.lives($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents)
                     values (tests.fx('shop_a'), tests.fx('inv'), 'Tire shine', 1500)$$, 'and adding a line (it only raises the total)');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(status, total_cents, balance_cents) from public.invoices where id = tests.fx('inv')),
                '["open", 21500, 21500]'::jsonb, 'the invoice still owes at least what the page charges');
-- also in trusted contexts (a direct session, the edge)
select tests.as_superuser();
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set unit_price_cents = 100 where id = tests.fx('line')$$),
                'checkout_open', 'nor cut a line from a direct session');
select tests.eq((select jsonb_build_array(status, total_cents) from public.invoices where id = tests.fx('inv')),
                '["open", 21500]'::jsonb, 'nothing changed');

-- ============================================================ an expired page no longer blocks
select tests.as_superuser();
update public.invoice_checkout_holds set expires_at = now() - interval '1 second' where stripe_checkout_session_id = 'cs_test_v1';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.invoice_line_items where invoice_id = tests.fx('inv') and name = 'Tire shine'$$),
                1::bigint, 'a line can be deleted once the page expired');

-- ============================================================ a deposit page of the invoice's job (a job hold)
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_v2', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.hint_of($$select public.void_invoice(tests.fx('inv'))$$), 'checkout_open',
                'a job''s open deposit / pay page blocks the void as well');
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set unit_price_cents = 15000 where id = tests.fx('line')$$),
                'checkout_open', 'and the price cut');

-- the edge's cancel_open_payments expires the pages and releases the holds: then void works
select tests.as_service();
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'), array['cs_test_v2']), 1, 'released');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.void_invoice(tests.fx('inv'), 'wrong price')$$, 'void once no page is open');
-- a void invoice never takes a new hold, so it cannot be paid later
select tests.as_service();
select tests.eq(pg_temp.hint_of($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_v3',
                                                                               now() + interval '35 minutes')$$),
                'invoice_closed', 'a void invoice is not held (the edge expires its page)');

-- ============================================================ the replacement invoice: its edits wait for the job's page too
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.job_line_items set unit_price_cents = 15000 where job_id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.as_superuser();
select tests.fx_set('line2', (select id from public.invoice_line_items where invoice_id = tests.fx('inv2') order by sort limit 1));
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_v4', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.hint_of($$update public.invoice_line_items set unit_price_cents = 1000 where id = tests.fx('line2')$$),
                'checkout_open', 'the new invoice''s price cannot be cut below the job''s open page either');
-- deleting the invoice itself cascades past the line check
select tests.as_superuser();
select tests.lives($$delete from public.invoices where id = tests.fx('inv2')$$, 'the invoice itself can still be deleted');
select tests.eq((select count(*) from public.invoice_line_items where invoice_id = tests.fx('inv2')), 0::bigint, 'with its lines');

-- another shop sees nothing
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.void_invoice(tests.fx('inv'))$$, 'P0002', 'another shop cannot probe the invoice');

-- ============================================================ deleting the shop (payments delete_shop) is not blocked by a hold
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv3', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv3'));
select tests.as_service();
select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv3'), 'cs_test_v5', now() + interval '35 minutes');
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_a')$$), 1::bigint,
                'the shop''s invoices and their lines cascade past the (already expired by the edge) holds');
