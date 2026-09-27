-- 00 foundation: jobs, job_line_items, job_assignments — role matrix,
-- technician column restrictions, numbering, integrity, isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ numbering
select tests.as_superuser();
select tests.eq((select array_agg(number order by number) from public.jobs where shop_id = tests.fx('shop_a')), array[1001::bigint, 1002],
                'job numbers per shop start at 1001');
select tests.eq((select number from public.jobs where id = tests.fx('job_b')), 1001::bigint, 'numbering is per shop');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, number, public_token, created_by, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 1, '00000000-0000-0000-0000-000000000001', tests.fx('u_owner_b'),
          '2025-06-03 15:00Z', '2025-06-03 16:00Z')
  returning tests.fx_set('job_m', id);
select tests.eq((select number from public.jobs where id = tests.fx('job_m')), 1003::bigint, 'client-sent number ignored; next number issued');
select tests.as_superuser();  -- staff cannot read job tokens once 0042 applies (customer credential)
select tests.ok((select public_token <> '00000000-0000-0000-0000-000000000001' from public.jobs where id = tests.fx('job_m')),
                'client-sent public_token ignored');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select created_by from public.jobs where id = tests.fx('job_m')), tests.fx('u_manager_a'), 'created_by is the caller');
select tests.eq((select status::text from public.jobs where id = tests.fx('job_m')), 'scheduled', 'staff jobs default to scheduled');
select tests.throws($$update public.jobs set number = 5000 where id = tests.fx('job_m')$$, '42501', 'numbers are immutable');
select tests.throws($$update public.jobs set public_token = gen_random_uuid() where id = tests.fx('job_m')$$, '42501', 'tokens are immutable');
select tests.lives($$update public.jobs set created_by = tests.fx('u_owner_a') where id = tests.fx('job_m')$$);
select tests.eq((select created_by from public.jobs where id = tests.fx('job_m')), tests.fx('u_manager_a'), 'created_by immutable');
-- automation markers are server-maintained
select tests.lives($$update public.jobs set reminder_sent_at = now(), review_requested_at = now() where id = tests.fx('job_m')$$);
select tests.ok((select reminder_sent_at is null and review_requested_at is null from public.jobs where id = tests.fx('job_m')),
                'clients cannot forge automation markers');
select tests.as_service();
select tests.lives($$update public.jobs set reminder_sent_at = '2025-06-02 12:00Z' where id = tests.fx('job_m')$$);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set reminder_sent_at = null where id = tests.fx('job_m')$$);
select tests.eq((select reminder_sent_at from public.jobs where id = tests.fx('job_m')), '2025-06-02 12:00Z'::timestamptz,
                'clients cannot clear automation markers set by the server');
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, reminder_sent_at) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', now())
  returning tests.fx_set('job_marker', id);
select tests.ok((select reminder_sent_at is not null from public.jobs where id = tests.fx('job_marker')), 'trusted code may set markers on insert');
delete from public.jobs where id = tests.fx('job_marker');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, reminder_sent_at) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', now())
  returning tests.fx_set('job_marker2', id);
select tests.ok((select reminder_sent_at is null from public.jobs where id = tests.fx('job_marker2')), 'clients cannot set markers on insert');
delete from public.jobs where id = tests.fx('job_marker2');
-- numbers are unique per shop even after deletes (no reuse)
select tests.lives($$delete from public.jobs where id = tests.fx('job_m')$$, 'manager deletes a job');
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')
  returning tests.fx_set('job_r', id);
select tests.eq((select number from public.jobs where id = tests.fx('job_r')), 1006::bigint, 'deleted numbers are never reused (1003-1005 were deleted)');
select tests.as_superuser();
select tests.lives($$update public.jobs set number = 1001 where id = tests.fx('job_r')$$);
select tests.eq((select number from public.jobs where id = tests.fx('job_r')), 1006::bigint, 'numbers are immutable even for trusted code');
select tests.eq((select count(distinct number) = count(*) from public.jobs where shop_id = tests.fx('shop_a')), true, 'numbers unique per shop');

-- ------------------------------------------------------------ schedule / integrity constraints
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-03 16:00Z', '2025-06-03 15:00Z')$$, '23514', 'end after start');
select tests.throws($$insert into public.jobs (shop_id, customer_id, scheduled_start) values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-03 16:00Z')$$,
                    '23514', 'start and end come together');
