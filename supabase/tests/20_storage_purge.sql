-- 20 field ops: storage regressions —
--   * shop-assets objects cannot be listed across tenants (anon or staff of
--     another shop): public files are served by URL, listing is members-only;
--   * the files of deleted jobs and shops do not become orphaned PII:
--     managers see and delete every job-photos object of their shop (also
--     deleted jobs' folders), and job / inspection / form / shop deletions
--     queue their files for the storage-purge worker (claim / finish RPCs);
--   * a signed inspection's evidence paths cannot be re-uploaded after the
--     original object is gone, and an inspection cannot be signed while a
--     mark's photo is missing.
\ir fixtures/two_shops.psql
-- The purge queue is global (the worker drains every shop's requests): start
-- from an empty queue. On a shared database (the local stack) this is part
-- of the file's own transaction and rolled back with it.
delete from public.storage_purge_requests;

-- =================================================================== #1 shop-assets listing
select tests.authenticate_as(tests.fx('u_owner_b'));
insert into storage.objects (bucket_id, name, owner, owner_id)
values ('shop-assets', tests.fx('shop_b') || '/unreleased-promo-2026.png', auth.uid(), auth.uid()::text);
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 1::bigint,
                'the uploading owner reads the asset back (upsert / listing of its own shop)');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 1::bigint,
                'members of the shop may list its assets');
select tests.as_anon();
select tests.eq((select count(*) from storage.objects where bucket_id = 'shop-assets'
                   and name like tests.fx('shop_b') || '/%'), 0::bigint,
                'anon cannot enumerate other shops'' asset objects');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint,
                'anon lists no shop assets at all (no shop ids, no file names)');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint,
                'the owner of another shop cannot list shop B''s assets');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint,
                'nor can its technicians');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint,
                'nor a signed-in user with no shop');

-- =================================================================== #2 (1) job deletion
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/before.jpg', auth.uid(), auth.uid()::text)$$, tests.fx('shop_a'), tests.fx('job_a')),
  'the assigned technician uploads a photo');
insert into public.job_photos (shop_id, job_id, storage_path, kind)
values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before.jpg', 'before');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a')$$), 1::bigint, 'manager deletes the job');
select tests.as_superuser();
-- (0076: plus its video folder in job-media and its documents folder)
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || is_prefix::text || ' ' || reason order by bucket_id)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a')),
                array['documents '  || tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/ true job_deleted',
                      'job-media '  || tests.fx('shop_a') || '/' || tests.fx('job_a') || '/ true job_deleted',
                      'job-photos ' || tests.fx('shop_a') || '/' || tests.fx('job_a') || '/ true job_deleted'],
                'deleting the job queues its photo, video and document folders for the storage purge');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count(format($$select 1 from storage.objects where bucket_id = 'job-photos' and name like '%s/%s/%%'$$,
                                       tests.fx('shop_a'), tests.fx('job_a'))), 0::bigint,
                'other technicians do not see the deleted job''s photos');
select set_config('storage.allow_delete_query', 'true', true);
select tests.eq(tests.row_count(format($$delete from storage.objects where bucket_id = 'job-photos' and name = '%s/%s/before.jpg'$$,
                                       tests.fx('shop_a'), tests.fx('job_a'))), 0::bigint,
                'nor delete them');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count(format($$select 1 from storage.objects where bucket_id = 'job-photos' and name like '%s/%%'$$,
                                       tests.fx('shop_a'))), 0::bigint,
                'another shop''s manager sees none of them');
select set_config('storage.allow_delete_query', 'true', true);
select tests.eq(tests.row_count(format($$delete from storage.objects where bucket_id = 'job-photos' and name = '%s/%s/before.jpg'$$,
                                       tests.fx('shop_a'), tests.fx('job_a'))), 0::bigint,
                'nor deletes them');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count(format($$select 1 from storage.objects where bucket_id = 'job-photos' and name like '%s/%s/%%'$$,
                                       tests.fx('shop_a'), tests.fx('job_a'))), 1::bigint,
                'managers still list the deleted job''s folder');
select set_config('storage.allow_delete_query', 'true', true);
select tests.eq(tests.row_count(format($$delete from storage.objects where bucket_id = 'job-photos' and name = '%s/%s/before.jpg'$$,
                                       tests.fx('shop_a'), tests.fx('job_a'))), 1::bigint,
                'the manager can remove the deleted job''s photo from storage');

