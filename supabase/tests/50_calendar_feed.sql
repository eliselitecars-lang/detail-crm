-- 50 sched: per-member iCal feed (P-19, 0055) — token rotation / revocation,
-- include_all for managers only (checked again at read time), technician
-- scope (assigned jobs, own events, shop-wide events without a customer),
-- curated content (no phone / email / prices / notes), window, statuses,
-- inactive members, last_accessed_at throttling, service-only reads.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set address_line1 = '1 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id = tests.fx('shop_a');
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
on conflict (key) do update set value = excluded.value;
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, service_city, service_region,
                         service_postal_code, scheduled_start, scheduled_end, notes)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'mobile', '9 Oak St', 'Hoover', 'AL', '35244',
          '2025-06-05 15:00Z', '2025-06-05 16:00Z', 'Dog in the yard') returning tests.fx_set('job_mobile', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', '2025-06-06 15:00Z', '2025-06-06 16:00Z')
  returning tests.fx_set('job_req', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, cancel_reason)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'cancelled', '2025-06-07 15:00Z', '2025-06-07 16:00Z', 'x')
  returning tests.fx_set('job_cancel', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-12-01 15:00Z', '2025-12-01 16:00Z') returning tests.fx_set('job_far', id);
insert into public.job_assignments (shop_id, job_id, member_id) values
  (tests.fx('shop_a'), tests.fx('job_mobile'), tests.fx('m_tech_a')),
  (tests.fx('shop_a'), tests.fx('job_req'), tests.fx('m_tech_a')),
  (tests.fx('shop_a'), tests.fx('job_cancel'), tests.fx('m_tech_a')),
  (tests.fx('shop_a'), tests.fx('job_far'), tests.fx('m_tech_a'));
insert into public.blocked_times (shop_id, kind, reason, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', 'Holiday', '2025-06-04 05:00Z', '2025-06-05 05:00Z') returning tests.fx_set('ev_closed', id);
insert into public.blocked_times (shop_id, member_id, kind, title, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'time_off', 'Dentist', '2025-06-03 19:00Z', '2025-06-03 21:00Z')
  returning tests.fx_set('ev_own', id);
insert into public.blocked_times (shop_id, member_id, kind, title, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'time_off', 'Private matter', '2025-06-03 19:00Z', '2025-06-03 21:00Z')
  returning tests.fx_set('ev_other', id);
insert into public.blocked_times (shop_id, kind, title, customer_id, starts_at, ends_at)
  values (tests.fx('shop_a'), 'consultation', 'Consult with Alice', tests.fx('cust_a'), '2025-06-03 15:00Z', '2025-06-03 15:30Z')
  returning tests.fx_set('ev_consult', id);
insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'meeting', '{"freq": "week", "count": 2}', '2025-06-02 13:00Z', '2025-06-02 13:30Z')
  returning tests.fx_set('ev_weekly', id);

-- ============================================================ tokens
select tests.authenticate_as(tests.fx('u_tech_a'));
create temp table feed1 as select public.create_calendar_feed(tests.fx('shop_a')) as r;
grant select on feed1 to authenticated, service_role;
select tests.ok((select r ->> 'path' = '/functions/v1/calendar-feed?token=' || (r ->> 'token') from feed1), '{token, path}');
select tests.throws_like($$select public.create_calendar_feed(tests.fx('shop_a'), true)$$, '42501', '%every job%',
                         'technicians cannot subscribe to every job');
select tests.eq((select count(*) from public.calendar_feed_tokens where revoked_at is null), 1::bigint, 'one live token (own row readable)');
create temp table feed2 as select public.create_calendar_feed(tests.fx('shop_a')) as r;
grant select on feed2 to authenticated, service_role;
select tests.ok((select revoked_at is not null from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from feed1)),
                'a new token revokes the previous one');
select tests.eq((select count(*) from public.calendar_feed_tokens where revoked_at is null), 1::bigint, 'still one live token');
select tests.throws($$insert into public.calendar_feed_tokens (shop_id, member_id) values (tests.fx('shop_a'), tests.fx('m_tech_a'))$$,
                    '42501', 'tokens are RPC-only');
select tests.throws($$update public.calendar_feed_tokens set include_all = true$$, '42501', 'no direct updates');
select tests.throws($$select public.calendar_feed_events((select (r ->> 'token')::uuid from feed2))$$, '42501',
                    'members cannot read feeds through the API (service only)');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count('select * from public.calendar_feed_tokens'), 0::bigint, 'another member cannot see the token');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count('select * from public.calendar_feed_tokens'), 0::bigint, 'not even the owner');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.create_calendar_feed(tests.fx('shop_a'))$$, '42501', 'shop B cannot create a feed in A');
