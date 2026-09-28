-- 100 (0107): a customer's client-portal link follows the email on file —
-- an email change or a customer merge never leaves (or hands) the record to
-- an account whose confirmed email is not the record's; the rightful owner
-- can claim it again. Also: every realtime-published table has REPLICA
-- IDENTITY FULL so filtered subscriptions receive DELETE events.
\ir fixtures/two_shops.psql

select tests.as_superuser();
select tests.fx_set('u_dave', tests.create_user('dave@example.com'));
select tests.fx_set('u_carol', tests.create_user('carol@example.com'));
select tests.fx_set('u_mal', tests.create_user('mal@example.com'));
select tests.fx_set('u_ally', tests.create_user('ally@example.com'));
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count)
  values (tests.fx('shop_a'), 'Club', 4000, 'month', 1) returning tests.fx_set('plan', id);

-- ============================================================ staff correct a mistyped email
-- staff typed Dave's address on Carol's record; Dave signs in and claims it
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, last_name, email, phone)
  values (tests.fx('shop_a'), 'Carol', 'Smith', 'dave@example.com', '+12055550177')
  returning tests.fx_set('cust_carol', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_carol'), 'scheduled', now() + interval '3 days', now() + interval '3 days 2 hours');
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status, price_cents, interval, interval_count, started_at,
                                stripe_subscription_id)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_carol'), 'active', 4000, 'month', 1, now(), 'sub_Carol1')
  returning tests.fx_set('mem_carol', id);
select tests.authenticate_as(tests.fx('u_dave'));
select tests.eq(public.portal_claim_customers(), 1, 'Dave claims the record that carries his address');
select tests.as_service();
select tests.ok(public.portal_membership_access(tests.fx('mem_carol'), tests.fx('u_dave')) is not null,
                'while linked, Dave reaches the membership''s Stripe handles');

-- a case-only edit keeps the link (same address)
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set email = 'Dave@Example.com' where id = tests.fx('cust_carol');
select tests.as_superuser();
select tests.eq((select portal_user_id from public.customers where id = tests.fx('cust_carol')), tests.fx('u_dave'),
                'a case-only email edit keeps the link');

-- staff fix the address: Dave loses the record
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set email = 'carol@example.com' where id = tests.fx('cust_carol');
select tests.as_superuser();
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_carol')),
                'the email change clears the link of the account that claimed the old address');
select tests.authenticate_as(tests.fx('u_dave'));
select tests.eq((select jsonb_array_length(o -> 'customers') + jsonb_array_length(o -> 'upcoming_jobs')
                   from (select public.portal_overview() as o) x), 0, 'Dave''s portal no longer shows Carol or her booking');
select tests.as_service();
select tests.ok(public.portal_membership_access(tests.fx('mem_carol'), tests.fx('u_dave')) is null,
                'nor can Dave cancel her membership or open her billing portal');
select tests.authenticate_as(tests.fx('u_dave'));
select tests.eq(public.portal_claim_customers(), 0, 'and Dave cannot claim it back');
-- Carol claims her own record
select tests.authenticate_as(tests.fx('u_carol'));
select tests.eq(public.portal_claim_customers(), 1, 'Carol claims her record');
select tests.eq((select o #>> '{customers,0,email}' from (select public.portal_overview() as o) x), 'carol@example.com',
                'Carol sees her record');

-- an edit that leaves the email alone keeps the link; removing the email clears it
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.customers set phone = '+12055550178' where id = tests.fx('cust_carol');
select tests.as_superuser();
select tests.eq((select portal_user_id from public.customers where id = tests.fx('cust_carol')), tests.fx('u_carol'),
                'other edits keep the link');
update public.customers set email = null where id = tests.fx('cust_carol');
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_carol')),
                'removing the email clears the link (every context)');
-- an account that is no longer confirmed does not keep a link through an edit
update public.customers set email = 'carol@example.com', portal_user_id = tests.fx('u_carol') where id = tests.fx('cust_carol');
select tests.eq((select portal_user_id from public.customers where id = tests.fx('cust_carol')), tests.fx('u_carol'),
                'a link to the account whose confirmed email is the new email is kept');
