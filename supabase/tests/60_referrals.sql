-- 60 money: customer referral program (P-29, 0069) — settings (seeded off,
-- admin-edited, CHECKs), referral codes and their coupons (unique, synced
-- with the settings), the server-set referral_code, the referee's new-
-- customer discount (staff and online), store credit for the referrer on the
-- referee's first completed job (once; skipped rows; self-referral), the
-- reward message, redeeming the credit, portal_referrals, RLS.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
-- (comms 0083 seeds default wording; this file uses its own)
insert into public.message_templates (shop_id, key, channel, body)
values (tests.fx('shop_a'), 'referral_reward', 'sms',
        'Thanks! {{referee_first_name}} came in, so you have {{credit_amount}} of store credit: {{gift_card_code}}')
on conflict (shop_id, key, channel) do update set body = excluded.body, enabled = true;

-- ============================================================ settings
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select concat_ws('/', enabled, referee_discount_kind, referee_discount_value, referrer_reward_cents)
                   from public.referral_settings where shop_id = tests.fx('shop_a')), 'f/fixed/0/0',
                'every shop starts with the program off and no amounts');
select tests.throws_like($$select public.get_or_create_referral_code(tests.fx('cust_a'))$$, '55000', '%not enabled%', 'no codes while off');
select tests.eq(tests.row_count($$update public.referral_settings set enabled = true where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'managers cannot change the program');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$update public.referral_settings set enabled = true where shop_id = tests.fx('shop_a')$$, '23514',
                         '%referral_settings_enabled_discount%', 'an enabled program needs the new customer''s discount');
select tests.throws($$update public.referral_settings set referee_discount_kind = 'percent', referee_discount_value = 10001
                      where shop_id = tests.fx('shop_a')$$, '23514', 'percent <= 100%');
update public.referral_settings set enabled = true, referee_discount_kind = 'fixed', referee_discount_value = 1500,
                                    referrer_reward_cents = 2000, terms = 'One reward per new customer.'
 where shop_id = tests.fx('shop_a');

-- ============================================================ codes
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_a')) as rc \gset
select tests.ok((:'rc'::jsonb ->> 'code') ~ '^[A-HJ-KM-NP-Z2-9]{8}$', 'an 8-character code without look-alike characters');
select tests.eq(:'rc'::jsonb ->> 'share_url', 'https://app.example.test/book/shop-a?coupon=' || (:'rc'::jsonb ->> 'code'),
                'a booking link that fills the code in');
select tests.eq(public.get_or_create_referral_code(tests.fx('cust_a')) ->> 'code', :'rc'::jsonb ->> 'code', 'the same code every time');
select tests.as_superuser();
select id as coupon_ref from public.coupons where shop_id = tests.fx('shop_a') and referrer_customer_id = tests.fx('cust_a') \gset
select tests.ok((select code::text = :'rc'::jsonb ->> 'code' and kind = 'fixed' and value = 1500 and once_per_customer and new_customers_only
                        and active and description = 'Referral from Alice'
                 from public.coupons where id = :'coupon_ref'::uuid), 'its coupon: the shop''s referee discount, new customers, once each');
select tests.eq((select count(*) from public.coupons where referrer_customer_id = tests.fx('cust_a')), 1::bigint, 'one coupon per referrer');
select tests.eq((select referral_code::text from public.customers where id = tests.fx('cust_a')), :'rc'::jsonb ->> 'code',
                'stored on the customer');
-- the code is server-set
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set referral_code = 'HACKED12' where id = tests.fx('cust_a');
select tests.eq((select referral_code::text from public.customers where id = tests.fx('cust_a')), :'rc'::jsonb ->> 'code',
                'staff cannot change a referral code');
insert into public.customers (shop_id, first_name, referral_code) values (tests.fx('shop_a'), 'Rex', 'MINE1234') returning tests.fx_set('cust_rex', id);
select tests.eq((select referral_code from public.customers where id = tests.fx('cust_rex')), null::extensions.citext,
                'nor set one');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.get_or_create_referral_code(tests.fx('cust_a'))$$, '42501', 'technicians cannot create codes');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.get_or_create_referral_code(tests.fx('cust_a'))$$, 'P0002', 'other shops: not found');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set archived_at = now() where id = tests.fx('cust_rex');
