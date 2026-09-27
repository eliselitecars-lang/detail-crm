-- 90 integration: reorder_job_line_items — one atomic reorder of a job's
-- lines (manager+): the list must be exactly the job's lines, only changed
-- rows are written, role matrix and cross-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.job_line_items set sort = 0 where id = tests.fx('line_a');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('job_a'), 'Wax', 5000, 1) returning tests.fx_set('l2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('job_a'), 'Tire shine', 1500, 2) returning tests.fx_set('l3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Other job line', 1000) returning tests.fx_set('l_other', id);

create function pg_temp.order_of(p_job uuid) returns text language sql as $$
  select string_agg(name || ':' || sort, ', ' order by sort, name) from public.job_line_items where job_id = p_job
$$;
grant execute on function pg_temp.order_of(uuid) to authenticated;
create temp table totals_before as select total_cents from public.jobs where id = tests.fx('job_a');
grant select on totals_before to authenticated;

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), tests.fx('line_a'), tests.fx('l2')])$$,
                   'a manager reorders the job''s lines');
select tests.eq(pg_temp.order_of(tests.fx('job_a')), 'Tire shine:0, Full Detail:1, Wax:2', 'sort = position (0-based)');
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_a')), (select total_cents from totals_before),
                'totals are unchanged by a reorder');
-- only rows whose position changes are written
select tests.as_superuser();
create temp table written (name text);
grant insert, select on written to authenticated;
create function pg_temp.log_write() returns trigger language plpgsql as $$
begin
  insert into pg_temp.written values (new.name);
  return null;
end
$$;
create trigger zz_log_write after update on public.job_line_items for each row execute function pg_temp.log_write();
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), tests.fx('l2'), tests.fx('line_a')]);
select tests.eq((select string_agg(name, ',' order by name) from written), 'Full Detail,Wax',
                'the line that kept its place was not rewritten');
select tests.as_superuser();
drop trigger zz_log_write on public.job_line_items;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.order_of(tests.fx('job_a')), 'Tire shine:0, Wax:1, Full Detail:2', 'new order');

-- ------------------------------------------------------------ the list must be exactly the job's lines
select tests.throws_like($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), tests.fx('l2')])$$, '22023',
                         'the list must contain each line of this job exactly once', 'a missing line');
select tests.throws_like($$select public.reorder_job_line_items(tests.fx('job_a'),
                           array[tests.fx('l3'), tests.fx('l2'), tests.fx('line_a'), tests.fx('l2')])$$, '22023',
                         '%exactly once%', 'a duplicate');
select tests.throws_like($$select public.reorder_job_line_items(tests.fx('job_a'),
                           array[tests.fx('l3'), tests.fx('l2'), tests.fx('l_other')])$$, '22023', '%exactly once%',
                         'another job''s line');
select tests.throws_like($$select public.reorder_job_line_items(tests.fx('job_a'),
                           array[tests.fx('l3'), tests.fx('l2'), tests.fx('line_a'), tests.fx('line_b')])$$, '22023', '%exactly once%',
                         'another shop''s line');
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), null, tests.fx('line_a')])$$, '22023',
                    'nulls');
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_a'), null)$$, '22023', 'a null list');
select tests.eq(pg_temp.order_of(tests.fx('job_a')), 'Tire shine:0, Wax:1, Full Detail:2', 'refused calls changed nothing');
-- a job without lines takes an empty list
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_empty', id);
select tests.lives($$select public.reorder_job_line_items(tests.fx('job_empty'), '{}')$$, 'an empty job, an empty list');
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_empty'), array[tests.fx('l2')])$$, '22023',
                    'and nothing else');

-- ------------------------------------------------------------ roles and isolation
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('line_a'), tests.fx('l2'), tests.fx('l3')])$$,
                   'owners');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('line_a'), tests.fx('l2'), tests.fx('l3')])$$,
                   'admins');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), tests.fx('l2'), tests.fx('line_a')])$$,
                    '42501', 'technicians cannot, even on their assigned job');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_a'), array[tests.fx('l3'), tests.fx('l2'), tests.fx('line_a')])$$,
                    'P0002', 'another shop''s job is not found');
select tests.throws($$select public.reorder_job_line_items(gen_random_uuid(), '{}')$$, 'P0002', 'unknown job');
select tests.as_anon();
select tests.throws($$select public.reorder_job_line_items(tests.fx('job_a'), '{}')$$, '42501', 'anon cannot execute');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.order_of(tests.fx('job_a')), 'Full Detail:0, Wax:1, Tire shine:2', 'denied calls changed nothing');
select tests.eq(pg_temp.order_of(tests.fx('job_a2')), 'Other job line:0', 'other jobs untouched');