select tests.throws($$insert into public.jobs (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, '23514',
                    'scheduled jobs need a time');
select tests.throws($$insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', '2025-06-03 15:00Z', '2025-07-15 15:00Z')$$, '23514',
                    'jobs longer than 31 days rejected');
select tests.throws($$insert into public.jobs (shop_id, customer_id, status, deposit_required_cents)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', -1)$$, '23514', 'non-negative deposit');
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, vehicle_id, status)
                           values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a2'), 'requested')$$, '23514',
                         '%does not belong%', 'job vehicle must belong to the job customer');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('job_a')$$, '23514',
                         '%does not belong%', 'changing the customer re-validates the vehicle');
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                   'customer and vehicle can change together');
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('job_a')$$);
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a2'), 'X', 1)$$, '23514',
                         '%does not belong%', 'line item vehicle must belong to the job customer');
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'Interior', 1000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('job_a')$$,
                         '23514', '%line items reference vehicles%', 'customer change blocked while lines reference old vehicles');
-- service name default on line items
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('svc_a'), 100)
  returning tests.fx_set('line_named', id);
select tests.eq((select name from public.job_line_items where id = tests.fx('line_named')), 'Full Detail', 'line name defaults to the service name');

-- ------------------------------------------------------------ composite-FK injection
select tests.throws($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_b'), 'requested')$$,
                    '23503', 'job cannot reference another shop''s customer');
select tests.throws($$update public.jobs set vehicle_id = tests.fx('veh_b') where id = tests.fx('job_a')$$, '23503',
                    'job cannot reference another shop''s vehicle');
select tests.throws($$update public.jobs set resource_id = tests.fx('res_b') where id = tests.fx('job_a')$$, '23503',
                    'job cannot reference another shop''s resource');
select tests.throws($$update public.jobs set coupon_id = tests.fx('coupon_b') where id = tests.fx('job_a')$$, '23503',
                    'job cannot reference another shop''s coupon');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_b'), 'X', 1)$$,
                    '23503', 'line item cannot attach to another shop''s job');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('svc_b'), 'X', 1)$$, '23503',
                    'line item cannot reference another shop''s service');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_b'), 'X', 1)$$, '23503',
                    'line item cannot reference another shop''s vehicle');
select tests.throws($$update public.job_line_items set job_id = tests.fx('job_b') where id = tests.fx('line_a')$$, '23503',
                    'line item cannot be moved to another shop''s job');
select tests.throws($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_tech_b'))$$,
                    '23503', 'cannot assign another shop''s member');
select tests.throws($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_b'), tests.fx('m_tech_a'))$$,
                    '23503', 'cannot assign to another shop''s job');
select tests.throws($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('m_tech_b'))$$,
                    '42501', 'manager of A cannot write B''s assignments');
select tests.throws($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_b'), tests.fx('cust_b'), 'requested')$$,
                    '42501', 'manager of A cannot create jobs in B');
select tests.throws($$update public.jobs set shop_id = tests.fx('shop_b') where id = tests.fx('job_a')$$, '42501', 'jobs cannot move shops');

-- ------------------------------------------------------------ manager+ isolation
select tests.eq(tests.row_count($$select id from public.jobs where shop_id = tests.fx('shop_b')$$), 0::bigint, 'cannot read B''s jobs');
select tests.eq(tests.row_count($$update public.jobs set notes = 'x' where id = tests.fx('job_b')$$), 0::bigint, 'cannot update B''s jobs');
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_b')$$), 0::bigint, 'cannot delete B''s jobs');
select tests.eq(tests.row_count($$select * from public.job_line_items where shop_id = tests.fx('shop_b')$$), 0::bigint, 'cannot read B''s lines');
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 1 where id = tests.fx('line_b')$$), 0::bigint,
                'cannot update B''s lines');
select tests.eq(tests.row_count($$delete from public.job_line_items where id = tests.fx('line_b')$$), 0::bigint, 'cannot delete B''s lines');
select tests.eq(tests.row_count($$select * from public.job_assignments where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'cannot read B''s assignments');
select tests.eq(tests.row_count($$delete from public.job_assignments where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'cannot delete B''s assignments');

-- assignments
select tests.lives($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_manager_a'))$$,
                   'manager assigns staff');
select tests.throws($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_manager_a'))$$,
                    '23505', 'no duplicate assignments');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_tech2_a'))$$,
                         '23514', '%active%', 'inactive members cannot be assigned');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech2_a');

-- ------------------------------------------------------------ technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(id) from public.jobs), array[tests.fx('job_a')], 'technician reads only assigned jobs');
select tests.eq(tests.row_count('select * from public.job_line_items'), 3::bigint, 'technician reads lines of assigned jobs');
select tests.eq(tests.row_count('select * from public.job_assignments'), 2::bigint, 'technician sees co-assignees on own jobs');
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'x' where id = tests.fx('job_a2')$$), 0::bigint,
                'technician cannot update unassigned jobs');
select tests.lives($$update public.jobs set internal_notes = 'Scratch on rear bumper' where id = tests.fx('job_a')$$,
                   'technician updates internal notes on an assigned job');
