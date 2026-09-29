-- 30 comms: an unsubscribe link keeps working after its customer is deleted.
-- Regression: public_unsubscribe looked the token up in public.messages, and
-- deleting a customer (e.g. cleaning up a duplicate record) cascades to their
-- messages, so every marketing email they had received lost its opt-out:
-- /u/<token> and the one-click List-Unsubscribe POST answered "invalid link",
-- nothing was suppressed, and the address kept getting campaigns through the
-- other record. Tokens now live in comms_unsubscribe_tokens (token -> shop +
-- address), which outlives the message. Access, isolation, denial paths.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.customers (shop_id, first_name, email, email_opt_in, created_at)
  values (tests.fx('shop_a'), 'Dana', 'dana@example.com', true, '2024-01-01Z') returning tests.fx_set('dana_old', id);
insert into public.customers (shop_id, first_name, email, email_opt_in, created_at)
  values (tests.fx('shop_a'), 'Dana', 'Dana@Example.com', true, '2025-01-01Z') returning tests.fx_set('dana_new', id);
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Evan', 'evan@example.com', true) returning tests.fx_set('evan', id);
-- the same address in shop B (isolation)
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_b'), 'Dana B', 'dana@example.com', true) returning tests.fx_set('dana_b', id);

-- ============================================================ the repro
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Spring', 'email', 'Spring deals', 'Hi {{customer_first_name}}') returning tests.fx_set('camp1', id);
select public.launch_campaign(tests.fx('camp1'));
select tests.as_superuser();
select tests.fx_set('msg', (select id from public.messages where campaign_id = tests.fx('camp1') and customer_id = tests.fx('dana_new')));
select tests.fx_set('tok', (select unsubscribe_token from public.messages where id = tests.fx('msg')));
select tests.eq((select count(*) from public.messages where campaign_id = tests.fx('camp1')), 2::bigint,
                'one email per address: Dana (newest record) and Evan');
select tests.eq((select array[address, message_id::text] from public.comms_unsubscribe_tokens where token = tests.fx('tok')),
                array['dana@example.com', tests.fx('msg')::text],
                'the token is recorded with the (normalized) address it was sent to and its message');

select tests.as_service();   -- 0125: erase_customer's delete (service role)
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('dana_new')$$), 1::bigint,
                'the duplicate record is deleted');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where id = tests.fx('msg')), 0::bigint,
                'the customer''s messages went with them');
select tests.ok((select message_id is null from public.comms_unsubscribe_tokens where token = tests.fx('tok')),
                'the token outlives its message');

select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('tok')), true,
                'the unsubscribe link in a sent marketing email still works');
select tests.eq(public.public_unsubscribe(tests.fx('tok')), true, 'idempotent');
select tests.as_superuser();
select tests.ok(public.comms_is_marketing_suppressed(tests.fx('shop_a'), 'email', 'dana@example.com'),
                'address suppressed (0126: from marketing)');
select tests.ok((select email_opted_out_at is null and not email_opt_in from public.customers where id = tests.fx('dana_old')),
                'the remaining record with that address loses marketing consent');
select tests.ok((select email_opted_out_at is null and email_opt_in from public.customers where id = tests.fx('evan')),
                'other recipients are untouched');
select tests.ok((select email_opted_out_at is null and email_opt_in from public.customers where id = tests.fx('dana_b')),
                'the same address in shop B is untouched');
select tests.ok(not public.comms_is_suppressed(tests.fx('shop_b'), 'email', 'dana@example.com'), 'no suppression in shop B');

-- the next campaign skips the address, whichever record carries it now or later
insert into public.customers (shop_id, first_name, email, email_opt_in)
  values (tests.fx('shop_a'), 'Dana', 'dana@example.com', true) returning tests.fx_set('dana_later', id);
select tests.ok((select email_opted_out_at is null and not email_opt_in from public.customers where id = tests.fx('dana_later')),
                'a record created later with the address starts out without marketing consent');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Summer', 'email', 'Summer deals', 'Hi {{customer_first_name}}') returning tests.fx_set('camp2', id);
select tests.eq((select recipient_count from public.launch_campaign(tests.fx('camp2'))), 1, 'only Evan gets the next campaign');
select tests.as_superuser();
select tests.eq((select array_agg(to_address) from public.messages where campaign_id = tests.fx('camp2')),
                array['evan@example.com'], 'the unsubscribed address gets nothing');

-- ============================================================ marketing template email too
update public.message_templates set enabled = true
 where shop_id = tests.fx('shop_a') and key = 'follow_up' and channel = 'email';
