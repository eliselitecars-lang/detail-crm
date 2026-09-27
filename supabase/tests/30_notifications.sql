-- 30 comms: notifications — notify_shop_staff (roles, active members,
-- manager-only kinds, exclusion, validation, not client-callable),
-- recipient-only visibility, visibility by the recipient's CURRENT role
-- (demotion / promotion), read_at as the only writable column, dismiss,
-- mark-all-read, composite FKs and cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ helper is not client-callable
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.notify_shop_staff(tests.fx('shop_a'), null, 'general', 'Hi')$$, '42501',
                    'owners cannot call notify_shop_staff');
select tests.as_anon();
select tests.throws($$select public.notify_shop_staff(tests.fx('shop_a'), null, 'general', 'Hi')$$, '42501', 'anon cannot');

-- ------------------------------------------------------------ fan-out
select tests.as_service();
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['owner', 'admin']::public.shop_role[], 'new_booking',
                                         ' New online booking ', ' Alice booked a Full Detail ', tests.fx('job_a')), 2,
                'owner + admin');
select tests.ok((select bool_and(kind = 'new_booking' and title = 'New online booking' and body = 'Alice booked a Full Detail'
                                 and job_id = tests.fx('job_a') and read_at is null)
                   from public.notifications), 'title/body trimmed, job linked');
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), null, 'general', 'Shop update'), 5, 'null roles = every active member');
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), '{}', 'general', 'Shop update 2'), 5, 'empty roles = everyone');
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['technician']::public.shop_role[], 'general', 'Techs only', '',
                                         null, tests.fx('u_tech2_a')), 1, 'actor excluded');
select tests.ok((select body is null from public.notifications where title = 'Techs only'), 'blank body stored as null');
select tests.throws($$select public.notify_shop_staff(tests.fx('shop_a'), null, 'general', '  ')$$, '22023', 'title required');
select tests.throws($$select public.notify_shop_staff(tests.fx('shop_a'), null, null, 'x')$$, '22023', 'kind required');
select tests.throws($$select public.notify_shop_staff(tests.fx('shop_a'), null, 'general', 'x', null, tests.fx('job_b'))$$, 'P0002',
                    'job must belong to the shop');
select tests.eq(public.notify_shop_staff(gen_random_uuid(), null, 'general', 'x'), 0, 'unknown shop: nobody');
select tests.eq(public.notify_shop_staff(tests.fx('shop_b'), array['manager']::public.shop_role[], 'payment_received',
                                         'Payment received', '$50.00', tests.fx('job_b')), 1, 'shop B manager');
select tests.lives($$select public.notify_shop_staff(tests.fx('shop_a'), null, 'general', repeat('t', 300), repeat('b', 3000))$$,
                   'long text is truncated, not rejected');
select tests.ok((select char_length(title) = 200 and char_length(body) = 2000 from public.notifications
                  where title like 'ttt%' limit 1), 'title ≤ 200, body ≤ 2000');

-- inactive members get nothing and lose access
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.as_service();
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), null, 'general', 'After deactivation'), 4,
                'inactive members are not notified');

-- ------------------------------------------------------------ visibility
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 5::bigint,
                'owner sees only their own (booking, 2 updates, long, after deactivation)');
select tests.eq(tests.row_count($$select 1 from public.notifications where user_id <> auth.uid()$$), 0::bigint, 'never anyone else''s');
select tests.eq(tests.row_count($$update public.notifications set read_at = now() where kind = 'new_booking'$$), 1::bigint,
                'recipients mark read');
select tests.throws($$update public.notifications set title = 'x'$$, '42501', 'only read_at is writable');
select tests.throws($$update public.notifications set user_id = tests.fx('u_admin_a')$$, '42501', 'recipient cannot be changed');
select tests.throws($$insert into public.notifications (shop_id, user_id, kind, title)
                      values (tests.fx('shop_a'), auth.uid(), 'general', 'self')$$, '42501', 'no direct inserts');