select tests.eq(tests.row_count($$select * from public.calendar_feed_tokens where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B reads none of A''s tokens');
select tests.as_anon();
select tests.throws($$select public.create_calendar_feed(tests.fx('shop_a'))$$, '42501', 'anon denied');
select tests.throws($$select public.calendar_feed_events(gen_random_uuid())$$, '42501', 'anon cannot read feeds');

-- ============================================================ technician feed
select tests.as_service();
create temp table tf as select public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:00Z') as f;
select tests.eq((select f -> 'shop' from tf), '{"name": "Shop A", "timezone": "America/Chicago"}'::jsonb, 'shop header');
select tests.eq((select f #>> '{member,display_name}' from tf),
                (select display_name from public.shop_members where id = tests.fx('m_tech_a')), 'member header');
select tests.eq((select count(*) from tf, jsonb_array_elements(f -> 'events') e), 7::bigint,
                'job_a, job_mobile, job_req, own time off, the closure, 2 weekly meetings');
select tests.ok((select bool_and(e ->> 'uid' <> 'job-' || tests.fx('job_a2') and e ->> 'uid' <> 'job-' || tests.fx('job_cancel')
                                 and e ->> 'uid' <> 'job-' || tests.fx('job_far')
                                 and e ->> 'uid' not like 'event-' || tests.fx('ev_other') || '%'
                                 and e ->> 'uid' not like 'event-' || tests.fx('ev_consult') || '%')
                   from tf, jsonb_array_elements(f -> 'events') e),
                'no unassigned / cancelled / out-of-window jobs, no other member''s time off, no customer consultation');
select tests.eq((select e from tf, jsonb_array_elements(f -> 'events') e where e ->> 'uid' = 'job-' || tests.fx('job_a')) - 'updated_at',
                jsonb_build_object('uid', 'job-' || tests.fx('job_a'),
                                   'starts_at', '2025-06-02T15:00:00+00:00', 'ends_at', '2025-06-02T17:00:00+00:00',
                                   'summary', 'Job #1001 - Full Detail - Alice A.',
                                   'location', '1 Main St, Birmingham, AL 35203',
                                   'description', E'2021 Honda Civic\nFull Detail\nhttps://app.example.test/app/jobs/' || tests.fx('job_a'),
                                   'status', 'CONFIRMED'),
                'job event: number, services, first name + initial, shop address, vehicle, services, app link');
select tests.eq((select e ->> 'location' from tf, jsonb_array_elements(f -> 'events') e where e ->> 'uid' = 'job-' || tests.fx('job_mobile')),
                '9 Oak St, Hoover, AL 35244', 'mobile jobs: the service address');
select tests.eq((select e ->> 'status' from tf, jsonb_array_elements(f -> 'events') e where e ->> 'uid' = 'job-' || tests.fx('job_req')),
                'TENTATIVE', 'requested jobs are tentative');
select tests.eq((select e ->> 'summary' from tf, jsonb_array_elements(f -> 'events') e where e ->> 'uid' like 'event-' || tests.fx('ev_own') || '%'),
                'Dentist', 'own event title');
select tests.eq((select e ->> 'summary' from tf, jsonb_array_elements(f -> 'events') e where e ->> 'uid' like 'event-' || tests.fx('ev_closed') || '%'),
                'Holiday', 'closure (reason as title)');
select tests.eq((select array_agg(e ->> 'summary') from tf, jsonb_array_elements(f -> 'events') e
                  where e ->> 'uid' like 'event-' || tests.fx('ev_weekly') || '%'), array['Meeting', 'Meeting'],
                'an untitled event is named after its kind');
select tests.ok((select f::text not like '%+12055550101%' and f::text not like '%alice@example.com%'
                        and f::text not like '%20000%' and f::text not like '%Customer is picky%'
                        and f::text not like '%Gate code%' and f::text not like '%Dog in the yard%'
                        and f::text not like '%Anders%' from tf),
                'no phone, email, prices, notes or full last name');

-- ============================================================ managers, include_all, role changes
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table mf as select public.create_calendar_feed(tests.fx('shop_a'), true) as r;
grant select on mf to service_role;
select tests.as_service();
select tests.eq((select count(*) from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from mf),
                   '2025-06-01 12:00Z') -> 'events') e where e ->> 'uid' like 'job-%'), 4::bigint,
                'include_all: every scheduled, non-cancelled job in the window');
select tests.ok(exists (select 1 from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from mf),
                   '2025-06-01 12:00Z') -> 'events') e where e ->> 'uid' like 'event-' || tests.fx('ev_consult') || '%'),
                'include_all: customer consultations too');
