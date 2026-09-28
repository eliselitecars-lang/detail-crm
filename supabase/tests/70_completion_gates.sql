-- 70 ops: required checklists and photo minimums block completion, with a
-- manager override (P-11) — the template's required flag is copied to the
-- job's items, technicians cannot change it, required items and after-photo
-- minimums block completion (technician and manager direct updates alike),
-- before-photo minimums block the start, packages count their services,
-- videos do not count, backward moves are free, set_job_status applies the
-- transition rules of a direct update, the override is manager-only and
-- recorded, job_completion_blockers, job_gate_overrides visibility, and
-- two-shop isolation.
\ir fixtures/two_shops.psql

-- ============================================================ required flag
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.checklist_templates (shop_id, name, items, service_id, required)
  values (tests.fx('shop_a'), 'Detail QA', '[{"label":"Vacuum"},{"label":"Glass"},{"label":"Tires"},{"label":"Mats"}]',
          tests.fx('svc_a'), true) returning tests.fx_set('tpl_req', id);
insert into public.checklist_templates (shop_id, name, items)
  values (tests.fx('shop_a'), 'Optional extras', '[{"label":"Air freshener"}]') returning tests.fx_set('tpl_opt', id);
select tests.eq((select count(*) from public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_req'))), 4::bigint,
                'the required template is applied');
select public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_opt'));
select tests.eq((select array_agg(label || ':' || required::text order by sort) from public.job_checklist_items where job_id = tests.fx('job_a')),
                array['Vacuum:true', 'Glass:true', 'Tires:true', 'Mats:true', 'Air freshener:false'],
                'the template''s required flag is copied to its items');
-- the automatic attach inherits it too
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.eq((select bool_and(required) from public.job_checklist_items where job_id = tests.fx('job_a2')), true,
                'items attached with a service line are required too');
insert into public.job_checklist_items (shop_id, job_id, label, required)
  values (tests.fx('shop_a'), tests.fx('job_a'), 'Manager walk-around', true) returning tests.fx_set('adhoc', id);
select tests.eq((select required from public.job_checklist_items where id = tests.fx('adhoc')), true, 'managers flag ad-hoc items');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$update public.job_checklist_items set required = false where id = tests.fx('adhoc')$$, '42501',
                         '%only managers%', 'technicians cannot drop the required flag');
select tests.throws($$update public.job_checklist_items set required = true
                      where job_id = tests.fx('job_a') and label = 'Air freshener'$$, '42501', 'nor set it');
select tests.eq(tests.row_count($$update public.services set min_after_photos = 0 where id = tests.fx('svc_a')$$), 0::bigint,
                'technicians cannot change photo minimums');

-- ============================================================ required items block completion
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
select tests.throws_like($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$, '23514',
                         'Finish the required checklist items first: Manager walk-around, Vacuum, Glass (and 2 more)',
                         'the technician cannot complete a job with open required items');
update public.job_checklist_items set done_at = now() where job_id = tests.fx('job_a') and label in ('Vacuum', 'Glass', 'Mats');
select tests.throws_like($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$, '23514',
                         'Finish the required checklist items first: Manager walk-around, Tires', 'the remaining labels are named');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$, '23514',
                    'managers are gated too on a direct update');
select tests.as_service();
select tests.throws($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$, '23514',
                    'so is trusted code');
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.job_checklist_items set done_at = now() where job_id = tests.fx('job_a') and label = 'Tires';
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.job_checklist_items set done_at = now() where id = tests.fx('adhoc');

-- ============================================================ photo minimums
select tests.throws($$update public.services set min_after_photos = 21 where id = tests.fx('svc_a')$$, '23514', 'at most 20');
select tests.throws($$update public.services set min_before_photos = -1 where id = tests.fx('svc_a')$$, '23514', 'not negative');
update public.services set min_before_photos = 1, min_after_photos = 2 where id = tests.fx('svc_a');
select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-2.jpg', tests.fx('u_tech_a')),
  ('job-media', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-after.mp4', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/before.jpg', tests.fx('u_tech2_a'));
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', 'after');
insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-after.mp4', 'after', 'video', 'job-media');
select tests.throws_like($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$, '23514',
                         '%at least 2 "after" photo(s)%(1 so far)%', 'two after photos are needed (the video does not count)');
select tests.eq(public.job_completion_blockers(tests.fx('job_a')),
                '{"open_required_items": [], "before_photos": {"required": 1, "have": 0}, "after_photos": {"required": 2, "have": 1}}'::jsonb,
                'the technician on the job sees the gate state');
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-2.jpg', 'after');
select tests.lives($$update public.jobs set status = 'completed' where id = tests.fx('job_a')$$,
                   'with every requirement met the technician completes the job');
