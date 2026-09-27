-- 00 foundation: job status machine — every (from, to) pair for managers and
-- assigned technicians, server-context behaviour, timestamps, cancel reason.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ exhaustive edge matrix
do $$
declare
  f        public.job_status;
  t        public.job_status;
  v_job    uuid;
  v_ok     boolean;
  v_state  text;
  v_edge   public.job_status_transitions;
  v_expect boolean;
  v_role   text;
begin
  foreach v_role in array array['manager', 'technician', 'admin', 'owner'] loop
    foreach f in array enum_range(null::public.job_status) loop
      foreach t in array enum_range(null::public.job_status) loop
        continue when f = t;
        perform tests.as_superuser();
        insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
        values (tests.fx('shop_a'), tests.fx('cust_a'), f, '2025-06-10 15:00Z', '2025-06-10 16:00Z')
        returning id into v_job;
        insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), v_job, tests.fx('m_tech_a'));
        select * into v_edge from public.job_status_transitions where from_status = f and to_status = t;
        v_expect := case v_role
                      when 'technician' then coalesce(v_edge.technician_allowed, false)
                      else v_edge.from_status is not null
                    end;
        perform tests.authenticate_as(tests.fx(case v_role
                                                 when 'manager' then 'u_manager_a'
                                                 when 'admin' then 'u_admin_a'
                                                 when 'owner' then 'u_owner_a'
                                                 else 'u_tech_a' end));
        begin
          update public.jobs set status = t where id = v_job;
          v_ok := true;
          v_state := null;
        exception when others then
          v_ok := false;
          get stacked diagnostics v_state = returned_sqlstate;
        end;
        perform tests.eq(v_ok, v_expect, format('%s: %s -> %s allowed=%s', v_role, f, t, v_expect));
        if not v_ok then
          -- not an edge at all -> 23514; an edge the role may not take -> 42501
          perform tests.eq(v_state, case when v_edge.from_status is null then '23514' else '42501' end,
                           format('%s: %s -> %s error class', v_role, f, t));
        end if;
      end loop;
    end loop;
  end loop;
  perform tests.as_superuser();
end
$$;

-- the transition table itself: backward edges are never technician edges
select tests.eq((select count(*) from public.job_status_transitions where direction = 'backward' and technician_allowed), 0::bigint,
                'no backward technician edges');
select tests.eq((select array_agg(from_status::text || '>' || to_status::text order by from_status, to_status)
                   from public.job_status_transitions where technician_allowed),
                array['scheduled>en_route', 'scheduled>in_progress', 'confirmed>en_route', 'confirmed>in_progress',
                      'en_route>in_progress', 'in_progress>completed'],
                'technician edges: scheduled/confirmed -> en_route -> in_progress -> completed');
select tests.eq((select count(*) from public.job_status_transitions where from_status = 'completed' and direction = 'forward'), 0::bigint,
                'completed is terminal going forward');

-- ------------------------------------------------------------ unassigned technician
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$update public.jobs set status = 'en_route' where id = tests.fx('job_a')$$), 0::bigint,
                'technician cannot move a job they are not assigned to');

-- ------------------------------------------------------------ timestamps
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select confirmed_at is null and en_route_at is null and started_at is null and completed_at is null and cancelled_at is null
                 from public.jobs where id = tests.fx('job_a')), 'scheduled job has no stamps');
update public.jobs set status = 'confirmed' where id = tests.fx('job_a');
select tests.eq((select confirmed_at from public.jobs where id = tests.fx('job_a')), now(), 'confirmed_at stamped');
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'en_route' where id = tests.fx('job_a');
select tests.eq((select en_route_at from public.jobs where id = tests.fx('job_a')), now(), 'en_route_at stamped (technician)');
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
select tests.eq((select started_at from public.jobs where id = tests.fx('job_a')), now(), 'started_at stamped (technician)');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.eq((select completed_at from public.jobs where id = tests.fx('job_a')), now(), 'completed_at stamped (technician)');
select tests.throws($$update public.jobs set status = 'in_progress' where id = tests.fx('job_a')$$, '42501', 'technician cannot reopen');