select tests.throws_like($$select public.get_or_create_referral_code(tests.fx('cust_rex'))$$, '22023', '%archived%', 'archived customers');

-- settings changes follow every referral coupon
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set referee_discount_kind = 'percent', referee_discount_value = 1000 where shop_id = tests.fx('shop_a');
select tests.eq((select kind || '/' || value from public.coupons where id = :'coupon_ref'::uuid), 'percent/1000', 'the coupon follows the settings');
update public.referral_settings set referee_discount_kind = 'fixed', referee_discount_value = 1500 where shop_id = tests.fx('shop_a');

-- ============================================================ the referee books with the code (online)
select tests.as_service();
select public.create_online_booking('shop-a',
         pg_temp.booking(jsonb_build_object('coupon_code', lower(:'rc'::jsonb ->> 'code'),
                                            'customer', jsonb_build_object('first_name', 'Nina', 'email', 'nina@example.com'))),
         '2025-06-01Z') as ob \gset
select tests.as_superuser();
select id as job_ref, customer_id as cust_nina from public.jobs where public_token = (:'ob'::jsonb ->> 'job_token')::uuid \gset
select tests.eq((select discount_cents from public.jobs where id = :'job_ref'::uuid), 1500::bigint, 'the new customer gets the discount');
-- a returning customer cannot use it
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'scheduled', '2025-05-01 15:00Z', '2025-05-01 16:00Z', null) returning tests.fx_set('j_a2_old', id);
update public.jobs set status = 'completed' where id = tests.fx('j_a2_old');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', $$
                           || quote_literal(:'coupon_ref') || $$)$$, '22023', '%for new customers%', 'returning customers cannot use a referral code');

-- ============================================================ reward on the referee's first completed job
select tests.as_superuser();
select tests.eq((select count(*) from public.referral_credits where job_id = :'job_ref'::uuid), 0::bigint, 'nothing before completion');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'scheduled' where id = :'job_ref'::uuid;
update public.jobs set status = 'completed' where id = :'job_ref'::uuid;
select tests.as_superuser();
select tests.eq((select concat_ws('/', status, amount_cents, referrer_customer_id = tests.fx('cust_a'), referee_customer_id = :'cust_nina'::uuid,
                                  coupon_id = :'coupon_ref'::uuid, gift_card_id is not null)
                   from public.referral_credits where job_id = :'job_ref'::uuid), 'issued/2000/t/t/t/t',
                'the referrer is credited once the referee''s first job is done');
select gift_card_id as credit_card from public.referral_credits where job_id = :'job_ref'::uuid \gset
select tests.ok((select kind = 'credit' and issued_via = 'referral' and owner_customer_id = tests.fx('cust_a') and balance_cents = 2000
                        and expires_at is null
                 from public.gift_cards where id = :'credit_card'::uuid), 'as store credit owned by the referrer');
select tests.ok((select m.body like 'Thanks! Nina came in, so you have $20.00 of store credit: ____-____-____-____'
                 from public.messages m where m.customer_id = tests.fx('cust_a') and m.template_key = 'referral_reward'
                   and m.channel = 'sms'),
                'the referrer is told (amount, who, and the credit code)');
-- completing again never pays twice
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'in_progress' where id = :'job_ref'::uuid;
update public.jobs set status = 'completed' where id = :'job_ref'::uuid;
select tests.as_superuser();
select tests.eq((select count(*) from public.referral_credits where referrer_customer_id = tests.fx('cust_a')), 1::bigint, 'once per job');
select tests.eq((select count(*) from public.gift_cards where owner_customer_id = tests.fx('cust_a') and issued_via = 'referral'), 1::bigint,
                'one credit issued');
-- the credit pays the referrer's invoices
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_a', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Wash","unit_price_cents":5000,"taxable":false}]')).id);
select public.mark_invoice_sent(tests.fx('inv_a'));
select tests.eq((public.redeem_customer_credit(tests.fx('inv_a'), :'credit_card'::uuid)).amount_cents, 2000::bigint,
                'store credit applied to the referrer''s invoice');

