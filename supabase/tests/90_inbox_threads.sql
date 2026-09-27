-- 90 integration: inbox_threads / inbox_unread_count — one row per
-- conversation (a customer, or an unknown sender's address) with its newest
-- message and unread count, keyset paging, role matrix and cross-shop
-- isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550200', tests.fx('shop_b'));

create function pg_temp.msg(p_shop uuid, p_cust uuid, p_dir text, p_ch text, p_to text, p_from text, p_body text,
                            p_at timestamptz, p_read boolean default false) returns uuid
language sql as $$
  insert into public.messages (shop_id, customer_id, direction, channel, to_address, from_address, subject, body, status,
                               read_at, created_at)
  values (p_shop, p_cust, p_dir::public.message_direction, p_ch::public.message_channel, p_to, p_from,
          case when p_ch = 'email' and p_dir = 'outbound' then 'Hello' end, p_body,
          case when p_dir = 'inbound' then 'received' else 'sent' end::public.message_status,
          case when p_read then p_at end, p_at)
  returning id
$$;

-- shop A
select tests.fx_set('m1', pg_temp.msg(tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', '+12055550100',
                                      'Hi Alice, see you Monday', '2025-06-01 10:00Z'));
select tests.fx_set('m2', pg_temp.msg(tests.fx('shop_a'), tests.fx('cust_a'), 'inbound', 'sms', '+12055550100', '+12055550101',
                                      'Thanks!', '2025-06-01 11:00Z'));
select tests.fx_set('m3', pg_temp.msg(tests.fx('shop_a'), tests.fx('cust_a'), 'inbound', 'sms', '+12055550100', '+12055550101',
                                      'See you', '2025-06-01 11:05Z', true));
select tests.fx_set('m4', pg_temp.msg(tests.fx('shop_a'), null, 'inbound', 'sms', '+12055550100', '+12055550177',
                                      'Do you do boats?', '2025-06-01 12:00Z'));
select tests.fx_set('m5', pg_temp.msg(tests.fx('shop_a'), null, 'inbound', 'sms', '+12055550100', '+12055550177',
                                      'Hello?', '2025-06-01 12:10Z'));
select tests.fx_set('m6', pg_temp.msg(tests.fx('shop_a'), tests.fx('cust_a3'), 'outbound', 'email', 'fleet@example.com', null,
                                      'Your fleet quote', '2025-06-01 09:00Z'));
select tests.fx_set('m7', pg_temp.msg(tests.fx('shop_a'), tests.fx('cust_a2'), 'outbound', 'sms', '+12055550102', '+12055550100',
                                      repeat('x', 400), '2025-06-01 08:00Z'));
-- shop B
select tests.fx_set('mb', pg_temp.msg(tests.fx('shop_b'), tests.fx('cust_b'), 'inbound', 'sms', '+12055550200', '+12055550999',
                                      'Shop B secret', '2025-06-01 13:00Z'));

-- ------------------------------------------------------------ grouping and order
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select array_agg(thread_key order by ord) from (
                   select t.thread_key, row_number() over () as ord from public.inbox_threads(tests.fx('shop_a')) t) x),
                array['a:+12055550177', 'c:' || tests.fx('cust_a'), 'c:' || tests.fx('cust_a3'), 'c:' || tests.fx('cust_a2')],
                'one thread per customer / unknown address, newest first');
select tests.eq((select jsonb_build_object('last', last_message_id = tests.fx('m3'), 'dir', last_direction, 'body', last_body,
                                           'unread', unread_count, 'first', customer_first_name, 'last_name', customer_last_name,
                                           'from', from_address, 'at', last_created_at)
                   from public.inbox_threads(tests.fx('shop_a')) where thread_key = 'c:' || tests.fx('cust_a')),
                jsonb_build_object('last', true, 'dir', 'inbound', 'body', 'See you', 'unread', 1, 'first', 'Alice',
                                   'last_name', 'Anders', 'from', '+12055550101', 'at', '2025-06-01T11:05:00+00:00'),
                'a customer thread: newest message, one unread inbound, the customer''s name');
select tests.eq((select jsonb_build_object('cust', customer_id, 'last', last_message_id = tests.fx('m5'), 'unread', unread_count,
                                           'from', from_address, 'channel', last_channel, 'status', last_status)
                   from public.inbox_threads(tests.fx('shop_a')) where thread_key = 'a:+12055550177'),
                '{"cust": null, "last": true, "unread": 2, "from": "+12055550177", "channel": "sms", "status": "received"}'::jsonb,
                'an unknown sender is its own thread');
