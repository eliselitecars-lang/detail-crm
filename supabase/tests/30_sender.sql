-- 30 comms: the sender pipeline (claim_queued_messages with SKIP LOCKED
-- semantics, mark_message_result incl. retry/backoff, delivery callbacks by
-- provider id, stuck-send timeout) and inbound SMS (routing, idempotency,
-- STOP/START keywords, unknown senders, staff notifications).
\ir fixtures/two_shops.psql

-- the platform binds each shop's Twilio number (supabase/setup/twilio.md)
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100', email = 'hello@shop-a.test' where id = tests.fx('shop_a');
update public.customers set email = 'bob@example.com', phone = '+13125550101' where id = tests.fx('cust_b');
insert into public.customers (shop_id, first_name, phone, sms_opted_out_at)
  values (tests.fx('shop_a'), 'Quiet', '+12055550177', now()) returning tests.fx_set('cust_quiet', id);

-- fixed queue
insert into public.messages (shop_id, customer_id, direction, channel, to_address, subject, body, status, send_after) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', null, 'one', 'queued', '2025-06-01 10:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'email', 'alice@example.com', 'Hi', 'two', 'queued', '2025-06-01 10:01Z'),
  (tests.fx('shop_a'), tests.fx('cust_a'), 'outbound', 'sms', '+12055550101', null, 'three', 'queued', '2025-06-01 12:00Z'),
  (tests.fx('shop_b'), tests.fx('cust_b'), 'outbound', 'email', 'bob@example.com', 'Hi', 'four', 'queued', '2025-06-01 10:02Z'),
  (tests.fx('shop_a'), tests.fx('cust_quiet'), 'outbound', 'sms', '+12055550177', null, 'five', 'queued', '2025-06-01 10:03Z'),
  (tests.fx('shop_b'), tests.fx('cust_b'), 'outbound', 'sms', '+13125550101', null, 'six', 'queued', '2025-06-01 10:04Z');