-- backward moves are never gated (the before-photo minimum is not met)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set status = 'in_progress' where id = tests.fx('job_a')$$,
                   'a manager moves the job back to in progress despite missing before photos');
select tests.lives($$update public.jobs set status = 'scheduled' where id = tests.fx('job_a')$$, 'and back to scheduled');
select tests.throws_like($$update public.jobs set status = 'in_progress' where id = tests.fx('job_a')$$, '23514',
                         '%at least 1 "before" photo(s) before starting%(0 so far)%', 'starting needs the before photos');
select tests.lives($$update public.jobs set status = 'confirmed' where id = tests.fx('job_a')$$, 'other moves are not gated');

-- packages count the services they include
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Ceramic', 'service', 60)
  returning tests.fx_set('svc_ceramic', id);
update public.services set min_after_photos = 3 where id = tests.fx('svc_ceramic');
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Ceramic Package', 'package', 120)
  returning tests.fx_set('pkg', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg'), tests.fx('svc_ceramic'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('pkg'), 'Ceramic Package', 90000);
select tests.eq(public.job_completion_blockers(tests.fx('job_a2')) -> 'after_photos', '{"required": 3, "have": 0}'::jsonb,
                'the package''s service minimum applies (the highest minimum of the job''s services)');

-- ============================================================ set_job_status
select tests.authenticate_as(tests.fx('u_tech2_a'));   -- assigned to job_a2
select tests.throws($$select public.set_job_status(tests.fx('job_a'), 'en_route')$$, '42501',
                    'a technician cannot move a job they are not assigned to');
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'completed')$$, '42501',
                    'technicians follow the technician edges (scheduled -> completed is manager-only)');
select tests.throws_like($$select public.set_job_status(tests.fx('job_a2'), 'in_progress', true)$$, '42501', '%override%',
                         'technicians cannot force');
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'requested')$$, '42501', 'nor move backwards');
select tests.throws_like($$select public.set_job_status(tests.fx('job_a2'), 'in_progress')$$, '23514', '%"before" photo%',
                         'the start is gated through set_job_status too');
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/before.jpg', 'before');
select tests.eq((select array[status::text, (public_token is null)::text]
                   from public.set_job_status(tests.fx('job_a2'), 'in_progress')),
                array['in_progress', 'true'], 'the normal path works once satisfied and hides the booking token');
select tests.throws_like($$select public.set_job_status(tests.fx('job_a2'), 'completed')$$, '23514', '%required checklist%',
                         'the gate applies to set_job_status too');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'completed', true)$$, 'P0002', 'another shop''s job');
select tests.as_anon();
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'completed', true)$$, '42501', 'anon cannot');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.set_job_status(gen_random_uuid(), 'completed')$$, 'P0002', 'unknown job');
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), null)$$, '22023', 'status required');
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'requested')$$, '23514',
                    'in_progress -> requested is not an edge');
select tests.throws($$select public.set_job_status(tests.fx('job_a2'), 'completed', true, repeat('x', 501))$$, '22023',
                    'reason is limited');
select tests.eq((select status from public.set_job_status(tests.fx('job_a2'), 'completed', true, ' Customer in a hurry ')),
                'completed'::public.job_status, 'a manager overrides the gates');
select tests.eq((select jsonb_build_array(to_status, reason, overridden_by = tests.fx('u_manager_a'),
                                          blockers -> 'after_photos', jsonb_array_length(blockers -> 'open_required_items'),
                                          blockers ? 'before_photos')
                   from public.job_gate_overrides where job_id = tests.fx('job_a2')),
                '["completed", "Customer in a hurry", true, {"required": 3, "have": 0}, 4, false]'::jsonb,
                'the override records who, why and what was waived');
select tests.eq(current_setting('detailcrm.force_job_gates', true), '', 'the bypass ends with the call');
-- the bypass never leaks to a later update
select tests.lives($$update public.jobs set status = 'in_progress' where id = tests.fx('job_a2')$$, 'back to in progress');
select tests.throws($$update public.jobs set status = 'completed' where id = tests.fx('job_a2')$$, '23514',
                    'a later direct update is gated again');
-- forcing when nothing blocks records nothing
select tests.eq((select status from public.set_job_status(tests.fx('job_a'), 'en_route', true)),
                'en_route'::public.job_status, 'forcing an ungated move just moves');
