-- 10 money: deleting a job gives its coupon redemption back, so a limited
-- coupon is never used up by jobs that no longer exist.
\ir fixtures/two_shops.psql

create function pg_temp.redeemed(p_coupon uuid) returns integer language sql as $$
  select redemptions from public.coupons where id = p_coupon
$$;

-- ============================================================ repro 1: manager deletes a job created by mistake
select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, max_redemptions) values (tests.fx('shop_a'), 'ONCE', 'fixed', 1000, 1)
  returning tests.fx_set('c_once', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, coupon_id)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('c_once')) returning tests.fx_set('j', id);
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('c_once')), 1, 'redeemed');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('j')$$), 1::bigint, 'the manager deletes the job');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('c_once')), 0, 'deleting the job releases the redemption');

-- ============================================================ repro 2: the coupon can be used again
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', tests.fx('c_once'))
  returning tests.fx_set('job_tmp', id);
delete from public.jobs where id = tests.fx('job_tmp');
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set redemptions = 0 where id = tests.fx('c_once');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set coupon_id = tests.fx('c_once') where id = tests.fx('job_a2')$$,
  'a coupon redeemed only by a job that was deleted can be used on another job');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('c_once')), 1, 'and counts that one job');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id)
                             values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', tests.fx('c_once'))$$,
                         '23514', '%fully redeemed%', 'the limit still holds for live jobs');

-- ============================================================ online bookings (trusted redemption) and jobs without coupons
select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, redemptions) values (tests.fx('shop_a'), 'WEB5', 'fixed', 500, 3)
  returning tests.fx_set('c_web', id);
insert into public.jobs (shop_id, customer_id, status, source, coupon_id, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', 'online_booking', tests.fx('c_web'), 'fixed', 500)
  returning tests.fx_set('j_web', id);
select tests.eq(pg_temp.redeemed(tests.fx('c_web')), 3, 'trusted inserts manage the counter themselves (no double count)');
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('j_web');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('c_web')), 2, 'deleting an online booking gives its redemption back');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested') returning tests.fx_set('j_plain', id);
delete from public.jobs where id = tests.fx('j_plain');
select tests.as_superuser();
select tests.eq(concat_ws('/', pg_temp.redeemed(tests.fx('c_web')), pg_temp.redeemed(tests.fx('c_once')), pg_temp.redeemed(tests.fx('coupon_a'))),
                '2/1/0', 'deleting a job without a coupon changes no counter');
update public.coupons set redemptions = 0 where id = tests.fx('c_web');
insert into public.jobs (shop_id, customer_id, status, source, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', 'online_booking', tests.fx('c_web'))
  returning tests.fx_set('j_web2', id);
delete from public.jobs where id = tests.fx('j_web2');
select tests.eq(pg_temp.redeemed(tests.fx('c_web')), 0, 'the counter never goes below zero');

-- ============================================================ denial: jobs that cannot be deleted keep their redemption
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a');
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.throws($$delete from public.jobs where id = tests.fx('job_a')$$, '23503', 'an invoiced job cannot be deleted');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('coupon_a')), 1, 'so its redemption stays counted');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a2')$$), 0::bigint, 'technicians cannot delete jobs');
select tests.as_superuser();
select tests.eq(pg_temp.redeemed(tests.fx('c_once')), 1, 'a refused delete releases nothing');
select tests.throws($$select public.jobs_release_coupon_on_delete()$$, null, 'the trigger function is not callable');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.jobs_release_coupon_on_delete()$$, '42501', 'staff cannot execute the trigger function');

-- ============================================================ isolation
select tests.authenticate_as(tests.fx('u_manager_b'));
update public.jobs set coupon_id = tests.fx('coupon_b') where id = tests.fx('job_b');
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a2')$$), 0::bigint, 'shop B cannot delete shop A''s jobs');
insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_b'), tests.fx('cust_b'), 'requested', tests.fx('coupon_b'))
  returning tests.fx_set('j_b', id);
delete from public.jobs where id = tests.fx('j_b');
select tests.as_superuser();
select tests.eq(concat_ws('/', pg_temp.redeemed(tests.fx('coupon_b')), pg_temp.redeemed(tests.fx('coupon_a')), pg_temp.redeemed(tests.fx('c_once'))),
                '1/1/1', 'a delete in shop B releases only shop B''s coupon');

-- deleting a whole shop with coupon jobs cascades cleanly
select tests.lives($$delete from public.shops where id = tests.fx('shop_b')$$, 'a shop with coupon jobs can still be deleted');
select tests.eq((select count(*) from public.coupons where shop_id = tests.fx('shop_b')), 0::bigint, 'its coupons are gone with it');
