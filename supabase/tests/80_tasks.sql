-- 80 comms: staff tasks (P-32, 0081/0084) — RLS per role (managers all,
-- technicians their own / assigned), server-set created_by / done_by /
-- due_notified_at, what technicians may change, assignment notifications,
-- due reminders exactly once (active assignee, else active creator, also
-- when the assignee was deactivated; 24 h window), the
-- automations hook, realtime publication, composite FKs and cross-shop
-- isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.notifications set pushed_at = now() where pushed_at is null;

-- ============================================================ managers
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.tasks (shop_id, title, notes, assignee_member_id, due_at, customer_id, job_id, created_by, done_by)
values (tests.fx('shop_a'), '  Call Alice about the coating  ', '  bring samples ', tests.fx('m_tech_a'), '2025-06-02 20:00+00',
        tests.fx('cust_a'), tests.fx('job_a'), tests.fx('u_owner_a'), tests.fx('u_owner_a'))
returning tests.fx_set('task1', id);
select tests.as_superuser();
select tests.eq((select array[title, notes, (created_by = tests.fx('u_manager_a'))::text, (done_by is null)::text]
                   from public.tasks where id = tests.fx('task1')),
                array['Call Alice about the coating', 'bring samples', 'true', 'true'],
                'trimmed; created_by is the caller (client values ignored)');
select tests.eq((select array[kind::text, title, body, (job_id = tests.fx('job_a'))::text, (customer_id = tests.fx('cust_a'))::text]
                   from public.notifications where user_id = tests.fx('u_tech_a') and kind = 'task_assigned'),
                array['task_assigned', 'Task: Call Alice about the coating', 'Due Monday, Jun 2 at 3:00 PM', 'true', 'true'],
                'the assignee is notified (local due time, deep links)');
select tests.throws($$insert into public.tasks (shop_id, title, customer_id) values (tests.fx('shop_a'), 'x', tests.fx('cust_b'))$$,
                    '23503', 'another shop''s customer (composite FK)');
select tests.throws($$insert into public.tasks (shop_id, title, job_id) values (tests.fx('shop_a'), 'x', tests.fx('job_b'))$$,
                    '23503', 'another shop''s job (composite FK)');
select tests.throws($$insert into public.tasks (shop_id, title, assignee_member_id) values (tests.fx('shop_a'), 'x', tests.fx('m_tech_b'))$$,
                    '23503', 'another shop''s member (composite FK)');
select tests.throws($$insert into public.tasks (shop_id, title) values (tests.fx('shop_a'), '   ')$$, '23514', 'title required');
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.throws_like($$insert into public.tasks (shop_id, title, assignee_member_id) values (tests.fx('shop_a'), 'x', tests.fx('m_tech2_a'))$$,
                         '22023', '%active team members%', 'only active members can be assigned');
update public.shop_members set active = true where id = tests.fx('m_tech2_a');

-- ============================================================ technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.tasks$$), 1::bigint, 'the assignee sees the task');
select tests.lives($$update public.tasks set title = 'Call Alice', notes = null, due_at = '2025-06-03 20:00+00' where id = tests.fx('task1')$$,
                   'the assignee edits title, notes and due time');
select tests.throws_like($$update public.tasks set assignee_member_id = tests.fx('m_tech2_a') where id = tests.fx('task1')$$,
                         '42501', '%reassign%', 'but cannot reassign it');
select tests.throws($$update public.tasks set customer_id = null where id = tests.fx('task1')$$, '42501', 'nor change its customer');
select tests.throws($$update public.tasks set job_id = null where id = tests.fx('task1')$$, '42501', 'nor its job');
update public.tasks set done_at = '2000-01-01', done_by = tests.fx('u_owner_a') where id = tests.fx('task1');
select tests.ok((select done_at = now() and done_by = tests.fx('u_tech_a') from public.tasks where id = tests.fx('task1')),
                'done is stamped by the server (time and who)');
update public.tasks set done_at = '2001-01-01' where id = tests.fx('task1');
select tests.ok((select done_at = now() from public.tasks where id = tests.fx('task1')), 'the done stamp is kept');
update public.tasks set done_at = null where id = tests.fx('task1');
select tests.ok((select done_at is null and done_by is null from public.tasks where id = tests.fx('task1')), 'reopened');
select tests.eq(tests.row_count($$delete from public.tasks where id = tests.fx('task1')$$), 0::bigint,
                'the assignee cannot delete a task someone else created');

-- own tasks
insert into public.tasks (shop_id, title) values (tests.fx('shop_a'), 'Restock towels') returning tests.fx_set('task2', id);
insert into public.tasks (shop_id, title, assignee_member_id, job_id, due_at)
  values (tests.fx('shop_a'), 'Check the paint depth', tests.fx('m_tech_a'), tests.fx('job_a'), '2025-06-02 16:00+00')
  returning tests.fx_set('task3', id);