select tests.fx_set('m' || n, (select id from public.messages where body = w))
  from (values (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four'), (5, 'five'), (6, 'six')) v(n, w);

-- ------------------------------------------------------------ access
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.claim_queued_messages(10)$$, '42501', 'staff cannot claim the queue');
select tests.throws($$select public.mark_message_result(tests.fx('m1'), 'sent')$$, '42501', 'staff cannot record results');
select tests.throws($$select public.update_message_status_by_provider_id('SM1', 'delivered')$$, '42501', 'staff cannot fake callbacks');
select tests.throws($$select * from public.record_inbound_sms('+12055550100', '+12055550101', 'hi')$$, '42501',
                    'staff cannot fake inbound texts');
select tests.as_anon();
select tests.throws($$select * from public.claim_queued_messages(10)$$, '42501', 'anon cannot claim');
select tests.throws($$select * from public.record_inbound_sms('+12055550100', '+12055550101', 'hi')$$, '42501', 'anon cannot post inbound');

-- ------------------------------------------------------------ claim
select tests.as_service();
create temp table claim1 on commit drop as select * from public.claim_queued_messages(2, '2025-06-01 11:00Z');
select tests.eq((select array_agg(id order by send_after) from claim1 join public.messages using (id)),
                array[tests.fx('m1'), tests.fx('m2')], 'first claim takes the two oldest due rows');
select tests.ok((select from_address = '+12055550100' and shop_name = 'Shop A' and reply_to = 'hello@shop-a.test'
                        and attempts = 1 and body = 'one' and to_address = '+12055550101'
                   from claim1 where id = tests.fx('m1')), 'sms claim carries the shop sending number and reply-to');
select tests.ok((select from_address is null and subject = 'Hi' and channel = 'email' from claim1 where id = tests.fx('m2')),
                'email claim');
select tests.ok((select bool_and(status = 'sending' and claimed_at = '2025-06-01 11:00Z' and attempts = 1)
                   from public.messages where id in (tests.fx('m1'), tests.fx('m2'))), 'claimed rows are marked sending');

create temp table claim2 on commit drop as select * from public.claim_queued_messages(10, '2025-06-01 11:00Z');
select tests.eq((select array_agg(id) from claim2), array[tests.fx('m4')],
                'a second claim never returns rows already claimed; future rows wait');
select tests.ok((select status = 'cancelled' and error like '%opted out%' and attempts = 0
                   from public.messages where id = tests.fx('m5')), 'opted-out recipient: cancelled, not sent');
select tests.ok((select status = 'failed' and error like '%not set up%' from public.messages where id = tests.fx('m6')),
                'sms without a shop number: failed');
select tests.eq((select count(*) from public.claim_queued_messages(10, '2025-06-01 11:00Z')), 0::bigint, 'nothing left to claim');
select tests.eq((select status::text from public.messages where id = tests.fx('m3')), 'queued', 'future message untouched');

-- Concurrent workers: rows another worker has locked are skipped. A single
-- session cannot hold a competing lock, so the sequential claims above prove
-- the status hand-off and this proves the locking clause.
select tests.ok((select pg_get_functiondef('public.claim_queued_messages(integer, timestamptz)'::regprocedure)
                   ilike '%for update skip locked%'), 'claim uses FOR UPDATE SKIP LOCKED');

-- ------------------------------------------------------------ results
select tests.throws($$select public.mark_message_result(tests.fx('m1'), 'received')$$, '22023', 'invalid result status');
select tests.throws($$select public.mark_message_result(gen_random_uuid(), 'sent')$$, 'P0002', 'unknown message');
select tests.throws($$select public.mark_message_result(tests.fx('m3'), 'sent')$$, '55000', 'only claimed messages get results');
select tests.ok((select status = 'sent' and provider_message_id = 'SM1' and sent_at = now() and error is null
                   from public.mark_message_result(tests.fx('m1'), 'sent', 'SM1')), 'sent');
select tests.ok((select status = 'sent' and provider_message_id = 'SM1'
                   from public.mark_message_result(tests.fx('m1'), 'sent', 'SM1')), 'replaying a result is a no-op');
select tests.throws($$select public.mark_message_result(tests.fx('m4'), 'sent', 'SM1')$$, '23505',
                    'a provider id belongs to one message');

-- delivery callbacks
select tests.eq(public.update_message_status_by_provider_id('SM1', 'delivered'), tests.fx('m1'), 'callback finds the message');
select tests.ok((select status = 'delivered' and delivered_at = now() from public.messages where id = tests.fx('m1')), 'delivered');
select tests.lives($$select public.update_message_status_by_provider_id('SM1', 'sent')$$);
select tests.lives($$select public.update_message_status_by_provider_id('SM1', 'failed', 'late')$$);
select tests.ok((select status = 'delivered' and error is null from public.messages where id = tests.fx('m1')),
                'stale callbacks never move a message backwards');
select tests.eq(public.update_message_status_by_provider_id('SM-unknown', 'delivered'), null::uuid, 'unknown provider id: ignored');
select tests.throws($$select public.update_message_status_by_provider_id('SM1', 'queued')$$, '22023', 'invalid callback status');
select tests.throws($$select public.update_message_status_by_provider_id('  ', 'sent')$$, '22023', 'provider id required');

-- transient failure → retry with backoff
select tests.ok((select status = 'queued' and error = 'rate limited' and claimed_at is null
                        and send_after = '2025-06-01 11:03Z'
                   from public.mark_message_result(tests.fx('m2'), 'queued', null, 'rate limited', p_now => '2025-06-01 11:01Z')),
                'retry is re-queued with 2^attempts minutes backoff');
select tests.eq((select count(*) from public.claim_queued_messages(10, '2025-06-01 11:02Z')), 0::bigint, 'not before the backoff');
select tests.eq((select array_agg(id) from public.claim_queued_messages(10, '2025-06-01 11:04Z')), array[tests.fx('m2')],
                'the retry is claimed again once due');
select tests.eq((select attempts from public.messages where id = tests.fx('m2')), 2, 'attempts counted');
update public.messages set attempts = 5 where id = tests.fx('m2');
select tests.ok((select status = 'failed' and error = 'still rate limited'
                   from public.mark_message_result(tests.fx('m2'), 'queued', null, 'still rate limited')),
                'after 5 attempts a retry becomes a failure');

-- permanent failure, then a late delivery report
select tests.ok((select status = 'failed' and error = 'invalid number' and provider_message_id = 'RE4'
                   from public.mark_message_result(tests.fx('m4'), 'failed', 'RE4', 'invalid number')), 'failed');
select tests.eq(public.update_message_status_by_provider_id('RE4', 'delivered'), tests.fx('m4'), 'late delivery report');
select tests.ok((select status = 'delivered' and error is null from public.messages where id = tests.fx('m4')),
                'a delivery report overrides an earlier failure');
select tests.throws($$select public.mark_message_result(tests.fx('m4'), 'queued')$$, '55000', 'finished messages are not retried');

-- a stuck send times out instead of being sent twice
select tests.eq((select array_agg(id) from public.claim_queued_messages(10, '2025-06-01 12:00Z')), array[tests.fx('m3')],
                'm3 claimed when due');
select tests.eq((select count(*) from public.claim_queued_messages(10, '2025-06-01 12:10Z')), 0::bigint, 'still sending');
select tests.eq((select status::text from public.messages where id = tests.fx('m3')), 'sending', 'not yet timed out');
select tests.eq((select count(*) from public.claim_queued_messages(10, '2025-06-01 12:16Z')), 0::bigint, 'sweep claims nothing new');
select tests.ok((select status = 'failed' and error like '%timed out%' from public.messages where id = tests.fx('m3')),
                'a message stuck in sending for 15 minutes fails');
select tests.ok((select status = 'sent' and error is null and provider_message_id = 'SM3'
                   from public.mark_message_result(tests.fx('m3'), 'sent', 'SM3')),
                'a late provider success corrects the timed-out row');
select tests.throws($$select public.mark_message_result(tests.fx('m5'), 'sent')$$, '55000', 'cancelled messages stay cancelled');
select tests.eq((select status::text from public.mark_message_result(tests.fx('m1'), 'delivered')), 'delivered',
                'replaying delivered is a no-op');
select tests.throws($$select public.mark_message_result(tests.fx('m1'), 'failed')$$, '55000',
                    'a delivered message cannot be marked failed');

-- ------------------------------------------------------------ inbound SMS
create temp table in1 on commit drop as
  select * from public.record_inbound_sms('+12055550100', '+12055550101', 'Hi, running 10 minutes late', 'SMin1');
select tests.ok((select shop_id = tests.fx('shop_a') and customer_id = tests.fx('cust_a') and opt_action is null from in1),
                'routed to the shop by To and the customer by From');
select tests.ok((select direction = 'inbound' and status = 'received' and channel = 'sms' and to_address = '+12055550100'
                        and from_address = '+12055550101' and body = 'Hi, running 10 minutes late' and read_at is null
                        and customer_id = tests.fx('cust_a') and sent_by is null
                   from public.messages where id = (select message_id from in1)), 'inbound row');
select tests.eq((select array_agg(n.user_id order by n.user_id) from public.notifications n
                  where n.kind = 'inbound_message' and n.shop_id = tests.fx('shop_a')),
                (select array_agg(u order by u) from unnest(array[tests.fx('u_owner_a'), tests.fx('u_admin_a'),
                                                                   tests.fx('u_manager_a')]) u),
                'owner, admin and manager are notified (not technicians)');
select tests.ok((select bool_and(title = 'New text from Alice Anders' and body = 'Hi, running 10 minutes late')
                   from public.notifications where kind = 'inbound_message'), 'notification text');
select tests.eq((select message_id from public.record_inbound_sms('+12055550100', '+12055550101', 'Hi, running 10 minutes late', 'SMin1')),
                (select message_id from in1), 'webhook retries are idempotent');
select tests.eq((select count(*) from public.messages where provider_message_id = 'SMin1'), 1::bigint, 'stored once');
select tests.eq((select count(*) from public.notifications where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))), 3::bigint,
                'notified once');
