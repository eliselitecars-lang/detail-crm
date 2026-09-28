-- 80 comms: self-serve SMS numbers (P-14, 0081/0089) — record_sms_number
-- (validation, one provisioned number per shop, a number belongs to one
-- shop, the shop's sending number), verification status + admin
-- notifications, sms_provisioning_status (owner/admin), release (the FK
-- clears the sending number, the release is logged), claim_queued_messages'
-- messaging_service_sid, RLS on the new columns and service-only RPCs.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.notifications set pushed_at = now() where pushed_at is null;
update public.messages set status = 'cancelled' where status = 'queued';
select 'PN' || repeat('a1', 16) as pn_a, 'MG' || repeat('b2', 16) as mg_a, 'PN' || repeat('c3', 16) as pn_b \gset

-- ============================================================ record
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.record_sms_number(tests.fx('shop_a'), '+18885550100', 'PN' || repeat('a1', 16), null, 'tollfree')$$,
                    '42501', 'owners cannot bind numbers themselves');
select tests.as_service();
select tests.throws($$select public.record_sms_number(gen_random_uuid(), '+18885550100', 'PN' || repeat('a1', 16), null, 'tollfree')$$,
                    'P0002', 'unknown shop');
select tests.throws($$select public.record_sms_number(tests.fx('shop_a'), '8885550100', 'PN' || repeat('a1', 16), null, 'tollfree')$$,
                    '22023', 'E.164 number');
select tests.throws($$select public.record_sms_number(tests.fx('shop_a'), '+18885550100', 'PNxyz', null, 'tollfree')$$,
                    '22023', 'a Twilio number sid');
select tests.throws($$select public.record_sms_number(tests.fx('shop_a'), '+18885550100', 'PN' || repeat('a1', 16), 'MG1', 'tollfree')$$,
                    '22023', 'a messaging service sid');
select tests.throws($$select public.record_sms_number(tests.fx('shop_a'), '+18885550100', 'PN' || repeat('a1', 16), null, 'shortcode')$$,
                    '22023', 'toll-free or local');
select tests.eq((select array[(r).phone_number, (r).twilio_number_sid, (r).messaging_service_sid, (r).kind, (r).verification_status]
                   from (select public.record_sms_number(tests.fx('shop_a'), ' +18885550100 ', :'pn_a', :'mg_a', 'tollfree') as r) x),
                array['+18885550100', :'pn_a', :'mg_a', 'tollfree', 'not_started'], 'the number is bound to the shop');
select tests.as_superuser();
select tests.eq((select sms_from_number from public.shops where id = tests.fx('shop_a')), '+18885550100',
                'and becomes its sending number');
select tests.as_service();
select tests.lives($$select public.record_sms_number(tests.fx('shop_a'), '+18885550100', 'PN' || repeat('a1', 16), null, 'tollfree')$$,
                   'recording the same number again is idempotent');
select tests.throws_like($$select public.record_sms_number(tests.fx('shop_b'), '+18885550100', 'PN' || repeat('c3', 16), null, 'local')$$,
                         '23505', '%another shop%', 'a number belongs to one shop');
select tests.throws_like($$select public.record_sms_number(tests.fx('shop_a'), '+18885550101', 'PN' || repeat('c3', 16), null, 'local')$$,
                         '23505', '%release it first%', 'one provisioned number per shop');
select tests.as_superuser();
select tests.throws($$insert into public.shop_sms_numbers (phone_number, shop_id, twilio_number_sid)
                      values ('+18885550102', tests.fx('shop_a'), 'PN' || repeat('d4', 16))$$, '23505',
                    'the one-provisioned-number index holds for direct writes too');
-- a number bound by hand (support) sits next to it
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));

-- ============================================================ RLS
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select array[kind, verification_status, business_info::text] from public.shop_sms_numbers
                  where phone_number = '+18885550100'), array['tollfree', 'not_started', '{}'], 'admins read the new columns');
select tests.throws($$update public.shop_sms_numbers set verification_status = 'approved'$$, '42501', 'but never write them');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.shop_sms_numbers$$), 0::bigint, 'managers do not see numbers');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$select 1 from public.shop_sms_numbers where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'another shop''s admin sees nothing');

-- ============================================================ verification
select tests.as_service();
select tests.throws($$select public.set_sms_verification(tests.fx('shop_a'), 'done')$$, '22023', 'known statuses only');
select tests.throws($$select public.set_sms_verification(tests.fx('shop_a'), 'pending', null, null, '[1]')$$, '22023',
                    'business info is an object');
select tests.throws($$select public.set_sms_verification(tests.fx('shop_b'), 'pending')$$, 'P0002', 'shop B has no provisioned number');
select tests.eq((select (r).verification_status || ' ' || (r).verification_sid || ' ' || ((r).business_info ->> 'legal_name')
                   from (select public.set_sms_verification(tests.fx('shop_a'), 'pending', 'HH' || repeat('9', 32),
                                                            null, '{"legal_name": "Shop A LLC", "website": "https://shop-a.test"}') as r) x),
                'pending HH99999999999999999999999999999999 Shop A LLC', 'submitted for verification');
