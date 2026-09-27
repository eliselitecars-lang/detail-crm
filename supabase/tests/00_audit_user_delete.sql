-- 00 foundation: deleting an auth account (Supabase auth.admin.deleteUser,
-- an erasure request) keeps the account's history and clears its audit
-- references (every such FK is ON DELETE SET NULL).
-- Regression: the BEFORE UPDATE triggers that pin created_by / recorded_by /
-- uploaded_by also pinned them inside the referential action's own UPDATE,
-- so the re-checked FK failed with 23503 and the whole delete rolled back:
-- a client who booked online while signed in, or a staff member who wrote a
-- quote/invoice/job/blocked time or recorded a payment, could never be
-- deleted. The columns stay write-once otherwise (public.audit_user_ref).
-- The foundation part runs with migrations 0001-0009 alone; the tables of
-- later domains (quotes, invoices, payments, memberships, time entries,
-- inspections, photos, campaigns, online booking) are covered when present.
\ir fixtures/two_shops.psql

select tests.as_superuser();
select (to_regproc('public.create_online_booking') is not null
        and to_regclass('public.quotes') is not null and to_regclass('public.payments') is not null
        and to_regclass('public.memberships') is not null and to_regclass('public.time_entries') is not null
        and to_regclass('public.inspections') is not null and to_regclass('public.job_photos') is not null
        and to_regclass('public.campaigns') is not null) as full_platform \gset

-- ------------------------------------------------------------ audit_user_ref
select tests.eq(public.audit_user_ref(null, tests.fx('u_manager_a')), tests.fx('u_manager_a'),
                'an existing account is never cleared');
select tests.eq(public.audit_user_ref(tests.fx('u_owner_a'), tests.fx('u_manager_a')), tests.fx('u_manager_a'),
                'nor re-pointed');
select tests.eq(public.audit_user_ref(null, '00000000-0000-4000-8000-000000000001'), '00000000-0000-4000-8000-000000000001'::uuid,
                'outside a trigger it reveals nothing: a missing account id comes back unchanged');
select tests.eq(public.audit_user_ref(null, null), null::uuid, 'null stays null');
select tests.as_anon();
select tests.throws($$select public.audit_user_ref(null, null)$$, '42501', 'anon cannot call the helper');

-- ------------------------------------------------------------ history written by the accounts (foundation)
-- a manager (no assignments, no time entries of their own) writes a job and
-- a blocked time; the admin sends an invite
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_m', id);
insert into public.blocked_times (shop_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), '2025-06-10 15:00Z', '2025-06-10 16:00Z', 'Supplier visit')
  returning tests.fx_set('block_m', id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('invite_admin', (public.invite_member(tests.fx('shop_a'), 'new-hire@test.local', 'technician')).id);

select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by = tests.fx('u_manager_a') from public.jobs where id = tests.fx('job_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.blocked_times where id = tests.fx('block_m')),
                                      (select invited_by = tests.fx('u_admin_a') from public.shop_invites where id = tests.fx('invite_admin')))),
                't,t,t', 'every foundation record carries its author');

-- ------------------------------------------------------------ history written by the accounts (later domains)
\if :full_platform
\ir fixtures/40_booking_setup.psql
select tests.as_superuser();
update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Monthly Wash', 4900)
  returning tests.fx_set('plan_a', id);
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before.jpg', tests.fx('u_manager_a'));

-- a client with an account books online while signed in: jobs.created_by = her id
select tests.fx_set('u_nina', tests.create_user('nina@example.com'));
create temp table fs as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a')], (now() at time zone 'America/Chicago')::date + 3,
         (now() at time zone 'America/Chicago')::date + 3, tests.fx('cat_car_a')) s;
create temp table booked (token uuid);
grant select on fs to authenticated;
grant insert on booked to authenticated;
select tests.authenticate_as(tests.fx('u_nina'));
insert into booked select (public.create_online_booking('shop-a',
  pg_temp.booking(jsonb_build_object('starts_at', (select starts_at from fs)))) ->> 'job_token')::uuid;
select tests.as_superuser();
select tests.fx_set('job_nina', (select j.id from public.jobs j join booked b on b.token = j.public_token));

-- the manager also writes a quote, an invoice + cash payment, a membership,
-- a manual time entry for a technician, an inspection, a photo and a campaign
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a3'))
  returning tests.fx_set('quote_m', id);
