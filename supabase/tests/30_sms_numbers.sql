-- 30 comms: shop_sms_numbers — the platform's binding of a Twilio number to
-- its shop. shops.sms_from_number (typed in by owners/admins) may only name
-- a number bound to that shop, so no tenant can claim another shop's number
-- and lock it out of SMS (regression: the old platform-wide unique index on
-- sms_from_number let the first shop to type a number keep it). Access
-- rules, unbinding / moving a number, inbound routing, cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ regression: squatting another shop's number
-- The platform provisioned +12055550188 for shop A, but shop A has not saved
-- it yet. Shop B's admin types it into shop B first.
select tests.as_service();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550188', tests.fx('shop_a'));
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws_like($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_b')$$,
                         '23503', '%not provisioned for this shop%', 'shop B admin cannot squat shop A''s number');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_b')$$, '23503',
                    'nor can shop B''s owner');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_a')$$,
                   'shop A can save the SMS number provisioned for it');
select tests.eq((select sms_from_number from public.shops where id = tests.fx('shop_a')), '+12055550188', 'saved');

-- clearing it for a moment does not let anyone else take it
select tests.lives($$update public.shops set sms_from_number = null where id = tests.fx('shop_a')$$, 'shop A clears its number');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_b')$$, '23503',
                    'a cleared number still belongs to shop A');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_a')$$,
                   'shop A takes it back any time');

-- an unbound number (a personal cell, another carrier) cannot be used at all
select tests.throws_like($$update public.shops set sms_from_number = '+12055550177' where id = tests.fx('shop_a')$$,
                         '23503', '%not provisioned%', 'a number the platform never bound is refused');
select tests.throws($$update public.shops set sms_from_number = 'not a number' where id = tests.fx('shop_a')$$, '23514',
                    'and it must still be E.164');
select tests.eq((select sms_from_number from public.shops where id = tests.fx('shop_a')), '+12055550188', 'unchanged');

-- trusted code is held to the binding too (the foreign key backs the trigger)
select tests.as_service();
select tests.throws($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_b')$$, '23503',
                    'service_role cannot give shop B a number bound to shop A');
select tests.as_superuser();
select tests.eq((select pg_get_constraintdef(c.oid) from pg_constraint c where c.conname = 'shops_sms_from_number_fk'),
                'FOREIGN KEY (id, sms_from_number) REFERENCES shop_sms_numbers(shop_id, phone_number) ON DELETE SET NULL (sms_from_number)',
                'shops (id, sms_from_number) references the binding: the database itself keeps a number in one shop');
select tests.ok(not exists (select 1 from pg_indexes where indexname = 'shops_sms_from_number_key'),
                'no tenant-typed uniqueness any more');

-- ------------------------------------------------------------ the binding table's access rules
select tests.as_service();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+13125550199', tests.fx('shop_b'));
select tests.throws($$insert into public.shop_sms_numbers (phone_number, shop_id) values ('+13125550199', tests.fx('shop_a'))$$,
                    '23505', 'a number is bound to one shop only');
select tests.throws($$insert into public.shop_sms_numbers (phone_number, shop_id) values ('555-0100', tests.fx('shop_a'))$$,
                    '23514', 'bound numbers are E.164');
select tests.throws($$update public.shop_sms_numbers set shop_id = tests.fx('shop_a') where phone_number = '+13125550199'$$,
                    '42501', 'a binding never moves between shops in place');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select array_agg(phone_number) from public.shop_sms_numbers), array['+12055550188'],
                'owner of A sees only shop A''s numbers');
select tests.throws($$insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550166', tests.fx('shop_a'))$$,
                    '42501', 'owners cannot bind numbers themselves');
select tests.throws($$update public.shop_sms_numbers set phone_number = '+12055550166'$$, '42501', 'or rewrite a binding');
select tests.throws($$delete from public.shop_sms_numbers$$, '42501', 'or remove one');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select count(*) from public.shop_sms_numbers), 1::bigint, 'admins see their shop''s numbers');
select tests.eq((select count(*) from public.shop_sms_numbers where shop_id = tests.fx('shop_b')), 0::bigint,
                'but never another shop''s');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.shop_sms_numbers), 0::bigint, 'managers do not see bindings');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.shop_sms_numbers), 0::bigint, 'technicians do not see bindings');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq((select array_agg(phone_number) from public.shop_sms_numbers), array['+13125550199'],
                'admin of B sees only shop B''s number');
select tests.throws($$delete from public.shop_sms_numbers where shop_id = tests.fx('shop_a')$$, '42501',
                    'shop B cannot touch shop A''s binding');
select tests.as_anon();
select tests.throws($$select * from public.shop_sms_numbers$$, '42501', 'anon has no access');

-- ------------------------------------------------------------ inbound routing follows the binding
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.lives($$update public.shops set sms_from_number = '+13125550199' where id = tests.fx('shop_b')$$,
                   'shop B saves its own number');
select tests.as_service();
select tests.ok((select shop_id = tests.fx('shop_a') from public.record_inbound_sms('+12055550188', '+12055550101', 'Hi', 'SMn1')),
                'a text to shop A''s number reaches shop A');
select tests.ok((select shop_id = tests.fx('shop_b') from public.record_inbound_sms('+13125550199', '+12055550101', 'Hi', 'SMn2')),
                'and one to shop B''s number reaches shop B');
select tests.eq((select opt_action from public.record_inbound_sms('+12055550188', '+12055550101', 'STOP', 'SMn3')), 'opt_out',
                'STOP to shop A''s number opts out of shop A');