select tests.eq((select count(*) from public.record_inbound_sms('+19995550100', '+12055550101', 'hi', 'SMin2')), 0::bigint,
                'a To number no shop uses is ignored');
select tests.throws($$select * from public.record_inbound_sms('2055550100', '+12055550101', 'hi')$$, '22023', 'To must be E.164');
select tests.throws($$select * from public.record_inbound_sms('+12055550100', 'alice', 'hi')$$, '22023', 'From must be E.164');

-- unknown sender, attached once a customer with that number exists
select tests.fx_set('in_unknown', (select message_id from public.record_inbound_sms('+12055550100', '+12055550188', '', 'SMin3')));
select tests.ok((select customer_id is null and body = '' from public.messages where id = tests.fx('in_unknown')),
                'unknown sender stored without a customer (media-only text has an empty body)');
select tests.ok((select bool_and(title = 'New text from (205) 555-0188' and body is null) from public.notifications
                  where title like '%0188'), 'notification names the number');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Newbie', '+12055550188')
  returning tests.fx_set('cust_new', id);
select tests.eq((select customer_id from public.messages where id = tests.fx('in_unknown')), tests.fx('cust_new'),
                'the orphan text is attached to the new customer');
select tests.eq(tests.row_count($$select 1 from public.messages where direction = 'inbound'$$), 2::bigint,
                'managers see inbound texts');
