-- 10 money: membership_plans, memberships (status machine, Stripe sync),
-- customer_payment_methods (saved cards) — role matrix, service-only writes,
-- idempotency, isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ membership_plans
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.membership_plans (shop_id, name, price_cents, interval, included_service_ids, discount_bps)
  values (tests.fx('shop_a'), '  Monthly Maintenance ', 4900, 'month', array[tests.fx('svc_a'), tests.fx('svc_a')], 1000)
  returning tests.fx_set('plan_a', id);
select tests.ok((select name = 'Monthly Maintenance' and included_service_ids = array[tests.fx('svc_a')] and interval_count = 1 and active
                 from public.membership_plans where id = tests.fx('plan_a')), 'manager creates a plan; included services de-duplicated');
select tests.throws_like($$insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
                           values (tests.fx('shop_a'), 'X', 100, array[tests.fx('svc_b')])$$, '23503', '%belong to this shop%',
                         'included services must be this shop''s');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count)
                      values (tests.fx('shop_a'), 'X', 100, 'year', 2)$$, '23514', 'yearly plans bill once a year');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count)
                      values (tests.fx('shop_a'), 'X', 100, 'month', 13)$$, '23514', 'at most 12 months');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'X', 0)$$, '23514',
                    'plans have a price');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, discount_bps) values (tests.fx('shop_a'), 'X', 100, 10001)$$,
                    '23514', 'discount <= 100%');
select tests.throws_like($$insert into public.membership_plans (shop_id, name, price_cents, stripe_price_id)
                           values (tests.fx('shop_a'), 'X', 100, 'price_123')$$, '42501', '%payments service%',
                         'Stripe ids cannot be set by staff');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_b'), 'X', 100)$$, '42501',
                    'manager of A cannot create plans in B');
select tests.as_service();
update public.membership_plans set stripe_product_id = 'prod_1', stripe_price_id = 'price_1' where id = tests.fx('plan_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.membership_plans set stripe_price_id = 'price_2' where id = tests.fx('plan_a')$$, '42501',
                    'staff cannot point a plan at another Stripe price');
select tests.throws($$update public.membership_plans set stripe_product_id = null where id = tests.fx('plan_a')$$, '42501',
                    'staff cannot change the Stripe product');
update public.membership_plans set name = 'Monthly Maintenance Plus', description = 'Two washes a month' where id = tests.fx('plan_a');
select tests.eq((select stripe_price_id from public.membership_plans where id = tests.fx('plan_a')), 'price_1', 'cosmetic edits keep the Stripe price');
update public.membership_plans set price_cents = 5900 where id = tests.fx('plan_a');
select tests.ok((select stripe_price_id is null and stripe_product_id = 'prod_1' from public.membership_plans where id = tests.fx('plan_a')),
                'changing the price detaches the (immutable) Stripe price; the product stays');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select * from public.membership_plans where shop_id = tests.fx('shop_a')$$), 1::bigint, 'owner reads plans');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select * from public.membership_plans$$), 0::bigint, 'technicians have no access to plans');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'X', 100)$$, '42501',
                    'technicians cannot create plans');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select * from public.membership_plans where shop_id = tests.fx('shop_a')$$), 0::bigint, 'B cannot read A''s plans');
