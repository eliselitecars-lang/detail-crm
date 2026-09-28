-- 60 money: coupon restrictions (P-13a, 0062) — service lists and discount
-- eligibility on job lines, the deferred service / minimum-subtotal check
-- (staff writes and online bookings), customer-specific / once-per-customer
-- / new-customer rules in every context, coupon_redemptions rows, the
-- customer-merge bypass, coupon settings guards, and public_validate_coupon
-- (restrictions, signed-in client rules, private booking links).
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- Fires the deferred coupon check now (then defers it again).
create function pg_temp.check_coupons() returns void language plpgsql as $$
begin
  set constraints public.jobs_zz_money_coupon_check immediate;
  set constraints public.jobs_zz_money_coupon_check deferred;
end $$;
grant execute on function pg_temp.check_coupons() to anon, authenticated, service_role;

create function pg_temp.jt(p_id uuid) returns text language sql as $$
  select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = p_id
$$;
grant execute on function pg_temp.jt(uuid) to authenticated, service_role;

create function pg_temp.elig(p_job uuid) returns text language sql as $$
  select string_agg(name || ':' || discount_eligible::text, ',' order by sort, name) from public.job_line_items where job_id = p_job
$$;
grant execute on function pg_temp.elig(uuid) to authenticated, service_role;

-- ============================================================ coupon settings (owner / admin)
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.coupons (shop_id, code, kind, value, service_ids, description)
  values (tests.fx('shop_a'), 'WASHONLY', 'percent', 5000, array[tests.fx('svc_wash'), tests.fx('svc_wash')], 'Half off the wash')
  returning tests.fx_set('cp_wash', id);
select tests.eq((select service_ids from public.coupons where id = tests.fx('cp_wash')), array[tests.fx('svc_wash')],
                'service list de-duplicated');
insert into public.coupons (shop_id, code, kind, value, min_subtotal_cents)
  values (tests.fx('shop_a'), 'MIN300', 'fixed', 5000, 30000) returning tests.fx_set('cp_min', id);
insert into public.coupons (shop_id, code, kind, value, once_per_customer)
  values (tests.fx('shop_a'), 'ONCE', 'fixed', 1000, true) returning tests.fx_set('cp_once', id);
insert into public.coupons (shop_id, code, kind, value, customer_id)
  values (tests.fx('shop_a'), 'VIP', 'percent', 2000, tests.fx('cust_a')) returning tests.fx_set('cp_vip', id);
insert into public.coupons (shop_id, code, kind, value, new_customers_only)
  values (tests.fx('shop_a'), 'NEWBIE', 'fixed', 2000, true) returning tests.fx_set('cp_new', id);
insert into public.coupons (shop_id, code, kind, value, service_ids)
  values (tests.fx('shop_a'), 'EMPTYLIST', 'fixed', 100, '{}') returning tests.fx_set('cp_emptylist', id);
select tests.eq((select service_ids from public.coupons where id = tests.fx('cp_emptylist')), null::uuid[],
                'an empty service list means every service');
select tests.throws_like($$insert into public.coupons (shop_id, code, kind, value, service_ids)
                           values (tests.fx('shop_a'), 'XSHOP', 'fixed', 100, array[tests.fx('svc_b')])$$, '23503',
                         '%must belong to this shop%', 'another shop''s service cannot be listed');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value, customer_id)
                      values (tests.fx('shop_a'), 'XCUST', 'fixed', 100, tests.fx('cust_b'))$$, '23503',
                    'composite FK: another shop''s customer');
select tests.throws($$insert into public.coupons (shop_id, code, kind, value, min_subtotal_cents)
                      values (tests.fx('shop_a'), 'NEGMIN', 'fixed', 100, -1)$$, '23514', 'minimum subtotal >= 0');
-- referral links are server-set
insert into public.coupons (shop_id, code, kind, value, referrer_customer_id)
  values (tests.fx('shop_a'), 'SNEAKY', 'fixed', 100, tests.fx('cust_a')) returning tests.fx_set('cp_sneaky', id);
select tests.eq((select referrer_customer_id from public.coupons where id = tests.fx('cp_sneaky')), null::uuid,
                'a client insert cannot make a referral coupon');
update public.coupons set referrer_customer_id = tests.fx('cust_a') where id = tests.fx('cp_sneaky');
select tests.eq((select referrer_customer_id from public.coupons where id = tests.fx('cp_sneaky')), null::uuid,
                'nor an update');
select tests.as_superuser();
update public.coupons set referrer_customer_id = tests.fx('cust_a2') where id = tests.fx('cp_sneaky');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$update public.coupons set code = 'RENAMED' where id = tests.fx('cp_sneaky')$$, '42501',
                         '%referral coupon%', 'a referral coupon''s code is fixed');
