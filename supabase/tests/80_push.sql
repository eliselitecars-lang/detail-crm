-- 80 comms: push notifications for the staff app (P-2, 0081/0082) —
-- device tokens (register / move / unregister / invalidate, own rows only,
-- 25 per user), technician-readable kinds, job assigned / rescheduled
-- notifications (actor excluded, system writes silent, no money), per-member
-- push preferences (own row only), the push claim queue (stale, unreadable,
-- muted, switched off, no device, idempotent), release / retry limit, and
-- cross-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
-- the push queue is global: settle whatever a shared database already holds
-- (rolled back with this file)
update public.notifications set pushed_at = now() where pushed_at is null;

-- ============================================================ kinds
select tests.ok(not public.notification_kind_for_managers('job_assigned')
                and not public.notification_kind_for_managers('job_rescheduled')
                and not public.notification_kind_for_managers('task_assigned')
                and not public.notification_kind_for_managers('task_due')
                and not public.notification_kind_for_managers('general'),
                'job / task kinds and general notices are for every member');
select tests.ok(public.notification_kind_for_managers('new_lead') and public.notification_kind_for_managers('sms_number_status')
                and public.notification_kind_for_managers('webhook_failing') and public.notification_kind_for_managers('payment_received')
                and public.notification_kind_for_managers('low_stock') and public.notification_kind_for_managers(null),
                'every other kind stays manager-only');
select tests.ok(public.user_can_read_notification(tests.fx('u_tech_a'), tests.fx('shop_a'), 'job_assigned')
                and not public.user_can_read_notification(tests.fx('u_tech_a'), tests.fx('shop_a'), 'new_booking')
                and public.user_can_read_notification(tests.fx('u_manager_a'), tests.fx('shop_a'), 'new_booking')
                and not public.user_can_read_notification(tests.fx('u_tech_a'), tests.fx('shop_b'), 'job_assigned'),
                'user_can_read_notification: active membership + current role');

-- ============================================================ device tokens
select tests.as_anon();
select tests.throws($$select public.register_push_token(repeat('a', 64), 'sandbox', 'com.example.app')$$, '42501',
                    'anon cannot register a device');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.register_push_token('xyz', 'sandbox', 'com.example.app')$$, '22023', 'token must be hex');
select tests.throws($$select public.register_push_token(repeat('a', 63), 'sandbox', 'com.example.app')$$, '22023', '64 characters at least');
select tests.throws($$select public.register_push_token(repeat('a', 64), 'staging', 'com.example.app')$$, '22023', 'env sandbox / production');
select tests.throws($$select public.register_push_token(repeat('a', 64), 'sandbox', '  ')$$, '22023', 'bundle id required');
select tests.throws($$select public.register_push_token(repeat('a', 64), 'sandbox', 'x', repeat('9', 41))$$, '22023', 'app version capped');
select tests.eq((select array[(r).user_id::text, (r).token, (r).apns_env, (r).bundle_id, (r).app_version, ((r).disabled_at is null)::text]
                   from (select public.register_push_token('  ' || repeat('AB', 32) || ' ', 'Sandbox', 'com.example.app', '1.2') as r) x),
                array[tests.fx('u_tech_a')::text, repeat('ab', 32), 'sandbox', 'com.example.app', '1.2', 'true'],
                'registered for the caller, token lower-cased and trimmed');
select tests.eq(tests.row_count($$select 1 from public.device_push_tokens$$), 1::bigint, 'the owner sees their device');
select tests.throws($$insert into public.device_push_tokens (user_id, token, apns_env, bundle_id)
                      values (auth.uid(), repeat('c', 64), 'sandbox', 'x')$$, '42501', 'no direct inserts');
