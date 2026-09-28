-- 50 sched: recurring series integrity (0051) —
--   * membership usage limits: every occurrence is priced at its own start,
--     so a limited plan makes exactly its included uses per billing period
--     free (the free line names the membership) and the other visits are
--     charged at the catalog price — at creation, after a "this and
--     following" edit (notes only and a rule change) and for a use another
--     job already took; unlimited plans stay free; a service listed twice
--     is included once per visit;
--   * an occurrence given to another customer is never deleted / recreated
--     by a series edit (the API change detaches it; a trusted change that
--     does not detach is still ineligible);
--   * an occurrence holding field records (signed form, inspection, photo,
--     ticked checklist item, time entry, document) is kept by edits and by
--     end_job_series, while an occurrence with only an unsigned form is
--     updated in place (same job, its form kept);
--   * address / location and notes edits detach an occurrence;
--   * roles and shops: technicians and the other shop's manager cannot edit.
\ir fixtures/two_shops.psql
\ir fixtures/50_ranges.psql

select tests.as_superuser();
create function pg_temp.occ(p_series uuid, p_seq integer) returns uuid language sql stable as $$
  select id from public.jobs where series_id = p_series and series_seq = p_seq
$$;
create function pg_temp.local_today() returns date language sql stable as $$
  select (now() at time zone 'America/Chicago')::date
$$;
create function pg_temp.weekly(p_customer uuid, p_vehicle uuid, p_start date, p_extra jsonb default '{}')
returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object('customer_id', p_customer, 'vehicle_id', p_vehicle, 'freq', 'week',
                            'local_start', '09:00', 'start_date', p_start::text,
                            'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'))))) || p_extra
$$;
-- free lines of a series' occurrences starting in [p_from, p_to)
create function pg_temp.free_lines(p_series uuid, p_from timestamptz, p_to timestamptz) returns bigint
language sql stable as $$
  select count(*) from public.jobs j join public.job_line_items li on li.job_id = j.id
   where j.series_id = p_series and j.scheduled_start >= p_from and j.scheduled_start < p_to
     and li.unit_price_cents = 0
$$;
create function pg_temp.lines(p_series uuid, p_from timestamptz, p_to timestamptz) returns bigint
language sql stable as $$
  select count(*) from public.jobs j join public.job_line_items li on li.job_id = j.id
   where j.series_id = p_series and j.scheduled_start >= p_from and j.scheduled_start < p_to
$$;
grant execute on function pg_temp.occ(uuid, integer), pg_temp.local_today(), pg_temp.weekly(uuid, uuid, date, jsonb),
                          pg_temp.free_lines(uuid, timestamptz, timestamptz), pg_temp.lines(uuid, timestamptz, timestamptz)
  to authenticated, service_role;

-- ============================================================ membership usage limits (money 0061 / 0069)
\if :has_money
-- a 1-visit-per-month plan whose current period ends in 25 days
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period)
  values (tests.fx('shop_a'), 'Detail club', 4000, 'month', 1, array[tests.fx('svc_a')], 1)
  returning tests.fx_set('plan1', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan1'), tests.fx('cust_a'), 'active', now() + interval '25 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem1', id);

-- ============================================================ usage limit at creation (weekly, starts tomorrow)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser1', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(tests.fx('cust_a'), tests.fx('veh_a'), pg_temp.local_today() + 1)) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.eq(pg_temp.lines(tests.fx('ser1'), now(), now() + interval '25 days'), 4::bigint,
                'four weekly visits fall in the current billing period');
select tests.eq(pg_temp.free_lines(tests.fx('ser1'), now(), now() + interval '25 days'), 1::bigint,
                'a 1-visit-per-month plan: one free weekly occurrence per period, the rest charged');
select tests.eq((select li.membership_id from public.jobs j join public.job_line_items li on li.job_id = j.id
                  where j.series_id = tests.fx('ser1') and li.unit_price_cents = 0
                    and j.scheduled_start < now() + interval '25 days'),
                tests.fx('mem1'), 'the free visit names the membership (the line trigger counted the use)');
select tests.eq((select series_seq from public.jobs j join public.job_line_items li on li.job_id = j.id
                  where j.series_id = tests.fx('ser1') and li.unit_price_cents = 0
                    and j.scheduled_start < now() + interval '25 days'),
                1, '... and it is the first visit of the period');
select tests.ok((select bool_and(li.unit_price_cents = 20000 and li.membership_id is null)
                   from public.jobs j join public.job_line_items li on li.job_id = j.id
                  where j.series_id = tests.fx('ser1') and j.scheduled_start < now() + interval '25 days'
                    and j.series_seq > 1),
                'visits 2-4 are charged at the catalog price, with no membership');
