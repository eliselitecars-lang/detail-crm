-- 80 comms: outbound webhooks (P-27, 0081/0089) — endpoint management
-- (owner/admin; URL and event validation; 20 per shop; the secret shown once
-- and never readable), one delivery per subscribed active endpoint per
-- integration event, curated payloads, the claim queue (skip locked,
-- stuck re-queue), retries with backoff, dead after 8 attempts, auto-disable
-- after 25 failures in a row (+ admin notification), re-enabling, test
-- deliveries, cascades and cross-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.notifications set pushed_at = now() where pushed_at is null;
-- the delivery queue is global: settle what a shared database already holds
update public.webhook_deliveries set status = 'dead' where status in ('pending', 'delivering');

-- ============================================================ endpoints
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_completed}')$$,
                    '42501', 'managers cannot manage webhooks');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_completed}')$$,
                    '42501', 'technicians cannot');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_completed}')$$,
                    '42501', 'nor another shop''s admin');
select tests.as_anon();
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_completed}')$$,
                    '42501', 'nor anon');

select tests.authenticate_as(tests.fx('u_admin_a'));
create temp table ep1 as
  select public.create_webhook_endpoint(tests.fx('shop_a'), '  https://hooks.zapier.test/hooks/catch/1/abc  ',
                                        '{job_completed, payment_succeeded, job_completed}', 'Zapier') as r;
grant select on ep1 to authenticated, service_role;
select tests.fx_set('e1', ((select r from ep1) ->> 'id')::uuid);
select tests.ok(((select r from ep1) ->> 'secret') ~ '^whsec_[0-9a-f]{64}$', 'the secret is shown once');
select tests.eq((select array[url, array_to_string(events, ','), description, active::text] from public.webhook_endpoints
                  where id = tests.fx('e1')),
                array['https://hooks.zapier.test/hooks/catch/1/abc', 'job_completed,payment_succeeded', 'Zapier', 'true'],
                'URL trimmed, events de-duplicated');
select tests.throws($$select secret from public.webhook_endpoints$$, '42501', 'the secret column is never readable');
select tests.throws($$select * from public.webhook_endpoints$$, '42501', '(not even with *)');
select tests.throws($$update public.webhook_endpoints set active = false$$, '42501', 'no direct writes');
select tests.throws($$insert into public.webhook_endpoints (shop_id, url, events, secret) values (tests.fx('shop_a'), 'https://a.test', '{on_the_way}', 'whsec_' || repeat('0', 64))$$,
                    '42501', 'no direct inserts');
select tests.eq((select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/second', '{job_completed}') ? 'id'),
                true, 'a second endpoint');
select tests.fx_set('e2', (select id from public.webhook_endpoints where url = 'https://hooks.example.com/second'));
select tests.fx_set('e3', ((public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/off', '{job_completed}')) ->> 'id')::uuid);
select public.update_webhook_endpoint(tests.fx('e3'), 'https://hooks.example.com/off', '{job_completed}', false);
-- validation
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'http://hooks.example.com/a', '{job_completed}')$$, '22023',
                    'https only');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://10.0.0.5/hook', '{job_completed}')$$, '22023',
                    'no IP addresses');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://[::1]/hook', '{job_completed}')$$, '22023',
                    'no IPv6 literals');
-- IPv4 literals as a WHATWG URL parser (Deno fetch / new URL) reads them: a
-- numeric last label makes the whole host an IPv4 address, hex included
select tests.throws_like($$select public.create_webhook_endpoint(tests.fx('shop_a'),
                           'https://169.254.169.0xfe/latest/meta-data', array['job_completed'])$$,
                         '22023', '%not an IP address%', 'the metadata address written with a hex last label is refused');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://127.0.0.0x1/hook', array['job_completed'])$$,
                    '22023', 'loopback written with a hex last label is refused');
select tests.throws($$select public.update_webhook_endpoint(tests.fx('e2'), 'https://10.0.0.0x1/', '{job_completed}', true)$$,
                    '22023', 'update_webhook_endpoint applies the same rule');