select tests.eq((select jsonb_build_array(customer_company, customer_first_name, from_address, last_channel::text, unread_count)
                   from public.inbox_threads(tests.fx('shop_a')) where thread_key = 'c:' || tests.fx('cust_a3')),
                '["Fleet Co", null, "fleet@example.com", "email", 0]'::jsonb, 'an outbound-only thread (company customer, email)');
select tests.eq((select char_length(last_body) from public.inbox_threads(tests.fx('shop_a'))
                  where thread_key = 'c:' || tests.fx('cust_a2')), 280, 'the preview body is cut to 280 characters');
select tests.eq(public.inbox_unread_count(tests.fx('shop_a')), 3, 'unread count: inbound messages not read');

-- ------------------------------------------------------------ paging
select tests.eq((select array_agg(thread_key) from public.inbox_threads(tests.fx('shop_a'), 2)),
                array['a:+12055550177', 'c:' || tests.fx('cust_a')], 'p_limit');
select tests.eq((select array_agg(thread_key) from public.inbox_threads(tests.fx('shop_a'), 2, '2025-06-01 11:05Z')),
                array['c:' || tests.fx('cust_a3'), 'c:' || tests.fx('cust_a2')], 'keyset page: threads older than p_before');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'), 2, '2025-06-01 08:00Z')), 0::bigint, 'last page is empty');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'), 0)), 1::bigint, 'p_limit is at least 1');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'), -5)), 1::bigint, 'negative limit clamps to 1');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'), 100000)), 4::bigint, 'large limits clamp to 200');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'), null)), 4::bigint, 'null limit = default');

-- ------------------------------------------------------------ state changes
-- reading marks the thread read
update public.messages set read_at = now() where id = tests.fx('m2');
select tests.eq((select unread_count from public.inbox_threads(tests.fx('shop_a')) where thread_key = 'c:' || tests.fx('cust_a')), 0,
                'reading clears the thread''s unread count');
select tests.eq(public.inbox_unread_count(tests.fx('shop_a')), 2, 'and the total');
-- the unknown sender becomes a customer: their texts join the customer's thread
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Boat', '+12055550177')
  returning tests.fx_set('cust_boat', id);
select tests.eq((select jsonb_build_array(thread_key, unread_count, customer_first_name)
                   from public.inbox_threads(tests.fx('shop_a')) where last_message_id = tests.fx('m5')),
                jsonb_build_array('c:' || tests.fx('cust_boat'), 2, 'Boat'), 'attached texts move to the customer''s thread');
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a')) where thread_key like 'a:%'), 0::bigint,
                'no address thread is left');

-- ------------------------------------------------------------ roles and isolation
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a')) where last_body = 'Shop B secret'), 0::bigint,
                'never another shop''s messages');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select count(*) from public.inbox_threads(tests.fx('shop_a'))), 4::bigint, 'owners read the inbox');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(public.inbox_unread_count(tests.fx('shop_a')), 2, 'admins too');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.inbox_threads(tests.fx('shop_a'))$$, '42501', 'technicians cannot read the inbox');
select tests.throws($$select public.inbox_unread_count(tests.fx('shop_a'))$$, '42501', 'nor its count');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.inbox_threads(tests.fx('shop_a'))$$, '42501', 'another shop''s manager is refused');
select tests.throws($$select public.inbox_unread_count(tests.fx('shop_a'))$$, '42501', 'and their count');
select tests.eq((select array_agg(jsonb_build_array(thread_key, unread_count, last_body))
                   from public.inbox_threads(tests.fx('shop_b'))),
                array[jsonb_build_array('c:' || tests.fx('cust_b'), 1, 'Shop B secret')], 'shop B sees only its own thread');
select tests.eq(public.inbox_unread_count(tests.fx('shop_b')), 1, 'shop B count');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.inbox_threads(tests.fx('shop_a'))$$, '42501', 'non-members are refused');
select tests.as_anon();
select tests.throws($$select * from public.inbox_threads(tests.fx('shop_a'))$$, '42501', 'anon cannot execute');
select tests.throws($$select public.inbox_unread_count(tests.fx('shop_a'))$$, '42501', 'anon cannot count');

-- ------------------------------------------------------------ indexes
select tests.as_superuser();
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'messages'
                          and indexdef like '%(shop_id, customer_id, created_at DESC)%'), 'messages (shop_id, customer_id, created_at desc)');
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'messages'
                          and indexdef like '%(shop_id, created_at DESC)%'), 'messages (shop_id, created_at desc)');
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'messages_unread_customer_idx'
                          and indexdef like '%(shop_id, customer_id) WHERE ((direction = ''inbound''%read_at IS NULL)%'),
                'partial unread index per customer');