-- =================================================================== #3 signed evidence cannot be re-uploaded
select tests.fx_set('ins', gen_random_uuid());
select tests.authenticate_as(tests.fx('u_tech2_a'));   -- assigned to job_a2 (veh_a2)
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg', auth.uid(), auth.uid()::text);
insert into public.inspections (id, shop_id, job_id, vehicle_id, kind)
  values (tests.fx('ins'), tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('veh_a2'), 'pre');
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
  values (tests.fx('shop_a'), tests.fx('ins'), 'front', 0.5, 0.5, 'scratch',
          tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg');
select set_config('storage.allow_delete_query', 'true', true);
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'job-photos'
   and name = tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg'$$), 1::bigint, 'unsigned: uploader may delete');
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', tests.fx('shop_a') || '/device/sig.png', auth.uid(), auth.uid()::text);
select tests.throws_like($$update public.inspections set customer_signature_path = tests.fx('shop_a') || '/device/sig.png',
    signed_by_name = 'Aaron Other' where id = tests.fx('ins')$$, '23514', '%damage photo%missing%',
  'an inspection cannot be signed while a mark''s photo is missing');
select tests.ok((select signed_at is null from public.inspections where id = tests.fx('ins')), 'still unsigned');
-- attach the photo again, then the customer signs
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg', auth.uid(), auth.uid()::text);
select tests.lives($$update public.inspections set customer_signature_path = tests.fx('shop_a') || '/device/sig.png',
    signed_by_name = 'Aaron Other' where id = tests.fx('ins')$$, 'customer signs once the photo is back');
-- the stored objects vanish outside the API policies (e.g. a service-role
-- cleanup racing the signature): nobody may put new content at those paths
select tests.as_superuser();
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where bucket_id = 'job-photos' and name = tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg';
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where bucket_id = 'signatures' and name = tests.fx('shop_a') || '/device/sig.png';
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$insert into storage.objects (bucket_id, name, owner)
    values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg', auth.uid())$$,
    '42501', 'uploading new content at a signed mark''s photo path must be refused');
select tests.throws($$insert into storage.objects (bucket_id, name, owner)
    values ('signatures', tests.fx('shop_a') || '/device/sig.png', auth.uid())$$,
    '42501', 'nor at a signed inspection''s signature path');
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/other.jpg', auth.uid(), auth.uid()::text);
select tests.throws($$update storage.objects set name = tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg'
    where bucket_id = 'job-photos' and name = tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/other.jpg'$$,
    '42501', 'nor may another object be moved onto the signed path');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into storage.objects (bucket_id, name, owner)
    values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg', auth.uid())$$,
    '42501', 'managers cannot re-upload signed evidence either');
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', tests.fx('shop_a') || '/device/mgr.png', auth.uid(), auth.uid()::text);
select tests.throws($$update storage.objects set name = tests.fx('shop_a') || '/device/sig.png'
    where bucket_id = 'signatures' and name = tests.fx('shop_a') || '/device/mgr.png'$$,
    '42501', 'nor move a signature image onto a signed inspection''s signature path');
select tests.lives($$insert into storage.objects (bucket_id, name, owner)
    values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/new.jpg', auth.uid())$$,
    'ordinary uploads to the job are unaffected');
-- un-signing unlocks the path again
update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null where id = tests.fx('ins');
select tests.lives($$insert into storage.objects (bucket_id, name, owner)
    values ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/scratch.jpg', auth.uid())$$,
    'after a manager removes the signature the photo can be attached again');

-- =================================================================== queue: inspections and forms
-- an inspection deleted with its job queues its signature image; one still
-- referenced elsewhere is never purged
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'requested')
  returning tests.fx_set('job_q', id);
insert into public.jobs (shop_id, customer_id, vehicle_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'requested')
  returning tests.fx_set('job_keep', id);
insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Release', 'I agree')
  returning tests.fx_set('ft', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('signatures', tests.fx('shop_a') || '/inspections/q.png', auth.uid(), auth.uid()::text),
  ('signatures', tests.fx('shop_a') || '/inspections/shared.png', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_q') || '/a.jpg', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_q') || '/b.jpg', auth.uid(), auth.uid()::text),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_keep') || '/keep.jpg', auth.uid(), auth.uid()::text);
insert into public.inspections (shop_id, job_id, kind, customer_signature_path, signed_by_name)
  values (tests.fx('shop_a'), tests.fx('job_q'), 'pre', tests.fx('shop_a') || '/inspections/q.png', 'Alice Anders');
insert into public.inspections (shop_id, job_id, kind, customer_signature_path, signed_by_name)
  values (tests.fx('shop_a'), tests.fx('job_q'), 'post', tests.fx('shop_a') || '/inspections/shared.png', 'Alice Anders');
insert into public.inspections (shop_id, job_id, kind, customer_signature_path, signed_by_name)
  values (tests.fx('shop_a'), tests.fx('job_keep'), 'pre', tests.fx('shop_a') || '/inspections/shared.png', 'Alice Anders');
insert into public.form_submissions (shop_id, job_id, form_template_id) values (tests.fx('shop_a'), tests.fx('job_q'), tests.fx('ft'))
  returning tests.fx_set('fs_q', id);