select tests.as_service();
select tests.fx_set('fu', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('evan'), 'follow_up', 'email'));
select tests.as_superuser();
select tests.fx_set('fu_tok', (select unsubscribe_token from public.messages where id = tests.fx('fu')));
select tests.ok(exists (select 1 from public.comms_unsubscribe_tokens
                         where token = tests.fx('fu_tok') and address = 'evan@example.com' and message_id = tests.fx('fu')),
                'follow_up email tokens are recorded as well');
delete from public.customers where id = tests.fx('evan');
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('fu_tok')), true, 'the follow-up''s link works after the customer is gone');
select tests.as_superuser();
select tests.ok(public.comms_is_marketing_suppressed(tests.fx('shop_a'), 'email', 'evan@example.com'), 'Evan''s address suppressed');

-- ============================================================ denial paths
-- transactional email never gets a token (and so no credential)
select tests.as_service();
select tests.fx_set('conf', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'email',
                                                             tests.fx('job_a')));
select tests.as_superuser();
select tests.ok((select unsubscribe_token is null from public.messages where id = tests.fx('conf')), 'no token on transactional email');
-- a token set on a transactional row afterwards is never recorded or honoured
update public.messages set unsubscribe_token = gen_random_uuid() where id = tests.fx('conf')
  returning tests.fx_set('conf_tok', unsubscribe_token);
select tests.ok(not exists (select 1 from public.comms_unsubscribe_tokens where token = tests.fx('conf_tok')), 'not recorded');
-- a hand-inserted outbound email that is not marketing is not recorded either
insert into public.messages (shop_id, customer_id, direction, channel, to_address, subject, body, status, unsubscribe_token)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'email', 'alice@example.com', 'Hi', 'Hi', 'queued',
          gen_random_uuid())
  returning tests.fx_set('plain_tok', unsubscribe_token);
select tests.ok(not exists (select 1 from public.comms_unsubscribe_tokens where token = tests.fx('plain_tok')),
                'only campaign / marketing template email records a token');
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('conf_tok')), false, 'a hand-set transactional token is refused');
select tests.eq(public.public_unsubscribe(tests.fx('plain_tok')), false, 'so is a non-marketing token');
select tests.eq(public.public_unsubscribe(gen_random_uuid()), false, 'unknown token');
select tests.eq(public.public_unsubscribe(null), false, 'null token');
select tests.as_superuser();
select tests.ok((select email_opted_out_at is null from public.customers where id = tests.fx('cust_a')), 'Alice untouched');

-- ============================================================ access
select tests.as_anon();
select tests.throws($$select * from public.comms_unsubscribe_tokens$$, '42501', 'anon cannot read tokens');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.comms_unsubscribe_tokens$$, '42501', 'owners cannot read tokens');
select tests.throws($$insert into public.comms_unsubscribe_tokens (shop_id, token, address)
                      values (tests.fx('shop_a'), gen_random_uuid(), 'x@example.com')$$, '42501', 'nor plant one');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$delete from public.comms_unsubscribe_tokens$$, '42501', 'another shop cannot touch them');
select tests.as_service();
select tests.lives($$select count(*) from public.comms_unsubscribe_tokens$$, 'service_role can read them');

-- ============================================================ integrity
select tests.as_superuser();
select tests.throws($$insert into public.comms_unsubscribe_tokens (shop_id, token, address)
                      values (tests.fx('shop_a'), tests.fx('tok'), 'x@example.com')$$, '23505', 'tokens are unique');
select tests.throws($$insert into public.comms_unsubscribe_tokens (shop_id, token, address)
                      values (tests.fx('shop_a'), gen_random_uuid(), 'X@example.com')$$, '23514', 'addresses are normalized');
select tests.throws($$insert into public.comms_unsubscribe_tokens (shop_id, token, address, message_id)
                      values (tests.fx('shop_b'), gen_random_uuid(), 'x@example.com', tests.fx('conf'))$$, '23503',
                    'a token cannot point at another shop''s message');
-- deleting the shop removes its tokens
select tests.eq((select count(*) from public.comms_unsubscribe_tokens where shop_id = tests.fx('shop_a')) > 0, true, 'shop A has tokens');
delete from public.shops where id = tests.fx('shop_a');
select tests.eq((select count(*) from public.comms_unsubscribe_tokens where shop_id = tests.fx('shop_a')), 0::bigint,
                'a deleted shop''s tokens go with it');