select tests.eq((select count(*) from public.job_gate_overrides where job_id = tests.fx('job_a')), 0::bigint,
                'and records no override');
select tests.eq((select status from public.set_job_status(tests.fx('job_a'), 'en_route')), 'en_route'::public.job_status,
                'setting the current status is a no-op');
select tests.eq((select jsonb_build_array(status, cancel_reason)
                   from public.set_job_status(tests.fx('job_a'), 'cancelled', false, ' Rain ')),
                '["cancelled", "Rain"]'::jsonb, 'a cancellation stores the reason');

-- ============================================================ blockers and overrides: access
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.job_completion_blockers(tests.fx('job_a2'))$$, '42501', 'not for a job the technician is not on');
select tests.eq(tests.row_count($$select 1 from public.job_gate_overrides$$), 0::bigint, 'nor its overrides');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.job_gate_overrides$$), 1::bigint, 'the technician on the job reads them');
select tests.throws($$insert into public.job_gate_overrides (shop_id, job_id, to_status, blockers)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), 'completed', '{}')$$, '42501', 'no direct writes');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.job_completion_blockers(tests.fx('job_a2'))$$, 'P0002', 'another shop gets not found');
select tests.eq(tests.row_count($$select 1 from public.job_gate_overrides$$), 0::bigint, 'and sees no overrides');
select tests.as_anon();
select tests.throws($$select public.job_completion_blockers(tests.fx('job_a2'))$$, '42501', 'anon cannot');
select tests.as_service();
select tests.throws($$insert into public.job_gate_overrides (shop_id, job_id, to_status, blockers)
                      values (tests.fx('shop_b'), tests.fx('job_a2'), 'completed', '{}')$$, '23503',
                    'the composite FK rejects another shop''s job');

-- ============================================================ removed services release their items
-- A required template item attached with a service line stops blocking
-- completion once that service is no longer on the job (the customer
-- declined the add-on): its open items leave with the line, ticked items
-- stay as the record of work done, and ad-hoc items and service-less
-- templates are untouched.
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-06-03 15:00+00', '2025-06-03 17:00+00')
  returning tests.fx_set('job_c', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_c'), tests.fx('m_tech_a'));
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Glass Coat', 'service', 60)
  returning tests.fx_set('svc_gc', id);
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Trim Restore', 'service', 30)
  returning tests.fx_set('svc_trim', id);
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Glass Package', 'package', 90)
  returning tests.fx_set('pkg_gc', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_gc'), tests.fx('svc_gc'));
insert into public.checklist_templates (shop_id, name, items, service_id, required)
  values (tests.fx('shop_a'), 'Glass coat prep', '[{"id":"ipa","label":"IPA wipe-down"},{"id":"cure","label":"Cure check"}]',
          tests.fx('svc_gc'), true);
insert into public.checklist_templates (shop_id, name, items, service_id, required)
  values (tests.fx('shop_a'), 'Trim prep', '[{"id":"dress","label":"Trim dressing"}]', tests.fx('svc_trim'), true);
insert into public.checklist_templates (shop_id, name, items, required)
  values (tests.fx('shop_a'), 'General QA', '[{"id":"wipe","label":"Final wipe"}]', true)
  returning tests.fx_set('tpl_general', id);
update public.jobs set status = 'in_progress' where id = tests.fx('job_c');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_c'), tests.fx('svc_gc'), 'Glass Coat', 30000) returning tests.fx_set('line_gc', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_c'), tests.fx('pkg_gc'), 'Glass Package', 45000) returning tests.fx_set('line_pkg', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_c'), tests.fx('svc_trim'), 'Trim Restore', 8000) returning tests.fx_set('line_trim', id);
select public.apply_checklist_template(tests.fx('job_c'), tests.fx('tpl_general'));
insert into public.job_checklist_items (shop_id, job_id, label, required)
  values (tests.fx('shop_a'), tests.fx('job_c'), 'Walk-around', true);
select tests.eq((select array_agg(label order by sort, label) from public.job_checklist_items where job_id = tests.fx('job_c') and required),
                array['Walk-around', 'IPA wipe-down', 'Cure check', 'Trim dressing', 'Final wipe']::text[],
                'the service templates attached once each (the package repeats Glass Coat), plus the general and ad-hoc items');

select tests.authenticate_as(tests.fx('u_tech_a'));
update public.job_checklist_items set done_at = now() where job_id = tests.fx('job_c') and label = 'Cure check';
select tests.eq(tests.row_count($$delete from public.job_line_items where id = tests.fx('line_gc')$$), 0::bigint,
                'technicians cannot remove lines');

select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from public.job_line_items where id = tests.fx('line_gc')$$), 0::bigint,
                'another shop cannot remove them either');
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_c')), 0::bigint,
                'nor see the items');