select tests.fx_set('inv_m', (public.create_invoice(tests.fx('cust_a3'),
  '[{"name":"Coat","unit_price_cents":20000,"taxable":false}]')).id);
select tests.fx_set('inv_m', (public.mark_invoice_sent(tests.fx('inv_m'))).id);
select tests.fx_set('pay_m', (public.record_manual_payment(tests.fx('inv_m'), 20000, 'cash')).id);
select tests.fx_set('mem_m', (public.create_membership(tests.fx('plan_a'), tests.fx('cust_a'), tests.fx('veh_a'))).id);
insert into public.time_entries (shop_id, member_id, kind, clock_in, clock_out, notes)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'shift', '2025-06-01 14:00Z', '2025-06-01 22:00Z', 'Forgot to clock')
  returning tests.fx_set('shift_m', id);
insert into public.inspections (shop_id, job_id, vehicle_id, kind) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre')
  returning tests.fx_set('insp_m', id);
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before.jpg', 'before')
  returning tests.fx_set('photo_m', id);
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Spring', 'sms', 'Spring detail special at {{shop_name}}! Call us to book.')
  returning tests.fx_set('camp_m', id);

select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by = tests.fx('u_nina') from public.jobs where id = tests.fx('job_nina')),
                                      (select created_by = tests.fx('u_manager_a') from public.quotes where id = tests.fx('quote_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.invoices where id = tests.fx('inv_m')),
                                      (select recorded_by = tests.fx('u_manager_a') from public.payments where id = tests.fx('pay_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.memberships where id = tests.fx('mem_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.time_entries where id = tests.fx('shift_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.inspections where id = tests.fx('insp_m')),
                                      (select uploaded_by = tests.fx('u_manager_a') from public.job_photos where id = tests.fx('photo_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.campaigns where id = tests.fx('camp_m')))),
                't,t,t,t,t,t,t,t,t', 'the signed-in booking records the client; every other record its author');
\endif

-- ------------------------------------------------------------ still write-once while the account exists
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set created_by = null, notes = 'x' where id = tests.fx('job_m');
update public.blocked_times set created_by = null, reason = 'Supplier' where id = tests.fx('block_m');
update public.blocked_times set created_by = tests.fx('u_owner_a') where id = tests.fx('block_m');
-- another shop's manager cannot reach the row at all
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set created_by = null where id = tests.fx('job_m')$$), 0::bigint,
                'shop B cannot touch shop A''s job');
select tests.as_service();
update public.jobs set created_by = null where id = tests.fx('job_m');
update public.shops set created_by = null where id = tests.fx('shop_a');
select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by = tests.fx('u_manager_a') from public.jobs where id = tests.fx('job_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.blocked_times where id = tests.fx('block_m')),
                                      (select created_by = tests.fx('u_owner_a') from public.shops where id = tests.fx('shop_a')))),
                't,t,t', 'clients and service_role can neither clear nor re-point an audit column of a live account');

\if :full_platform
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.quotes set created_by = null, notes = 'x' where id = tests.fx('quote_m');
update public.jobs set created_by = tests.fx('u_owner_a') where id = tests.fx('job_nina');
update public.job_photos set uploaded_by = null, caption = 'x' where id = tests.fx('photo_m');
update public.inspections set created_by = null, notes = 'x' where id = tests.fx('insp_m');
update public.time_entries set created_by = null, notes = 'x' where id = tests.fx('shift_m');
select tests.as_service();
update public.payments set recorded_by = null, note = 'x' where id = tests.fx('pay_m');
update public.invoices set created_by = null where id = tests.fx('inv_m');
update public.memberships set created_by = null where id = tests.fx('mem_m');
select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by = tests.fx('u_manager_a') from public.quotes where id = tests.fx('quote_m')),
                                      (select created_by = tests.fx('u_nina') from public.jobs where id = tests.fx('job_nina')),
                                      (select uploaded_by = tests.fx('u_manager_a') from public.job_photos where id = tests.fx('photo_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.inspections where id = tests.fx('insp_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.time_entries where id = tests.fx('shift_m')),
                                      (select recorded_by = tests.fx('u_manager_a') from public.payments where id = tests.fx('pay_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.invoices where id = tests.fx('inv_m')),
                                      (select created_by = tests.fx('u_manager_a') from public.memberships where id = tests.fx('mem_m')))),
                't,t,t,t,t,t,t,t', 'the later domains'' audit columns are write-once too');
\endif

-- ------------------------------------------------------------ the accounts are deleted
-- Production deletes accounts through the GoTrue admin API, which runs as
-- supabase_auth_admin (the owner of auth.users); service_role has no DELETE
-- privilege there, so the tests delete as the superuser.
select tests.as_superuser();
select tests.lives($$delete from auth.users where id = tests.fx('u_manager_a')$$,
  'a manager who wrote records (jobs, blocked times, and in later domains quotes, invoices, payments, memberships, time entries, inspections, photos, campaigns) can be deleted');
select tests.lives($$delete from auth.users where id = tests.fx('u_admin_a')$$,
  'an admin who sent an invite can be deleted');

select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by is null from public.jobs where id = tests.fx('job_m')),
                                      (select created_by is null from public.blocked_times where id = tests.fx('block_m')),
                                      (select invited_by is null from public.shop_invites where id = tests.fx('invite_admin')))),
                't,t,t', 'the history is kept and its references to the deleted accounts are cleared');