select tests.ok(exists (select 1 from public.comms_suppressions
                         where shop_id = tests.fx('shop_a') and channel = 'sms' and address = '+12055550101'),
                'recorded for shop A');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_b')),
                'shop B is unaffected');

-- ------------------------------------------------------------ unbinding and moving a number
-- the platform moves +12055550188 to shop B: unbinding clears it from shop A
delete from public.shop_sms_numbers where phone_number = '+12055550188';
select tests.eq((select sms_from_number from public.shops where id = tests.fx('shop_a')), null::text,
                'unbinding a number clears it from its shop');
select tests.eq((select count(*) from public.record_inbound_sms('+12055550188', '+12055550101', 'Hi', 'SMn4')), 0::bigint,
                'an unbound number routes nowhere');
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550188', tests.fx('shop_b'));
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_a')$$, '23503',
                    'shop A can no longer use a number moved to shop B');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.lives($$update public.shops set sms_from_number = '+12055550188' where id = tests.fx('shop_b')$$,
                   'shop B can use the number once the platform binds it to shop B');

-- deleting a shop removes its bindings (and the number becomes free)
select tests.as_superuser();
insert into public.shops (name, slug, timezone) values ('Gone', 'gone-shop', 'UTC') returning tests.fx_set('shop_gone', id);
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550144', tests.fx('shop_gone'));
update public.shops set sms_from_number = '+12055550144' where id = tests.fx('shop_gone');
select tests.lives($$delete from public.shops where id = tests.fx('shop_gone')$$, 'a shop with a bound number can be deleted');
select tests.ok(not exists (select 1 from public.shop_sms_numbers where phone_number = '+12055550144'),
                'its binding goes with it');

-- ------------------------------------------------------------ inbound follows the binding, not the sending number
-- Regression: record_inbound_sms routed by shops.sms_from_number, which
-- owners/admins may clear at any time (e.g. to pause texting). While it was
-- empty every reply to the shop's still-bound number was dropped, STOP
-- included: nothing was suppressed, so texting resumed to that customer as
-- soon as the number was set again.
select tests.as_service();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550133', tests.fx('shop_a'));
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.shops set sms_from_number = '+12055550133' where id = tests.fx('shop_a')$$, 'shop A sends from it');
select tests.lives($$update public.shops set sms_from_number = null where id = tests.fx('shop_a')$$,
                   'and pauses texting; the number stays bound');
select tests.as_service();
select count(*) as optout_notes_before from public.notifications
 where shop_id = tests.fx('shop_a') and kind = 'inbound_message' and title like '%opted out of text messages' \gset
select tests.eq((select array[shop_id::text, customer_id::text, opt_action]
                   from public.record_inbound_sms('+12055550133', '+12055550101', 'STOP', 'SMp1')),
                array[tests.fx('shop_a')::text, tests.fx('cust_a')::text, 'opt_out'],
                'a STOP to the paused number reaches shop A and its customer');
select tests.ok(public.comms_is_suppressed(tests.fx('shop_a'), 'sms', '+12055550101'),
                'a STOP sent to a number bound to the shop is recorded even while the shop has paused its sending number');
select tests.ok((select sms_opted_out_at is not null from public.customers where id = tests.fx('cust_a')), 'the customer is stamped');
select tests.ok(exists (select 1 from public.messages where provider_message_id = 'SMp1' and shop_id = tests.fx('shop_a')
                          and direction = 'inbound' and body = 'STOP'), 'the text is in shop A''s inbox');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'inbound_message'
                   and title like '%opted out of text messages'), :optout_notes_before + 3::bigint,
                'owner, admin and manager are told');
select tests.ok((select shop_id = tests.fx('shop_a') and opt_action is null
                   from public.record_inbound_sms('+12055550133', '+12055550101', 'Sorry, wrong number', 'SMp2')),
                'an ordinary reply is recorded too');
-- texting resumes: the opted-out customer is not texted
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.shops set sms_from_number = '+12055550133' where id = tests.fx('shop_a')$$, 'texting resumes');
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'booking_confirmed', 'sms', tests.fx('job_a')),
                null::uuid, 'the customer who said STOP while texting was paused is not texted');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_b') and address = '+12055550101'),
                'shop B is unaffected');
-- a number bound to shop B never lands in shop A, whatever shop A's settings say
select tests.ok((select shop_id = tests.fx('shop_b') from public.record_inbound_sms('+12055550188', '+12055550101', 'STOP', 'SMp3')),
                'a text to shop B''s bound number reaches shop B');

-- ------------------------------------------------------------ YES opts back in (like START / UNSTOP)
select tests.as_service();
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and channel = 'sms'
                         and address = '+12055550101'), 'shop A still has the STOP on record');
select tests.eq((select opt_action from public.record_inbound_sms('+12055550133', '+12055550101', ' yes! ', 'SMyes1')), 'opt_in',
                'replying YES is an opt-in keyword (case and trailing punctuation ignored)');
select tests.ok(not exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_a') and channel = 'sms'
                             and address = '+12055550101'), 'the number is re-subscribed in shop A');
select tests.ok((select sms_opted_out_at is null from public.customers where id = tests.fx('cust_a')),
                'and its customer can be texted again');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'on_the_way', 'sms', tests.fx('job_a'))
                  is not null, 'appointment texts go out again');
select tests.ok(exists (select 1 from public.comms_suppressions where shop_id = tests.fx('shop_b') and address = '+12055550101'),
                'shop B''s opt-out is unaffected by a YES to shop A');
select tests.eq((select opt_action from public.record_inbound_sms('+12055550133', '+12055550101', 'Yes please, Tuesday works', 'SMyes2')),
                null::text, 'YES inside a sentence is an ordinary reply');