select tests.throws($$update public.device_push_tokens set apns_env = 'production'$$, '42501', 'no direct updates');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.device_push_tokens$$), 0::bigint, 'another user sees nothing');
select tests.eq(tests.row_count($$delete from public.device_push_tokens$$), 0::bigint, 'and deletes nothing');
select tests.eq(public.unregister_push_token(repeat('ab', 32)), false, 'nor unregisters someone else''s token');
-- the same physical device signs in as another user: the token moves
select public.register_push_token(repeat('ab', 32), 'production', 'com.example.app', '1.3');
select tests.eq(tests.row_count($$select 1 from public.device_push_tokens where apns_env = 'production'$$), 1::bigint,
                'the token moved to the new user (env updated)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.device_push_tokens$$), 0::bigint, 'the previous user lost it');

-- invalid token reported by APNs; registering again re-enables it
select tests.as_service();
select public.mark_push_token_invalid(upper(repeat('ab', 32)), 'BadDeviceToken');
select tests.ok((select disabled_at is not null and disabled_reason = 'BadDeviceToken' from public.device_push_tokens
                  where token = repeat('ab', 32)), 'marked invalid');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select public.register_push_token(repeat('ab', 32), 'production', 'com.example.app', '1.3');
select tests.as_superuser();
select tests.ok((select disabled_at is null and disabled_reason is null from public.device_push_tokens where token = repeat('ab', 32)),
                're-registering re-enables it');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(public.unregister_push_token(repeat('ab', 32)), true, 'unregister own token');
select tests.eq(public.unregister_push_token(repeat('ab', 32)), false, 'unregister is idempotent');

-- at most 25 enabled devices per user (the least recently seen are disabled)
select tests.authenticate_as(tests.fx('u_outsider'));
select public.register_push_token(lpad(to_hex(i), 64, '0'), 'sandbox', 'com.example.app') from generate_series(1, 27) i;
select tests.as_superuser();
select tests.eq((select count(*) from public.device_push_tokens where user_id = tests.fx('u_outsider') and disabled_at is null),
                25::bigint, '25 enabled devices at most');
select tests.eq((select count(*) from public.device_push_tokens where user_id = tests.fx('u_outsider') and disabled_reason = 'too many devices'),
                2::bigint, 'the oldest two were disabled');

-- ============================================================ job assigned
select tests.as_superuser();
-- the fixture assigned techs as the superuser: system writes announce nothing
select tests.eq((select count(*) from public.notifications where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))),
                0::bigint, 'fixture assignments (no signed-in actor) are silent');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_tech2_a'));
select tests.as_superuser();
select tests.eq((select array[kind::text, title, body, (job_id = tests.fx('job_a'))::text]
                   from public.notifications where user_id = tests.fx('u_tech2_a')),
                array['job_assigned', 'New job #' || (select number from public.jobs where id = tests.fx('job_a')),
                      'Monday, Jun 2 at 10:00 AM - Full Detail', 'true'],
                'the assigned technician is told: number, local date / time, services (no money, no phone)');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'job_assigned'$$), 1::bigint,
                'technicians can read job_assigned (RLS + kind rule)');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'job_assigned'$$), 0::bigint,
                'assigning yourself notifies nobody');
-- an unscheduled job
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_u', id);
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_u'), tests.fx('m_tech_a'));
select tests.as_superuser();
select tests.eq((select body from public.notifications where user_id = tests.fx('u_tech_a') and job_id = tests.fx('job_u')),
                'Not scheduled yet', 'an unscheduled job without lines says so');

-- ============================================================ job rescheduled
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = '2025-06-03 14:00+00', scheduled_end = '2025-06-03 16:00+00' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq((select array_agg(user_id order by user_id) from public.notifications where kind = 'job_rescheduled'),
                (select array_agg(u order by u) from unnest(array[tests.fx('u_tech_a'), tests.fx('u_tech2_a')]) u),
                'every assigned member except the one who moved it');
select tests.eq((select distinct body from public.notifications where kind = 'job_rescheduled'),
                'Now Tuesday, Jun 3 at 9:00 AM - Full Detail', 'with the new local time');
-- system moves and moves of jobs that are not scheduled / confirmed are silent
update public.jobs set scheduled_start = '2025-06-04 14:00+00', scheduled_end = '2025-06-04 16:00+00' where id = tests.fx('job_a');
select tests.eq((select count(*) from public.notifications where kind = 'job_rescheduled'), 2::bigint, 'superuser move: silent');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled' where id = tests.fx('job_a2');
update public.jobs set scheduled_start = '2025-06-05 14:00+00', scheduled_end = '2025-06-05 15:00+00' where id = tests.fx('job_a2');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'job_rescheduled'), 2::bigint,
                'a cancelled job moving is not announced');

