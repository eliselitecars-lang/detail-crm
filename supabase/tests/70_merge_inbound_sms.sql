-- 70 ops: after a customer merge (P-20), a text from the merged duplicate's
-- number reaches the surviving customer (comms_inbound_sms_customer follows
-- merged_into_id, replaced in 0074): the message, the reply thread
-- (inbox_threads), the staff notification and opt-outs. Chains of merges,
-- a customer who really holds the number, unknown numbers, the helper's
-- grants and two-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+13125550100', tests.fx('shop_b'));
update public.shops set sms_from_number = '+13125550100' where id = tests.fx('shop_b');
-- shop B has its own customer with Alice's number
update public.customers set phone = '+12055550101' where id = tests.fx('cust_b');
update public.customers set phone = '+12055550999' where id = tests.fx('cust_a2');

-- ============================================================ before any merge
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Hello', 'SMm0')),
                tests.fx('cust_a'), 'before the merge Alice''s number is Alice');
-- the whole file is one transaction (now() is constant), so date this earlier
-- text back: otherwise it ties with the post-merge text on created_at and the
-- survivor thread's "latest message" below falls to a random uuid tie-break
select tests.as_superuser();
update public.messages set created_at = created_at - interval '1 minute'
 where shop_id = tests.fx('shop_a') and provider_message_id = 'SMm0';
select tests.eq((select count(*) from public.messages
                  where shop_id = tests.fx('shop_a') and provider_message_id = 'SMm0'
                    and created_at < now()), 1::bigint, 'the pre-merge text is dated earlier');

-- ============================================================ merge Alice into Aaron
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('cust_a'), tests.fx('cust_a2'));
select tests.as_superuser();
select tests.eq((select array[phone, merged_into_id::text, (archived_at is not null)::text]
                   from public.customers where id = tests.fx('cust_a')),
                array['+12055550101', tests.fx('cust_a2')::text, 'true'],
                'the duplicate keeps its number and points at the survivor');
select tests.eq((select phone from public.customers where id = tests.fx('cust_a2')), '+12055550999',
                'the survivor keeps its own number');

select tests.as_service();
create temp table in1 as
  select * from public.record_inbound_sms('+12055550100', '+12055550101', 'Running 10 min late', 'SMm1');
select tests.fx_set('m1', (select message_id from in1));
select tests.eq((select customer_id from in1), tests.fx('cust_a2'),
                'a text from the merged duplicate''s number reaches the surviving customer');
select tests.eq((select opt_action from in1), null::text, 'an ordinary reply');
select tests.eq((select customer_id from public.messages where id = tests.fx('m1')), tests.fx('cust_a2'),
                'the message is stored on the survivor');
select tests.as_superuser();
select tests.eq((select array_agg(distinct customer_id) from public.notifications
                  where shop_id = tests.fx('shop_a') and kind = 'inbound_message' and body = 'Running 10 min late'),
                array[tests.fx('cust_a2')], 'the staff notifications link the survivor');
select tests.ok((select bool_and(title = 'New text from Aaron Other') from public.notifications
                  where shop_id = tests.fx('shop_a') and kind = 'inbound_message' and body = 'Running 10 min late'),
                'and name the survivor');

-- the inbox shows one thread for the survivor, none for the duplicate
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a')) where customer_id = tests.fx('cust_a')),
                0::bigint, 'no thread of the merged duplicate');
select tests.eq((select array[thread_key, from_address, last_message_id::text]
                   from public.inbox_threads(tests.fx('shop_a')) where customer_id = tests.fx('cust_a2')),
                array['c:' || tests.fx('cust_a2'), '+12055550101', tests.fx('m1')::text],
                'the survivor''s thread carries the new text and the number it came from');

-- replaying the webhook returns the stored row (idempotent)
select tests.as_service();
select tests.eq((select array[message_id::text, customer_id::text]
                   from public.record_inbound_sms('+12055550100', '+12055550101', 'Running 10 min late', 'SMm1')),
                array[tests.fx('m1')::text, tests.fx('cust_a2')::text], 'a replay is the same message');

-- STOP from the duplicate's number opts the number out and is the survivor's
select tests.eq((select array[customer_id::text, opt_action]
                   from public.record_inbound_sms('+12055550100', '+12055550101', 'stop', 'SMm2')),
                array[tests.fx('cust_a2')::text, 'opt_out'], 'STOP from the old number: the survivor, opt-out');
select tests.ok(public.comms_is_suppressed(tests.fx('shop_a'), 'sms', '+12055550101'), 'the number is suppressed');
select tests.eq((select array[customer_id::text, opt_action]
                   from public.record_inbound_sms('+12055550100', '+12055550101', 'START', 'SMm3')),
                array[tests.fx('cust_a2')::text, 'opt_in'], 'START: the survivor, opt-in');

-- ============================================================ chains
-- the survivor is merged again: the text follows both links
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('cust_a2'), tests.fx('cust_a3'));
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Still coming', 'SMm4')),
                tests.fx('cust_a3'), 'a chain of merges ends at the last survivor');
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550999', 'From Aaron''s phone', 'SMm5')),
                tests.fx('cust_a3'), 'the middle duplicate''s own number follows too');