select tests.eq(public.mark_all_notifications_read(tests.fx('shop_a')), 4, 'mark all read');
select tests.eq(tests.row_count($$select 1 from public.notifications where read_at is null$$), 0::bigint, 'all read');
select tests.eq(tests.row_count($$delete from public.notifications where title = 'Shop update'$$), 1::bigint, 'recipients dismiss');
select tests.throws($$select public.mark_all_notifications_read(tests.fx('shop_b'))$$, '42501', 'not for another shop');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where read_at is null$$), 5::bigint,
                'the admin''s copies are independent');
select tests.eq(tests.row_count($$update public.notifications set read_at = now() where user_id = tests.fx('u_owner_a')$$),
                0::bigint, 'cannot touch the owner''s notifications');
select tests.eq(tests.row_count($$delete from public.notifications where user_id = tests.fx('u_owner_a')$$), 0::bigint,
                'or dismiss them');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 5::bigint, 'technicians see their own');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 0::bigint, 'deactivated members see nothing');
select tests.eq(tests.row_count($$update public.notifications set read_at = now()$$), 0::bigint, 'and change nothing');

select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 1::bigint, 'shop B manager sees their one');
select tests.eq(tests.row_count($$select 1 from public.notifications where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'nothing of shop A');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 0::bigint, 'outsiders see nothing');

-- ------------------------------------------------------------ integrity
select tests.as_superuser();
select tests.throws($$insert into public.notifications (shop_id, user_id, kind, title)
                      values (tests.fx('shop_a'), tests.fx('u_owner_b'), 'general', 'x')$$, '23503',
                    'the recipient must be a member of the shop');
select tests.throws($$insert into public.notifications (shop_id, user_id, kind, title, job_id)
                      values (tests.fx('shop_a'), tests.fx('u_owner_a'), 'general', 'x', tests.fx('job_b'))$$, '23503',
                    'the job must belong to the shop');
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_b'), tests.fx('cust_b'), 'requested')
  returning tests.fx_set('job_tmp', id);
select public.notify_shop_staff(tests.fx('shop_b'), array['owner']::public.shop_role[], 'new_booking', 'Temp', null, tests.fx('job_tmp'));
delete from public.jobs where id = tests.fx('job_tmp');
select tests.ok((select job_id is null from public.notifications where title = 'Temp'), 'deleting a job keeps its notifications');

-- ------------------------------------------------------------ demoted recipients
-- Regression: every event kind is sent to owners/admins/managers only, but
-- the policies checked only "own + active member", so a manager demoted to
-- technician kept reading payment amounts, customer names and inbound texts
-- (and got them over Realtime). Visibility now follows the CURRENT role.
select tests.as_superuser();
delete from public.notifications where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['owner', 'admin', 'manager']::public.shop_role[], 'payment_received',
                                         'Payment received: $500.00 from Alice Anders', 'Job #1001 · card', tests.fx('job_a'), null),
                3, 'owner, admin and manager notified');
select public.notify_shop_staff(tests.fx('shop_a'), array['manager']::public.shop_role[], 'inbound_message',
                                'New text from Alice Anders', 'Can you come earlier?');
select public.notify_shop_staff(tests.fx('shop_a'), array['manager']::public.shop_role[], 'general', 'Team meeting at 8');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications$$), 3::bigint, 'the manager reads all three');

select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set role = 'technician' where id = tests.fx('m_manager_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.shop_role_of(tests.fx('shop_a'))::text, 'technician', 'now a technician');
select tests.eq(tests.row_count('select 1 from public.payments'), 0::bigint, 'technician: no payment rows');
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'payment_received'$$), 0::bigint,
                'a technician must not keep reading manager-only payment notifications');
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'inbound_message'$$), 0::bigint,
                'or customers'' texts');
select tests.eq((select array_agg(title) from public.notifications), array['Team meeting at 8'],
                'general notices stay visible');
select tests.eq(tests.row_count($$update public.notifications set read_at = now() where kind <> 'general'$$), 0::bigint,
                'hidden notifications cannot be marked read');