select tests.ok((select bool_and(j.total_cents > 0) from public.jobs j
                  where j.series_id = tests.fx('ser1') and j.scheduled_start < now() + interval '25 days'
                    and j.series_seq > 1), 'the charged visits have a total to collect');
-- every later billing period gets exactly one free visit too
select tests.eq((select count(*) from (
                   select public.membership_period_bounds(tests.fx('mem1'), j.scheduled_start) as p,
                          count(*) filter (where li.unit_price_cents = 0) as free_n,
                          count(*) filter (where li.unit_price_cents = 0 and li.membership_id = tests.fx('mem1')) as named_n
                     from public.jobs j join public.job_line_items li on li.job_id = j.id
                    where j.series_id = tests.fx('ser1')
                    group by 1) x
                  where x.free_n <> 1 or x.named_n <> 1), 0::bigint,
                'every billing period the series covers has exactly one free visit, naming the membership');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = tests.fx('ser1') and li.unit_price_cents = 0 and li.membership_id is null),
                0::bigint, 'no free line without a membership anywhere in the series');
select tests.eq(public.membership_uses_in_period(tests.fx('mem1'), now()), 1,
                'the membership counts one use in the current period');

-- ============================================================ a notes-only edit keeps the limit
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((public.update_job_series(tests.fx('ser1'), '{"notes": "gate code 1234"}', pg_temp.occ(tests.fx('ser1'), 1))
                 ->> 'changed')::integer > 0, 'the edit updated the eligible occurrences in place');
select tests.as_superuser();
select tests.eq(pg_temp.free_lines(tests.fx('ser1'), now(), now() + interval '25 days'), 1::bigint,
                'after a series edit still one free visit in the period');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = tests.fx('ser1') and li.unit_price_cents = 0 and li.membership_id is null),
                0::bigint, 'after the edit no free line without a membership');
select tests.ok((select bool_and(notes = 'gate code 1234') from public.jobs where series_id = tests.fx('ser1')),
                'the updated occurrences carry the new notes');

-- ============================================================ a rule change (weekly -> twice a week) keeps the limit
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser1'),
                       jsonb_build_object('by_weekday', jsonb_build_array(
                         extract(dow from pg_temp.local_today() + 1)::integer,
                         (extract(dow from pg_temp.local_today() + 1)::integer + 3) % 7)),
                       pg_temp.occ(tests.fx('ser1'), 1))$$, 'twice a week from the first visit');
select tests.as_superuser();
select tests.ok(pg_temp.lines(tests.fx('ser1'), now(), now() + interval '25 days') >= 7,
                'twice a week: at least seven visits in the period');
select tests.eq(pg_temp.free_lines(tests.fx('ser1'), now(), now() + interval '25 days'), 1::bigint,
                'a rule change still leaves one free visit in the period');

-- ============================================================ a use another job already took
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan1'), tests.fx('cust_a2'), 'active', now() + interval '25 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem2', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 'scheduled', now() + interval '2 days', now() + interval '2 days 2 hours')
  returning tests.fx_set('other_job', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('other_job'), tests.fx('svc_a'), 'Full Detail', 0);
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('other_job')), tests.fx('mem2'),
                'a free staff job took the period''s use');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser2', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(tests.fx('cust_a2'), null, pg_temp.local_today() + 3)) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.eq(pg_temp.free_lines(tests.fx('ser2'), now(), now() + interval '25 days'), 0::bigint,
                'the period''s use is taken: every series visit in it is charged');
select tests.ok(pg_temp.free_lines(tests.fx('ser2'), now() + interval '25 days', now() + interval '56 days') >= 1,
                'the next period''s visit is free again');
select tests.eq(public.membership_uses_in_period(tests.fx('mem2'), now()), 1, 'still one use in the current period');
\endif

-- ============================================================ #2 an occurrence given to another customer
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(tests.fx('cust_a3'), null, pg_temp.local_today() + 7)) ->> 'series_id')::uuid);
select tests.fx_set('r_occ2', pg_temp.occ(tests.fx('ser3'), 2));
select tests.fx_set('r_occ3', pg_temp.occ(tests.fx('ser3'), 3));
select tests.fx_set('r_occ4', pg_temp.occ(tests.fx('ser3'), 4));
select tests.fx_set('r_occ5', pg_temp.occ(tests.fx('ser3'), 5));
update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('r_occ2');
select tests.ok((select customer_id = tests.fx('cust_a2') and series_detached from public.jobs where id = tests.fx('r_occ2')),
                'a staff customer change detaches the occurrence ("this job only")');
update public.jobs set service_address_line1 = '1 Main St', location_type = 'mobile' where id = tests.fx('r_occ4');
select tests.ok((select series_detached from public.jobs where id = tests.fx('r_occ4')),
                'a staff address / location change detaches the occurrence');