select tests.as_superuser();
select tests.fx_set('tok_q', (select public_token from public.form_submissions where id = tests.fx('fs_q')));
select tests.as_anon();
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_q') || '/pending.png');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_q')$$), 1::bigint, 'manager deletes the second job');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || reason order by path)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a') and reason <> 'job_deleted'),
                array['signatures ' || tests.fx('shop_a') || '/forms/' || tests.fx('tok_q') || '/ form_deleted',
                      'signatures ' || tests.fx('shop_a') || '/inspections/q.png inspection_deleted',
                      'signatures ' || tests.fx('shop_a') || '/inspections/shared.png inspection_deleted'],
                'the job''s inspection signatures and its form''s public upload folder are queued');
select tests.eq((select count(*) from public.storage_purge_requests
                  where path = tests.fx('shop_a') || '/' || tests.fx('job_q') || '/' and reason = 'job_deleted'
                    and bucket_id = 'job-photos'), 1::bigint,
                'and its photo folder');

-- =================================================================== #2 (2) shop deletion
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.lives(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', '%s/sig/customer.png', auth.uid(), auth.uid()::text)$$, tests.fx('shop_b')),
  'shop B collects a signature image');
select tests.lives(format($$insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('job-photos', '%s/%s/car.jpg', auth.uid(), auth.uid()::text)$$, tests.fx('shop_b'), tests.fx('job_b')),
  'and a car photo');
insert into public.inspections (shop_id, job_id, kind, customer_signature_path, signed_by_name)
  values (tests.fx('shop_b'), tests.fx('job_b'), 'pre', tests.fx('shop_b') || '/sig/customer.png', 'Bob Burns');
select tests.as_service();  -- payments delete_shop (0117)
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 1::bigint, 'shop B is deleted');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || reason order by bucket_id)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_b')),
                array['documents '   || tests.fx('shop_b') || '/ shop_deleted',
                      'job-media '   || tests.fx('shop_b') || '/ shop_deleted',
                      'job-photos '  || tests.fx('shop_b') || '/ shop_deleted',
                      'shop-assets ' || tests.fx('shop_b') || '/ shop_deleted',
                      'signatures '  || tests.fx('shop_b') || '/ shop_deleted'],
                'deleting the shop queues its whole folder in every bucket (and nothing per cascaded row)');

-- =================================================================== worker: claim / finish
-- only service_role may drive the queue
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.claim_storage_purge(100, '2026-01-01 00:00+00')$$, '42501', 'staff cannot claim purges');
select tests.throws($$select public.finish_storage_purge(array[1::bigint])$$, '42501', 'nor report them');
select tests.throws($$select 1 from public.storage_purge_requests$$, '42501', 'nor read the queue');
select tests.as_anon();
select tests.throws($$select * from public.claim_storage_purge(100, '2026-01-01 00:00+00')$$, '42501', 'anon cannot claim purges');
select tests.throws($$select 1 from public.storage_purge_requests$$, '42501', 'nor read the queue');

select tests.as_service();
select tests.throws($$select * from public.claim_storage_purge(0, '2026-01-01 00:00+00')$$, '22023', 'the batch size is bounded');
create temporary table claimed on commit drop as
  select * from public.claim_storage_purge(1000, '2026-01-01 00:00+00');
select tests.eq((select array_agg(object_name order by object_name) from claimed where object_name like tests.fx('shop_b') || '/%'),
                array[tests.fx('shop_b') || '/' || tests.fx('job_b') || '/car.jpg',
                      tests.fx('shop_b') || '/sig/customer.png',
                      tests.fx('shop_b') || '/unreleased-promo-2026.png'],
                'the deleted shop''s photos, signatures and assets are handed to the worker');
select tests.eq((select array_agg(object_name order by object_name) from claimed where object_name like tests.fx('shop_a') || '/%'),
                array[tests.fx('shop_a') || '/' || tests.fx('job_q') || '/a.jpg',
                      tests.fx('shop_a') || '/' || tests.fx('job_q') || '/b.jpg',
                      tests.fx('shop_a') || '/forms/' || tests.fx('tok_q') || '/pending.png',
                      tests.fx('shop_a') || '/inspections/q.png'],
                'the deleted job''s photos, its form upload and its inspection signature (not the one still in use, not other jobs)');
select tests.eq((select count(*) from public.storage_purge_requests), 6::bigint,
                'requests with nothing left to remove are finished at claim time (the manager already removed job_a''s photo; shared.png is in use)');
select tests.eq((select count(*) from public.claim_storage_purge(1000, '2026-01-01 00:05+00')), 0::bigint,
                'claimed requests are leased: a second worker gets nothing');