select tests.eq(tests.row_count($$update public.messages set read_at = now() where direction = 'inbound' and read_at is null$$),
                2::bigint, 'and mark the thread read');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.messages where direction = 'inbound'$$), 0::bigint,
                'another shop sees none of them');
select tests.as_service();

-- several customers share a number: most recent active one wins
insert into public.customers (shop_id, first_name, phone, created_at, archived_at) values
  (tests.fx('shop_a'), 'Old', '+12055550166', '2024-01-01Z', null),
  (tests.fx('shop_a'), 'New', '+12055550166', '2025-01-01Z', null),
  (tests.fx('shop_a'), 'Archived', '+12055550166', '2025-06-01Z', now());
insert into public.customers (shop_id, first_name, phone, sms_opt_in) values (tests.fx('shop_b'), 'Elsewhere', '+12055550166', true);
select tests.eq((select c.first_name from public.record_inbound_sms('+12055550100', '+12055550166', 'Is Friday ok?', 'SMin4') r
                   join public.customers c on c.id = r.customer_id), 'New', 'most recently created active customer');

-- STOP opts out every customer of the shop with that number and withdraws queued texts
update public.customers set sms_opt_in = true where shop_id = tests.fx('shop_a') and phone = '+12055550166';
insert into public.messages (shop_id, customer_id, direction, channel, to_address, body, status)
  select tests.fx('shop_a'), id, 'outbound', 'sms', phone, 'Reminder', 'queued'
    from public.customers where shop_id = tests.fx('shop_a') and first_name = 'New';
select tests.eq((select opt_action from public.record_inbound_sms('+12055550100', '+12055550166', '  stop.  ', 'SMin5')), 'opt_out',
                'STOP (any case, trailing punctuation) opts out');
select tests.ok((select bool_and(sms_opted_out_at = now() and not sms_opt_in) from public.customers
                  where shop_id = tests.fx('shop_a') and phone = '+12055550166'), 'all matching customers opted out');
select tests.ok((select sms_opted_out_at is null and sms_opt_in from public.customers
                  where shop_id = tests.fx('shop_b') and phone = '+12055550166'), 'other shops are unaffected');
select tests.ok((select status = 'cancelled' and error like '%opted out%' from public.messages
                  where body = 'Reminder' and to_address = '+12055550166'), 'queued texts to the number are withdrawn');
select tests.ok(exists (select 1 from public.notifications where title = 'New opted out of text messages'),
                'staff are told about the opt-out');
select tests.eq((select body from public.messages where provider_message_id = 'SMin5'), '  stop.  ', 'the STOP text is kept verbatim');

-- every carrier keyword; ordinary texts that merely contain the word do not count
select tests.eq((select array_agg(r.opt_action order by k.ord)
                   from unnest(array['STOPALL', 'Unsubscribe', 'cancel', 'END', 'quit!', 'optout', 'REVOKE',
                                     'Please stop by at 3', 'stop it']) with ordinality k(word, ord)
                   cross join lateral public.record_inbound_sms('+12055550100', '+12055550101', k.word,
                                                               'SMkw' || k.ord) r),
                array['opt_out', 'opt_out', 'opt_out', 'opt_out', 'opt_out', 'opt_out', 'opt_out', null, null],
                'opt-out keywords are whole-message matches');
select tests.ok((select sms_opted_out_at is not null from public.customers where id = tests.fx('cust_a')), 'Alice opted out');

-- START / UNSTOP opt back in
select tests.eq((select opt_action from public.record_inbound_sms('+12055550100', '+12055550166', 'Start', 'SMin6')), 'opt_in',
                'START opts back in');
select tests.ok((select bool_and(sms_opted_out_at is null) from public.customers
                  where shop_id = tests.fx('shop_a') and phone = '+12055550166'), 'opt-out cleared');
select tests.eq((select opt_action from public.record_inbound_sms('+12055550100', '+12055550101', 'unstop', 'SMin7')), 'opt_in',
                'UNSTOP opts back in');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('cust_a')), 'Alice can be texted again');
select tests.ok(exists (select 1 from public.notifications where title = 'Alice Anders opted back in to text messages'),
                'staff are told about the opt-in');

-- routing to the other shop
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b');
select tests.ok((select shop_id = tests.fx('shop_b') and customer_id = tests.fx('cust_b')
                   from public.record_inbound_sms('+13125550199', '+13125550101', 'hello', 'SMin8')), 'routed to shop B');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_b')), 3::bigint,
                'only shop B staff are notified');
select tests.throws($$update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_a')$$, '23503',
                    'a sending number belongs to the one shop it is bound to');
select tests.as_superuser();
