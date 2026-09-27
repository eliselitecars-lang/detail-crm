-- 20 field ops: storage purge coverage regressions (SPEC §4.6: deleting a
-- shop, job, inspection or form queues its files for the storage purge).
--   * folders are canonical lower-case uuids: no policy or validator accepts
--     an upper/mixed-case shop, job or form-token folder, which the purge
--     (case-sensitive prefix match) would never find;
--   * deleting an inspection queues its damage-mark photos;
--   * re-tokenizing an unsigned form (job moved to another customer) queues
--     the old token's public upload folder.
\ir fixtures/two_shops.psql
-- The purge queue is global (the worker drains every shop's requests): start
-- from an empty queue. On a shared database (the local stack) this is part
-- of the file's own transaction and rolled back with it.
delete from public.storage_purge_requests;

-- =================================================================== canonical folders
select tests.eq(public.storage_path_uuid(tests.fx('shop_a')::text || '/x.jpg', 1), tests.fx('shop_a'),
                'a lower-case folder is read as its uuid');
select tests.eq(public.storage_path_uuid(upper(tests.fx('shop_a')::text) || '/x.jpg', 1), null::uuid,
                'an upper-case folder is not a canonical uuid');
select tests.eq(public.storage_path_uuid('0000000A-0000-0000-0000-000000000000/x.jpg', 1), null::uuid,
                'nor is a mixed-case one');

-- job-photos: the technician on the job
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/before.jpg', auth.uid(), auth.uid()::text)$$,
  upper(tests.fx('shop_a')::text), upper(tests.fx('job_a')::text)), '42501',
  'an upload under upper-case shop/job folders is refused');
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/before.jpg', auth.uid(), auth.uid()::text)$$,
  tests.fx('shop_a'), upper(tests.fx('job_a')::text)), '42501',
  'so is one under an upper-case job folder only');
select tests.lives(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/before.jpg', auth.uid(), auth.uid()::text)$$, tests.fx('shop_a'), tests.fx('job_a')),
  'the canonical folder is accepted');
select tests.lives(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind) values (%L, %L, %L, 'before')$$,
  tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before.jpg'),
  'and recorded as a job photo');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/x.jpg', auth.uid(), auth.uid()::text)$$, tests.fx('shop_a'), tests.fx('job_a')), '42501',
  'another shop''s technician cannot upload into shop A''s job folder');

-- the row validators refuse non-canonical paths even when such an object exists
select tests.as_superuser();
insert into storage.objects (bucket_id, name)
values ('job-photos', upper(tests.fx('shop_a')::text) || '/' || upper(tests.fx('job_a')::text) || '/upper.jpg'),
       ('signatures', upper(tests.fx('shop_a')::text) || '/device/upper.png');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind) values (%L, %L, %L, 'before')$$,
  tests.fx('shop_a'), tests.fx('job_a'), upper(tests.fx('shop_a')::text) || '/' || upper(tests.fx('job_a')::text) || '/upper.jpg'),
  '23514', 'a job photo row cannot point at an upper-case folder');
select tests.fx_set('ins_case', gen_random_uuid());
insert into public.inspections (id, shop_id, job_id, vehicle_id, kind)
values (tests.fx('ins_case'), tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre');
select tests.throws(format($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
  values (%L, %L, 'front', 0.5, 0.5, 'dent', %L)$$,
  tests.fx('shop_a'), tests.fx('ins_case'), upper(tests.fx('shop_a')::text) || '/' || upper(tests.fx('job_a')::text) || '/upper.jpg'),
  '23514', 'nor a damage mark');
select tests.throws(format($$update public.inspections set customer_signature_path = %L, signed_by_name = 'Alice Anders'
  where id = %L$$, upper(tests.fx('shop_a')::text) || '/device/upper.png', tests.fx('ins_case')),
  '23514', 'nor an inspection signature');

-- signatures: staff and public form signers
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', '%s/device/s.png', auth.uid(), auth.uid()::text)$$, upper(tests.fx('shop_a')::text)), '42501',
  'staff cannot upload a signature under an upper-case shop folder');
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body, attach_to)
values (tests.fx('shop_a'), 'Waiver', 'I agree', 'manual') returning tests.fx_set('ft', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.form_submissions (shop_id, job_id, form_template_id)
values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('ft')) returning tests.fx_set('fs', id);
select tests.as_superuser();
select tests.fx_set('tok', (select public_token from public.form_submissions where id = tests.fx('fs')));
select tests.as_anon();
select tests.ok(not public.public_form_signature_upload_allowed(
                  upper(tests.fx('shop_a')::text) || '/forms/' || upper(tests.fx('tok')::text) || '/sig.png'),
                'the public upload check refuses upper-case folders');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/sig.png')$$,
  upper(tests.fx('shop_a')::text), upper(tests.fx('tok')::text)), '42501',
  'a form-link holder cannot upload under upper-case shop/token folders');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/sig.png')$$,
  tests.fx('shop_a'), upper(tests.fx('tok')::text)), '42501',
  'nor under an upper-case token folder');