select tests.lives($$update public.coupons set description = 'Thanks!' where id = tests.fx('cp_sneaky')$$,
                   'other fields of a referral coupon stay editable');
select tests.eq((select referrer_customer_id from public.coupons where id = tests.fx('cp_sneaky')), tests.fx('cust_a2'),
                'the server-set referrer is kept on client updates');
-- role rules unchanged: managers read, only owners/admins write, technicians nothing
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'MGR', 'fixed', 1)$$,
                    '42501', 'managers cannot create coupons');
select tests.eq((select count(*) from public.coupons where id = tests.fx('cp_wash')), 1::bigint, 'managers read coupons');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.coupons where shop_id = tests.fx('shop_a')), 0::bigint, 'technicians read no coupons');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$update public.coupons set value = 1 where id = tests.fx('cp_wash')$$), 0::bigint,
                'another shop''s admin cannot touch them');

-- ============================================================ eligibility on job lines
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), '2025-07-01 15:00Z', '2025-07-01 17:00Z') returning tests.fx_set('job_e', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort) values
  (tests.fx('shop_a'), tests.fx('job_e'), tests.fx('svc_a'), 'Full Detail', 20000, 1),
  (tests.fx('shop_a'), tests.fx('job_e'), tests.fx('svc_wash'), 'Exterior Wash', 5000, 2),
  (tests.fx('shop_a'), tests.fx('job_e'), null, 'Tire shine', 1000, 3);
select tests.eq(pg_temp.jt(tests.fx('job_e')), '26000/0/2600/28600', 'no coupon: 10% tax on 26000');
update public.jobs set coupon_id = tests.fx('cp_wash') where id = tests.fx('job_e');
select tests.eq(pg_temp.elig(tests.fx('job_e')), 'Full Detail:false,Exterior Wash:true,Tire shine:false',
                'only the listed service''s line is discount-eligible');
-- E = 5000 -> 50% = 2500 (taxable share 2500); tax = 10% of (26000 - 2500) = 2350
select tests.eq(pg_temp.jt(tests.fx('job_e')), '26000/2500/2350/25850', 'the coupon discounts the wash only');
select tests.lives($$select pg_temp.check_coupons()$$, 'an eligible line: the deferred check passes');
update public.job_line_items set discount_eligible = true where job_id = tests.fx('job_e') and name = 'Full Detail';
select tests.eq(pg_temp.elig(tests.fx('job_e')), 'Full Detail:false,Exterior Wash:true,Tire shine:false',
                'discount_eligible on job lines is server-maintained (client writes ignored)');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('job_e'), tests.fx('svc_wash'), 'Second wash', 5000, 4);
select tests.eq((select discount_eligible from public.job_line_items where job_id = tests.fx('job_e') and name = 'Second wash'), true,
                'a new line of a listed service is eligible');
select tests.eq(pg_temp.jt(tests.fx('job_e')), '31000/5000/2600/28600', '50% of both washes (10000)');
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_e');
select tests.eq(pg_temp.elig(tests.fx('job_e')), 'Full Detail:true,Exterior Wash:true,Tire shine:true,Second wash:true',
                'a coupon without a service list re-stamps every line eligible');
select tests.eq(pg_temp.jt(tests.fx('job_e')), '31000/3100/2790/30690', '10% of everything');
update public.jobs set coupon_id = tests.fx('cp_wash') where id = tests.fx('job_e');
update public.jobs set coupon_id = null where id = tests.fx('job_e');
select tests.eq(pg_temp.elig(tests.fx('job_e')), 'Full Detail:true,Exterior Wash:true,Tire shine:true,Second wash:true',
                'removing the coupon makes every line eligible again');
select tests.eq(pg_temp.jt(tests.fx('job_e')), '31000/0/3100/34100', 'and removes its discount');
-- the stored totals always equal the canonical function over the lines
select tests.as_superuser();
select tests.ok((select bool_and(j.total_cents = r.total_cents and j.discount_cents = r.discount_cents)
                 from public.jobs j
                 cross join lateral public.compute_document_totals(
                   (select coalesce(jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                                 'discount_cents', li.discount_cents, 'taxable', li.taxable,
                                                                 'discount_eligible', li.discount_eligible)), '[]')
                      from public.job_line_items li where li.job_id = j.id),
                   j.discount_kind, j.discount_value, j.tax_rate_bps) r
                 where j.shop_id = tests.fx('shop_a')),
                'every job''s totals match compute_document_totals with discount_eligible');