select tests.eq((select url from public.webhook_endpoints where id = tests.fx('e2')), 'https://hooks.example.com/second',
                '(the endpoint keeps its URL)');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://127.0.0.1./hook', '{job_completed}')$$,
                    '22023', 'a trailing dot does not hide an IP address');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://10.0.0.0X1./hook', '{job_completed}')$$,
                    '22023', 'nor upper case plus a trailing dot');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://0x7f000001/hook', '{job_completed}')$$,
                    '22023', 'a single hex number');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://0x7f.1/hook', '{job_completed}')$$,
                    '22023', 'mixed hex and decimal');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://0177.0.0.1/hook', '{job_completed}')$$,
                    '22023', 'octal');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://2130706433:443/hook', '{job_completed}')$$,
                    '22023', 'a single decimal number with a port');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.0x/hook', '{job_completed}')$$,
                    '22023', 'a bare 0x last label is a number to the URL parser');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.123/hook', '{job_completed}')$$,
                    '22023', 'any numeric last label');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://0xa.example.com/hook', '{job_completed}')$$,
                    '22023', 'a hex-number label anywhere');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://localhost:8443/hook', '{job_completed}')$$, '22023',
                    'no localhost');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://printer.local/hook', '{job_completed}')$$, '22023',
                    'no .local names');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://metadata.internal/', '{job_completed}')$$, '22023',
                    'no .internal names');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://user:pw@hooks.example.com/', '{job_completed}')$$,
                    '22023', 'no credentials in the URL');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_deleted}')$$, '22023',
                    'known events only');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{}')$$, '22023',
                    'at least one event');
select tests.throws($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/a', '{job_completed}', repeat('d', 201))$$,
                    '22023', 'description at most 200');
select tests.lives($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com:8443/p?x=1', '{on_the_way}')$$,
                   'a port and a query are fine');
select tests.throws_like($$select public.create_webhook_endpoint(tests.fx('shop_a'), 'https://hooks.example.com/n' || i, '{on_the_way}')
                           from generate_series(1, 17) i$$, '23514', '%at most 20%', 'at most 20 endpoints per shop');
select tests.as_superuser();
delete from public.webhook_endpoints where events = '{on_the_way}';

-- update / rotate / roles
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select r - 'created_at' - 'updated_at' - 'id' - 'shop_id'
                   from (select public.update_webhook_endpoint(tests.fx('e2'), 'https://hooks.example.com/second', '{job_completed,form_signed}',
                                                               true, 'Forms too') as r) x),
                '{"url": "https://hooks.example.com/second", "events": ["form_signed", "job_completed"], "description": "Forms too", "active": true, "consecutive_failures": 0, "disabled_at": null}'::jsonb,
                'saved (no secret in the result)');
select tests.throws($$select public.update_webhook_endpoint(tests.fx('e2'), 'https://hooks.example.com/x', '{job_completed}', null)$$,
                    '22023', 'active is required');
select tests.throws($$select public.update_webhook_endpoint(gen_random_uuid(), 'https://hooks.example.com/x', '{job_completed}', true)$$,
                    'P0002', 'unknown endpoint');
create temp table rot as select public.rotate_webhook_secret(tests.fx('e1')) as r;
select tests.as_superuser();
select tests.ok((select (r ->> 'secret') <> (select r ->> 'secret' from ep1) and (r ->> 'secret') = w.secret
                   from rot, public.webhook_endpoints w where w.id = tests.fx('e1')), 'a rotated secret replaces the old one');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select id from public.webhook_endpoints$$), 0::bigint, 'managers do not see endpoints');
select tests.throws($$select public.rotate_webhook_secret(tests.fx('e1'))$$, '42501', 'managers cannot rotate');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.rotate_webhook_secret(tests.fx('e1'))$$, 'P0002', 'another shop''s endpoint: not found');
select tests.throws($$select public.delete_webhook_endpoint(tests.fx('e1'))$$, 'P0002', '… cannot be deleted');
select tests.eq(tests.row_count($$select id from public.webhook_endpoints$$), 0::bigint, 'and is not visible');
select public.create_webhook_endpoint(tests.fx('shop_b'), 'https://hooks.example.org/b', '{job_completed}');

-- ============================================================ deliveries
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.fx_set('ev_done', (select id from public.integration_events where event = 'job_completed' and job_id = tests.fx('job_a')));
select tests.eq((select array_agg(endpoint_id order by endpoint_id) from public.webhook_deliveries
                  where integration_event_id = tests.fx('ev_done')),
                (select array_agg(e order by e) from unnest(array[tests.fx('e1'), tests.fx('e2')]) e),
                'one delivery per active subscribed endpoint (not the inactive one, not another shop''s)');