select tests.lives(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/sig.png')$$,
  tests.fx('shop_a'), tests.fx('tok')), 'the canonical token folder is accepted');

-- the canonical upload is what the purge finds when the job goes
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.inspections where id = tests.fx('ins_case');
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a')$$), 1::bigint, 'the manager deletes the job');
select tests.as_service();
create temp table claimed_case as select * from public.claim_storage_purge(500, '2030-01-01Z');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || object_name order by bucket_id, object_name) from claimed_case),
                array['job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before.jpg',
                      'signatures ' || tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png'],
                'the purge worker is handed the deleted job''s photo and its form''s signature upload');
drop table claimed_case;
delete from public.storage_purge_requests;

-- =================================================================== inspection deletion queues mark photos
select tests.fx_set('ins', gen_random_uuid());
select tests.authenticate_as(tests.fx('u_tech2_a'));   -- assigned to job_a2
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-dent.jpg', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-chip.jpg', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/gallery.jpg', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/lone.jpg', auth.uid(), auth.uid()::text);
insert into public.job_photos (shop_id, job_id, storage_path, kind)
values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/gallery.jpg', 'inspection');
insert into public.inspections (id, shop_id, job_id, vehicle_id, kind)
values (tests.fx('ins'), tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('veh_a2'), 'pre');
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path) values
  (tests.fx('shop_a'), tests.fx('ins'), 'front', 0.5, 0.5, 'dent', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-dent.jpg'),
  (tests.fx('shop_a'), tests.fx('ins'), 'left', 0.2, 0.3, 'chip', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-chip.jpg'),
  (tests.fx('shop_a'), tests.fx('ins'), 'rear', 0.1, 0.1, 'scratch', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/gallery.jpg'),
  (tests.fx('shop_a'), tests.fx('ins'), 'top', 0.4, 0.4, 'stain', null);
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
values (tests.fx('shop_a'), tests.fx('ins'), 'right', 0.6, 0.6, 'swirl', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/lone.jpg')
returning tests.fx_set('lone_mark', id);

-- a mark removed on its own keeps its photo (documented: the app removes it)
select tests.eq(tests.row_count($$delete from public.inspection_marks where id = tests.fx('lone_mark')$$), 1::bigint,
                'the technician removes one mark');
select tests.as_superuser();
select tests.eq((select count(*) from public.storage_purge_requests), 0::bigint, 'a single mark deletion queues nothing');

-- another shop cannot delete the inspection (and so queues nothing)
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from public.inspections where id = tests.fx('ins')$$), 0::bigint,
                'shop B''s manager cannot delete shop A''s inspection');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.inspections where id = tests.fx('ins')$$), 0::bigint,
                'nor can a technician who is not on the job');
select tests.as_superuser();
select tests.eq((select count(*) from public.storage_purge_requests), 0::bigint, 'denied deletions queue nothing');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.inspections where id = tests.fx('ins')$$), 1::bigint, 'the manager deletes the inspection');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || is_prefix::text || ' ' || reason order by path)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a')),
                array['job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/gallery.jpg false inspection_deleted',
                      'job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-chip.jpg false inspection_deleted',
                      'job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-dent.jpg false inspection_deleted'],
                'deleting the inspection queues each of its marks'' photos');
