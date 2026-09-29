-- 120 (0123): staff can re-apply a job's own coupon (0121's remedy for a
-- job skipped by a coupon service-list edit). The deposit paid on the job
-- itself does not make its customer a returning one for a new-customers
-- (or referral) coupon, and an online-only coupon may be set on a job that
-- is an online booking.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, new_customers_only)
  values (tests.fx('shop_a'), 'WELCOME', 'percent', 2000, true) returning tests.fx_set('cp_welcome', id);
insert into public.coupons (shop_id, code, kind, value, online_only)
  values (tests.fx('shop_a'), 'WEB15', 'percent', 1500, true) returning tests.fx_set('cp_web', id);
select tests.eq((select jsonb_build_array(
                   (select count(*) from public.payments p where p.customer_id = j.customer_id),
                   (select count(*) from public.jobs j2 where j2.customer_id = j.customer_id and j2.status = 'completed'))
                   from public.jobs j where j.id = tests.fx('job_a')),
                '[0, 0]'::jsonb, 'job_a''s customer is new (no payments, no completed jobs)');

-- ============================================================ new customers only, after the job's own deposit
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job_a');
update public.jobs set coupon_id = null where id = tests.fx('job_a');
select tests.lives($$update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job_a')$$,
                   'set, remove, set again: fine');
select tests.as_superuser();
insert into public.payments (shop_id, customer_id, job_id, kind, method, status, amount_cents)
select j.shop_id, j.customer_id, j.id, 'deposit', 'cash', 'succeeded', 1000 from public.jobs j where j.id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set coupon_id = null where id = tests.fx('job_a');
select tests.lives($$update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job_a')$$,
                   're-apply WELCOME on the same job after its own deposit was paid');
select tests.eq((select jsonb_build_array(discount_kind, discount_value) from public.jobs where id = tests.fx('job_a')),
                '["percent", 2000]'::jsonb, 'the discount is back');
-- money paid on ANOTHER job still makes the customer a returning one
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, notes, scheduled_start, scheduled_end)
select j.shop_id, j.customer_id, 'Second visit', j.scheduled_start + interval '7 days', j.scheduled_end + interval '7 days' from public.jobs j where j.id = tests.fx('job_a')
returning tests.fx_set('job_a2', id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job_a2')$$,
                         '22023', 'this coupon is for new customers', 'another job of a paying customer: refused');
select tests.as_superuser();
select tests.eq((select public.coupon_customer_reason(c, j.customer_id, null) from public.coupons c, public.jobs j
                  where c.id = tests.fx('cp_welcome') and j.id = tests.fx('job_a')),
                'this coupon is for new customers', 'with no job, every payment counts');
select tests.authenticate_as(tests.fx('u_owner_a'));

-- ============================================================ online-only coupons
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('cp_web') where id = tests.fx('job_a2')$$,
                         '23514', 'coupon WEB15 can only be used for online bookings', 'a staff-made job: refused as before');
select tests.as_superuser();
update public.jobs set source = 'online_booking', coupon_id = tests.fx('cp_web') where id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set coupon_id = null where id = tests.fx('job_a');
select tests.lives($$update public.jobs set coupon_id = tests.fx('cp_web') where id = tests.fx('job_a')$$,
                   're-apply an online-only coupon on an online booking');
select tests.eq((select jsonb_build_array(discount_kind, discount_value) from public.jobs where id = tests.fx('job_a')),
                '["percent", 1500]'::jsonb, 'its discount is back');

-- ============================================================ still refused: expired coupons
select tests.as_superuser();
update public.coupons set ends_at = now() - interval '1 day' where id = tests.fx('cp_web');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set coupon_id = null where id = tests.fx('job_a');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('cp_web') where id = tests.fx('job_a')$$,
                         '23514', 'coupon WEB15 has expired', 'an expired coupon is refused as for any new use');
-- the helpers still refuse to run as RPCs
select tests.throws($$select public.coupon_redeem_for_job(tests.fx('shop_a'), tests.fx('cp_welcome'), true)$$, '42501',
                    'coupon_redeem_for_job (3 arguments) outside a trigger');
select tests.as_anon();
select tests.throws($$select public.coupon_redeem_for_job(tests.fx('shop_a'), tests.fx('cp_welcome'), true)$$, '42501',
                    'anon: no execute');