select tests.eq(tests.row_count($$update public.membership_plans set name = 'x' where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor edit them');
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_b'), 'B plan', 3000) returning tests.fx_set('plan_b', id);

-- ------------------------------------------------------------ create_membership
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select concat_ws('/', status, customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a'), created_by = tests.fx('u_manager_a'),
                                  started_at is null, stripe_subscription_id is null)
                   from public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'), tests.fx('veh_a'))),
                'incomplete/t/t/t/t/t', 'manager creates an incomplete membership');
select tests.fx_set('mem_a', (select id from public.memberships where customer_id = tests.fx('cust_a') and vehicle_id = tests.fx('veh_a')));
select tests.throws_like($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'), tests.fx('veh_a'))$$, '23505',
                         '%already has an open membership%', 'one open membership per plan, customer and vehicle');
select tests.lives($$select tests.fx_set('mem_a_novehicle', (public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'))).id)$$,
                   'a customer-level membership is separate from a vehicle one');
select tests.throws($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'))$$, '23505',
                    'customer-level duplicate rejected (nulls not distinct)');
select tests.throws_like($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a2'), tests.fx('veh_a'))$$, '22023',
                         '%does not belong%', 'vehicle must belong to the customer');
select tests.throws($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_b'))$$, 'P0002', 'another shop''s customer: not found');
select tests.throws($$select public.create_membership(tests.fx('plan_b'), tests.fx('cust_a'))$$, 'P0002', 'another shop''s plan: not found');
select tests.throws($$insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan_a'), tests.fx('cust_a2'))$$,
                    '42501', 'memberships are created through create_membership');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a2'))$$, '42501', 'technicians cannot create memberships');
select tests.eq(tests.row_count($$select * from public.memberships$$), 0::bigint, 'technicians see no memberships');
select tests.as_anon();
select tests.throws($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a2'))$$, '42501', 'anon cannot create memberships');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.membership_plans set archived_at = now() where id = tests.fx('plan_a');
select tests.throws_like($$select public.create_membership(tests.fx('plan_a'), tests.fx('cust_a2'))$$, '22023', '%not available%',
                         'archived plans take no new members');
update public.membership_plans set archived_at = null where id = tests.fx('plan_a');

-- staff edits: vehicle only; status is billing's (membership_cancel)
select tests.throws_like($$update public.memberships set vehicle_id = tests.fx('veh_a2') where id = tests.fx('mem_a')$$, '23514',
                         '%does not belong%', 'membership vehicle must belong to the customer');
select tests.throws_like($$update public.memberships set status = 'active' where id = tests.fx('mem_a')$$, '42501', '%billing%',
                         'staff cannot activate memberships');
select tests.throws($$update public.memberships set stripe_subscription_id = 'sub_forged' where id = tests.fx('mem_a')$$, '42501',
                    'staff cannot set Stripe fields');
select tests.throws($$update public.memberships set current_period_end = now() where id = tests.fx('mem_a')$$, '42501',
                    'staff cannot set billing periods');
-- An incomplete membership may have a payable subscription-mode Checkout link
-- (membership_checkout) the database does not know about: only
-- membership_cancel, which expires those links first, abandons it.
select tests.throws_like($$update public.memberships set status = 'cancelled', cancelled_at = '2020-01-01Z' where id = tests.fx('mem_a_novehicle')$$,
                         '42501', '%membership_cancel%',
                         'staff cannot cancel an incomplete membership behind membership_cancel''s back');
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_novehicle')$$, '42501',
                    'staff cannot delete an incomplete membership (its checkout link would stay payable)');
select tests.eq((select status::text from public.memberships where id = tests.fx('mem_a_novehicle')), 'incomplete',
                'the membership is untouched');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_novehicle')$$, '42501', 'nor can the owner');
select tests.throws($$update public.memberships set status = 'cancelled' where id = tests.fx('mem_a_novehicle')$$, '42501',
                    'nor cancel it directly');
-- membership_cancel (payments edge function, service_role) abandons it once its links are expired
select tests.as_service();
select tests.eq(tests.row_count($$update public.memberships set status = 'cancelled'
                                  where id = tests.fx('mem_a_novehicle') and status = 'incomplete' and stripe_subscription_id is null$$),
                1::bigint, 'membership_cancel abandons the incomplete membership');
select tests.eq((select cancelled_at from public.memberships where id = tests.fx('mem_a_novehicle')), now(), 'cancelled_at is server-stamped');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select tests.fx_set('mem_a_again', (public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'))).id)$$,
                   'a cancelled membership frees the slot');
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_novehicle')$$, '42501',
                    'cancelled memberships are history (not deletable)');
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_again')$$, '42501',
                    'never-billed incomplete memberships are not deletable either');
select tests.throws($$update public.memberships set status = 'cancelled' where id = tests.fx('mem_a_again')$$, '42501',
                    'nor cancellable directly');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_again')$$, '42501', 'technicians cannot delete memberships');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a_again')$$, '42501', 'another shop''s manager cannot delete them');
select tests.eq(tests.row_count($$update public.memberships set status = 'cancelled' where id = tests.fx('mem_a_again')$$), 0::bigint,
                'nor cancel them (RLS: not visible)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.membership_plans where id = tests.fx('plan_a')$$, '23503', 'plans with memberships cannot be deleted');

-- ------------------------------------------------------------ sync_stripe_subscription (service_role)
select tests.throws($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active')$$, '42501', 'staff cannot sync subscriptions');
select tests.as_service();
select tests.eq((select concat_ws('/', status, stripe_subscription_id, started_at, current_period_end, cancel_at_period_end)
                   from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-07-01Z', false, tests.fx('mem_a'), '2025-06-01Z')),
                'active/sub_1/2025-06-01 00:00:00+00/2025-07-01 00:00:00+00/f', 'first sync links the subscription and activates');
select tests.lives($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-07-01Z', false, tests.fx('mem_a'), '2025-06-05Z')$$);
select tests.eq((select started_at from public.memberships where id = tests.fx('mem_a')), '2025-06-01Z'::timestamptz, 'replay keeps started_at');
select tests.eq((select status::text from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'past_due', null, false, null, '2025-07-02Z')),
                'past_due', 'active -> past_due');
select tests.eq((select concat_ws('/', status, current_period_end) from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-08-01Z', false, null, '2025-07-03Z')),
                'active/2025-08-01 00:00:00+00', 'past_due -> active with a new period');
select tests.eq((select status::text from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'incomplete', null, false, null, '2025-07-03Z')),
                'active', 'a late "incomplete" event never regresses an active membership');
select tests.eq((select cancel_at_period_end from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-08-01Z', true, null, '2025-07-04Z')),
                true, 'cancel at period end tracked');
select tests.eq((select concat_ws('/', status, cancelled_at, cancel_at_period_end)
                   from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'cancelled', '2025-08-01Z', false, null, '2025-08-01Z')),
                'cancelled/2025-08-01 00:00:00+00/f', 'cancelled with the event time');
select tests.eq((select concat_ws('/', status, cancelled_at) from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-09-01Z', false, null, '2025-08-02Z')),
                'cancelled/2025-08-01 00:00:00+00', 'a late "active" event never revives a cancelled membership');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_b'), 'sub_1', 'active')$$, '22023', '%another shop%',
                         'a subscription cannot switch shops');
select tests.throws($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_unknown', 'active')$$, 'P0002', 'unknown subscription');
select tests.throws($$select public.sync_stripe_subscription(tests.fx('shop_b'), 'sub_2', 'active', null, false, tests.fx('mem_a'))$$, 'P0002',
                    'a membership of another shop cannot be linked');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_2', 'active', null, false, tests.fx('mem_a'))$$, '22023',
                         '%another subscription%', 'a linked membership cannot be re-linked');
select tests.as_superuser();
select tests.throws($$update public.memberships set status = 'active' where id = tests.fx('mem_a')$$, '23514', 'cancelled is terminal even for trusted code');
select tests.throws($$insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan_b'), tests.fx('cust_a'))$$,
                    '23503', 'membership cannot use another shop''s plan');
select tests.throws($$insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan_a'), tests.fx('cust_b'))$$,
                    '23503', 'membership cannot use another shop''s customer');

-- membership payments (invoice.paid for the subscription)
insert into public.memberships (shop_id, plan_id, customer_id, status, stripe_subscription_id)
  values (tests.fx('shop_a'), tests.fx('plan_a'), tests.fx('cust_a2'), 'active', 'sub_3') returning tests.fx_set('mem_a3', id);
select tests.as_service();
select tests.eq((select concat_ws('/', kind, customer_id = tests.fx('cust_a2'), invoice_id is null, job_id is null)
                   from public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_mem1', 'succeeded', 5900, p_kind => 'membership',
                                                     p_membership_id => tests.fx('mem_a3'))),
                'membership/t/t/t', 'membership payment takes the membership''s customer');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_mem2', 'succeeded', 5900, p_kind => 'membership',
                                                              p_membership_id => tests.fx('mem_a3'), p_customer_id => tests.fx('cust_a'))$$,
                         '23514', '%membership''s customer%', 'membership payment customer must match');
select tests.as_superuser();
select tests.throws($$delete from public.memberships where id = tests.fx('mem_a3')$$, '23503', 'memberships with payments cannot be deleted');

-- ------------------------------------------------------------ memberships isolation
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select * from public.memberships where shop_id = tests.fx('shop_a')$$), 0::bigint, 'B cannot read A''s memberships');
select tests.eq(tests.row_count($$update public.memberships set vehicle_id = null where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor edit them');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select * from public.memberships where shop_id = tests.fx('shop_a')$$), 4::bigint, 'admin reads memberships');

-- ------------------------------------------------------------ customer_payment_methods (saved cards)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_1')$$, '42501',
                    'staff cannot write saved cards');
select tests.throws($$insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'pm_1')$$, '42501', 'no direct inserts');
select tests.as_service();
select tests.eq((select concat_ws('/', brand, last4, exp_month, exp_year, is_default)
                   from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_1', ' Visa ', '4242', 12, 2030)),
                'visa/4242/12/2030/t', 'first card becomes the default');
select tests.eq((select is_default from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_2', 'mastercard', '4444', 1, 2031)),
                false, 'second card is not the default');
select tests.eq((select is_default from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_2', p_make_default => true)),
                true, 'make default');
select tests.eq((select string_agg(stripe_payment_method_id || ':' || is_default::text, ',' order by stripe_payment_method_id)
                   from public.customer_payment_methods where customer_id = tests.fx('cust_a')),
                'pm_1:false,pm_2:true', 'exactly one default');
select tests.eq((select concat_ws('/', last4, exp_year, is_default) from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_2', null, null, 2, 2032)),
                '4444/2032/t', 'replay updates details, keeps the default and the known card data');
select tests.eq((select count(*) from public.customer_payment_methods where customer_id = tests.fx('cust_a')), 2::bigint, 'upsert is idempotent');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_1')$$, '22023',
                         '%another customer%', 'a card cannot move to another customer');
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_b'), 'pm_9')$$, 'P0002',
                    'another shop''s customer: not found');
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_9', 'visa', '42')$$, '23514',
                    'last4 is exactly four digits');
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), '4242424242424242')$$, '23514',
                    'only Stripe payment method ids are stored (never card numbers)');