select tests.eq((select count(*) from public.shop_members where user_id in (tests.fx('u_manager_a'), tests.fx('u_admin_a'))),
                0::bigint, 'the memberships of the deleted accounts are gone');

\if :full_platform
select tests.as_superuser();
select tests.lives($$delete from auth.users where id = tests.fx('u_nina')$$,
  'a client who booked online while signed in can delete her account (jobs.created_by ON DELETE SET NULL)');
select tests.as_superuser();
select tests.eq((select concat_ws(',', (select created_by is null from public.jobs where id = tests.fx('job_nina')),
                                      (select created_by is null from public.quotes where id = tests.fx('quote_m')),
                                      (select created_by is null from public.invoices where id = tests.fx('inv_m')),
                                      (select recorded_by is null from public.payments where id = tests.fx('pay_m')),
                                      (select created_by is null from public.memberships where id = tests.fx('mem_m')),
                                      (select created_by is null from public.time_entries where id = tests.fx('shift_m')),
                                      (select created_by is null from public.inspections where id = tests.fx('insp_m')),
                                      (select uploaded_by is null from public.job_photos where id = tests.fx('photo_m')),
                                      (select created_by is null from public.campaigns where id = tests.fx('camp_m')))),
                't,t,t,t,t,t,t,t,t', 'the later domains keep their records with the deleted authors cleared');
select tests.eq((select concat_ws('/', status, total_cents, amount_paid_cents) from public.invoices where id = tests.fx('inv_m')),
                'paid/20000/20000', 'a paid invoice is untouched apart from its creator');
select tests.eq((select count(*) from public.jobs where id = tests.fx('job_nina')), 1::bigint,
                'the booking itself survives its client''s account');
\endif

-- the shop's creator can leave too: shops.created_by
select tests.fx_set('shop_c', tests.make_shop('founder-c@test.local', 'shop-c', 'Shop C'));
-- ownership passes to an heir (one owner per shop), then the founder leaves
select tests.fx_set('m_heir_c', tests.add_member(tests.fx('shop_c'), 'heir-c@test.local', 'admin'));
select tests.authenticate_as(tests.user_id('founder-c@test.local'));
select public.transfer_ownership(tests.fx('shop_c'), tests.fx('m_heir_c'));
select tests.as_superuser();
select tests.eq((select created_by from public.shops where id = tests.fx('shop_c')), tests.user_id('founder-c@test.local'),
                'the founder created shop C');
select tests.as_superuser();
select tests.lives($$delete from auth.users where email = 'founder-c@test.local'$$,
                   'the founder of a shop that has another owner can delete their account');
select tests.as_superuser();
select tests.eq((select created_by from public.shops where id = tests.fx('shop_c')), null::uuid, 'shops.created_by is cleared');

-- ------------------------------------------------------------ other accounts and shop B are untouched
select tests.ok((select created_by = tests.fx('u_owner_a') from public.shops where id = tests.fx('shop_a')),
                'shop A keeps its creator (a live account)');
select tests.ok((select created_by = tests.fx('u_owner_b') from public.shops where id = tests.fx('shop_b')),
                'shop B keeps its creator');
select tests.eq((select count(*) from public.shop_members where shop_id = tests.fx('shop_b')), 4::bigint,
                'shop B''s team is untouched');
