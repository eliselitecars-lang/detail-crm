-- 110 comms (0113): the members assigned to a job are told when it is
-- cancelled or marked a no-show before it ended — by staff (every assigned
-- member but the one who did it) or by the customer online (the assigned
-- technicians; managers get public_cancel_booking's own notification).
-- Kind 'general' (every member may read it, so it is pushed too).
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.jobs set scheduled_start = now() + interval '1 day', scheduled_end = now() + interval '1 day 2 hours', status = 'scheduled'
 where id in (tests.fx('job_a'), tests.fx('job_a2'));
-- job_a: tech_a and the manager; job_a2: tech2_a
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_manager_a'));
create function pg_temp.notes(p_user uuid, p_job uuid) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and job_id = p_job and kind = 'general'
$$;
create function pg_temp.job_no(p_job uuid) returns text language sql as $$
  select number::text from public.jobs where id = p_job
$$;
delete from public.notifications where shop_id = tests.fx('shop_a');

-- ============================================================ a staff cancellation
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled', cancel_reason = 'Customer called' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.notes(tests.fx('u_tech_a'), tests.fx('job_a')), 1::bigint, 'the assigned technician is told');
select tests.eq(pg_temp.notes(tests.fx('u_manager_a'), tests.fx('job_a')), 0::bigint, 'not the manager who cancelled it');
select tests.eq(pg_temp.notes(tests.fx('u_tech2_a'), tests.fx('job_a')), 0::bigint, 'nor a technician not on the job');
select tests.ok((select title = 'Job #' || pg_temp.job_no(tests.fx('job_a')) || ' cancelled'
                        and body like 'Was %' and body like '%Full Detail%'
                        and body not like '%Customer called%' and body not like '%$%'
                   from public.notifications where user_id = tests.fx('u_tech_a') and job_id = tests.fx('job_a')),
                'titled with the job number; the slot it had and its services (no reason, no money)');
select tests.ok(public.user_can_read_notification(tests.fx('u_tech_a'), tests.fx('shop_a'), 'general'),
                'a kind the technician may read (and so is pushed)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.notifications where job_id = tests.fx('job_a')), 1::bigint,
                'the technician sees it in their bell');

-- reopening and cancelling again tells them again; a completed job's status change does not
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('job_a');
update public.jobs set status = 'no_show' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.ok((select count(*) = 1 from public.notifications
                  where user_id = tests.fx('u_manager_a') and job_id = tests.fx('job_a')
                    and title = 'Job #' || pg_temp.job_no(tests.fx('job_a')) || ' marked no-show'),
                'a no-show marked by the owner tells the assigned manager');
select tests.eq(pg_temp.notes(tests.fx('u_tech_a'), tests.fx('job_a')), 2::bigint, 'and the technician');
select tests.eq((select count(*) from public.notifications where user_id = tests.fx('u_owner_a') and job_id = tests.fx('job_a')),
                0::bigint, 'the owner who did it (not assigned) hears nothing');

-- ============================================================ the customer cancels online
select tests.fx_set('tok2', (select public_token from public.jobs where id = tests.fx('job_a2')));
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('m_manager_a'));
select tests.as_anon();
select public.public_cancel_booking(tests.fx('tok2'), 'moving away') is not null;
select tests.as_superuser();
select tests.eq(pg_temp.notes(tests.fx('u_tech2_a'), tests.fx('job_a2')), 1::bigint, 'the assigned technician is told');
select tests.eq(pg_temp.notes(tests.fx('u_manager_a'), tests.fx('job_a2')), 0::bigint,
                'an assigned manager gets only the booking_cancelled notice (no duplicate)');
select tests.eq((select count(*) from public.notifications where user_id = tests.fx('u_manager_a') and job_id = tests.fx('job_a2')
                    and kind = 'booking_cancelled'), 1::bigint, 'which it does get');

-- ============================================================ nothing for jobs that already ended, or other shops
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), now() - interval '3 days', now() - interval '3 days' + interval '1 hour')
  returning tests.fx_set('job_old', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_old'), tests.fx('m_tech_a'));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled' where id = tests.fx('job_old');
select tests.as_superuser();
select tests.eq(pg_temp.notes(tests.fx('u_tech_a'), tests.fx('job_old')), 0::bigint, 'tidying up a past job tells nobody');
update public.jobs set scheduled_start = now() + interval '2 days', scheduled_end = now() + interval '2 days 1 hour', status = 'scheduled'
 where id = tests.fx('job_b');
select tests.authenticate_as(tests.fx('u_owner_b'));
update public.jobs set status = 'cancelled' where id = tests.fx('job_b');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where job_id = tests.fx('job_b') and user_id = tests.fx('u_tech_b')), 1::bigint,
                'shop B''s technician is told about shop B''s job');
select tests.eq((select count(*) from public.notifications where job_id = tests.fx('job_b') and shop_id <> tests.fx('shop_b')), 0::bigint,
                'and nobody outside shop B');
select tests.ok(not has_function_privilege('authenticated', 'public.jobs_comms_notify_cancelled()', 'execute'),
                'the trigger function is internal');
