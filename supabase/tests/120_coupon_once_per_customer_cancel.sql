-- 120 (0121): a cancelled / no-show job holds no once-per-customer coupon
-- use. A customer who booked online with a "first visit" code (or a
-- friend's referral code) and cancelled can book with it again; a job that
-- is not cancelled still holds the use, and reopening a cancelled job takes
-- it back unless another job of the customer holds it by then (the
-- reopened booking is honoured either way).
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
insert into public.coupons (shop_id, code, kind, value, once_per_customer)
  values (tests.fx('shop_a'), 'WELCOME', 'percent', 2000, true) returning tests.fx_set('cp_welcome', id);
select ((now() at time zone 'America/Chicago')::date + 10)::text as d1,
       ((now() at time zone 'America/Chicago')::date + 11)::text as d2,
       ((now() at time zone 'America/Chicago')::date + 12)::text as d3 \gset
create function pg_temp.book(p_day text, p_code text, p_email text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Nina', 'last_name', 'New', 'email', p_email),
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', p_day || 'T10:00:00',
           'coupon_code', p_code)))
$$;
grant execute on function pg_temp.book(text, text, text) to anon;
create function pg_temp.commit_checks() returns void language plpgsql as $$
begin
  set constraints public.jobs_zz_money_coupon_check, public.jobs_zzz_money_coupon_booking immediate;
  set constraints public.jobs_zz_money_coupon_check, public.jobs_zzz_money_coupon_booking deferred;
end $$;
grant execute on function pg_temp.commit_checks() to anon;

-- ============================================================ the repro: book, cancel online, book again
select tests.as_anon();
select pg_temp.book(:'d1', 'WELCOME', 'nina@example.com') ->> 'job_token' as t1 \gset
select pg_temp.commit_checks();
select public.public_cancel_booking(:'t1', 'wrong day') is not null;
select tests.as_superuser();
select tests.fx_set('job1', (select id from public.jobs where public_token = :'t1'::uuid));
select tests.fx_set('nina', (select customer_id from public.jobs where id = tests.fx('job1')));
select tests.eq((select jsonb_build_array(status, coupon_id = tests.fx('cp_welcome')) from public.jobs where id = tests.fx('job1')),
                '["cancelled", true]'::jsonb, 'the cancelled booking keeps its coupon (history)');
select tests.eq((select once_per_customer from public.coupon_redemptions where job_id = tests.fx('job1')), false,
                'but no longer holds the customer''s single use');

select tests.as_anon();
select pg_temp.book(:'d2', 'WELCOME', 'nina@example.com') ->> 'job_token' as t2 \gset
select tests.lives($$select pg_temp.commit_checks()$$, 'after cancelling, the customer can rebook with the code (commit checks pass)');
select tests.as_superuser();
select tests.fx_set('job2', (select id from public.jobs where public_token = :'t2'::uuid));
select tests.eq((select jsonb_build_array(customer_id = tests.fx('nina'), discount_kind, discount_value, discount_cents > 0)
                   from public.jobs where id = tests.fx('job2')),
                '[true, "percent", 2000, true]'::jsonb, 'the same customer, discounted');
select tests.eq((select once_per_customer from public.coupon_redemptions where job_id = tests.fx('job2')), true,
                'the new booking holds the use');

-- a live job still holds it: a third booking is refused (masked for anonymous bookers)
select tests.as_anon();
select tests.throws_like(format($$select pg_temp.book(%L, 'WELCOME', 'nina@example.com'); select pg_temp.commit_checks()$$, :'d3'),
                         '22023', 'this coupon cannot be used for this booking%',
                         'a second live booking with the code is refused (nothing is written)');
select tests.as_superuser();
select tests.eq((select public.coupon_customer_reason(c, tests.fx('nina'), null) from public.coupons c where c.id = tests.fx('cp_welcome')),
                'this coupon can only be used once per customer', 'the rule itself (proven callers see it)');

-- ============================================================ reopening
-- job2 is live and holds the use: reopening job1 is honoured without it
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set status = 'requested' where id = tests.fx('job1')$$, 'staff reopen the cancelled booking');
select tests.as_superuser();
select tests.eq((select array_agg(once_per_customer order by job_id = tests.fx('job1'))
                   from public.coupon_redemptions where job_id in (tests.fx('job1'), tests.fx('job2'))),
                array[true, false], 'job2 keeps the use; the reopened job1 is honoured without it');
select tests.eq((select redemptions from public.coupons where id = tests.fx('cp_welcome')), 2, 'both count as redemptions');

-- no-show releases it too; reopening then takes it back
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled' where id = tests.fx('job1');
update public.jobs set status = 'scheduled' where id = tests.fx('job2');
update public.jobs set status = 'no_show' where id = tests.fx('job2');
select tests.as_superuser();
select tests.eq((select count(*) filter (where once_per_customer) from public.coupon_redemptions
                  where job_id in (tests.fx('job1'), tests.fx('job2'))), 0::bigint, 'cancelled and no-show hold nothing');
select tests.ok((select public.coupon_customer_reason(c, tests.fx('nina'), null) is null from public.coupons c where c.id = tests.fx('cp_welcome')),
                'the customer may use the code again');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('job2');
select tests.as_superuser();
select tests.eq((select once_per_customer from public.coupon_redemptions where job_id = tests.fx('job2')), true,
                'reopened while nothing else holds it: it takes the use again');
select tests.eq((select public.coupon_customer_reason(c, tests.fx('nina'), null) from public.coupons c where c.id = tests.fx('cp_welcome')),
                'this coupon can only be used once per customer', 'and the rule applies again');

-- a coupon set on a cancelled job holds no use
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = null where id = tests.fx('job2');
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('nina'), 'cancelled')
  returning tests.fx_set('job3', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job3');
select tests.as_superuser();
select tests.eq((select once_per_customer from public.coupon_redemptions where job_id = tests.fx('job3')), false,
                'a cancelled job given the coupon holds no use');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set coupon_id = tests.fx('cp_welcome') where id = tests.fx('job2')$$,
                   'so a live job of the customer can still take it');

-- ============================================================ referral codes
select tests.as_superuser();
update public.referral_settings set enabled = true, referee_discount_kind = 'fixed', referee_discount_value = 1500,
                                    referrer_reward_cents = 2000
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_a2')) ->> 'code' as ref_code \gset
select tests.as_anon();
select pg_temp.book(:'d1', :'ref_code', 'rita@example.com') ->> 'job_token' as r1 \gset
select pg_temp.commit_checks();
select public.public_cancel_booking(:'r1', 'changed plans') is not null;
select pg_temp.book(:'d2', :'ref_code', 'rita@example.com') ->> 'job_token' as r2 \gset
select tests.lives($$select pg_temp.commit_checks()$$, 'a friend''s referral code can be used again after cancelling');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs j join public.coupons c on c.id = j.coupon_id
                  where j.public_token in (:'r1'::uuid, :'r2'::uuid) and c.referrer_customer_id = tests.fx('cust_a2')),
                2::bigint, 'both bookings carry the referral coupon (the live one can earn the referrer''s credit)');