update public.jobs set notes = 'bring the ladder' where id = tests.fx('r_occ5');
select tests.ok((select series_detached from public.jobs where id = tests.fx('r_occ5')),
                'a notes change for this visit only detaches it too');
-- a trusted path (service_role) that moves the job without detaching it
select tests.as_service();
update public.jobs set customer_id = tests.fx('cust_a2') where id = tests.fx('r_occ3');
select tests.as_superuser();
select tests.ok((select customer_id = tests.fx('cust_a2') and not series_detached from public.jobs where id = tests.fx('r_occ3')),
                'a trusted customer change leaves the flag alone');
select tests.as_anon();
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser3'), '{"notes": "gate code 1234"}',
                                                     pg_temp.occ(tests.fx('ser3'), 1))$$, 'notes edit of the series');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('r_occ2') and customer_id = tests.fx('cust_a2')),
                'Aaron''s appointment is not deleted by an edit of Fleet Co''s series');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('r_occ3') and customer_id = tests.fx('cust_a2')),
                '... not even when the change did not detach it (another customer''s job is never eligible)');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('r_occ4') and service_address_line1 = '1 Main St'),
                'the occurrence with its own address is kept');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('r_occ5') and notes = 'bring the ladder'),
                'the visit''s own note survives a later series edit');
select tests.eq((select count(*) from public.jobs j where j.series_id = tests.fx('ser3')
                  and (j.scheduled_start at time zone 'America/Chicago')::date
                      = (select (scheduled_start at time zone 'America/Chicago')::date from public.jobs where id = tests.fx('r_occ2'))),
                1::bigint, 'the reassigned visit''s date gets no new occurrence for the series'' customer');
select tests.eq((select count(*) from public.jobs j where j.series_id = tests.fx('ser3') and not j.series_detached
                   and j.customer_id = tests.fx('cust_a3') and j.notes is distinct from 'gate code 1234'),
                0::bigint, 'every other occurrence was regenerated with the new notes');
-- ending the series keeps them too
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.end_job_series(tests.fx('ser3'), pg_temp.local_today())$$, 'end the series today');
select tests.as_superuser();
select tests.ok((select count(*) = 3 from public.jobs where id in (tests.fx('r_occ2'), tests.fx('r_occ3'), tests.fx('r_occ4'))),
                'ending the series keeps the reassigned and detached jobs');

-- ============================================================ #4 field records keep an occurrence
insert into public.form_templates (shop_id, name, body, requires_signature, attach_to)
  values (tests.fx('shop_a'), 'Waiver', 'I accept the terms.', false, 'all_jobs');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser4', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(tests.fx('cust_a'), tests.fx('veh_a'), pg_temp.local_today() + 7)) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.fx_set('f_occ2', pg_temp.occ(tests.fx('ser4'), 2));   -- signed form
select tests.fx_set('f_occ3', pg_temp.occ(tests.fx('ser4'), 3));   -- inspection
select tests.fx_set('f_occ4', pg_temp.occ(tests.fx('ser4'), 4));   -- photo
select tests.fx_set('f_occ5', pg_temp.occ(tests.fx('ser4'), 5));   -- ticked checklist item
select tests.fx_set('f_occ6', pg_temp.occ(tests.fx('ser4'), 6));   -- time entry
select tests.fx_set('f_occ7', pg_temp.occ(tests.fx('ser4'), 7));   -- document
select tests.fx_set('f_occ8', pg_temp.occ(tests.fx('ser4'), 8));   -- unsigned form only
select tests.fx_set('f_occ9', pg_temp.occ(tests.fx('ser4'), 9));   -- unticked checklist item
select tests.fx_set('form2', (select id from public.form_submissions where job_id = tests.fx('f_occ2')));
select public_token as ftok from public.form_submissions where id = tests.fx('form2') \gset
select tests.as_anon();
select public.public_sign_form(:'ftok'::uuid, 'Alice Anders');
select tests.as_superuser();
select tests.ok((select signed_at is not null from public.form_submissions where id = tests.fx('form2')), 'signed');
insert into public.inspections (shop_id, job_id, vehicle_id, kind)
  values (tests.fx('shop_a'), tests.fx('f_occ3'), tests.fx('veh_a'), 'pre');
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('f_occ4') || '/before.jpg', tests.fx('u_manager_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('f_occ4'), tests.fx('shop_a') || '/' || tests.fx('f_occ4') || '/before.jpg', 'before');
insert into public.job_checklist_items (shop_id, job_id, label, done_at)
  values (tests.fx('shop_a'), tests.fx('f_occ5'), 'Vacuum', now());
insert into public.job_checklist_items (shop_id, job_id, label)
  values (tests.fx('shop_a'), tests.fx('f_occ9'), 'Vacuum');
insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in, clock_out, source)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), tests.fx('f_occ6'), 'job', now() - interval '3 hours',
          now() - interval '2 hours', 'manual');