select tests.throws($$insert into public.tasks (shop_id, title, assignee_member_id) values (tests.fx('shop_a'), 'x', tests.fx('m_tech2_a'))$$,
                    '42501', 'technicians cannot assign colleagues');
select tests.throws($$insert into public.tasks (shop_id, title, customer_id) values (tests.fx('shop_a'), 'x', tests.fx('cust_a'))$$,
                    '42501', 'technicians cannot link customers');
select tests.throws($$insert into public.tasks (shop_id, title, job_id) values (tests.fx('shop_a'), 'x', tests.fx('job_a2'))$$,
                    '42501', 'nor jobs they do not work');
select tests.throws($$insert into public.tasks (shop_id, title) values (tests.fx('shop_b'), 'x')$$, '42501', 'nor another shop');
select tests.eq(tests.row_count($$select 1 from public.tasks$$), 3::bigint, 'assigned + own tasks');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'task_assigned' and user_id = tests.fx('u_tech_a')), 1::bigint,
                'assigning yourself notifies nobody');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.tasks$$), 0::bigint, 'a colleague sees none of them');
select tests.eq(tests.row_count($$update public.tasks set title = 'x'$$), 0::bigint, 'nor updates');
select tests.eq(tests.row_count($$delete from public.tasks$$), 0::bigint, 'nor deletes');

-- reassigning notifies the new assignee
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.tasks set assignee_member_id = tests.fx('m_tech2_a') where id = tests.fx('task2');
select tests.as_superuser();
select tests.eq((select title from public.notifications where kind = 'task_assigned' and user_id = tests.fx('u_tech2_a')),
                'Task: Restock towels', 'reassignment notifies the new assignee');
select tests.eq((select body from public.notifications where kind = 'task_assigned' and user_id = tests.fx('u_tech2_a')),
                null, 'no due time: no body');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.tasks where id = tests.fx('task2')$$), 1::bigint,
                'the creator still sees a task they handed over');
select tests.eq(tests.row_count($$delete from public.tasks where id = tests.fx('task2')$$), 1::bigint, 'and may delete it');

-- a removed member loses access to tasks they created
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.tasks$$), 0::bigint, 'deactivated members see nothing');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');

-- ============================================================ due reminders
select tests.as_superuser();
insert into public.tasks (shop_id, title, created_by, due_at)
  values (tests.fx('shop_a'), 'Unassigned: order supplies', tests.fx('u_manager_a'), '2025-06-02 17:00+00')
  returning tests.fx_set('task4', id);
insert into public.tasks (shop_id, title, assignee_member_id, due_at)
  values (tests.fx('shop_a'), 'Stale', tests.fx('m_tech_a'), '2025-05-30 17:00+00');
insert into public.tasks (shop_id, title, assignee_member_id, due_at, done_at)
  values (tests.fx('shop_a'), 'Already done', tests.fx('m_tech_a'), '2025-06-02 16:30+00', now());
insert into public.tasks (shop_id, title, assignee_member_id, due_at)
  values (tests.fx('shop_b'), 'Shop B task', tests.fx('m_tech_b'), '2025-06-02 16:30+00') returning tests.fx_set('task_b', id);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.enqueue_task_reminders()$$, '42501', 'reminders are service-only');
select tests.as_service();
select tests.eq(public.enqueue_task_reminders('2025-06-02 15:00+00'), 0, 'nothing due yet');
select tests.eq(public.enqueue_task_reminders('2025-06-02 18:00+00'), 3, 'task3 (assignee), task4 (creator) and shop B''s task');
select tests.as_superuser();
select tests.eq((select array_agg(n.title order by n.title) from public.notifications n where n.kind = 'task_due' and n.shop_id = tests.fx('shop_a')),
                array['Task due: Check the paint depth', 'Task due: Unassigned: order supplies'], 'due tasks only');
select tests.eq((select user_id from public.notifications where title = 'Task due: Unassigned: order supplies'), tests.fx('u_manager_a'),
                'an unassigned task reminds its creator');
select tests.ok((select due_notified_at = '2025-06-02 18:00+00' from public.tasks where id = tests.fx('task3')), 'stamped');
select tests.as_service();
select tests.eq(public.enqueue_task_reminders('2025-06-02 18:05+00'), 0, 'exactly once');
-- moving the due time re-arms the reminder
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.tasks set due_at = '2025-06-02 19:00+00' where id = tests.fx('task3');
select tests.as_superuser();
select tests.ok((select due_notified_at is null from public.tasks where id = tests.fx('task3')), 'new due time: reminder re-armed');
update public.tasks set due_at = '2025-06-02 19:30+00', due_notified_at = '2025-06-02 18:30+00' where id = tests.fx('task_b');
select tests.ok((select due_notified_at = '2025-06-02 18:30+00' from public.tasks where id = tests.fx('task_b')),
                'trusted code may set both explicitly');