select tests.eq((select array_agg(n.user_id order by n.user_id) from public.notifications n where n.kind = 'sms_number_status'),
                (select array_agg(u order by u) from unnest(array[tests.fx('u_owner_a'), tests.fx('u_admin_a')]) u),
                'owners and admins are told');
select tests.eq((select distinct title from public.notifications where kind = 'sms_number_status'),
                'Text messaging number verification submitted', 'what happened');
select public.set_sms_verification(tests.fx('shop_a'), 'pending');
select tests.eq((select count(*) from public.notifications where kind = 'sms_number_status'), 2::bigint, 'no change: no new notice');
select tests.eq((select array[(r).verification_status, (r).rejection_reason, (r).business_info ->> 'legal_name', (r).verification_sid]
                   from (select public.set_sms_verification(tests.fx('shop_a'), 'rejected', null, '  Opt-in flow unclear  ') as r) x),
                array['rejected', 'Opt-in flow unclear', 'Shop A LLC', 'HH' || repeat('9', 32)],
                'rejected with the reason; business info and sid kept');
select tests.eq((select body from public.notifications where kind = 'sms_number_status' and title like '%rejected%' limit 1),
                'Opt-in flow unclear', 'the reason reaches the admins');
select tests.eq((select (r).rejection_reason from (select public.set_sms_verification(tests.fx('shop_a'), 'approved') as r) x), null,
                'approved clears the reason');
select tests.eq((select body from public.notifications where kind = 'sms_number_status' and title = 'Text messaging number approved'
                  limit 1), '(888) 555-0100 can now send text messages.', 'approval notice');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'sms_number_status'$$), 0::bigint,
                'managers are not sent these');

-- ============================================================ status
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(public.sms_provisioning_status(tests.fx('shop_a')),
                '{"number": "+18885550100", "kind": "tollfree", "verification_status": "approved", "rejection_reason": null, "provisioned": true}'::jsonb,
                'admins read the status (the provisioned number first)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.sms_provisioning_status(tests.fx('shop_a'))$$, '42501', 'managers cannot');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.sms_provisioning_status(tests.fx('shop_a'))$$, '42501', 'technicians cannot');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.sms_provisioning_status(tests.fx('shop_a'))$$, '42501', 'another shop''s admin cannot');
select tests.eq(public.sms_provisioning_status(tests.fx('shop_b')),
                '{"number": null, "kind": null, "verification_status": null, "rejection_reason": null, "provisioned": false}'::jsonb,
                'a shop without a number');
select tests.as_anon();
select tests.throws($$select public.sms_provisioning_status(tests.fx('shop_a'))$$, '42501', 'anon cannot');

-- ============================================================ sender: messaging service
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Your car is ready');
select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'email', 'Hello', 'Your car is ready');
select tests.as_service();
create temp table claimed as select * from public.claim_queued_messages(50, now());
select tests.eq((select array[from_address, messaging_service_sid] from claimed where channel = 'sms' and shop_id = tests.fx('shop_a')),
                array['+18885550100', :'mg_a'], 'SMS carries the sending number''s messaging service');
select tests.eq((select messaging_service_sid from claimed where channel = 'email' and shop_id = tests.fx('shop_a')), null,
                'email has none');
-- a shop sending from a number bound by hand has no messaging service
select tests.as_superuser();
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.queue_message(tests.fx('shop_a'), tests.fx('cust_a'), 'sms', null, 'Second text');
select tests.as_service();
select tests.eq((select array[from_address, coalesce(messaging_service_sid, 'none')] from public.claim_queued_messages(50, now())
                  where shop_id = tests.fx('shop_a')), array['+12055550100', 'none'], 'a hand-bound number: none');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select * from public.claim_queued_messages()$$, '42501', 'the claim stays service-only');

-- ============================================================ release
select tests.as_superuser();
update public.shops set sms_from_number = '+18885550100' where id = tests.fx('shop_a');
select tests.as_service();
select public.release_sms_number(tests.fx('shop_a'));
select tests.as_superuser();
select tests.eq((select sms_from_number from public.shops where id = tests.fx('shop_a')), null, 'the sending number is cleared (FK)');
select tests.eq((select array_agg(phone_number order by phone_number) from public.shop_sms_numbers where shop_id = tests.fx('shop_a')),
                array['+12055550100'], 'only the provisioned binding is removed');
select tests.eq((select shop_name from public.sms_number_releases where phone_number = '+18885550100' and shop_id = tests.fx('shop_a')),
                'Shop A', 'the release is logged');
select tests.as_service();
select tests.lives($$select public.release_sms_number(tests.fx('shop_a'))$$, 'releasing again is a no-op');
select tests.eq(public.sms_provisioning_status(tests.fx('shop_a')) -> 'provisioned', 'false'::jsonb, 'no longer provisioned');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.release_sms_number(tests.fx('shop_a'))$$, '42501', 'release is service-only');
select tests.throws($$select public.set_sms_verification(tests.fx('shop_a'), 'approved')$$, '42501', 'verification is service-only');
