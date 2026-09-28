-- 60 money: an unproven online booker must not learn anything about the
-- matched customer through the coupon customer rules (0062:
-- coupon_rules_masked, jobs_zzz_money_coupon_booking). Anonymous (and
-- signed-in but unlinked) bookings see the same errors, in the same order,
-- for a returning, a phone-only and an unknown contact: every other check
-- first (booking answers, the coupon's service list), then one neutral
-- message at commit for any customer rule (new customers only, once per
-- customer, customer-specific, referral codes). Proven bookers (the linked
-- client, a manager+ of the shop, service_role) keep the specific reason
-- immediately. Probes write nothing. Two-shop isolation: another shop's
-- manager is an ordinary unproven booker here.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
insert into public.coupons (shop_id, code, kind, value, new_customers_only)
  values (tests.fx('shop_a'), 'WELCOME', 'percent', 1000, true) returning tests.fx_set('cp_welcome', id);
insert into public.coupons (shop_id, code, kind, value, once_per_customer)
  values (tests.fx('shop_a'), 'ONCEONLY', 'fixed', 1000, true) returning tests.fx_set('cp_once', id);
insert into public.coupons (shop_id, code, kind, value, customer_id)
  values (tests.fx('shop_a'), 'ALICEVIP', 'percent', 2000, tests.fx('cust_a')) returning tests.fx_set('cp_vip', id);
-- new customers only AND a service list the probe's service is not on
insert into public.coupons (shop_id, code, kind, value, new_customers_only, service_ids)
  values (tests.fx('shop_a'), 'NEWWASH', 'percent', 1000, true, array[tests.fx('svc_wash')]);

-- Alice (alice@example.com, +12055550101) had a job done earlier
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
values (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-03-10 14:00Z', '2025-03-10 16:00Z', '2025-03-10 16:00Z');
-- ... and already used ONCEONLY on a staff job
insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', tests.fx('cp_once'));
-- Pat: a phone-only returning customer (no email on file)
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Pat', '+12055550177')
  returning tests.fx_set('cust_pat', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
values (tests.fx('shop_a'), tests.fx('cust_pat'), 'completed', '2025-03-12 14:00Z', '2025-03-12 16:00Z', '2025-03-12 16:00Z');

-- Aaron's referral code (shared publicly as /book/shop-a?coupon=CODE)
update public.referral_settings set enabled = true, referee_discount_kind = 'fixed', referee_discount_value = 1500,
                                    referrer_reward_cents = 2000
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_a2')) ->> 'code' as ref_code \gset
select tests.as_superuser();

-- One booking attempt, as the current role. p_commit fires the deferred
-- checks as a commit would. A booking that succeeds is rolled back too
-- ('booked'), so no probe writes anything.
create function pg_temp.probe(p_email text, p_code text, p_answers jsonb default null, p_commit boolean default true,
                              p_phone text default null)
returns text language plpgsql as $$
begin
  begin
    perform public.create_online_booking('shop-a', pg_temp.booking(jsonb_strip_nulls(jsonb_build_object(
      'customer', jsonb_strip_nulls(jsonb_build_object('first_name', 'X', 'email', p_email, 'phone', p_phone)),
      'starts_at', to_char(current_date + 14, 'YYYY-MM-DD') || 'T10:00:00',
      'coupon_code', p_code,
      'answers', p_answers))));
    if p_commit then
      set constraints public.jobs_zz_money_coupon_check, public.jobs_zzz_money_coupon_booking immediate;
    end if;
    raise exception using errcode = 'P0001', message = '__booked__';
  exception when others then
    if sqlerrm = '__booked__' then
      return 'booked';
    end if;
    return sqlstate || ': ' || sqlerrm;
  end;
end $$;
grant execute on function pg_temp.probe(text, text, jsonb, boolean, text) to anon, authenticated, service_role;

create temp table before_counts as
  select (select count(*) from public.jobs where shop_id = tests.fx('shop_a')) as jobs,
         (select count(*) from public.customers where shop_id = tests.fx('shop_a')) as customers,
         (select count(*) from public.coupon_redemptions where shop_id = tests.fx('shop_a')) as redemptions,
         (select sum(redemptions) from public.coupons where shop_id = tests.fx('shop_a')) as used;
grant select on before_counts to anon, authenticated, service_role;

\set neutral '22023: this coupon cannot be used for this booking; remove it to book, or sign in to your account and try again'

-- ============================================================ anonymous: the reported probe
select tests.as_anon();
create temp table probes as select
  pg_temp.probe('alice@example.com', 'WELCOME', '{"zz_probe":"x"}') as known,
  pg_temp.probe('nobody-here@example.com', 'WELCOME', '{"zz_probe":"x"}') as unknown,
  pg_temp.probe('someone@example.com', 'WELCOME', '{"zz_probe":"x"}', true, '+12055550177') as phone_only,
  pg_temp.probe('alice@example.com', 'ONCEONLY', '{"zz_probe":"x"}') as once_known,
  pg_temp.probe('nobody-here@example.com', 'ONCEONLY', '{"zz_probe":"x"}') as once_unknown,
  pg_temp.probe('alice@example.com', :'ref_code', '{"zz_probe":"x"}') as ref_known,
  pg_temp.probe('alice@example.com', 'WELCOME', '{"zz_probe":"x"}', false) as known_nocommit;
select tests.reset();
select tests.eq((select known from probes), '22023: unknown job field "zz_probe"',
                'a returning customer''s bad answer fails like anyone''s (the coupon rule does not answer first)');
select tests.eq((select known from probes), (select unknown from probes),
                'an anonymous booking attempt does not reveal whether the email is a returning customer');
select tests.eq((select phone_only from probes), (select unknown from probes),
                '... nor whether the phone belongs to an email-less customer');
select tests.eq((select once_known from probes), (select once_unknown from probes),
                '... nor whether the customer already used a once-per-customer coupon (no 23505 from the redemption row)');
select tests.eq((select ref_known from probes), (select unknown from probes), '... nor through a public referral code');
select tests.eq((select known_nocommit from probes), (select unknown from probes), '... before commit either');

-- ============================================================ anonymous: everything else passes
select tests.as_anon();
create temp table probes2 as select
  pg_temp.probe('alice@example.com', 'WELCOME') as new_known,
  pg_temp.probe('nobody-here@example.com', 'WELCOME') as new_unknown,
  pg_temp.probe('someone@example.com', 'WELCOME', null, true, '+12055550177') as new_phone_only,
  pg_temp.probe('alice@example.com', 'ONCEONLY') as once_known,
  pg_temp.probe('nobody-here@example.com', 'ONCEONLY') as once_unknown,
  pg_temp.probe('alice@example.com', 'ALICEVIP') as vip_owner,
  pg_temp.probe('nobody-here@example.com', 'ALICEVIP') as vip_other,
  pg_temp.probe('alice@example.com', :'ref_code') as ref_known,
  pg_temp.probe('nobody-here@example.com', :'ref_code') as ref_unknown,
  pg_temp.probe('alice@example.com', 'NEWWASH') as svc_known,
  pg_temp.probe('nobody-here@example.com', 'NEWWASH') as svc_unknown,
  pg_temp.probe('alice@example.com', 'WELCOME', null, false) as new_known_nocommit;
select tests.reset();
select tests.eq((select new_unknown from probes2), 'booked', 'a new customer books with a new-customer coupon');
select tests.eq((select once_unknown from probes2), 'booked', '... and with a once-per-customer coupon');
select tests.eq((select ref_unknown from probes2), 'booked', '... and with a referral code');
select tests.eq((select new_known from probes2), :'neutral', 'a returning customer is refused with the neutral message');
select tests.eq((select new_phone_only from probes2), :'neutral', 'the phone-only returning customer too');
select tests.eq((select once_known from probes2), :'neutral', 'a used once-per-customer coupon: the same message');
select tests.eq((select ref_known from probes2), :'neutral', 'a referral code for a returning customer: the same message');
select tests.eq((select vip_owner from probes2), :'neutral',
                'a customer-specific coupon typed with its owner''s email proves nothing: the same message (the owner signs in)');
select tests.eq((select vip_other from probes2), :'neutral', '... and for anyone else the same message');
select tests.eq((select svc_known from probes2), '22023: coupon NEWWASH: this coupon does not apply to the selected services',
                'the coupon''s own restrictions answer before the customer rule');
select tests.eq((select svc_known from probes2), (select svc_unknown from probes2),
                '... identically for a known and an unknown contact');
select tests.eq((select new_known_nocommit from probes2), 'booked',
                'the customer rule of an unproven booking waits for commit (jobs_zzz_money_coupon_booking)');

select tests.eq((select concat_ws('/', (select count(*) from public.jobs where shop_id = tests.fx('shop_a')),
                                       (select count(*) from public.customers where shop_id = tests.fx('shop_a')),
                                       (select count(*) from public.coupon_redemptions where shop_id = tests.fx('shop_a')),
                                       (select sum(redemptions) from public.coupons where shop_id = tests.fx('shop_a')))),
                (select concat_ws('/', jobs, customers, redemptions, used) from before_counts),
                'no probe wrote a job, customer, redemption or coupon use');

-- ============================================================ signed in but not proven
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME'), :'neutral', 'a technician is an unproven booker');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME'), :'neutral', 'another shop''s manager is an unproven booker');
select tests.as_superuser();
select tests.fx_set('u_stranger', tests.create_user('stranger@example.com'));
select tests.authenticate_as(tests.fx('u_stranger'));
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME'), :'neutral',
                'a signed-in client whose confirmed email is not the customer''s is unproven');