-- ============================================================ notify_member
select tests.as_service();
select tests.ok(public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'Hello') is not null, 'notify_member');
select tests.ok(public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'new_lead', 'Lead') is null,
                'a manager-only kind is never sent to a technician');
select tests.ok(public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_b'), 'general', 'Hi') is null,
                'a member of another shop gets nothing');
select tests.throws($$select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'x', null, tests.fx('job_b'))$$,
                    'P0002', 'deep links stay in the shop');
select tests.throws($$select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', '  ')$$, '22023', 'title required');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'x')$$, '42501',
                    'not callable by API clients');

-- ============================================================ preferences
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select (p).member_id from (select public.set_notification_prefs(tests.fx('shop_a'),
                                             array['job_rescheduled', 'job_rescheduled']::public.notification_kind[]) as p) x),
                tests.fx('m_tech_a'), 'own membership only');
select tests.eq((select push_kinds::text from public.member_notification_prefs), '{job_rescheduled}', 'duplicates dropped');
select tests.throws($$select public.set_notification_prefs(tests.fx('shop_b'), null)$$, '42501', 'not in another shop');
select tests.throws($$insert into public.member_notification_prefs (member_id, shop_id) values (tests.fx('m_tech2_a'), tests.fx('shop_a'))$$,
                    '42501', 'not for a colleague');
select tests.lives($$update public.member_notification_prefs set muted_until = null$$, 'members edit their own row');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.member_notification_prefs$$), 0::bigint, 'managers do not see others'' prefs');
select tests.eq(tests.row_count($$update public.member_notification_prefs set muted_until = now() + interval '1 day'$$), 0::bigint,
                'nor edit them');
select tests.lives($$insert into public.member_notification_prefs (member_id, shop_id, muted_until)
                     values (tests.fx('m_manager_a'), tests.fx('shop_a'), now() + interval '1 hour')$$,
                   'a member may create their own row directly');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(tests.row_count($$select 1 from public.member_notification_prefs$$), 0::bigint, 'other shops see nothing');

-- ============================================================ push claim queue
select tests.as_superuser();
update public.notifications set pushed_at = now() where pushed_at is null;   -- a clean queue for this section
update public.member_notification_prefs set push_kinds = enum_range(null::public.notification_kind), muted_until = null
 where member_id = tests.fx('m_tech_a');
delete from public.member_notification_prefs where member_id = tests.fx('m_manager_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select public.register_push_token(repeat('1', 64), 'sandbox', 'com.example.app');
select public.register_push_token(repeat('2', 64), 'production', 'com.example.app');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.register_push_token(repeat('3', 64), 'sandbox', 'com.example.app');
select tests.as_service();
select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'N1 for tech', null, tests.fx('job_a'));
select public.notify_shop_staff(tests.fx('shop_a'), array['manager']::public.shop_role[], 'new_booking', 'N2 for manager', null,
                                tests.fx('job_a'), null, tests.fx('cust_a'));
select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech2_a'), 'general', 'N3 no device');
select tests.as_superuser();
insert into public.notifications (shop_id, user_id, kind, title, created_at)
  values (tests.fx('shop_a'), tests.fx('u_tech_a'), 'general', 'N4 stale', now() - interval '2 hours');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.claim_push_batch()$$, '42501', 'the queue is service-only');

select tests.as_service();
create temp table claim1 as select * from public.claim_push_batch(100, now());
select tests.eq((select array_agg(n.title order by n.title) from claim1 c join public.notifications n on n.id = c.notification_id),
                array['N1 for tech', 'N2 for manager'], 'deliverable notifications only');
select tests.eq((select jsonb_array_length(tokens) from claim1 where user_id = tests.fx('u_tech_a')), 2,
                'every enabled device of the recipient');
select tests.ok((select tokens @> '[{"token": "1111111111111111111111111111111111111111111111111111111111111111", "apns_env": "sandbox"}]'::jsonb
                   from claim1 where user_id = tests.fx('u_tech_a')), 'token + environment');