update public.customers set email = 'carol.old@example.com' where id = tests.fx('cust_carol');
update public.customers set portal_user_id = tests.fx('u_carol') where id = tests.fx('cust_carol');
update auth.users set email_confirmed_at = null where id = tests.fx('u_carol');
update public.customers set email = 'carol@example.com' where id = tests.fx('cust_carol');
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_carol')),
                'an unconfirmed account does not keep the link through an email edit');

-- staff may still clear a link themselves; a client can never set one (0004)
select tests.as_superuser();
update auth.users set email_confirmed_at = now() where id = tests.fx('u_carol');
update public.customers set portal_user_id = tests.fx('u_carol') where id = tests.fx('cust_carol');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.customers set portal_user_id = null where id = tests.fx('cust_carol')$$, 'staff can unlink');
select tests.throws($$update public.customers set portal_user_id = tests.fx('u_carol') where id = tests.fx('cust_carol')$$, '42501',
                    'staff cannot link');

-- ============================================================ merging a claimed duplicate into the real customer
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, last_name, email, phone)
  values (tests.fx('shop_a'), 'Victor', 'Real', 'victor@example.com', '+12055550188') returning tests.fx_set('cust_v', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_v'), 'scheduled', now() + interval '2 days', now() + interval '2 days 1 hour');
select tests.as_superuser();
-- a "duplicate" lead with the same name but someone else's (confirmed) address
insert into public.customers (shop_id, first_name, last_name, email, lifecycle)
  values (tests.fx('shop_a'), 'Victor', 'Real', 'mal@example.com', 'lead') returning tests.fx_set('cust_dup', id);
select tests.authenticate_as(tests.fx('u_mal'));
select tests.eq(public.portal_claim_customers(), 1, 'the lead is claimed by the account of its address');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.merge_customers(tests.fx('cust_dup'), tests.fx('cust_v'));
select tests.as_superuser();
select tests.eq((select jsonb_build_array(email::text, portal_user_id) from public.customers where id = tests.fx('cust_v')),
                '["victor@example.com", null]'::jsonb, 'the survivor keeps its email and does not take the duplicate''s link');
select tests.authenticate_as(tests.fx('u_mal'));
select tests.eq((select jsonb_array_length(o -> 'customers') + jsonb_array_length(o -> 'upcoming_jobs')
                   from (select public.portal_overview() as o) x), 0, 'the duplicate''s account sees nothing of Victor');

-- a survivor without an email takes the duplicate's email, and with it the link
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Ally', '+12055550199')
  returning tests.fx_set('cust_ally', id);
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'Ally', 'ally@example.com')
  returning tests.fx_set('cust_ally_dup', id);
select tests.authenticate_as(tests.fx('u_ally'));
select tests.eq(public.portal_claim_customers(), 1, 'Ally claims the record with her address');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.merge_customers(tests.fx('cust_ally_dup'), tests.fx('cust_ally'));
select tests.as_superuser();
select tests.eq((select jsonb_build_array(email::text, portal_user_id) from public.customers where id = tests.fx('cust_ally')),
                jsonb_build_array('ally@example.com', tests.fx('u_ally')), 'email and matching link move together');

-- ============================================================ realtime: DELETE events are filterable
select tests.ok((select count(*) >= 6 from pg_catalog.pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename in ('jobs', 'messages', 'notifications', 'payments', 'time_entries', 'tasks')),
                'the realtime tables are published');
select tests.eq((select coalesce(string_agg(pt.tablename, ', ' order by pt.tablename), '')
                   from pg_catalog.pg_publication_tables pt
                   join pg_catalog.pg_class c on c.relname = pt.tablename
                   join pg_catalog.pg_namespace n on n.oid = c.relnamespace and n.nspname = pt.schemaname
                  where pt.pubname = 'supabase_realtime' and c.relreplident <> 'f'), '',
                'every published table has REPLICA IDENTITY FULL (a filtered subscription hears its deletes)');
