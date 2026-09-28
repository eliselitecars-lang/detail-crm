-- 60 money: a referee earns the referrer ONE reward (P-29, 0069), even
-- when the rewarded job is deleted afterwards: the referral credit outlives
-- the job (referral_credits.job_id ON DELETE SET NULL, 0061), the reward
-- check is per referee, and a rewarded referee is no longer a new customer
-- (coupon_customer_reason, 0062) so the referral code cannot be reused.
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set enabled = true, referee_discount_kind = 'fixed', referee_discount_value = 1500,
                                    referrer_reward_cents = 2000 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_a')) as rc \gset
select tests.as_superuser();
select id as coupon_ref from public.coupons where shop_id = tests.fx('shop_a') and referrer_customer_id = tests.fx('cust_a') \gset

create function pg_temp.rewards() returns bigint language sql as $$
  select coalesce(sum(initial_cents), 0) from public.gift_cards
   where shop_id = tests.fx('shop_a') and owner_customer_id = tests.fx('cust_a') and issued_via = 'referral'
$$;

-- ============================================================ the rewarded job is deleted
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Nina') returning tests.fx_set('nina', id);
insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('nina'), 'scheduled', :'coupon_ref', '2025-06-01 15:00Z', '2025-06-01 16:00Z')
  returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_a'), 'Detail', 20000);
update public.jobs set status = 'completed' where id = tests.fx('j1');
select tests.as_superuser();
select tests.eq(pg_temp.rewards(), 2000::bigint, 'setup: referrer rewarded once');
select id as credit_id from public.referral_credits where referee_customer_id = tests.fx('nina') \gset

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('j1')$$), 1::bigint,
                'managers may delete the (unbilled) rewarded job');
select tests.as_superuser();
select tests.eq((select concat_ws('/', coalesce(job_id::text, 'none'), status, amount_cents, gift_card_id is not null)
                 from public.referral_credits where id = :'credit_id'::uuid),
                'none/issued/2000/t', 'the credit survives the job (its audit record), only the job link is cleared');

-- ============================================================ the referral code cannot be used again
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like(format($$insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
                                  values (%L, %L, 'scheduled', %L, '2025-07-01 15:00Z', '2025-07-01 16:00Z')$$,
                                tests.fx('shop_a'), tests.fx('nina'), :'coupon_ref'),
                         '22023', '%new customers%', 'a rewarded referee is no longer a new customer');
-- nor any other new-customers-only coupon
select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, new_customers_only)
  values (tests.fx('shop_a'), 'WELCOME', 'percent', 1000, true) returning tests.fx_set('cp_welcome', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, coupon_id, status) values (tests.fx('shop_a'), tests.fx('nina'), tests.fx('cp_welcome'), 'requested')$$,
                         '22023', '%new customers%', 'the welcome coupon either');
-- another genuinely new customer still can
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Omar') returning tests.fx_set('omar', id);
select tests.lives($$insert into public.jobs (shop_id, customer_id, coupon_id, status) values (tests.fx('shop_a'), tests.fx('omar'), tests.fx('cp_welcome'), 'requested')$$,
                   'a new customer still gets new-customer coupons');

-- ============================================================ a later completion earns nothing
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('nina'), 'scheduled', '2025-07-01 15:00Z', '2025-07-01 16:00Z')
  returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j2'), tests.fx('svc_a'), 'Detail', 20000);
update public.jobs set status = 'completed' where id = tests.fx('j2');
select tests.as_superuser();
select tests.eq(pg_temp.rewards(), 2000::bigint, 'a referee earns the referrer one reward, even after the rewarded job is deleted');

-- The reward trigger itself checks per referee: a job that carries the
-- referral coupon (attached here with triggers off, as no API path can any
-- more) completing later earns nothing either. Needs a superuser connection.
select rolsuper as is_superuser from pg_roles where rolname = current_user \gset
\if :is_superuser
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('nina'), 'scheduled', '2025-08-01 15:00Z', '2025-08-01 16:00Z')
  returning tests.fx_set('j3', id);
set local session_replication_role = replica;
update public.jobs set coupon_id = :'coupon_ref' where id = tests.fx('j3');
set local session_replication_role = origin;
update public.jobs set status = 'completed' where id = tests.fx('j3');
select tests.eq(pg_temp.rewards(), 2000::bigint, 'the reward trigger finds the surviving credit (per referee)');
select tests.eq((select count(*) from public.referral_credits where referee_customer_id = tests.fx('nina')), 1::bigint,
                'one credit row per referee');
\else
\echo SKIP (needs superuser) reward trigger per-referee check
\endif

-- ============================================================ isolation and client writes
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.referral_credits where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops see no credits');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.referral_credits set job_id = null$$, '42501', 'credits are not client-writable');
select tests.throws($$delete from public.referral_credits$$, '42501', 'nor client-deletable');
select tests.as_superuser();
select tests.eq((select attnotnull from pg_attribute where attrelid = 'public.referral_credits'::regclass and attname = 'job_id'), false,
                'job_id is nullable (the credit outlives the job)');
select tests.eq((select confdeltype from pg_constraint where conname = 'referral_credits_job_fk'), 'n'::"char",
                'ON DELETE SET NULL');