-- the worker removes the objects through the Storage API (service role)
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects o using claimed c where o.bucket_id = c.bucket_id and o.name = c.object_name;
select tests.eq(public.finish_storage_purge((select array_agg(distinct request_id) from claimed), null, '2026-01-01 00:01+00'),
                6, 'the worker reports success');
select tests.eq((select count(*) from public.claim_storage_purge(1000, '2026-01-01 00:02+00')), 0::bigint,
                'nothing is left to remove');
select tests.eq((select count(*) from public.storage_purge_requests), 0::bigint, 'and every request is finished');
select tests.as_superuser();
select tests.eq((select count(*) from storage.objects where name like tests.fx('shop_b') || '/%'), 0::bigint,
  'no customer photos / signatures of the deleted shop are left behind in storage');
select tests.ok(exists (select 1 from storage.objects where bucket_id = 'signatures' and name = tests.fx('shop_a') || '/inspections/shared.png'),
                'a signature image another job''s inspection still references is kept');
select tests.ok(exists (select 1 from storage.objects where bucket_id = 'job-photos'
                         and name = tests.fx('shop_a') || '/' || tests.fx('job_keep') || '/keep.jpg'),
                'other jobs'' photos are untouched');
select tests.ok(exists (select 1 from storage.objects where bucket_id = 'job-photos'
                         and name = tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/new.jpg'),
                'live jobs'' photos are untouched');

-- failures back off and are recorded; the lease then expires and the work resumes
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_keep');
select tests.as_service();
select tests.eq((select array_agg(object_name order by object_name) from public.claim_storage_purge(10, '2026-01-02 00:00+00')),
                array[tests.fx('shop_a') || '/' || tests.fx('job_keep') || '/keep.jpg',
                      tests.fx('shop_a') || '/inspections/shared.png'],
                'a later job deletion is claimed, now including the signature image nothing references any more');
select tests.eq(public.finish_storage_purge((select array_agg(id) from public.storage_purge_requests), 'storage: 503 Service Unavailable',
                                            '2026-01-02 00:01+00'), 2, 'the worker reports a failure');
select tests.eq((select count(*) from public.storage_purge_requests where last_error = 'storage: 503 Service Unavailable'
                   and locked_until = '2026-01-02 00:16+00'), 2::bigint, 'the error is kept and the retry waits 15 minutes');
select tests.eq((select count(*) from public.claim_storage_purge(10, '2026-01-02 00:15+00')), 0::bigint, 'not before');
select tests.eq((select array_agg(object_name order by object_name) from public.claim_storage_purge(10, '2026-01-02 00:16+00')),
                array[tests.fx('shop_a') || '/' || tests.fx('job_keep') || '/keep.jpg',
                      tests.fx('shop_a') || '/inspections/shared.png'],
                'then both are retried');
select tests.eq((select array_agg(attempts) from public.storage_purge_requests), array[2, 2], 'attempts are counted');
select tests.eq(public.finish_storage_purge((select array_agg(id) from public.storage_purge_requests), null, '2026-01-02 00:17+00'),
                2, 'a success releases the lease');
select tests.eq((select count(*) from public.storage_purge_requests where last_error is null and locked_until is null), 2::bigint,
                'and clears the error');
select tests.eq((select count(*) from public.claim_storage_purge(1, '2026-01-02 00:18+00')), 1::bigint,
                'a claim never returns more than p_limit objects');
select tests.eq((select count(*) from public.storage_purge_requests where locked_until is not null), 1::bigint,
                'and leases only the requests it handed out');

-- =================================================================== privileges
select tests.as_superuser();
select tests.ok(has_function_privilege('service_role', 'public.claim_storage_purge(integer, timestamptz)', 'execute')
                and has_function_privilege('service_role', 'public.finish_storage_purge(bigint[], text, timestamptz)', 'execute'),
                'the worker RPCs are granted to service_role');
select tests.ok(not has_function_privilege('authenticated', 'public.queue_storage_purge(uuid, text, text, boolean, text)', 'execute')
                and not has_function_privilege('anon', 'public.queue_storage_purge(uuid, text, text, boolean, text)', 'execute')
                and not has_function_privilege('authenticated', 'public.storage_object_in_use(text, text)', 'execute'),
                'queueing and the in-use probe are internal');
select tests.throws($$insert into public.storage_purge_requests (shop_id, bucket_id, path, is_prefix, reason)
                      values (gen_random_uuid(), 'job-photos', gen_random_uuid() || '/', true, 'shop_deleted')$$,
                    '23514', 'a request path must be under its own shop folder');
select tests.throws(format($$insert into public.storage_purge_requests (shop_id, bucket_id, path, is_prefix, reason)
                      values ('%1$s', 'job-photos', '%1$s/%%', true, 'shop_deleted')$$, tests.fx('shop_a')),
                    '23514', 'prefixes are uuid folders only (no LIKE wildcards)');
