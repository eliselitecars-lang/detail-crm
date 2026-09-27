-- 20 field ops: job_photos — staff on the job upload, uploader or manager+
-- edit/delete, path/object validation, server-stamped uploader, isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', tests.fx('u_manager_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-2.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/a2.jpg', tests.fx('u_tech2_a')),
  ('job-photos', tests.fx('shop_b') || '/' || tests.fx('job_b') || '/b.jpg', tests.fx('u_tech_b')),
  ('signatures', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/in-wrong-bucket.jpg', tests.fx('u_tech_a'));

-- ------------------------------------------------------------ insert
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind, caption, uploaded_by)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg', 'before',
          'Driver door', tests.fx('u_owner_a'))
  returning tests.fx_set('photo_tech', id);
select tests.eq((select uploaded_by from public.job_photos where id = tests.fx('photo_tech')), tests.fx('u_tech_a'),
                'uploaded_by is the acting user, not the client value');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg')$$,
                    '23505', 'a stored object is registered once');
select tests.throws_like($$insert into public.job_photos (shop_id, job_id, storage_path)
                           values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/a2.jpg')$$,
                         '23514', '%<shop_id>/<job_id>/%', 'the path must be this job''s folder');
select tests.throws_like($$insert into public.job_photos (shop_id, job_id, storage_path)
                           values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/missing.jpg')$$,
                         '23514', '%upload the photo%', 'the object must exist');
select tests.throws_like($$insert into public.job_photos (shop_id, job_id, storage_path)
                           values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/in-wrong-bucket.jpg')$$,
                         '23514', '%upload the photo%', 'the object must be in the job-photos bucket');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/./before-1.jpg')$$,
                    '23514', 'unsafe paths are rejected');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_a'), tests.fx('job_a'), '/' || tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg')$$,
                    '23514', 'absolute paths are rejected');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/a2.jpg')$$,
                    '42501', 'technicians cannot add photos to unassigned jobs');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path, kind)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-2.jpg', 'selfie')$$,
                    '22P02', 'kind is an enum');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', 'after')
  returning tests.fx_set('photo_mgr', id);
insert into public.job_photos (shop_id, job_id, storage_path)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/a2.jpg')
  returning tests.fx_set('photo_a2', id);
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('shop_b') || '/' || tests.fx('job_b') || '/b.jpg')$$,
                    '42501', 'managers cannot add photos to another shop');
select tests.as_service();
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path)
                      values (tests.fx('shop_a'), tests.fx('job_b'), tests.fx('shop_a') || '/' || tests.fx('job_b') || '/b.jpg')$$,
                    '23503', 'composite FK blocks another shop''s job');

-- ------------------------------------------------------------ read
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 2::bigint, 'technician sees photos of assigned jobs only');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 1::bigint, 'the other technician sees only job_a2');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 3::bigint, 'managers see every photo of the shop');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 0::bigint, 'shop B sees none of A''s photos');
select tests.eq(tests.row_count($$update public.job_photos set caption = 'x'$$), 0::bigint, 'shop B edits none of A''s photos');
select tests.eq(tests.row_count($$delete from public.job_photos$$), 0::bigint, 'shop B deletes none of A''s photos');

-- ------------------------------------------------------------ update
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.job_photos set caption = 'Driver door, close-up', kind = 'inspection'
                                   where id = tests.fx('photo_tech')$$), 1::bigint, 'the uploader edits caption and kind');
select tests.throws($$update public.job_photos set storage_path = tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-2.jpg'
                      where id = tests.fx('photo_tech')$$, '42501', 'the file cannot be swapped');
select tests.lives($$update public.job_photos set uploaded_by = tests.fx('u_tech2_a') where id = tests.fx('photo_tech')$$);
select tests.eq((select uploaded_by from public.job_photos where id = tests.fx('photo_tech')), tests.fx('u_tech_a'),
                'uploaded_by is immutable');
select tests.eq(tests.row_count($$update public.job_photos set caption = 'mine now' where id = tests.fx('photo_mgr')$$), 0::bigint,
                'technicians cannot edit other people''s photos');
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('photo_mgr')$$), 0::bigint,
                'technicians cannot delete other people''s photos');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.job_photos set caption = 'Reviewed' where id = tests.fx('photo_tech')$$), 1::bigint,
                'managers edit any photo');
select tests.throws($$update public.job_photos set job_id = tests.fx('job_a2') where id = tests.fx('photo_tech')$$, '42501',
                    'photos do not move between jobs');

-- ------------------------------------------------------------ delete
-- an uploader who is no longer assigned can still remove their own photo
select tests.as_superuser();
delete from public.job_assignments where job_id = tests.fx('job_a') and member_id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 1::bigint, 'unassigned: only own uploads stay visible');
select tests.eq(tests.row_count($$update public.job_photos set caption = 'late edit' where id = tests.fx('photo_tech')$$), 0::bigint,
                'captions are edited only while on the job');
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('photo_tech')$$), 1::bigint,
                'the uploader deletes their own photo while still a member');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('photo_a2')$$), 0::bigint,
                'a technician cannot delete a photo someone else uploaded on their job');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('photo_a2')$$), 1::bigint, 'managers delete any photo');
-- deactivated uploaders lose even their own photos
select tests.as_superuser();
insert into public.job_photos (shop_id, job_id, storage_path, uploaded_by)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-2.jpg', tests.fx('u_tech_a'))
  returning tests.fx_set('photo_old', id);
select tests.eq((select uploaded_by from public.job_photos where id = tests.fx('photo_old')), tests.fx('u_tech_a'),
                'trusted imports may set uploaded_by');
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('photo_old')$$), 0::bigint,
                'former members cannot delete photos');
-- job deletion cascades
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_photos where job_id = tests.fx('job_a')), 0::bigint, 'photos cascade with the job');
select tests.ok(not has_table_privilege('anon', 'public.job_photos', 'select'), 'anon has no photo access');