select tests.eq((select customer_id from public.messages where provider_message_id = 'SMm4'), tests.fx('cust_a3'),
                'stored on the last survivor');

-- an archived (not merged) survivor is still the survivor
select tests.as_superuser();
update public.customers set archived_at = now() where id = tests.fx('cust_a3');
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Anyone?', 'SMm6')),
                tests.fx('cust_a3'), 'an archived survivor still gets its duplicate''s texts');
select tests.as_superuser();
update public.customers set archived_at = null where id = tests.fx('cust_a3');

-- someone who really holds the number now wins over a merged holder
insert into public.customers (shop_id, first_name, phone, created_at)
  values (tests.fx('shop_a'), 'Newer', '+12055550101', now() - interval '1 day') returning tests.fx_set('cust_new', id);
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Hi again', 'SMm7')),
                tests.fx('cust_new'), 'an active customer with the number wins over a merged duplicate''s survivor');
select tests.as_superuser();
update public.customers set archived_at = now() where id = tests.fx('cust_new');
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Hi once more', 'SMm8')),
                tests.fx('cust_a3'), 'an active survivor wins over an archived holder');

-- ============================================================ unknown numbers and other shops
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550777', 'Who is this', 'SMm9')),
                null::uuid, 'an unknown number has no customer');
select tests.eq((select customer_id from public.record_inbound_sms('+13125550100', '+12055550101', 'Hi B', 'SMm10')),
                tests.fx('cust_b'), 'shop B''s own customer with the same number is unaffected by shop A''s merges');
select tests.eq((select (public.comms_inbound_sms_customer(tests.fx('shop_b'), '+12055550999')).id), null::uuid,
                'another shop''s merged numbers are never matched');

-- ============================================================ grants
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.comms_inbound_sms_customer(tests.fx('shop_a'), '+12055550101')$$, '42501',
                    'staff cannot call the internal matcher');
select tests.as_anon();
select tests.throws($$select public.comms_inbound_sms_customer(tests.fx('shop_a'), '+12055550101')$$, '42501',
                    'nor anon');

-- ============================================================ upgrade-path regression
-- 0074 defines comms_inbound_sms_customer and re-defines record_inbound_sms
-- itself (the committed 0033 is never edited in place). A database that
-- already applied 0033 gets only what 0074 says, so 0074 must revoke the
-- default PUBLIC execute of the new definer function (it returns a whole
-- customers row) and must route record_inbound_sms through it.
select tests.as_superuser();
update public.customers set phone = '+12055550123', email = 'secret@example.com' where id = tests.fx('cust_a');
select tests.eq(has_function_privilege('anon', 'public.comms_inbound_sms_customer(uuid, text)', 'execute'), false,
                'anon cannot execute comms_inbound_sms_customer');
select tests.eq(has_function_privilege('authenticated', 'public.comms_inbound_sms_customer(uuid, text)', 'execute'), false,
                'authenticated cannot execute comms_inbound_sms_customer');
select tests.eq((select count(*) from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = 'public.comms_inbound_sms_customer(uuid, text)'::regprocedure
                    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
                0::bigint, 'PUBLIC has no execute on comms_inbound_sms_customer');
select tests.eq(has_function_privilege('service_role', 'public.comms_inbound_sms_customer(uuid, text)', 'execute'), true,
                'service_role executes comms_inbound_sms_customer');
select tests.eq(array[has_function_privilege('anon', 'public.record_inbound_sms(text, text, text, text)', 'execute'),
                      has_function_privilege('authenticated', 'public.record_inbound_sms(text, text, text, text)', 'execute'),
                      has_function_privilege('service_role', 'public.record_inbound_sms(text, text, text, text)', 'execute')],
                array[false, false, true], 'record_inbound_sms stays service_role only');
select tests.eq((select array[p.prosecdef::text, array_to_string(p.proconfig, ',')] from pg_proc p
                  where p.oid = 'public.comms_inbound_sms_customer(uuid, text)'::regprocedure),
                array['true', 'search_path=""'], 'the matcher is security definer with an empty search_path');
select tests.eq((select array[p.prosecdef::text, array_to_string(p.proconfig, ',')] from pg_proc p
                  where p.oid = 'public.record_inbound_sms(text, text, text, text)'::regprocedure),
                array['true', 'search_path=""'], 'record_inbound_sms keeps security definer with an empty search_path');
select tests.ok((select p.prosrc like '%public.comms_inbound_sms_customer(v_shop.id, v_from)%' from pg_proc p
                  where p.oid = 'public.record_inbound_sms(text, text, text, text)'::regprocedure),
                'record_inbound_sms looks the sender up through comms_inbound_sms_customer');
select tests.eq((select obj_description('public.record_inbound_sms(text, text, text, text)'::regprocedure, 'pg_proc')),
                '@nullable: customer_id, opt_action', 'the contract tag survives the re-definition');
select tests.as_anon();
select tests.throws($$select (public.comms_inbound_sms_customer(tests.fx('shop_a'), '+12055550123')).email$$, '42501',
                    'anon cannot read a customer row by phone number');
select tests.as_service();
select tests.eq((select customer_id from public.record_inbound_sms('+12055550100', '+12055550123', 'New number', 'SMm11')),
                tests.fx('cust_a3'), 'a text from the duplicate''s new number still follows the merge chain');
