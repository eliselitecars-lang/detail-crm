-- 40 integration: the booking page's deposit block follows the invoice.
-- Regression: booking_public_json capped the deposit by the JOB total while
-- job_payment_summary (0013) caps it by the invoice total once there is
-- one. With an invoice below the deposit (a discount at invoicing, edited
-- lines) paid in full, /booking/<token> still said deposit "due" with a
-- positive amount and a pay button that could only fail.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.jobs set deposit_required_cents = 10000 where id = tests.fx('job_a');   -- job total 20000
select tests.fx_set('tok', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_a')), 20000::bigint, 'setup: job total');

-- before any invoice: capped by the job total
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('tok')) -> 'deposit') - 'card_payments_enabled'::text,
                '{"required_cents": 10000, "paid_cents": 0, "due_cents": 10000, "status": "due", "payment_pending": false}'::jsonb,
                'no invoice yet: the full deposit is due');

-- the invoice is discounted below the deposit
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
update public.invoices set discount_kind = 'fixed', discount_value = 15000 where id = tests.fx('inv'); -- invoice total 5000
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv')), 5000::bigint, 'setup: invoice total 5000');
select tests.eq((select deposit_due_cents from public.job_payment_summary(tests.fx('job_a'))), 5000::bigint,
                'staff summary: at most the invoice total is due');
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('tok')) #>> '{deposit,due_cents}')::bigint, 5000::bigint,
                'the booking page agrees: capped by the invoice total, not the job''s');

-- partly paid
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.record_manual_payment(tests.fx('inv'), 2000, 'cash');
select tests.eq((select deposit_due_cents from public.job_payment_summary(tests.fx('job_a'))), 3000::bigint, 'staff: 3000 due');
select tests.as_anon();
select tests.ok((select d #>> '{deposit,status}' = 'due' and (d #>> '{deposit,due_cents}')::bigint = 3000
                   from (select public.public_get_booking(tests.fx('tok')) as d) x),
                'booking page: 3000 still due');

-- paid in full (the reported case)
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.record_manual_payment(tests.fx('inv'), 3000, 'cash');
select tests.eq((select status::text from public.invoices where id = tests.fx('inv')), 'paid', 'invoice paid in full');
select tests.eq((select deposit_due_cents from public.job_payment_summary(tests.fx('job_a'))), 0::bigint, 'staff summary: no deposit due');
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('tok')) #>> '{deposit,status}'), 'paid',
                'booking page must not ask for a deposit on a fully paid job');
select tests.eq((public.public_get_booking(tests.fx('tok')) #>> '{deposit,due_cents}')::bigint, 0::bigint,
                'booking page deposit due agrees with job_payment_summary');
select tests.eq((public.public_get_booking(tests.fx('tok')) #>> '{totals,balance_cents}')::bigint, 0::bigint,
                'and with the balance');

-- a voided invoice no longer caps it: back to the job total
select tests.as_superuser();
select tests.fx_set('job_a2_tok', (select public_token from public.jobs where id = tests.fx('job_a2')));
insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Interior', 1, 6000);
update public.jobs set deposit_required_cents = 4000 where id = tests.fx('job_a2');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
update public.invoices set discount_kind = 'fixed', discount_value = 5000 where id = tests.fx('inv2');
select tests.ok((select status = 'open' and amount_paid_cents = 0 and total_cents < 4000
                   from public.invoices where id = tests.fx('inv2')),
                'setup: an unpaid invoice below the deposit');
create temp table inv2_total as select total_cents from public.invoices where id = tests.fx('inv2');
grant select on inv2_total to anon;
select tests.eq((select deposit_due_cents from public.job_payment_summary(tests.fx('job_a2'))),
                (select total_cents from inv2_total), 'staff summary: capped by the unpaid invoice');
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('job_a2_tok')) #>> '{deposit,due_cents}')::bigint,
                (select total_cents from inv2_total),
                'an unpaid invoice caps it too (as in job_payment_summary)');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv2'));
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('job_a2_tok')) #>> '{deposit,due_cents}')::bigint, 4000::bigint,
                'a void invoice does not');

-- another shop's owner cannot see or change shop A's numbers
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select * from public.job_payment_summary(tests.fx('job_a'))$$, 'P0002', 'cross-shop summary refused');
select tests.eq(tests.row_count($$update public.invoices set discount_value = 0 where id = tests.fx('inv')$$), 0::bigint,
                'cross-shop invoice edit affects nothing');