select tests.ok(not exists (select 1 from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from mf),
                   '2025-06-01 12:00Z') -> 'events') e where e ->> 'uid' like 'event-' || tests.fx('ev_other') || '%'),
                'not other members'' time off');
select tests.as_superuser();
update public.shop_members set role = 'technician' where id = tests.fx('m_manager_a');
select tests.as_service();
select tests.eq((select count(*) from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from mf),
                   '2025-06-01 12:00Z') -> 'events') e where e ->> 'uid' like 'job-%'), 0::bigint,
                'a demoted manager''s include_all token only shows their assigned jobs');
select tests.as_superuser();
update public.shop_members set role = 'manager' where id = tests.fx('m_manager_a');

-- ============================================================ dead tokens, window, access stamps
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed1), '2025-06-01 12:00Z'), null::jsonb, 'revoked token');
select tests.eq(public.calendar_feed_events(gen_random_uuid(), '2025-06-01 12:00Z'), null::jsonb, 'unknown token');
select tests.eq((select count(*) from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from feed2),
                   '2025-11-15 12:00Z') -> 'events') e where e ->> 'uid' = 'job-' || tests.fx('job_far')), 1::bigint,
                'the window moves with now (90 days ahead)');
select tests.eq((select count(*) from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from feed2),
                   '2025-06-10 12:00Z') -> 'events') e where e ->> 'uid' = 'job-' || tests.fx('job_a')), 0::bigint,
                'and 7 days back');
select tests.as_superuser();
update public.calendar_feed_tokens set last_accessed_at = null where token = (select (r ->> 'token')::uuid from feed2);
select tests.as_service();
select tests.lives($$select public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:00Z')$$, 'read');
select tests.eq((select last_accessed_at from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from feed2)),
                '2025-06-01 12:00Z'::timestamptz, 'first read stamps last_accessed_at');
select tests.lives($$select public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:05Z')$$, 'read');
select tests.eq((select last_accessed_at from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from feed2)),
                '2025-06-01 12:00Z'::timestamptz, 'at most one stamp per 10 minutes');
select tests.lives($$select public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:11Z')$$, 'read');
select tests.eq((select last_accessed_at from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from feed2)),
                '2025-06-01 12:11Z'::timestamptz, 'stamped again after 10 minutes');
-- the manager's include_all token and shop B's tokens must survive the
-- technician's removal below
select tests.authenticate_as(tests.fx('u_tech_b'));
create temp table feed_b as select public.create_calendar_feed(tests.fx('shop_b')) as r;
grant select on feed_b to service_role;
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:00Z'), null::jsonb,
                'an inactive member''s feed is dead');
select tests.ok((select revoked_at is not null from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from feed2)),
                'deactivation revokes the member''s live token');
select tests.ok((select revoked_at is null from public.calendar_feed_tokens where token = (select (r ->> 'token')::uuid from mf)),
                'other members'' tokens are untouched');
select tests.ok(public.calendar_feed_events((select (r ->> 'token')::uuid from feed_b), '2025-06-01 12:00Z') is not null,
                'shop B''s feeds are untouched');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed2), '2025-06-01 12:00Z'), null::jsonb,
                'reactivating the same membership does not revive the old feed URL');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.revoke_calendar_feed(tests.fx('shop_a')), false, 'nothing live after the removal');
create temp table feed3 as select public.create_calendar_feed(tests.fx('shop_a')) as r;
grant select on feed3 to service_role;
select tests.as_service();
select tests.ok(public.calendar_feed_events((select (r ->> 'token')::uuid from feed3), '2025-06-01 12:00Z') is not null,
                'the re-added member subscribes again with a new token');

-- revoke
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.revoke_calendar_feed(tests.fx('shop_a')), true, 'revoke the live token');
select tests.eq(public.revoke_calendar_feed(tests.fx('shop_a')), false, 'nothing left to revoke');
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed3), '2025-06-01 12:00Z'), null::jsonb,
                'a revoked feed is dead');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.revoke_calendar_feed(tests.fx('shop_a'))$$, '42501', 'shop B cannot revoke in A');
-- deleting a membership removes its tokens (ON DELETE CASCADE)
select tests.as_superuser();
select tests.fx_set('m_temp', tests.add_member(tests.fx('shop_a'), 'temp-a@test.local', 'technician'));
select tests.authenticate_as(tests.user_id('temp-a@test.local'));
select tests.lives($$select public.create_calendar_feed(tests.fx('shop_a'))$$, 'a new member subscribes');
select tests.as_superuser();
delete from public.shop_members where id = tests.fx('m_temp');
select tests.eq((select count(*) from public.calendar_feed_tokens where member_id = tests.fx('m_temp')), 0::bigint,
                'the membership''s tokens are gone with it');