-- ============================================================ proven bookers keep the specific reason
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME', null, false), '22023: this coupon is for new customers',
                'a manager of the shop sees the reason immediately');
select tests.as_service();
select tests.eq(pg_temp.probe('alice@example.com', 'ONCEONLY', null, false), '22023: this coupon can only be used once per customer',
                'service_role sees the reason immediately');
-- Alice signed in with her confirmed email, not linked yet: the booking links
-- her before the job is written, so she is proven
select tests.as_superuser();
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME', null, false), '22023: this coupon is for new customers',
                'the customer herself (confirmed email) sees the reason');
select tests.eq(pg_temp.probe('alice@example.com', 'ALICEVIP'), 'booked', 'and may use her own coupon');
select tests.eq(pg_temp.probe('alice@example.com', 'WELCOME', '{"zz_probe":"x"}'), '22023: this coupon is for new customers',
                'her specific reason comes first, as before');
select tests.as_superuser();
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.probe('alice@example.com', 'ONCEONLY', null, false), '22023: this coupon can only be used once per customer',
                'the linked client sees the reason');

-- ============================================================ a real booking commits with its coupon
select tests.as_anon();
select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
         'customer', jsonb_build_object('first_name', 'Nia', 'email', 'nia@example.com'),
         'starts_at', to_char(current_date + 15, 'YYYY-MM-DD') || 'T10:00:00',
         'coupon_code', 'WELCOME'))) as ob \gset