-- ============================================================ deferred check: service list and minimum
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), '2025-07-02 15:00Z', '2025-07-02 17:00Z') returning tests.fx_set('job_d', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_d'), tests.fx('svc_a'), 'Full Detail', 20000);
savepoint no_wash;
update public.jobs set coupon_id = tests.fx('cp_wash') where id = tests.fx('job_d');
select tests.eq(pg_temp.jt(tests.fx('job_d')), '20000/0/2000/22000', 'nothing eligible: no discount');
select tests.throws_like($$select pg_temp.check_coupons()$$, '22023', '%does not apply to the selected services%',
                         'a coupon whose services are not on the job is refused at commit');
rollback to savepoint no_wash;
savepoint minimum;
update public.jobs set coupon_id = tests.fx('cp_min') where id = tests.fx('job_d');
select tests.throws_like($$select pg_temp.check_coupons()$$, '22023', '%subtotal of at least $300.00%',
                         'eligible subtotal below the minimum is refused at commit');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_d'), 'Ceramic coating', 15000);
select tests.lives($$select pg_temp.check_coupons()$$, 'lines added in the same transaction count (checked at commit)');
select tests.eq(pg_temp.jt(tests.fx('job_d')), '35000/5000/3000/33000', '$50 off once the minimum is met');
rollback to savepoint minimum;

-- online bookings: the lines are inserted after the job, so the check runs at commit
select tests.as_service();
savepoint online_bad;
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.booking('{"coupon_code":"washonly"}'), '2025-06-01Z')$$,
                   'the booking itself is written ...');
select tests.throws_like($$select pg_temp.check_coupons()$$, '22023', '%does not apply to the selected services%',
                         '... and refused when the transaction commits (a Full Detail only)');
rollback to savepoint online_bad;
select public.create_online_booking('shop-a',
         pg_temp.booking(jsonb_build_object('coupon_code', 'WASHONLY',
                                            'service_ids', jsonb_build_array(tests.fx('svc_a'), tests.fx('svc_wash')),
                                            'starts_at', '2025-06-10T15:00:00Z')), '2025-06-01Z') as r \gset ob_
select tests.lives($$select pg_temp.check_coupons()$$, 'an online booking with an eligible service commits');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, total_cents) from public.jobs where public_token = (:'ob_r'::jsonb ->> 'job_token')::uuid),
                '25000/2500/24750', 'online booking: 50% off the wash only (tax 10% of 22500)');
select tests.eq((select count(*) from public.coupon_redemptions r join public.jobs j on j.id = r.job_id
                  where j.public_token = (:'ob_r'::jsonb ->> 'job_token')::uuid and r.coupon_id = tests.fx('cp_wash')),
                1::bigint, 'online bookings write their redemption row too');

-- editing the coupon's service list re-stamps its unbilled jobs
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = array[tests.fx('svc_wash'), tests.fx('svc_a')] where id = tests.fx('cp_wash');
select tests.as_superuser();
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents) from public.jobs where public_token = (:'ob_r'::jsonb ->> 'job_token')::uuid),
                '25000/12500', 'the booking''s Full Detail line became eligible too (50% of 25000)');
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = array[tests.fx('svc_wash')] where id = tests.fx('cp_wash');

-- ============================================================ customer rules (every context)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('cp_vip'))$$,
                         '22023', '%not valid for this customer%', 'a customer-specific coupon refuses other customers');
insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', tests.fx('cp_vip'))
  returning tests.fx_set('job_vip', id);
select tests.ok(tests.fx('job_vip') is not null, 'the coupon''s own customer may use it');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('job_vip')$$, '22023',
                         '%not valid for this customer%', 'moving the job to another customer re-checks its coupon');
select tests.as_service();
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"coupon_code":"VIP","starts_at":"2025-06-11T15:00:00Z"}'), '2025-06-01Z')$$,
                         '22023', '%not valid for this customer%', 'online bookings obey the customer rule');

-- once per customer
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', tests.fx('cp_once'))
  returning tests.fx_set('job_once1', id);
select tests.eq((select concat_ws('/', coupon_id = tests.fx('cp_once'), customer_id = tests.fx('cust_a3'), once_per_customer)
                   from public.coupon_redemptions where job_id = tests.fx('job_once1')), 't/t/t',
                'redemption row with the coupon''s once-per-customer flag');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', tests.fx('cp_once'))$$,
                         '22023', '%once per customer%', 'a second job of the same customer is refused');
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_once2', id);
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('cp_once') where id = tests.fx('job_once2')$$, '22023',
                         '%once per customer%', '... also when attached later');