select tests.lives($$update public.jobs set status = 'en_route' where id = tests.fx('job_a')$$, 'technician progresses status');
select tests.throws_like($$update public.jobs set notes = 'changed' where id = tests.fx('job_a')$$, '42501', '%only update the status%',
                         'technician cannot change customer-visible notes');
select tests.throws_like($$update public.jobs set scheduled_end = scheduled_end + interval '1 hour' where id = tests.fx('job_a')$$, '42501',
                         '%only update the status%', 'technician cannot reschedule');
select tests.throws_like($$update public.jobs set deposit_required_cents = 500 where id = tests.fx('job_a')$$, '42501',
                         '%only update the status%', 'technician cannot touch money fields');
select tests.throws_like($$update public.jobs set discount_kind = 'fixed', discount_value = 100 where id = tests.fx('job_a')$$, '42501',
                         '%only update the status%', 'technician cannot discount');
select tests.throws_like($$update public.jobs set status = 'cancelled', cancel_reason = 'nope' where id = tests.fx('job_a')$$, '42501',
                         '%only update the status%', 'technician cannot set cancel_reason');
select tests.throws($$insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')$$,
                    '42501', 'technician cannot create jobs');
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a')$$), 0::bigint, 'technician cannot delete jobs');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a'), 'Free', 0)$$,
                    '42501', 'technician cannot add line items');
select tests.eq(tests.row_count($$update public.job_line_items set unit_price_cents = 0 where job_id = tests.fx('job_a')$$), 0::bigint,
                'technician cannot change prices');
select tests.eq(tests.row_count($$delete from public.job_line_items where job_id = tests.fx('job_a')$$), 0::bigint,
                'technician cannot delete line items');
select tests.throws($$insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('m_tech_a'))$$,
                    '42501', 'technician cannot self-assign');
select tests.eq(tests.row_count($$delete from public.job_assignments where member_id = tests.fx('m_tech_a')$$), 0::bigint,
                'technician cannot unassign');
select tests.as_superuser();
select tests.eq((select internal_notes || '|' || status from public.jobs where id = tests.fx('job_a')), 'Scratch on rear bumper|en_route',
                'technician changes persisted');

select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq((select array_agg(id) from public.jobs), array[tests.fx('job_b')], 'tech B sees only B''s assigned job');
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'x' where id = tests.fx('job_a')$$), 0::bigint,
                'tech B cannot update A''s jobs');

select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count('select id from public.jobs'), 0::bigint, 'outsider sees no jobs');
select tests.eq(tests.row_count('select * from public.job_line_items'), 0::bigint, 'outsider sees no line items');
select tests.eq(tests.row_count('select * from public.job_assignments'), 0::bigint, 'outsider sees no assignments');

-- ------------------------------------------------------------ deletes cascade / restrict
-- a manager deleting a vehicle used by a job: the FK's SET NULL runs even
-- though the job row is updated on the manager's behalf
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'Spare')
  returning tests.fx_set('veh_spare', id);
update public.jobs set vehicle_id = tests.fx('veh_spare') where id = tests.fx('job_a2');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$delete from public.vehicles where id = tests.fx('veh_spare')$$, 'manager deletes a vehicle that is on a job');
select tests.ok((select vehicle_id is null from public.jobs where id = tests.fx('job_a2')), 'job vehicle cleared by the FK');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$delete from public.jobs where id = tests.fx('job_a2')$$, 'owner deletes a job');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_assignments where job_id = tests.fx('job_a2')), 0::bigint, 'assignments cascade');
select tests.lives($$delete from public.vehicles where id = tests.fx('veh_a')$$, 'vehicle delete');
select tests.ok((select vehicle_id is null and shop_id = tests.fx('shop_a') from public.jobs where id = tests.fx('job_a')),
                'job keeps its shop, loses the deleted vehicle');
select tests.ok((select bool_and(vehicle_id is null) from public.job_line_items where job_id = tests.fx('job_a')),
                'line items lose the deleted vehicle');
select tests.lives($$delete from public.services where id = tests.fx('svc_a')$$, 'service delete');
select tests.ok((select bool_and(service_id is null) from public.job_line_items where job_id = tests.fx('job_a')),
                'line items keep their snapshot but lose the deleted service link');
select tests.eq((select subtotal_cents from public.jobs where id = tests.fx('job_a')), 21100::bigint, 'totals unchanged by catalog deletes');

-- ------------------------------------------------------------ reference table
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok((select count(*) > 20 from public.job_status_transitions), 'staff can read the transition table');
select tests.throws($$insert into public.job_status_transitions values ('completed', 'requested', 'backward', false)$$, '42501',
                    'transition table is read-only');
select tests.throws($$delete from public.job_status_transitions$$, '42501', 'transition table cannot be emptied');
