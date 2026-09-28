-- 60 money: Stripe Terminal / Tap to Pay (P-6, 0061 + 0064) —
-- shop_terminal_locations (format CHECKs, service_role writes, owner/admin
-- reads, isolation, cascade) and a card_present PaymentIntent recorded
-- pending, in flight meanwhile, settling like a PaymentSheet payment.
\ir fixtures/two_shops.psql

-- ============================================================ shop_terminal_locations
select tests.as_service();
insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
  values (tests.fx('shop_a'), 'tml_A1b2C3', encode(sha256('1 Main St|Birmingham|35203|US'::bytea), 'hex'));
insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
  values (tests.fx('shop_b'), 'tml_B9', encode(sha256('b'::bytea), 'hex'));
select tests.throws($$insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
                      values (tests.fx('shop_a'), 'tml_dup', repeat('a', 64))$$, '23505', 'one Terminal location per shop');
select tests.as_superuser();
delete from public.shop_terminal_locations where shop_id = tests.fx('shop_b');
select tests.as_service();
select tests.throws($$insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
                      values (tests.fx('shop_b'), 'loc_123', repeat('a', 64))$$, '23514', 'Stripe location ids start with tml_');
select tests.throws($$insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
                      values (tests.fx('shop_b'), 'tml_1', 'not-a-hash')$$, '23514', 'address_hash is a sha256 hex digest');
insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
  values (tests.fx('shop_b'), 'tml_B9', encode(sha256('b'::bytea), 'hex'));
update public.shop_terminal_locations set stripe_location_id = 'tml_A2', address_hash = encode(sha256('new address'::bytea), 'hex')
 where shop_id = tests.fx('shop_a');
select tests.ok((select updated_at = now() from public.shop_terminal_locations where shop_id = tests.fx('shop_a')),
                'the edge function replaces the location when the address changes');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select stripe_location_id from public.shop_terminal_locations where shop_id = tests.fx('shop_a')), 'tml_A2',
                'owners read their shop''s Terminal location');
select tests.eq((select count(*) from public.shop_terminal_locations where shop_id = tests.fx('shop_b')), 0::bigint,
                'but not another shop''s');
select tests.throws($$insert into public.shop_terminal_locations (shop_id, stripe_location_id, address_hash)
                      values (tests.fx('shop_a'), 'tml_x', repeat('a', 64))$$, '42501', 'clients never write it (owner)');
select tests.throws($$update public.shop_terminal_locations set stripe_location_id = 'tml_x' where shop_id = tests.fx('shop_a')$$,
                    '42501', 'nor update it');
select tests.throws($$delete from public.shop_terminal_locations where shop_id = tests.fx('shop_a')$$, '42501', 'nor delete it');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select count(*) from public.shop_terminal_locations), 1::bigint, 'admins read it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.shop_terminal_locations), 0::bigint, 'managers do not (Stripe account data)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.shop_terminal_locations), 0::bigint, 'technicians do not');
select tests.as_anon();
select tests.throws($$select count(*) from public.shop_terminal_locations$$, '42501', 'anon has no access');

-- ============================================================ a Terminal payment
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
-- terminal_payment_intent: the edge function records the pending card_present row
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tml1', 'pending', 15000, 2000, 'payment', 'card_present',
                                    p_invoice_id => tests.fx('inv'), p_stripe_method_type => 'card_present');
select tests.eq((select concat_ws('/', status, method, job_id = tests.fx('job_a'), customer_id = tests.fx('cust_a'))
                   from public.payments where stripe_payment_intent_id = 'pi_tml1'), 'pending/card_present/t/t',
                'a pending card_present row linked like any invoice payment');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv'), 10000, 'cash')$$, '22023', '%in progress%',
                         'while the reader is being tapped the same balance cannot be paid in cash');
select tests.eq((select pending_cents from public.job_payment_summary(tests.fx('job_a'))), 17000::bigint,
                'the job summary shows the charge in progress (amount + tip)');
-- the customer taps the card: payment_intent.succeeded with card_present details
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_tml1', 'succeeded', 15000, 2000, 'payment', 'card_present',
                                    p_charge_id => 'ch_tml1', p_card_brand => 'Visa', p_card_last4 => '4242');
select tests.eq((select concat_ws('/', status, card_brand, card_last4, tip_cents) from public.payments where stripe_payment_intent_id = 'pi_tml1'),
                'succeeded/visa/4242/2000', 'settles like a PaymentSheet payment, with the card details');
select tests.eq((select concat_ws('/', status, amount_paid_cents, balance_cents, tip_cents) from public.invoices where id = tests.fx('inv')),
                'partially_paid/15000/5000/2000', 'the tip never counts toward the balance');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 5000, 'cash')$$, 'the rest can be paid in cash now');

-- ============================================================ cascade with the shop
select tests.as_superuser();
delete from public.shops where id = tests.fx('shop_b');
select tests.eq((select count(*) from public.shop_terminal_locations where shop_id = tests.fx('shop_b')), 0::bigint,
                'the location row goes with its shop');