update public.jobs set coupon_id = null where id = tests.fx('job_once1');
select tests.eq((select count(*) from public.coupon_redemptions where job_id = tests.fx('job_once1')), 0::bigint,
                'removing the coupon deletes its redemption row');
select tests.lives($$update public.jobs set coupon_id = tests.fx('cp_once') where id = tests.fx('job_once2')$$,
                   'the use is free again');
select tests.eq((select redemptions from public.coupons where id = tests.fx('cp_once')), 1, 'the redemption counter follows');
select tests.as_superuser();
select tests.throws($$insert into public.coupon_redemptions (shop_id, coupon_id, customer_id, job_id, once_per_customer)
                      values (tests.fx('shop_a'), tests.fx('cp_once'), tests.fx('cust_a3'), tests.fx('job_e'), true)$$, '23505',
                    'the unique index backs once-per-customer against races');

-- new customers only
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', tests.fx('cp_new'))$$,
                   'a customer without completed jobs or payments is new');
select tests.as_superuser();
update public.jobs set status = 'completed' where id = tests.fx('job_a');   -- Alice (cust_a) completed a job
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', tests.fx('cp_new'))$$,
                         '22023', '%for new customers%', 'a customer with a completed job is not new');
-- a received payment also makes a customer known
select tests.fx_set('inv_x', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Wash","unit_price_cents":1000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_x'));
select public.record_manual_payment(tests.fx('inv_x'), 500, 'cash');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, status, coupon_id) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested', tests.fx('cp_new'))$$,
                         '22023', '%for new customers%', 'a customer who paid before is not new');
select tests.as_service();
select tests.throws_like($$select public.create_online_booking('shop-a',
                              pg_temp.booking('{"coupon_code":"NEWBIE","starts_at":"2025-06-12T15:00:00Z","customer":{"first_name":"Alice","email":"alice@example.com","phone":"+12055550101"}}'),
                              '2025-06-01Z')$$,
                         '22023', '%for new customers%', 'online: the matched returning customer cannot use a new-customer coupon');
select tests.lives($$select public.create_online_booking('shop-a',
                       pg_temp.booking('{"coupon_code":"NEWBIE","starts_at":"2025-06-12T15:00:00Z","customer":{"first_name":"Zed","email":"zed@example.com"}}'),
                       '2025-06-01Z')$$, 'online: a brand-new customer can');

-- ============================================================ coupon_redemptions rows
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_e');
update public.jobs set coupon_id = tests.fx('cp_fixed') where id = tests.fx('job_e');
select tests.eq((select concat_ws('/', count(*), min(coupon_id::text) = tests.fx('cp_fixed')::text)
                   from public.coupon_redemptions where job_id = tests.fx('job_e')), '1/t',
                'one row per job, following the current coupon');
update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('job_e');
select tests.eq((select customer_id from public.coupon_redemptions where job_id = tests.fx('job_e')), tests.fx('cust_a3'),
                'the row follows the job''s customer');
select tests.throws($$insert into public.coupon_redemptions (shop_id, coupon_id, customer_id, job_id, once_per_customer)
                      values (tests.fx('shop_a'), tests.fx('coupon_a'), tests.fx('cust_a'), tests.fx('job_a'), false)$$, '42501',
                    'no client writes');
select tests.throws($$delete from public.coupon_redemptions where job_id = tests.fx('job_e')$$, '42501',
                    'no client deletes (no privilege)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.coupon_redemptions where shop_id = tests.fx('shop_a')), 0::bigint,
                'technicians read no redemptions');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.coupon_redemptions where shop_id = tests.fx('shop_a')), 0::bigint,
                'other shops read nothing');
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_once2');
select tests.eq((select count(*) from public.coupon_redemptions where job_id = tests.fx('job_once2')), 0::bigint,
                'deleting the job deletes its row');

-- ============================================================ customer merge bypass (P-20 contract)
select tests.as_superuser();
select set_config('detailcrm.customer_merge', 'on', true);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('job_vip')$$,
                   'during merge_customers the job moves with its customer-specific coupon');
select tests.eq((select customer_id from public.coupon_redemptions where job_id = tests.fx('job_vip')), tests.fx('cust_a'),
                'the redemption row is left for merge_customers to move');
select set_config('detailcrm.customer_merge', '', true);
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_vip')$$, '22023',
                         '%not valid for this customer%', 'outside a merge the rule applies again');