select tests.as_service();
select tests.eq((select array_agg(object_name order by object_name) from public.claim_storage_purge(100, '2030-01-01Z')),
                array[tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-chip.jpg',
                      tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/mark-dent.jpg'],
                'the worker removes the mark photos, but not one still in the job''s gallery');
select tests.as_superuser();
delete from public.storage_purge_requests;

-- a job deletion covers its inspections' mark photos with the folder request
select tests.authenticate_as(tests.fx('u_tech2_a'));
insert into public.inspections (id, shop_id, job_id, vehicle_id, kind)
values (tests.fx_set('ins2', gen_random_uuid()), tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('veh_a2'), 'post');
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
values (tests.fx('shop_a'), tests.fx('ins2'), 'front', 0.5, 0.5, 'dent', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/lone.jpg');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a2')$$), 1::bigint, 'the manager deletes the job');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || reason order by bucket_id, path)
                   from public.storage_purge_requests where bucket_id = 'job-photos'),
                array['job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/ job_deleted'],
                'only the job''s photo folder is queued (no per-mark rows)');
delete from public.storage_purge_requests;

-- =================================================================== re-tokenized forms queue the old folder
insert into public.form_templates (shop_id, name, body, attach_to) values (tests.fx('shop_a'), 'Release', 'I agree', 'all_jobs');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
values (tests.fx('shop_a'), tests.fx('cust_a2'), '2025-07-01 15:00Z', '2025-07-01 16:00Z') returning tests.fx_set('job_x', id);
select tests.fx_set('tok1', (select public_token from public.form_submissions
                              where job_id = tests.fx('job_x') and title = 'Release'));
select tests.as_anon();
select tests.lives(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/sig.png')$$,
                          tests.fx('shop_a'), tests.fx('tok1')), 'the first customer uploads a signature image but never signs');

-- denial: another shop's manager cannot move the job (nothing is queued)
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_x')$$), 0::bigint,
                'shop B cannot move shop A''s job');
select tests.as_superuser();
select tests.eq((select count(*) from public.storage_purge_requests), 0::bigint, 'and nothing is queued');

select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('job_x');
select tests.as_superuser();
select tests.fx_set('tok2', (select public_token from public.form_submissions
                              where job_id = tests.fx('job_x') and title = 'Release'));
select tests.ok(tests.fx('tok2') <> tests.fx('tok1'), 'the move re-tokenizes the unsigned form');
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || is_prefix::text || ' ' || reason)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a')),
                array['signatures ' || tests.fx('shop_a') || '/forms/' || tests.fx('tok1') || '/ true form_token_rotated'],
                'and queues the old token''s upload folder right away');
select tests.as_anon();
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/again.png')$$,
                           tests.fx('shop_a'), tests.fx('tok1')), '42501', 'the old folder takes no new uploads');
select tests.lives(format($$insert into storage.objects (bucket_id, name) values ('signatures', '%s/forms/%s/new.png')$$,
                          tests.fx('shop_a'), tests.fx('tok2')), 'the new customer uploads under the new token');
select tests.as_service();
select tests.eq((select array_agg(c.object_name) from public.claim_storage_purge(1000, '2025-08-01Z') c),
                array[tests.fx('shop_a') || '/forms/' || tests.fx('tok1') || '/sig.png'],
                'the previous customer''s image is purged; the new customer''s upload is not');
select tests.as_superuser();
delete from public.storage_purge_requests;

-- deleting the job later still queues the current token's folder
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_x');
select tests.as_service();
select tests.ok(exists (select 1 from public.claim_storage_purge(1000, '2025-08-02Z') c
                         where c.bucket_id = 'signatures'
                           and c.object_name = tests.fx('shop_a') || '/forms/' || tests.fx('tok2') || '/new.png'),
                'the deleted form''s current upload folder is purged with the job');

select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.inspection_marks_queue_storage_purge()', 'execute')
                and not has_function_privilege('anon', 'public.inspection_marks_queue_storage_purge()', 'execute'),
                'the mark purge trigger function is not callable through the API');
