-- 80 comms: an unsubscribe link opts out the ADDRESS the email went to, never
-- the current, different address of the customer the message points at now.
-- Regression: public_unsubscribe (0035) also stamped email_opted_out_at on
-- the message's current customer; customers_comms_optout_sync then
-- suppressed that customer's current address shop-wide, and every email to
-- them (transactional included) was refused. It happened after a plain email
-- change, and after merge_customers (0074) moved a duplicate's messages (and
-- so its unsubscribe links) to the survivor. Fixed in 0083 (public_unsubscribe
-- relies on comms_suppress, which stamps only customers whose current email
-- is the link's address). Also: the link's own address is still opted out on
-- every record that has it; moving back to it opts out again; a customer with
-- no email is not stamped (so their next address is not suppressed); shop
-- isolation; unknown tokens.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
update public.message_templates set enabled = true, body = 'Come back! {{unsubscribe_link}}'
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'email';

-- ============================================================ merge (the repro)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Dup', 'old-address@example.com', true) returning tests.fx_set('dup', id);
insert into public.customers (shop_id, first_name, email)
  values (tests.fx('shop_a'), 'Survivor', 'current@example.com') returning tests.fx_set('surv', id);
-- another record that still has the old address, and the same address in shop B
insert into public.customers (shop_id, first_name, email)
  values (tests.fx('shop_a'), 'Other', 'Old-Address@Example.com') returning tests.fx_set('other_old', id);
insert into public.customers (shop_id, first_name, email)
  values (tests.fx('shop_b'), 'Survivor B', 'current@example.com') returning tests.fx_set('surv_b', id);

select tests.as_service();
select tests.fx_set('mkt', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('dup'), 'follow_up', 'email'));
select tests.reset();
select tests.fx_set('tok', (select unsubscribe_token from public.messages where id = tests.fx('mkt')));
select tests.ok(tests.fx('tok') is not null, 'the marketing email carries an unsubscribe token');

select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('dup'), tests.fx('surv'));
select tests.reset();
select tests.eq((select customer_id from public.messages where id = tests.fx('mkt')), tests.fx('surv'),
                'the merge moved the duplicate''s email (and its link) to the survivor');
select tests.eq((select email::text from public.customers where id = tests.fx('surv')), 'current@example.com',
                'the survivor keeps its own address');

select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('tok')), 'the old address unsubscribes');
select tests.ok(public.public_unsubscribe(tests.fx('tok')), 'idempotent');
select tests.reset();
select tests.ok(public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'old-address@example.com'),
                'the address the email went to is suppressed');
select tests.eq((select count(*) from public.comms_suppressions
                  where shop_id = tests.fx('shop_a') and address = 'current@example.com'), 0::bigint,
                'an address that never unsubscribed is not suppressed');
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('surv')),
                'the survivor is not opted out by a link sent to old-address@example.com');
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('other_old')),
                'a record whose current email is the link''s address is opted out (case-insensitive)');
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('surv_b'))
                and not public.comms_is_suppressed(tests.fx('shop_b'), 'email', 'current@example.com')
                and not public.comms_is_suppressed(tests.fx('shop_b'), 'email', 'old-address@example.com'),
                'shop B is untouched');

-- the survivor still gets email
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.queue_message(tests.fx('shop_a'), tests.fx('surv'), 'email', 'Your invoice', 'Here it is')).to_address,
                'current@example.com', 'staff can still email the survivor');
select tests.reset();
select tests.as_service();
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('other_old'), 'follow_up', 'email') is null,
                'marketing to the unsubscribed address is refused');
select tests.reset();

-- moving the survivor back to the unsubscribed address opts them out again
update public.customers set email = 'old-address@example.com' where id = tests.fx('surv');
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('surv')),
                'the unsubscribed address carries its opt-out to whoever uses it');
update public.customers set email = 'current@example.com' where id = tests.fx('surv');
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('surv')),
                'and moving away again drops it without suppressing the new address');
select tests.ok(not public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'current@example.com'),
                'current@example.com is still not suppressed');

-- ============================================================ plain email change (no merge)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Mover', 'mover-old@example.com', true) returning tests.fx_set('mover', id);
select tests.as_service();
select tests.fx_set('mkt2', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('mover'), 'follow_up', 'email'));
select tests.reset();
select tests.fx_set('tok2', (select unsubscribe_token from public.messages where id = tests.fx('mkt2')));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set email = 'mover-new@example.com' where id = tests.fx('mover');
select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('tok2')), 'the old address unsubscribes after the change');
select tests.reset();
select tests.ok(public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'mover-old@example.com'), 'old address suppressed');
select tests.ok(not public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'mover-new@example.com'), 'new address not suppressed');
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('mover')),
                'the customer at the new address is not opted out');

-- ============================================================ email removed, then a new one
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Nomail', 'nomail-old@example.com', true) returning tests.fx_set('nomail', id);
select tests.as_service();
select tests.fx_set('mkt3', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('nomail'), 'follow_up', 'email'));
select tests.reset();
select tests.fx_set('tok3', (select unsubscribe_token from public.messages where id = tests.fx('mkt3')));
update public.customers set email = null where id = tests.fx('nomail');
select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('tok3')), 'the removed address unsubscribes');
select tests.reset();
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('nomail')),
                'a customer with no email is not stamped by a link to a previous address');
update public.customers set email = 'nomail-new@example.com' where id = tests.fx('nomail');
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('nomail'))
                and not public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'nomail-new@example.com'),
                'so the address they give next is not suppressed');

-- ============================================================ current address still works (happy path)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Stayer', 'stayer@example.com', true) returning tests.fx_set('stayer', id);
select tests.as_service();
select tests.fx_set('mkt4', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('stayer'), 'follow_up', 'email'));
select tests.reset();
select tests.fx_set('tok4', (select unsubscribe_token from public.messages where id = tests.fx('mkt4')));
select tests.as_anon();
select tests.ok(public.public_unsubscribe(tests.fx('tok4')), 'unsubscribes');
select tests.reset();
select tests.ok((select email_opted_out_at is not null and not email_opt_in from public.customers where id = tests.fx('stayer')),
                'a customer still at the link''s address is opted out');
select tests.eq((select status::text from public.messages where id = tests.fx('mkt4')), 'cancelled',
                'and the queued email to it is withdrawn');

-- ============================================================ invalid links
select tests.as_anon();
select tests.eq(public.public_unsubscribe(gen_random_uuid()), false, 'unknown token: false');
select tests.eq(public.public_unsubscribe(null), false, 'null token: false');
select tests.reset();