select tests.eq((select payload - 'created_at' from public.webhook_deliveries where endpoint_id = tests.fx('e1')),
                jsonb_build_object(
                  'id', tests.fx('ev_done'), 'event', 'job_completed',
                  'shop', jsonb_build_object('id', tests.fx('shop_a'), 'name', 'Shop A'),
                  'data', jsonb_build_object(
                    'job', jsonb_build_object('id', tests.fx('job_a'), 'number', (select number from public.jobs where id = tests.fx('job_a')),
                                              'status', 'completed', 'scheduled_start', '2025-06-02T15:00:00+00:00',
                                              'scheduled_end', '2025-06-02T17:00:00+00:00', 'location_type', 'shop',
                                              'total_cents', 20000, 'currency', 'usd'),
                    'customer', jsonb_build_object('id', tests.fx('cust_a'), 'first_name', 'Alice', 'last_name', 'Anders',
                                                   'email', 'alice@example.com', 'phone', '+12055550101'))),
                'curated payload (no notes, tokens or internal ids)');
select tests.ok((select payload::text not like '%Gate code%' and payload::text not like '%picky%'
                        and payload::text not like '%' || (select public_token::text from public.jobs where id = tests.fx('job_a')) || '%'
                   from public.webhook_deliveries where endpoint_id = tests.fx('e1')), 'no notes, no booking token');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq((select count(*) from public.webhook_deliveries where shop_id = tests.fx('shop_a')), 2::bigint,
                'completing again: no new event, no new delivery');
insert into public.payments (shop_id, customer_id, job_id, kind, method, status, amount_cents, tip_cents, paid_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_a'), 'payment', 'cash', 'succeeded', 20000, 1500, now())
  returning tests.fx_set('pay', id);
select tests.eq((select payload -> 'data' -> 'payment' from public.webhook_deliveries where event = 'payment_succeeded'),
                jsonb_build_object('id', tests.fx('pay'), 'amount_cents', 20000, 'tip_cents', 1500, 'method', 'cash', 'kind', 'payment'),
                'payment payload');
select tests.ok((select payload -> 'data' ? 'job' and payload -> 'data' ? 'customer' and endpoint_id = tests.fx('e1')
                   from public.webhook_deliveries where event = 'payment_succeeded'), 'with its job and customer, to e1 only');
select tests.eq((select count(*) from public.webhook_deliveries where event = 'payment_succeeded'), 1::bigint, 'one delivery');
select tests.eq(public.webhook_payload(gen_random_uuid()), null, 'unknown event: no payload');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.webhook_deliveries$$), 3::bigint, 'admins read their deliveries');
select tests.throws($$select public.webhook_payload(tests.fx('ev_done'))$$, '42501', 'payloads are built by the server only');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.webhook_deliveries$$), 0::bigint, 'managers do not');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$select 1 from public.webhook_deliveries where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'other shops do not');
select tests.throws($$select * from public.claim_webhook_deliveries()$$, '42501', 'the queue is service-only');

-- ============================================================ claim, retries, dead
select tests.as_service();
create temp table c1 as select * from public.claim_webhook_deliveries(50, '2030-01-01 12:00Z');
select tests.eq((select count(*) from c1), 3::bigint, 'every due delivery of active endpoints');
select tests.ok((select bool_and(attempts = 1 and secret ~ '^whsec_') from c1), 'attempt 1, signed with the endpoint secret');
select tests.eq((select url from c1 where endpoint_id = tests.fx('e2')), 'https://hooks.example.com/second', 'with the URL');
select tests.eq((select count(*) from public.claim_webhook_deliveries(50, '2030-01-01 12:01Z')), 0::bigint, 'claimed rows are not handed out twice');
select tests.fx_set('d_ok', (select id from c1 where endpoint_id = tests.fx('e2')));
select tests.fx_set('d_fail', (select id from c1 where endpoint_id = tests.fx('e1') and event = 'job_completed'));
select tests.fx_set('d_pay', (select id from c1 where event = 'payment_succeeded'));
select public.mark_webhook_delivery(tests.fx('d_ok'), 204, null, '2030-01-01 12:00:05Z');
select tests.eq((select array[status, last_status_code::text, delivered_at::text] from public.webhook_deliveries where id = tests.fx('d_ok')),
                array['succeeded', '204', '2030-01-01 12:00:05+00'], 'a 2xx succeeds');
