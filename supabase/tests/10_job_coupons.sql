-- 10 money: coupons on staff jobs (SPEC §4.3 / §4.5). Attaching a coupon
-- validates it (active, window, max_redemptions, not online_only), consumes a
-- redemption and derives the job's discount server-side; removing or
-- replacing it releases the redemption; its discount cannot drift by hand.
\ir fixtures/two_shops.psql

create function pg_temp.totals(p_job uuid) returns text language sql as $$
  select concat_ws('/', subtotal_cents, discount_cents, total_cents) from public.jobs where id = p_job
$$;
create function pg_temp.redeemed(p_coupon uuid) returns integer language sql as $$
  select redemptions from public.coupons where id = p_coupon
$$;

-- ============================================================ the repro: SAVE10 on a 20000 job
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/2000/18000', 'SAVE10 (10%) on a 20000 job discounts 2000');
select tests.eq((select concat_ws('/', discount_kind, discount_value) from public.jobs where id = tests.fx('job_a')), 'percent/1000',
                'the discount is derived from the coupon');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'the redemption is counted');

select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set internal_notes = 'VIP' where id = tests.fx('job_a');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/2000/18000', 'other edits keep the coupon discount');
select tests.throws_like($$update public.jobs set discount_kind = 'fixed', discount_value = 5000 where id = tests.fx('job_a')$$,
                         '23514', '%comes from its coupon%', 'the coupon discount cannot be edited by hand');
select tests.throws_like($$update public.jobs set discount_value = 0 where id = tests.fx('job_a')$$,
                         '23514', '%comes from its coupon%', 'nor zeroed while the coupon stays');

-- invoices carry the coupon discount
select tests.fx_set('inv', (select id from public.create_invoice_from_job(tests.fx('job_a'))));
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, total_cents) from public.invoices where id = tests.fx('inv')),
                '20000/2000/18000', 'the invoice copies the coupon discount');

-- the invoiced job's coupon is frozen (its discount was billed) ...
select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('job_a')$$,
                         '23514', '%invoice #%', 'an invoiced job keeps its coupon');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'and its redemption');
-- ... until the invoice is void
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv'), 'wrong discount');
select tests.authenticate_as(tests.fx('u_manager_a'));

-- removal releases the redemption and the discount
update public.jobs set coupon_id = null where id = tests.fx('job_a');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/0/20000', 'removing the coupon removes its discount');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 0, 'and releases its redemption');

-- removal together with a manual discount keeps the manual discount
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a');
update public.jobs set coupon_id = null, discount_kind = 'fixed', discount_value = 1500 where id = tests.fx('job_a');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/1500/18500', 'a manual discount can replace the coupon in one write');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 0, 'the replaced coupon was released');

-- ============================================================ switching coupons, fixed coupons, new jobs
insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'FIVE0', 'fixed', 5000)
  returning tests.fx_set('coupon_fixed', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a');
update public.jobs set coupon_id = tests.fx('coupon_fixed') where id = tests.fx('job_a');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/5000/15000', 'a fixed coupon discounts its amount');
select tests.as_superuser();
select tests.eq(concat_ws('/', pg_temp.redeemed(tests.fx('coupon_a')), pg_temp.redeemed(tests.fx('coupon_fixed'))), '0/1',
                'switching releases the old coupon and redeems the new one');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, coupon_id, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('coupon_a'), 'fixed', 99999)
  returning tests.fx_set('job_new', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_new'), 'Wash', 3000);
select tests.eq(pg_temp.totals(tests.fx('job_new')), '3000/300/2700', 'a new job with a coupon gets the coupon discount (client values ignored)');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'and redeems it');

-- ============================================================ unavailable coupons are rejected (and not counted)
select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, active) values (tests.fx('shop_a'), 'OFF', 'percent', 500, false)
  returning tests.fx_set('c_inactive', id);
insert into public.coupons (shop_id, code, kind, value, starts_at) values (tests.fx('shop_a'), 'SOON', 'percent', 500, now() + interval '1 day')
  returning tests.fx_set('c_future', id);