select tests.eq(tests.row_count($$delete from public.notifications where kind <> 'general'$$), 0::bigint, 'or dismissed');
select tests.eq(public.mark_all_notifications_read(tests.fx('shop_a')), 1, 'mark-all only touches what they can read');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where user_id = tests.fx('u_manager_a') and read_at is null), 2::bigint,
                'the hidden ones were left alone');

-- manager-only kinds are never sent to technicians, whatever roles are asked for
select tests.as_service();
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), null, 'payment_received', 'Payment received: $10.00'), 2,
                'null roles: owner + admin only (everyone else is a technician now)');
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['technician']::public.shop_role[], 'new_booking', 'New booking'), 0,
                'asking for technicians sends a manager-only kind to nobody');
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['technician']::public.shop_role[], 'general', 'Techs'), 2,
                'general notices still reach technicians');

-- promoted back: the earlier notifications are readable again
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set role = 'manager' where id = tests.fx('m_manager_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind in ('payment_received', 'inbound_message')$$),
                2::bigint, 'visible again once a manager');

-- end to end: a real payment notifies the manager, who loses it on demotion
-- (payment notifications come from the integration range, 0041; skipped when
-- only the comms ranges are applied)
select to_regclass('public.integration_events') is not null as has_integration \gset
\if :has_integration
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select public.record_manual_payment(tests.fx('inv'), 5000, 'cash', 0, null);
select tests.as_service();
select tests.eq((select count(*) from public.notifications where user_id = tests.fx('u_manager_a') and kind = 'payment_received'
                   and title like 'Payment received: $50.00%'), 1::bigint, 'manager notified of the payment');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set role = 'technician' where id = tests.fx('m_manager_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.notifications where kind = 'payment_received'), 0::bigint,
                'a technician must not keep reading payment notifications');
\endif

-- the other shop is unaffected
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'payment_received'$$), 1::bigint,
                'shop B''s manager still reads their payment notification');
select tests.eq(tests.row_count($$select 1 from public.notifications where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'and nothing of shop A');

-- ============================================================ card dispute alerts are manager-only
-- Regression: stripe-webhook posted dispute alerts ("Stripe dispute
-- (fraudulent, $1,234.00): lost.") as 'general', the one kind every member
-- may read, so an owner/admin demoted to technician kept reading dispute
-- amounts and reasons. They are now sent as 'payment_received' (exactly the
-- call handlers.ts makes), which follows the reader's CURRENT role.
select tests.ok(public.notification_kind_for_managers('payment_received'), 'payment_received is manager-only');
select tests.ok(not public.notification_kind_for_managers('general'), 'general is the only kind for every member');
select tests.as_service();
select tests.eq(public.notify_shop_staff(tests.fx('shop_a'), array['owner','admin']::public.shop_role[], 'payment_received',
                  'Dispute lost: money taken back', 'Stripe dispute (fraudulent, $1,234.00): lost.', tests.fx('job_a')),
                2, 'the owner and the admin are alerted');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where body like '%$1,234.00%'$$), 1::bigint,
                'the admin reads the dispute alert');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set role = 'technician' where id = tests.fx('m_admin_a');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where body like '%$1,234.00%'$$), 0::bigint,
                'a member demoted to technician no longer reads dispute amounts in old notifications');
select tests.eq(tests.row_count($$update public.notifications set read_at = now() where body like '%$1,234.00%'$$), 0::bigint,
                'nor marks them read');
select tests.eq(public.mark_all_notifications_read(tests.fx('shop_a')), 0, 'mark-all skips them too');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where body like '%$1,234.00%'$$), 1::bigint,
                'the owner still reads theirs');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where body like '%$1,234.00%'$$), 0::bigint,
                'technicians never see it');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$select 1 from public.notifications where body like '%$1,234.00%'$$), 0::bigint,
                'nor does another shop');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where body like '%$1,234.00%'
                   and user_id = tests.fx('u_admin_a') and read_at is null), 1::bigint,
                'the demoted admin''s copy is kept (unread) should they be promoted again');