-- backward moves keep earlier stamps (not re-stamped) and clear later ones
select tests.as_superuser();
update public.jobs set confirmed_at = '2020-01-01 00:00Z', en_route_at = '2020-01-02 00:00Z', started_at = '2020-01-03 00:00Z'
 where id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
select tests.ok((select completed_at is null and started_at = '2020-01-03 00:00Z' and en_route_at = '2020-01-02 00:00Z'
                 from public.jobs where id = tests.fx('job_a')), 'completed -> in_progress clears completed_at, keeps earlier stamps');
update public.jobs set status = 'scheduled' where id = tests.fx('job_a');
select tests.ok((select confirmed_at is null and en_route_at is null and started_at is null and completed_at is null
                 from public.jobs where id = tests.fx('job_a')), 'in_progress -> scheduled clears all later stamps');
update public.jobs set status = 'confirmed' where id = tests.fx('job_a');
select tests.eq((select confirmed_at from public.jobs where id = tests.fx('job_a')), now(), 'forward into confirmed re-stamps');

-- clients cannot forge stamps
update public.jobs set confirmed_at = '1999-01-01', completed_at = '1999-01-01', cancelled_at = '1999-01-01' where id = tests.fx('job_a');
select tests.ok((select confirmed_at = now() and completed_at is null and cancelled_at is null from public.jobs where id = tests.fx('job_a')),
                'client-sent timestamps are ignored');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, confirmed_at, started_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-05-01 15:00Z', '2025-05-01 16:00Z', '1999-01-01', '1999-01-01')
  returning tests.fx_set('job_hist', id);
select tests.ok((select completed_at = now() and confirmed_at is null and started_at is null from public.jobs where id = tests.fx('job_hist')),
                'insert stamps only the initial status');

-- ------------------------------------------------------------ cancellation
update public.jobs set status = 'cancelled', cancel_reason = '   ' where id = tests.fx('job_a');
select tests.ok((select cancelled_at = now() and cancel_reason is null from public.jobs where id = tests.fx('job_a')),
                'cancel_reason is optional; blank becomes null');
select tests.ok((select confirmed_at is not null from public.jobs where id = tests.fx('job_a')), 'cancelling keeps earlier stamps');
update public.jobs set cancel_reason = '  Rain  ' where id = tests.fx('job_a');
select tests.eq((select cancel_reason from public.jobs where id = tests.fx('job_a')), 'Rain', 'reason editable (trimmed) while cancelled');
update public.jobs set status = 'scheduled' where id = tests.fx('job_a');
select tests.ok((select cancelled_at is null and cancel_reason is null and confirmed_at is null from public.jobs where id = tests.fx('job_a')),
                'reinstating clears cancellation and later stamps');
update public.jobs set cancel_reason = 'not cancelled' where id = tests.fx('job_a');
select tests.ok((select cancel_reason is null from public.jobs where id = tests.fx('job_a')), 'cancel_reason ignored unless cancelled');
update public.jobs set status = 'cancelled', cancel_reason = 'Customer rescheduled' where id = tests.fx('job_a');
select tests.eq((select cancel_reason from public.jobs where id = tests.fx('job_a')), 'Customer rescheduled', 'reason stored on cancel');
insert into public.jobs (shop_id, customer_id, status, cancel_reason) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', 'x')
  returning tests.fx_set('job_req', id);
select tests.ok((select cancel_reason is null from public.jobs where id = tests.fx('job_req')), 'no cancel_reason on non-cancelled insert');
select tests.throws($$update public.jobs set status = 'scheduled' where id = tests.fx('job_req')$$, '23514',
                    'a requested job needs a time before it is scheduled');
select tests.lives($$update public.jobs set status = 'cancelled' where id = tests.fx('job_req')$$, 'a requested job can be cancelled without a time');

-- ------------------------------------------------------------ trusted (server) context
select tests.as_service();
select tests.lives($$update public.jobs set status = 'requested' where id = tests.fx('job_req')$$,
                   'service_role follows backward edges without a staff role');
select tests.throws($$update public.jobs set status = 'completed' where id = tests.fx('job_req')$$, '23514',
                    'service_role still cannot jump along a non-edge');
select tests.as_superuser();
select tests.throws($$update public.jobs set status = 'requested' where id = tests.fx('job_hist')$$, '23514',
                    'even the superuser respects the transition table');
