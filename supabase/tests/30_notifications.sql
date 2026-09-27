-- 30 comms: notifications — notify_shop_staff (roles, active members,
-- exclusion, validation, not client-callable), recipient-only visibility,
-- read_at as the only writable column, dismiss, mark-all-read, composite
-- FKs and cross-shop isolation.
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