-- documents are ops' (0071): without the ops range occurrence 7 has none
\if :has_ops
insert into storage.objects (bucket_id, name, owner) values
  ('documents', tests.fx('shop_a') || '/jobs/' || tests.fx('f_occ7') || '/estimate.pdf', tests.fx('u_manager_a'));
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('f_occ7'),
          tests.fx('shop_a') || '/jobs/' || tests.fx('f_occ7') || '/estimate.pdf', 'estimate.pdf', 'application/pdf', 1000);
\endif
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser4'), '{"notes": "bring ladder"}',
                                                     pg_temp.occ(tests.fx('ser4'), 1))$$, 'notes edit of the series');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.form_submissions where id = tests.fx('form2')),
                'the customer''s signed waiver survives a series edit');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ2')), '... on its kept occurrence');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ3')), 'an occurrence with an inspection is kept');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ4')), 'an occurrence with a photo is kept');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ5')), 'an occurrence with a ticked checklist item is kept');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ6')), 'an occurrence with a time entry is kept');
\if :has_ops
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ7')), 'an occurrence with a document is kept');
\endif
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ8') and notes = 'bring ladder'),
                'an occurrence with only an unsigned form is updated in place');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('f_occ9') and notes = 'bring ladder'),
                'an occurrence with only unticked checklist items is updated in place');
select tests.eq((select count(*) from public.form_submissions f join public.jobs j on j.id = f.job_id
                  where j.series_id = tests.fx('ser4') and j.series_seq = 8), 1::bigint,
                'occurrence 8 keeps its (one) form');
select tests.eq((select count(*) - count(distinct (scheduled_start at time zone 'America/Chicago')::date)
                   from public.jobs where series_id = tests.fx('ser4')), 0::bigint, 'never two occurrences on one day');
-- ending and deleting the series keep them as well
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((public.delete_job_series(tests.fx('ser4')) ->> 'kept')::integer >= 5 + :'has_ops'::boolean::integer,
                'delete_job_series keeps them');
select tests.as_superuser();
select tests.ok((select bool_and(series_id is null) and count(*) = 5 + :'has_ops'::boolean::integer from public.jobs
                  where id in (tests.fx('f_occ2'), tests.fx('f_occ3'), tests.fx('f_occ4'), tests.fx('f_occ5'),
                               tests.fx('f_occ6'), tests.fx('f_occ7'))),
                'they stay as ordinary jobs');
select tests.ok(exists (select 1 from public.form_submissions where id = tests.fx('form2') and signed_at is not null),
                'the signed waiver is still there');

-- ============================================================ unlimited plans and a service listed twice
\if :has_money
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids)
  values (tests.fx('shop_a'), 'Unlimited club', 9000, 'month', 1, array[tests.fx('svc_a')])
  returning tests.fx_set('plan_u', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_u'), tests.fx('cust_a3'), 'active', now() + interval '25 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem_u', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_u', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(tests.fx('cust_a3'), null, pg_temp.local_today() + 1,
                         jsonb_build_object('template_lines', jsonb_build_array(
                           jsonb_build_object('service_id', tests.fx('svc_a')),
                           jsonb_build_object('service_id', tests.fx('svc_a')))))) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.ok((select bool_and(x.free_n = 1 and x.paid_n = 1) from (
                   select j.id, count(*) filter (where li.unit_price_cents = 0 and li.membership_id = tests.fx('mem_u')) as free_n,
                          count(*) filter (where li.unit_price_cents = 20000 and li.membership_id is null) as paid_n
                     from public.jobs j join public.job_line_items li on li.job_id = j.id
                    where j.series_id = tests.fx('ser_u') group by j.id) x),
                'unlimited plan: every visit''s first line is included, the repeated service is charged');
select tests.ok((select count(*) >= 12 from public.jobs where series_id = tests.fx('ser_u')),
                'the unlimited series generated its whole horizon');
\endif

-- ============================================================ roles and shops
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.update_job_series(tests.fx('ser3'), '{"notes": "x"}')$$, '42501',
                    'a technician cannot edit a series');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.update_job_series(tests.fx('ser3'), '{"notes": "x"}')$$, 'P0002',
                    'another shop''s manager cannot see the series');
select tests.throws($$select public.job_series_price_lines(null::public.job_series, true, now())$$, '42501',
                    'the pricing helper is not callable by API roles');
select tests.throws($$select public.job_series_lock_memberships(null::public.job_series)$$, '42501',
                    'the membership lock helper is not callable by API roles');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b') and series_id is not null), 0::bigint,
                'shop B has no occurrences');