select tests.lives($$set constraints public.jobs_zz_money_coupon_check, public.jobs_zzz_money_coupon_booking immediate$$,
                   'the new customer''s booking passes the commit-time checks');
set constraints public.jobs_zz_money_coupon_check, public.jobs_zzz_money_coupon_booking deferred;
select tests.as_superuser();
select tests.eq((select concat_ws('/', j.coupon_id = tests.fx('cp_welcome'), j.discount_cents > 0,
                                  (select count(*) from public.coupon_redemptions r where r.job_id = j.id))
                   from public.jobs j where j.public_token = (:'ob'::jsonb ->> 'job_token')::uuid), 't/t/1',
                'the booked job carries the coupon, its discount and its redemption row');
-- a later staff job of that new customer (no longer new once completed) is unaffected
select tests.as_anon();
select tests.eq(pg_temp.probe('nia@example.com', 'WELCOME'), 'booked',
                'a not-yet-completed first booking does not make the customer returning');

-- ============================================================ privileges
select tests.as_anon();
select tests.throws($$select public.coupon_rules_masked(tests.fx('shop_a'), tests.fx('cust_a'), 'online_booking')$$, '42501',
                    'anon cannot call the internal helper');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.coupon_rules_masked(tests.fx('shop_a'), tests.fx('cust_a'), 'online_booking')$$, '42501',
                    'authenticated cannot call the internal helper');
select tests.throws($$select public.coupon_booking_refused_message()$$, '42501', 'nor the message helper');
select tests.as_service();
select tests.eq(public.coupon_rules_masked(tests.fx('shop_a'), tests.fx('cust_a'), 'online_booking'), false,
                'service_role is never masked');
select tests.reset();