select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.job_line_items where id = tests.fx('line_gc');
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_c') and label = 'IPA wipe-down'), 1::bigint,
                'the service is still on the job through the package: its items stay');
delete from public.job_line_items where id = tests.fx('line_pkg');
select tests.eq((select array_agg(label || ':' || (done_at is not null)::text order by sort, label)
                   from public.job_checklist_items where job_id = tests.fx('job_c')),
                array['Walk-around:false', 'Cure check:true', 'Trim dressing:false', 'Final wipe:false']::text[],
                'with Glass Coat gone its open item leaves; the ticked one stays as the record');
-- changing a line's service swaps the service's items both ways
update public.job_line_items set service_id = tests.fx('svc_gc'), name = 'Glass Coat' where id = tests.fx('line_trim');
select tests.eq((select array_agg(label || ':' || (done_at is not null)::text order by sort, label)
                   from public.job_checklist_items where job_id = tests.fx('job_c')),
                array['Walk-around:false', 'Cure check:true', 'Final wipe:false', 'IPA wipe-down:false']::text[],
                'Trim Restore''s open item leaves and Glass Coat''s missing item comes back (the ticked one is kept)');
update public.job_line_items set service_id = null, name = 'Custom glass work' where id = tests.fx('line_trim');
select tests.eq((select array_agg(label order by sort, label) from public.job_checklist_items
                  where job_id = tests.fx('job_c') and done_at is null),
                array['Walk-around', 'Final wipe']::text[],
                'a line that loses its service releases its items; the service-less template and ad-hoc items stay');
select tests.eq((select jsonb_agg(x ->> 'label') from jsonb_array_elements(public.job_completion_blockers(tests.fx('job_c')) -> 'open_required_items') x),
                '["Walk-around", "Final wipe"]'::jsonb,
                'the blockers list only what the job still requires');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$update public.jobs set status = 'completed' where id = tests.fx('job_c')$$, '23514',
                         'Finish the required checklist items first: Walk-around, Final wipe',
                         'ad-hoc and general required items still block');
update public.job_checklist_items set done_at = now() where job_id = tests.fx('job_c') and label in ('Final wipe', 'Walk-around');
select tests.lives($$update public.jobs set status = 'completed' where id = tests.fx('job_c')$$,
                   'the technician completes: nothing the job''s current services require is open');

-- the finding's repro: the declined add-on on a job with no other service
select tests.as_superuser();
update public.jobs set status = 'in_progress' where id = tests.fx('job_a2');
delete from public.job_checklist_items where job_id = tests.fx('job_a2');
delete from public.job_line_items where job_id = tests.fx('job_a2');
delete from public.job_gate_overrides where job_id = tests.fx('job_a2');
update public.services set min_after_photos = 0, min_before_photos = 0 where id in (tests.fx('svc_a'), tests.fx('svc_ceramic'));
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_gc'), 'Glass Coat', 30000) returning tests.fx_set('line_a2_gc', id);
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_a2') and required), 2::bigint,
                'the add-on attached its required items');
delete from public.job_line_items where id = tests.fx('line_a2_gc');
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_a2')), 0::bigint,
                'declining the add-on removes them');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.lives($$update public.jobs set status = 'completed' where id = tests.fx('job_a2')$$,
                   'the assigned technician can complete the job');

-- isolation and cascades
select tests.as_superuser();
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_b'), 'Glass Coat', 'service', 60)
  returning tests.fx_set('svc_gc_b', id);
insert into public.checklist_templates (shop_id, name, items, service_id, required)
  values (tests.fx('shop_b'), 'B prep', '[{"id":"ipa","label":"IPA wipe-down"}]', tests.fx('svc_gc_b'), true);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('svc_gc_b'), 'Glass Coat', 30000);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_c'), tests.fx('svc_trim'), 'Trim Restore', 8000) returning tests.fx_set('line_trim2', id);
delete from public.job_line_items where id = tests.fx('line_trim2');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_b') and done_at is null), 1::bigint,
                'another shop''s items are never touched');
select tests.lives($$delete from public.jobs where id = tests.fx('job_b')$$,
                   'deleting a job cascades through its lines and items');
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_b')), 0::bigint, 'nothing is left');