insert into public.coupons (shop_id, code, kind, value, starts_at, ends_at)
  values (tests.fx('shop_a'), 'OLD', 'percent', 500, now() - interval '10 days', now())
  returning tests.fx_set('c_expired', id);
insert into public.coupons (shop_id, code, kind, value, online_only) values (tests.fx('shop_a'), 'WEB', 'percent', 500, true)
  returning tests.fx_set('c_online', id);
insert into public.coupons (shop_id, code, kind, value, max_redemptions) values (tests.fx('shop_a'), 'ONCE', 'fixed', 1000, 1)
  returning tests.fx_set('c_once', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('c_inactive') where id = tests.fx('job_a2')$$,
                         '23514', '%no longer active%', 'inactive coupon rejected');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('c_future') where id = tests.fx('job_a2')$$,
                         '23514', '%not active yet%', 'coupon before its window rejected');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('c_expired') where id = tests.fx('job_a2')$$,
                         '23514', '%expired%', 'coupon at the end of its window rejected');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('c_online') where id = tests.fx('job_a2')$$,
                         '23514', '%online bookings%', 'online_only coupons cannot be used on staff jobs');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id)
                           values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('c_inactive'))$$,
                         '23514', '%no longer active%', 'also on insert');
select tests.lives($$update public.jobs set coupon_id = tests.fx('c_once') where id = tests.fx('job_a2')$$, 'ONCE: first use');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('c_once') where id = tests.fx('job_new')$$,
                         '23514', '%fully redeemed%', 'max_redemptions is enforced');
update public.jobs set coupon_id = null where id = tests.fx('job_a2');
select tests.lives($$update public.jobs set coupon_id = tests.fx('c_once') where id = tests.fx('job_new')$$,
                   'a released redemption can be used elsewhere');
select tests.as_superuser();
select tests.eq((select array_agg(redemptions order by code) from public.coupons where id in
                   (tests.fx('c_inactive'), tests.fx('c_future'), tests.fx('c_expired'), tests.fx('c_online'), tests.fx('c_once'))),
                array[0, 0, 1, 0, 0], 'rejected attempts count nothing (OFF, OLD, ONCE, SOON, WEB); ONCE is used by job_new');
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 0, 'job_new''s SAVE10 was released when ONCE replaced it');

-- ============================================================ roles, isolation, helpers
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a')$$, '42501',
                    'technicians cannot attach coupons');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.jobs set coupon_id = tests.fx('coupon_b') where id = tests.fx('job_a2')$$, '23503',
                    'another shop''s coupon cannot be attached');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set coupon_id = null where id = tests.fx('job_new')$$), 0::bigint,
                'shop B cannot touch A''s job coupons');
select tests.throws($$insert into public.jobs (shop_id, customer_id, status, coupon_id)
                      values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('coupon_a'))$$, '42501',
                    'shop B cannot redeem A''s coupons through an insert');
select tests.as_superuser();
select tests.eq(concat_ws('/', pg_temp.redeemed(tests.fx('coupon_a')), pg_temp.redeemed(tests.fx('coupon_b'))), '0/0',
                'denied writes redeem nothing');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.coupon_redeem_for_job(tests.fx('shop_a'), tests.fx('coupon_a'))$$, '42501',
                    'the redemption helper is not an RPC');
select tests.throws($$select public.coupon_release_for_job(tests.fx('shop_a'), tests.fx('coupon_a'))$$, '42501',
                    'nor is the release helper');
select tests.as_anon();
select tests.throws($$select public.coupon_redeem_for_job(tests.fx('shop_a'), tests.fx('coupon_a'))$$, '42501', 'anon: no execute');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 0, 'helpers called directly changed nothing');

-- a deleted coupon leaves the discount the job already received
select tests.authenticate_as(tests.fx('u_admin_a'));
delete from public.coupons where id = tests.fx('coupon_fixed');
select tests.as_superuser();
select tests.ok((select coupon_id is null and discount_kind = 'fixed' and discount_value = 5000 from public.jobs where id = tests.fx('job_a')),
                'deleting a coupon keeps the job''s discount');
select tests.eq(pg_temp.totals(tests.fx('job_a')), '20000/5000/15000', 'totals unchanged');