select tests.eq(public.remove_customer_payment_method(tests.fx('shop_a'), 'pm_2'), true, 'remove the default card');
select tests.eq((select is_default from public.customer_payment_methods where stripe_payment_method_id = 'pm_1'), true,
                'the remaining card is promoted to default');
select tests.eq(public.remove_customer_payment_method(tests.fx('shop_a'), 'pm_2'), false, 'removal is idempotent');
select tests.eq(public.remove_customer_payment_method(tests.fx('shop_b'), 'pm_1'), false, 'removal is scoped to the shop');
select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a3'), 'pm_3', 'amex', '0005', 3, 2029);
select public.upsert_customer_payment_method(tests.fx('shop_b'), tests.fx('cust_b'), 'pm_b', 'visa', '1881', 3, 2029);
select tests.as_superuser();
select tests.throws($$insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id, is_default)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'pm_4', true)$$, '23505', 'at most one default card per customer');
select tests.throws($$insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id)
                      values (tests.fx('shop_a'), tests.fx('cust_b'), 'pm_5')$$, '23503', 'a card cannot point at another shop''s customer');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select * from public.customer_payment_methods where customer_id = tests.fx('cust_a')$$), 1::bigint,
                'managers read saved cards');
select tests.throws($$update public.customer_payment_methods set is_default = false where customer_id = tests.fx('cust_a')$$, '42501',
                    'no direct updates');
select tests.throws($$delete from public.customer_payment_methods where customer_id = tests.fx('cust_a')$$, '42501', 'no direct deletes');
select tests.eq(tests.row_count($$select * from public.customer_payment_methods where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'A cannot read B''s cards');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select * from public.customer_payment_methods$$), 2::bigint, 'owner reads the shop''s cards');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select * from public.customer_payment_methods$$), 0::bigint, 'technicians never see saved cards');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select * from public.customer_payment_methods where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'B cannot read A''s cards');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_a3')$$), 1::bigint, 'a customer without money records can be deleted');
select tests.as_superuser();
select tests.eq((select count(*) from public.customer_payment_methods where stripe_payment_method_id = 'pm_3'), 0::bigint,
                'their saved card references go with them');