select public.mark_webhook_delivery(tests.fx('d_ok'), 500, 'late', '2030-01-01 12:00:06Z');
select tests.eq((select status from public.webhook_deliveries where id = tests.fx('d_ok')), 'succeeded', 'a replayed result changes nothing');
select tests.throws($$select public.mark_webhook_delivery(gen_random_uuid(), 200)$$, 'P0002', 'unknown delivery');
select tests.throws($$select public.mark_webhook_delivery(tests.fx('d_ok'), 1000)$$, '22023', 'status code range');
-- failures back off 1m, 5m, 30m, 2h, 6h, 12h, 24h, then dead after the 8th attempt
create temp table backoff (n integer, gap interval);
do $$
declare
  v_at timestamptz := '2030-01-01 12:00Z';
  v_next timestamptz;
begin
  for i in 1 .. 8 loop
    perform public.mark_webhook_delivery(tests.fx('d_fail'), case when i % 2 = 0 then null else 502 end,
                                         case when i % 2 = 0 then 'connection reset' end, v_at);
    select d.next_attempt_at into v_next from public.webhook_deliveries d where d.id = tests.fx('d_fail');
    insert into backoff values (i, v_next - v_at);
    exit when (select status from public.webhook_deliveries where id = tests.fx('d_fail')) = 'dead';
    -- not due a second early, due right on time
    perform tests.eq((select count(*) from public.claim_webhook_deliveries(50, v_next - interval '1 second')
                       where id = tests.fx('d_fail')), 0::bigint, format('attempt %s: not before its time', i + 1));
    v_at := v_next;
    perform tests.eq((select attempts from public.claim_webhook_deliveries(50, v_at) where id = tests.fx('d_fail')), (i + 1)::smallint,
                     format('attempt %s claimed', i + 1));
  end loop;
end
$$;
select tests.eq((select array_agg(gap order by n) from backoff where n < 8),
                array['1 minute', '5 minutes', '30 minutes', '2 hours', '6 hours', '12 hours', '24 hours']::interval[], 'the backoff schedule');
select tests.eq((select array[status, attempts::text, last_error, coalesce(last_status_code::text, 'none')]
                   from public.webhook_deliveries where id = tests.fx('d_fail')),
                array['dead', '8', 'connection reset', 'none'], 'dead after the 8th attempt');
select tests.eq((select consecutive_failures from public.webhook_endpoints where id = tests.fx('e1')), 8, 'the failure streak');
-- the payment delivery succeeds: the streak resets
select public.mark_webhook_delivery(tests.fx('d_pay'), 200);
select tests.eq((select consecutive_failures from public.webhook_endpoints where id = tests.fx('e1')), 0, 'a success resets the streak');

-- a crashed worker: re-queued after 10 minutes
select tests.as_superuser();
update public.webhook_deliveries set status = 'pending', next_attempt_at = '2030-02-01 00:00Z', attempts = 0 where id = tests.fx('d_pay');
select tests.as_service();
select tests.eq((select count(*) from public.claim_webhook_deliveries(50, '2030-02-01 00:00Z')), 1::bigint, 'claimed');
select tests.eq((select count(*) from public.claim_webhook_deliveries(50, '2030-02-01 00:09Z')), 0::bigint, 'still with the worker');
select tests.eq((select attempts from public.claim_webhook_deliveries(50, '2030-02-01 00:11Z') where id = tests.fx('d_pay')), 2::smallint,
                'stuck for 10 minutes: re-queued and claimed again (the attempt counts)');
select tests.eq((select last_error from public.webhook_deliveries where id = tests.fx('d_pay')), 'the delivery attempt timed out',
                'the timeout is recorded');