-- ============================================================ removal paths never revive a feed
-- An admin's removal through the API (RLS update), leave_shop, and re-adding
-- through accept_invite (which reactivates the SAME membership row).
select tests.authenticate_as(tests.fx('u_tech2_a'));
create temp table feed_t2 as select public.create_calendar_feed(tests.fx('shop_a')) as r;
grant select on feed_t2 to service_role;
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shop_members set active = false where id = tests.fx('m_tech2_a')$$), 1::bigint,
                'an admin removes the technician');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shop_members set active = true where id = tests.fx('m_tech2_a')$$), 1::bigint,
                'and adds them back');
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed_t2), '2025-06-01 12:00Z'), null::jsonb,
                'admin removal + re-add: the old URL stays dead');
-- leave_shop, then accept_invite
select tests.authenticate_as(tests.fx('u_tech2_a'));
create temp table feed_t3 as select public.create_calendar_feed(tests.fx('shop_a')) as r;
grant select on feed_t3 to service_role;
select tests.lives($$select public.leave_shop(tests.fx('shop_a'))$$, 'the technician leaves');
select tests.throws($$select public.create_calendar_feed(tests.fx('shop_a'))$$, '42501', 'a former member cannot make a feed');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('inv_t2', (select i.token from public.invite_member(tests.fx('shop_a'),
                                'tech2-a@test.local', 'technician') i));
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq((select m.id from public.accept_invite(tests.fx('inv_t2')) m),
                tests.fx('m_tech2_a'), 'accept_invite reactivates the same membership');
select tests.as_service();
select tests.eq(public.calendar_feed_events((select (r ->> 'token')::uuid from feed_t3), '2025-06-01 12:00Z'), null::jsonb,
                'leave_shop + accept_invite: the old URL stays dead');
select tests.eq((select count(*) from public.calendar_feed_tokens where member_id = tests.fx('m_tech2_a') and revoked_at is null),
                0::bigint, 'no live token until they subscribe again');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.lives($$select public.create_calendar_feed(tests.fx('shop_a'))$$, 'they can subscribe again');
-- only a deactivation revokes: other membership updates keep the feed
select tests.fx_set('tok_t4', (select token from public.calendar_feed_tokens
                                where member_id = tests.fx('m_tech2_a') and revoked_at is null));
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shop_members set display_name = 'Tech Two' where id = tests.fx('m_tech2_a')$$),
                1::bigint, 'a rename');
select tests.as_service();
select tests.ok(public.calendar_feed_events(tests.fx('tok_t4'), '2025-06-01 12:00Z') is not null, 'a rename keeps the feed');

-- ============================================================ a deleted customer's event stays out of technicians' feeds
select tests.as_superuser();
insert into public.customers (shop_id, first_name, last_name, phone)
  values (tests.fx('shop_a'), 'Carol', 'Privacy', '+12055550177') returning tests.fx_set('cust_priv', id);
insert into public.blocked_times (shop_id, kind, title, reason, customer_id, starts_at, ends_at)
  values (tests.fx('shop_a'), 'consultation', 'Consult Carol Privacy re: insurance claim', 'Call 205-555-0177',
          tests.fx('cust_priv'), '2025-06-03 16:00Z', '2025-06-03 16:30Z') returning tests.fx_set('ev_priv', id);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.fx_set('tok_priv', (public.create_calendar_feed(tests.fx('shop_a')) ->> 'token')::uuid);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_priv')$$), 1::bigint,
                'the customer is deleted (the event stays, unlinked)');
select tests.as_service();
select tests.ok((select not exists (select 1 from jsonb_array_elements(public.calendar_feed_events(tests.fx('tok_priv'),
                   '2025-06-01 12:00Z') -> 'events') e where e ->> 'uid' like 'event-' || tests.fx('ev_priv') || '%')),
                'the technician''s feed still leaves out the event about the deleted customer');
select tests.ok(public.calendar_feed_events(tests.fx('tok_priv'), '2025-06-01 12:00Z')::text not like '%Carol%',
                'no trace of their name');
select tests.ok(exists (select 1 from jsonb_array_elements(public.calendar_feed_events((select (r ->> 'token')::uuid from mf),
                   '2025-06-01 12:00Z') -> 'events') e
                 where e ->> 'uid' like 'event-' || tests.fx('ev_priv') || '%'
                   and e ->> 'summary' = 'Consult Carol Privacy re: insurance claim'),
                'a manager''s include_all feed still lists it');
