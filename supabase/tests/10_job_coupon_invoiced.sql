-- 10 money: once a job is invoiced its coupon is frozen. create_invoice_from_job
-- copies the coupon discount onto the invoice, so the redemption was billed:
-- removing or replacing the job's coupon must not give it back (a one-use
-- coupon would be used twice), and a coupon attached now would be used up
-- without ever reaching the invoice. Voiding the invoice (or deleting a draft)
-- unfreezes it.
\ir fixtures/two_shops.psql

create function pg_temp.redeemed(p_coupon uuid) returns integer language sql as $$
  select redemptions from public.coupons where id = p_coupon
$$;

select tests.as_superuser();
update public.coupons set max_redemptions = 1 where id = tests.fx('coupon_a');
insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'FIVE0', 'fixed', 5000)
  returning tests.fx_set('coupon_fixed', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 10000);

-- ============================================================ the repro: one-use SAVE10 billed and paid on job_a
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a');
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.record_manual_payment(tests.fx('inv'), (select balance_cents from public.invoices where id = tests.fx('inv')), 'cash');
select tests.eq((select concat_ws('/', status, discount_cents) from public.invoices where id = tests.fx('inv')), 'paid/2000',
                'discount billed and paid');

select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('job_a')$$, '23514', '%invoice #%',
                         'the billed coupon cannot be removed');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('coupon_fixed') where id = tests.fx('job_a')$$, '23514',
                         '%invoice #%', 'nor replaced');
select tests.throws_like($$update public.jobs set coupon_id = null, discount_kind = 'fixed', discount_value = 100
                           where id = tests.fx('job_a')$$, '23514', '%invoice #%', 'nor swapped for a manual discount');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'a coupon whose discount is on an invoice keeps its redemption');
select tests.eq(pg_temp.redeemed(tests.fx('coupon_fixed')), 0, 'the refused replacement consumed nothing');
select tests.ok((select coupon_id = tests.fx('coupon_a') and discount_kind = 'percent' and discount_value = 1000
                   from public.jobs where id = tests.fx('job_a')), 'the job keeps its coupon and discount');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a2')$$, '23514',
                         '%fully redeemed%', 'the one-use coupon cannot be used a second time');
select tests.lives($$update public.jobs set internal_notes = 'paid in cash' where id = tests.fx('job_a')$$,
                   'other edits of the invoiced job still work');

-- ============================================================ attaching a coupon to an invoiced job
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('coupon_fixed') where id = tests.fx('job_a2')$$, '23514',
                         '%invoice #%', 'a coupon cannot be attached after the job is invoiced (it would never reach the invoice)');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_fixed')), 0, 'nothing was redeemed');

-- ============================================================ a void invoice unfreezes the coupon
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv2'), 're-issue with a coupon');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set coupon_id = tests.fx('coupon_fixed') where id = tests.fx('job_a2')$$,
                   'after the void the coupon can be attached');
select tests.eq((select discount_cents from public.create_invoice_from_job(tests.fx('job_a2'))), 5000::bigint,
                'and reaches the replacement invoice');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_fixed')), 1, 'redeemed once');

-- a draft invoice freezes it too; deleting the draft unfreezes it
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice((select id from public.invoices where job_id = tests.fx('job_a2') and status <> 'void'), 'redo');
select tests.as_superuser();
insert into public.invoices (shop_id, job_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'draft')
  returning tests.fx_set('inv_draft', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('job_a2')$$, '23514', '%invoice #%',
                         'a draft invoice freezes the coupon as well');
delete from public.invoices where id = tests.fx('inv_draft');
select tests.lives($$update public.jobs set coupon_id = null where id = tests.fx('job_a2')$$, 'the draft is gone: the coupon can go');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_fixed')), 0, 'and its redemption is released');

-- ============================================================ roles and isolation
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set coupon_id = null where id = tests.fx('job_a')$$, '42501',
                    'technicians cannot touch coupons');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set coupon_id = null where id = tests.fx('job_a')$$), 0::bigint,
                'shop B cannot touch A''s job');
select tests.as_superuser();
select tests.ok((select coupon_id = tests.fx('coupon_a') from public.jobs where id = tests.fx('job_a')), 'job_a keeps SAVE10');
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'still counted once');

-- shop B's own invoiced job is frozen independently of shop A
select tests.authenticate_as(tests.fx('u_manager_b'));
update public.jobs set coupon_id = tests.fx('coupon_b') where id = tests.fx('job_b');
select public.create_invoice_from_job(tests.fx('job_b'));
select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('job_b')$$, '23514', '%invoice #%',
                         'shop B: invoiced coupon frozen');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_b')), 1, 'shop B''s coupon keeps its redemption');