-- through the automations run (needs the app origin, like every run)
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-06-02 19:10+00'), 1, 'enqueue_due_automations runs task reminders');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where title = 'Task due: Check the paint depth'), 2::bigint,
                'the moved task was reminded again');

-- ============================================================ deactivated assignee
-- Regression: the creator was only looked up when there was no assignee, so
-- a task whose assignee had left the shop (membership deactivated, row kept,
-- so the ON DELETE SET NULL never fires) was reminded to nobody and its
-- reminder was used up (due_notified_at stamped).
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.tasks (shop_id, title, assignee_member_id, due_at)
  values (tests.fx('shop_a'), 'Call back about ceramic quote', tests.fx('m_tech2_a'), '2025-06-05 20:00+00')
  returning tests.fx_set('task_left', id);
select tests.as_superuser();
-- a task the leaver created for themselves: nobody active is left to tell
insert into public.tasks (shop_id, title, assignee_member_id, created_by, due_at)
  values (tests.fx('shop_a'), 'Own note of the leaver', tests.fx('m_tech2_a'), tests.fx('u_tech2_a'), '2025-06-05 20:00+00')
  returning tests.fx_set('task_own', id);
-- a creator who is a member of ANOTHER shop only is never reminded here
insert into public.tasks (shop_id, title, assignee_member_id, created_by, due_at)
  values (tests.fx('shop_a'), 'Foreign creator', tests.fx('m_tech2_a'), tests.fx('u_manager_b'), '2025-06-05 20:00+00')
  returning tests.fx_set('task_foreign', id);
-- an active assignee still gets it, not the creator
insert into public.tasks (shop_id, title, assignee_member_id, created_by, due_at)
  values (tests.fx('shop_a'), 'Still assigned', tests.fx('m_tech_a'), tests.fx('u_manager_a'), '2025-06-05 20:00+00')
  returning tests.fx_set('task_active', id);
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.as_service();
select tests.eq(public.enqueue_task_reminders('2025-06-05 21:00+00'), 2,
                'the leaver''s task is reminded to its creator; the active assignee keeps theirs');
select tests.as_superuser();
select tests.eq((select array_agg(user_id) from public.notifications where title = 'Task due: Call back about ceramic quote'),
                array[tests.fx('u_manager_a')], 'the creator is told once the assignee is inactive');
select tests.eq((select array_agg(user_id) from public.notifications where title = 'Task due: Still assigned'),
                array[tests.fx('u_tech_a')], 'an active assignee is reminded, not the creator');
select tests.eq((select count(*) from public.notifications
                  where title in ('Task due: Own note of the leaver', 'Task due: Foreign creator')), 0::bigint,
                'no active assignee or creator in the shop: no notification (and none to another shop''s manager)');
select tests.eq((select count(*) from public.notifications where user_id = tests.fx('u_manager_b') and kind = 'task_due'
                    and shop_id = tests.fx('shop_a')), 0::bigint, 'shop B''s manager gets nothing from shop A');
select tests.ok((select bool_and(due_notified_at = '2025-06-05 21:00+00') from public.tasks
                  where id in (tests.fx('task_left'), tests.fx('task_own'), tests.fx('task_foreign'), tests.fx('task_active'))),
                'every due task is stamped');
select tests.as_service();
select tests.eq(public.enqueue_task_reminders('2025-06-05 21:05+00'), 0, 'still exactly once');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech2_a');

-- ============================================================ isolation / realtime / anon
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.tasks where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B managers do not see shop A tasks');
select tests.eq(tests.row_count($$update public.tasks set title = 'x' where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'nor update them');
select tests.as_anon();
select tests.throws($$select 1 from public.tasks$$, '42501', 'anon has no access');
select tests.as_superuser();
select tests.ok(exists (select 1 from pg_catalog.pg_publication_tables
                         where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tasks'),
                'tasks are in the realtime publication');
-- deleting the customer / job keeps the task
select tests.as_superuser();
delete from public.tasks where job_id = tests.fx('job_a2');
insert into public.tasks (shop_id, title, customer_id) values (tests.fx('shop_a'), 'For Fleet Co', tests.fx('cust_a3'))
  returning tests.fx_set('task5', id);
delete from public.customers where id = tests.fx('cust_a3');
select tests.ok((select customer_id is null from public.tasks where id = tests.fx('task5')), 'a deleted customer unlinks the task');