-- ============================================================ auto-disable and re-enable
select tests.as_superuser();
update public.webhook_endpoints set consecutive_failures = 24 where id = tests.fx('e1');
select tests.as_service();
select public.mark_webhook_delivery(tests.fx('d_pay'), 410, 'Gone', '2030-02-01 00:12Z');
select tests.as_superuser();
select tests.ok((select disabled_at = '2030-02-01 00:12Z' and consecutive_failures = 25 from public.webhook_endpoints
                  where id = tests.fx('e1')), 'disabled after 25 failures in a row');
select tests.eq((select array_agg(n.user_id order by n.user_id) from public.notifications n where n.kind = 'webhook_failing'),
                (select array_agg(u order by u) from unnest(array[tests.fx('u_owner_a'), tests.fx('u_admin_a')]) u),
                'owners and admins are told');
select tests.eq((select distinct body from public.notifications where kind = 'webhook_failing'),
                'Deliveries to hooks.zapier.test failed 25 times in a row. Fix the endpoint and turn it back on.', 'which endpoint');
select tests.as_service();
select tests.eq((select count(*) from public.claim_webhook_deliveries(50, '2030-02-02 00:00Z') where endpoint_id = tests.fx('e1')), 0::bigint,
                'a disabled endpoint gets nothing');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.send_test_webhook(tests.fx('e1'))$$, '55000', 'no test to a disabled endpoint');
select tests.eq((select array[r ->> 'disabled_at', r ->> 'consecutive_failures']
                   from (select public.update_webhook_endpoint(tests.fx('e1'), 'https://hooks.zapier.test/hooks/catch/1/abc',
                                                               '{job_completed,payment_succeeded}', true) as r) x),
                array[null, '0'], 'saving it active re-enables it');
select tests.fx_set('d_test', public.send_test_webhook(tests.fx('e1')));
select tests.as_superuser();
select tests.eq((select array[event, status, payload ->> 'event', payload -> 'data' ->> 'x', (payload -> 'shop' ->> 'name')]
                   from public.webhook_deliveries where id = tests.fx('d_test')),
                array['test', 'pending', 'test', null, 'Shop A'], 'a test delivery');
select tests.as_service();
select tests.ok(exists (select 1 from public.claim_webhook_deliveries(50, now() + interval '1 minute') where id = tests.fx('d_test')),
                'claimed like any delivery');

-- ============================================================ delete / cascade / FKs
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.delete_webhook_endpoint(tests.fx('e1'));
select tests.as_superuser();
select tests.eq((select count(*) from public.webhook_deliveries where endpoint_id = tests.fx('e1')), 0::bigint, 'deliveries go with it');
select tests.throws($$insert into public.webhook_deliveries (shop_id, endpoint_id, event, payload)
                      values (tests.fx('shop_b'), tests.fx('e2'), 'test', '{}')$$, '23503', 'composite FK: another shop''s endpoint');
select tests.throws($$insert into public.webhook_deliveries (shop_id, endpoint_id, integration_event_id, event, payload)
                      values (tests.fx('shop_a'), tests.fx('e2'), tests.fx('ev_done'), 'job_completed', '{}')$$, '23505',
                    'one delivery per endpoint and event');
select tests.ok(not has_column_privilege('authenticated', 'public.webhook_endpoints', 'secret', 'SELECT')
                and has_column_privilege('authenticated', 'public.webhook_endpoints', 'url', 'SELECT'),
                'column privileges: everything but the secret');

-- the validator itself: real host names that merely contain digits or 0x pass
select tests.as_superuser();
select tests.eq(public.comms_webhook_url('https://api.0xproject.com/hook'), 'https://api.0xproject.com/hook',
                'a label that only starts with 0x is a name');
select tests.eq(public.comms_webhook_url('https://hooks.example.com./x'), 'https://hooks.example.com./x',
                'a trailing dot on a name is fine');
select tests.eq(public.comms_webhook_url('https://123.example.com:8443/'), 'https://123.example.com:8443/',
                'numeric labels before a name are fine (the last label decides)');
select tests.eq(public.comms_webhook_url('https://a1.b2.io/h'), 'https://a1.b2.io/h', 'alphanumeric labels');
select tests.throws($$select public.comms_webhook_url('https://10.0.0.0x1/')$$, '22023', 'comms_webhook_url: 10.0.0.0x1');
select tests.throws($$select public.comms_webhook_url('https://192.168.0.0xFF./')$$, '22023', 'comms_webhook_url: 192.168.0.0xFF.');