-- ============================================================ public_validate_coupon
select tests.as_anon();
select tests.eq(public.public_validate_coupon('shop-a', 'washonly', array[tests.fx('svc_a'), tests.fx('svc_wash')])
                  - array['message', 'code', 'kind', 'value', 'description'],
                jsonb_build_object('valid', true, 'subtotal_cents', 25000, 'discount_cents', 2500, 'tax_cents', 2250,
                                   'total_cents', 24750, 'eligible_service_ids', jsonb_build_array(tests.fx('svc_wash')),
                                   'restrictions_text', 'Applies to Exterior Wash.'),
                'preview discounts the eligible services only and says which');
select tests.eq(public.public_validate_coupon('shop-a', 'WASHONLY', array[tests.fx('svc_a')])
                  - array['code', 'kind', 'value', 'description', 'subtotal_cents', 'tax_cents', 'total_cents'],
                jsonb_build_object('valid', false, 'message', 'this coupon does not apply to the selected services',
                                   'discount_cents', 0, 'eligible_service_ids', '[]'::jsonb,
                                   'restrictions_text', 'Applies to Exterior Wash.'),
                'no eligible service: an answer with the restriction');
select tests.eq(public.public_validate_coupon('shop-a', 'MIN300', array[tests.fx('svc_a')]) ->> 'message',
                'this coupon needs a subtotal of at least $300.00', 'minimum subtotal');
select tests.eq(public.public_validate_coupon('shop-a', 'MIN300', array[tests.fx('pkg_a')]) ->> 'discount_cents', '5000',
                'minimum met');
select tests.eq(public.public_validate_coupon('shop-a', 'VIP', array[tests.fx('svc_a')]) ->> 'message',
                'this coupon is not valid for this customer', 'a customer-specific coupon is not valid for an anonymous visitor');
select tests.eq(public.public_validate_coupon('shop-a', 'NEWBIE', array[tests.fx('svc_a')]) ->> 'valid', 'true',
                'new-customer coupons preview for anonymous visitors (enforced at booking)');
select tests.eq(public.public_validate_coupon('shop-a', 'NEWBIE', array[tests.fx('svc_a')]) ->> 'restrictions_text',
                'New customers only.', 'restrictions text');
select tests.eq(public.public_validate_coupon('shop-a', 'ONCE', array[tests.fx('svc_a')]) ->> 'restrictions_text',
                'One use per customer.', 'restrictions text (once)');
-- the signed-in client linked to Alice
select tests.as_superuser();
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(public.public_validate_coupon('shop-a', 'VIP', array[tests.fx('svc_a')]) ->> 'valid', 'true',
                'the linked client may use their own coupon');
select tests.eq(public.public_validate_coupon('shop-a', 'VIP', array[tests.fx('svc_a')]) ->> 'restrictions_text',
                'For one customer only.', 'restrictions text (customer)');
select tests.eq(public.public_validate_coupon('shop-a', 'NEWBIE', array[tests.fx('svc_a')]) ->> 'message',
                'this coupon is for new customers', 'a returning linked client sees the new-customer rule');
-- private booking links: services outside the online catalog
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'Fleet', array[tests.fx('svc_hidden')])
  returning tests.fx_set('link_a', token);
select tests.authenticate_as(tests.fx('u_admin_b'));
insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_b'), 'B link', array[tests.fx('svc_b')])
  returning tests.fx_set('link_b', token);
select tests.as_anon();
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_hidden')])$$, '22023',
                         '%not available for online booking%', 'without the link a hidden service is not bookable');
select tests.eq(public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_hidden')], null, now(), tests.fx('link_a')) ->> 'discount_cents',
                '100', 'with the link its services are priced and discounted');
select tests.throws_like($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_a')], null, now(), tests.fx('link_a'))$$,
                         '22023', '%not available for online booking%', 'a link offers exactly its services');
select tests.throws($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_hidden')], null, now(), gen_random_uuid())$$,
                    'PT404', 'unknown link: not found');
select tests.throws($$select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_hidden')], null, now(), tests.fx('link_b'))$$,
                    'PT404', 'another shop''s link: not found');
select tests.ok(has_function_privilege('anon', 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)', 'execute'),
                'anon may preview coupons');
select tests.as_superuser();
select tests.eq((select count(*) from pg_proc where proname = 'public_validate_coupon'), 1::bigint, 'no leftover overload');
select tests.ok(not has_function_privilege('authenticated', 'public.coupon_restriction_reason(public.coupons, uuid, jsonb, timestamptz)', 'execute')
                and not has_function_privilege('anon', 'public.coupon_customer_reason(public.coupons, uuid, uuid)', 'execute')
                and has_function_privilege('service_role', 'public.coupon_restriction_reason(public.coupons, uuid, jsonb, timestamptz)', 'execute'),
                'rule helpers are internal (service_role)');