-- ============================================================ skipped rewards and self-referral
-- program off at completion: a skipped row
select public.get_or_create_referral_code(tests.fx('cust_a3')) as rc3 \gset
select tests.as_superuser();
select id as coupon_ref3 from public.coupons where referrer_customer_id = tests.fx('cust_a3') \gset
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Newt') returning tests.fx_set('cust_newt', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, coupon_id)
  values (tests.fx('shop_a'), tests.fx('cust_newt'), 'scheduled', '2025-06-20 15:00Z', '2025-06-20 16:00Z', :'coupon_ref3'::uuid)
  returning tests.fx_set('j_newt', id);
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set enabled = false where shop_id = tests.fx('shop_a');
select tests.eq((select bool_and(not active) from public.coupons where shop_id = tests.fx('shop_a') and referrer_customer_id is not null), true,
                'turning the program off deactivates every referral coupon');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'completed' where id = tests.fx('j_newt');
select tests.as_superuser();
select tests.eq((select concat_ws('/', status, amount_cents, coalesce(gift_card_id::text, 'none')) from public.referral_credits
                  where job_id = tests.fx('j_newt')), 'skipped/0/none', 'a completion while the program is off is recorded as skipped');
-- self-referral earns nothing
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.referral_settings set enabled = true where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.get_or_create_referral_code(tests.fx('cust_newt')) as rcn \gset
select tests.as_superuser();
select id as coupon_newt from public.coupons where referrer_customer_id = tests.fx('cust_newt') \gset
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Selfie') returning tests.fx_set('cust_self', id);
update public.coupons set referrer_customer_id = tests.fx('cust_self') where id = :'coupon_newt'::uuid;
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, coupon_id)
  values (tests.fx('shop_a'), tests.fx('cust_self'), 'scheduled', '2025-06-21 15:00Z', '2025-06-21 16:00Z', :'coupon_newt'::uuid)
  returning tests.fx_set('j_self', id);
update public.jobs set status = 'completed' where id = tests.fx('j_self');
select tests.as_superuser();
select tests.eq((select count(*) from public.referral_credits where job_id = tests.fx('j_self')), 0::bigint, 'a self-referral earns nothing');

-- ============================================================ portal
select tests.as_superuser();
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id in (tests.fx('cust_a'));
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq((select jsonb_agg(r - 'share_url') from jsonb_array_elements(public.portal_referrals()) r),
                jsonb_build_array(jsonb_build_object('shop_name', 'Shop A', 'shop_slug', 'shop-a', 'timezone', 'America/Chicago',
                                                     'currency', 'usd', 'code', :'rc'::jsonb ->> 'code',
                                                     'credits_earned_cents', 2000, 'credit_balance_cents', 0)),
                'the client sees their code, what they earned and their remaining credit (used up)');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.portal_referrals(), '[]'::jsonb, 'nothing for someone else');
select tests.as_superuser();
update public.customers set portal_user_id = tests.fx('u_outsider') where id = tests.fx('cust_a2');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.ok((public.portal_referrals() -> 0 ->> 'code') ~ '^[A-Z0-9]{8}$', 'a linked customer gets a code on first visit');
select tests.as_anon();
select tests.throws($$select public.portal_referrals()$$, '42501', 'anon cannot call the portal');

-- ============================================================ RLS
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select count(*) >= 2 from public.referral_credits where shop_id = tests.fx('shop_a')), 'managers read referral credits');
select tests.throws($$insert into public.referral_credits (shop_id, referrer_customer_id, referee_customer_id, job_id, amount_cents, status)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cust_a2'), tests.fx('job_a'), 100, 'issued')$$, '42501',
                    'no client writes');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.referral_credits), 0::bigint, 'technicians: nothing');
select tests.eq((select count(*) from public.referral_settings), 0::bigint, 'technicians: no settings');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.referral_credits where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops: nothing');
select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.referral_code_core(uuid)', 'execute')
                and has_function_privilege('authenticated', 'public.get_or_create_referral_code(uuid)', 'execute')
                and not has_function_privilege('anon', 'public.get_or_create_referral_code(uuid)', 'execute'),
                'grants');
