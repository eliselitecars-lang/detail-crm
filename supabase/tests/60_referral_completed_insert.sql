-- 60 money: the referrer's reward (0069 jobs_zz_money_referral_reward) is
-- earned on the referee's first completed job however it became completed:
-- a job recorded as already completed (walk-in logged afterwards), the
-- referral coupon put on a completed job, or the usual status change. Once
-- per referee (a second completed job, or re-inserting / re-adding the
-- coupon, earns nothing), a 'skipped' row while the program is off,
-- self-referral earns nothing, and shops are isolated.
\ir fixtures/two_shops.psql

create function pg_temp.credits(p_referee uuid) returns text language sql as $$
  select coalesce(string_agg(status || ':' || amount_cents, ',' order by created_at, id), '')
    from public.referral_credits where referee_customer_id = p_referee
$$;
create function pg_temp.cards(p_owner uuid) returns bigint language sql as $$
  select coalesce(sum(initial_cents), 0) from public.gift_cards where owner_customer_id = p_owner and issued_via = 'referral'
$$;
grant execute on function pg_temp.credits(uuid), pg_temp.cards(uuid) to authenticated;

select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set enabled = true, referee_discount_kind = 'fixed', referee_discount_value = 1500, referrer_reward_cents = 2000
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_a')) as rc \gset
select tests.as_superuser();
select id as coupon_ref from public.coupons where shop_id = tests.fx('shop_a') and referrer_customer_id = tests.fx('cust_a') \gset

-- ============================================================ recorded as completed (the finding)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Nina') returning tests.fx_set('nina', id);
insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('nina'), 'completed', :'coupon_ref'::uuid, now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j'), tests.fx('svc_a'), 'Detail', 20000);
set constraints jobs_zz_money_coupon_check immediate;
select tests.as_superuser();
select tests.eq((select discount_cents from public.jobs where id = tests.fx('j')), 1500::bigint, 'the referee got the discount');
select tests.eq(pg_temp.credits(tests.fx('nina')), 'issued:2000', 'the referee''s completed first job is recorded and rewarded');
select tests.eq((select job_id from public.referral_credits where referee_customer_id = tests.fx('nina')), tests.fx('j'),
                'for that job');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 2000::bigint, 'referrer credited');
select tests.eq((select kind::text || '/' || owner_customer_id::text from public.gift_cards g
                   join public.referral_credits rc on rc.gift_card_id = g.id where rc.referee_customer_id = tests.fx('nina')),
                'credit/' || tests.fx('cust_a')::text, 'as store credit owned by the referrer');

-- a later completion of the same referee earns nothing more
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('nina'), 'completed', now() - interval '2 hours', now() - interval '1 hour')
  returning tests.fx_set('j_again', id);
select tests.as_superuser();
select tests.eq(pg_temp.credits(tests.fx('nina')), 'issued:2000', 'once per referee');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 2000::bigint, 'no second credit');

-- ============================================================ coupon put on a completed job
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Omar') returning tests.fx_set('omar', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('omar'), 'completed', now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j_omar', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j_omar'), tests.fx('svc_a'), 'Detail', 20000);
select tests.eq(pg_temp.credits(tests.fx('omar')), '', 'no coupon: no referral');
update public.jobs set coupon_id = :'coupon_ref'::uuid where id = tests.fx('j_omar');
set constraints jobs_zz_money_coupon_check immediate;
select tests.as_superuser();
select tests.eq((select discount_cents from public.jobs where id = tests.fx('j_omar')), 1500::bigint, 'the code applied afterwards');
select tests.eq(pg_temp.credits(tests.fx('omar')), 'issued:2000', 'rewards the referrer');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 4000::bigint, 'second referee, second credit');
-- removing and re-adding the coupon earns nothing more
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = null where id = tests.fx('j_omar');
update public.jobs set coupon_id = :'coupon_ref'::uuid where id = tests.fx('j_omar');
set constraints jobs_zz_money_coupon_check immediate;
select tests.as_superuser();
select tests.eq(pg_temp.credits(tests.fx('omar')), 'issued:2000', 're-adding the coupon: still one reward');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 4000::bigint, 'no extra credit');

-- ============================================================ usual path unchanged
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Pia') returning tests.fx_set('pia', id);
insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('pia'), 'scheduled', :'coupon_ref'::uuid, now() + interval '1 day', now() + interval '1 day 1 hour')
  returning tests.fx_set('j_pia', id);
select tests.eq(pg_temp.credits(tests.fx('pia')), '', 'nothing before completion');
update public.jobs set status = 'in_progress' where id = tests.fx('j_pia');
update public.jobs set status = 'completed' where id = tests.fx('j_pia');
select tests.as_superuser();
select tests.eq(pg_temp.credits(tests.fx('pia')), 'issued:2000', 'a status change to completed still rewards');

-- ============================================================ program off: skipped row, never a later reward
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set referrer_reward_cents = 0 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Quin') returning tests.fx_set('quin', id);
insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('quin'), 'completed', :'coupon_ref'::uuid, now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j_quin', id);
select tests.as_superuser();
select tests.eq(pg_temp.credits(tests.fx('quin')), 'skipped:0', 'recorded as skipped without a reward');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 6000::bigint, 'no credit for it');

-- ============================================================ self-referral and isolation
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set referrer_reward_cents = 2000 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', :'coupon_ref'::uuid, now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j_self', id);
select tests.as_superuser();
select tests.eq(pg_temp.credits(tests.fx('cust_a')), '', 'self-referral earns nothing');
-- technicians cannot record a completed job (RLS), so they cannot mint credit
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws(format($$insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
                                     values (tests.fx('shop_a'), %L, 'completed', %L, now() - interval '2 hours', now() - interval '1 hour')$$,
                           tests.fx('cust_a2'), :'coupon_ref'), '42501', 'technicians cannot insert jobs');
-- shop B cannot use shop A's referral coupon
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws(format($$insert into public.jobs (shop_id, customer_id, status, coupon_id, scheduled_start, scheduled_end)
                                     values (tests.fx('shop_b'), tests.fx('cust_b'), 'completed', %L, now() - interval '2 hours', now() - interval '1 hour')$$,
                           :'coupon_ref'), '23503', 'another shop''s coupon is refused');
select tests.as_superuser();
select tests.eq((select count(*) from public.referral_credits where shop_id = tests.fx('shop_b')), 0::bigint, 'and shop B has no referral rows');
select tests.eq(pg_temp.cards(tests.fx('cust_a')), 6000::bigint, 'referrer total: three rewarded referees');