select tests.eq((select array[badge::text, kind::text, (job_id = tests.fx('job_a'))::text] from claim1 where user_id = tests.fx('u_tech_a')),
                array[(select count(*)::text from public.notifications where user_id = tests.fx('u_tech_a') and read_at is null),
                      'general', 'true'],
                'badge = the recipient''s unread notifications');
select tests.eq((select customer_id from claim1 where user_id = tests.fx('u_manager_a')), tests.fx('cust_a'), 'deep links included');
select tests.ok((select bool_and(pushed_at = now()) from public.notifications where title like 'N_ %'),
                'every claimed row is settled (pushed or skipped)');
select tests.eq((select array_agg(push_attempts order by title) from public.notifications where title like 'N_ %'),
                array[1, 1, 0, 0]::smallint[], 'attempts count only real pushes');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 0::bigint, 'a second claim finds nothing');

-- transient failure: back in the queue, at most 3 claims
select tests.eq(public.release_push((select notification_id from claim1 where user_id = tests.fx('u_tech_a'))), true, 'released');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 1::bigint, 'claimed again');
select tests.eq(public.release_push((select notification_id from claim1 where user_id = tests.fx('u_tech_a'))), true, 'released twice');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 1::bigint, 'third claim');
select tests.eq(public.release_push((select notification_id from claim1 where user_id = tests.fx('u_tech_a'))), false,
                'no fourth attempt');
select tests.eq(public.release_push(gen_random_uuid()), false, 'unknown id');

-- muted / kind switched off / demoted / history
select tests.authenticate_as(tests.fx('u_tech_a'));
select public.set_notification_prefs(tests.fx('shop_a'), array['job_assigned']::public.notification_kind[]);
select tests.as_service();
select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'M1 kind off');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 0::bigint, 'a kind switched off is not pushed');
select tests.ok((select pushed_at is not null and push_attempts = 0 from public.notifications where title = 'M1 kind off'),
                '… but settled');
select tests.authenticate_as(tests.fx('u_tech_a'));
select public.set_notification_prefs(tests.fx('shop_a'), null, now() + interval '1 hour');
select tests.as_service();
select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'M2 muted');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 0::bigint, 'muted: nothing pushed');
select tests.eq((select count(*) from public.claim_push_batch(100, now() + interval '2 hours')), 0::bigint,
                'a muted notification is not pushed later either');
select tests.authenticate_as(tests.fx('u_tech_a'));
select public.set_notification_prefs(tests.fx('shop_a'), null, now() - interval '1 minute');
select tests.as_service();
select public.notify_member(tests.fx('shop_a'), tests.fx('m_tech_a'), 'general', 'M3 unmuted');
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 1::bigint, 'an expired mute pushes again');
-- a manager demoted before the push: the manager-only notice is never pushed
select public.notify_shop_staff(tests.fx('shop_a'), array['manager']::public.shop_role[], 'payment_received', 'M4 money');
select tests.as_superuser();
update public.shop_members set role = 'technician' where id = tests.fx('m_manager_a');
select tests.as_service();
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 0::bigint,
                'a notification its recipient may no longer read is not pushed');
select tests.as_superuser();
update public.shop_members set role = 'manager' where id = tests.fx('m_manager_a');
-- history that was already handled is never pushed again
insert into public.notifications (shop_id, user_id, kind, title, pushed_at)
  values (tests.fx('shop_a'), tests.fx('u_manager_a'), 'general', 'M5 history', now() - interval '1 day');
select tests.as_service();
select tests.eq((select count(*) from public.claim_push_batch(100, now())), 0::bigint, 'handled history is not pushed');
select tests.eq((select count(*) from public.notifications where pushed_at is null), 0::bigint, 'the queue is empty');

-- ============================================================ isolation
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(tests.row_count($$select 1 from public.notifications where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B sees none of shop A''s notifications');
select tests.throws($$select public.release_push((select id from public.notifications limit 1))$$, '42501', 'release is service-only');
select tests.throws($$select public.mark_push_token_invalid('x', 'y')$$, '42501', 'invalidation is service-only');
