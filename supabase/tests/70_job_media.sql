-- 70 ops: job videos (P-30) — the job-media bucket and its storage policies
-- per role, video rows (media type / bucket consistency, 'v-' names, the
-- object in the row's own bucket, the poster frame, duration), media
-- columns fixed after insert, the storage purge for videos and posters,
-- in-use protection, the public report's media list, isolation.
\ir fixtures/two_shops.psql
delete from public.storage_purge_requests;

select tests.eq((select jsonb_build_array(public, file_size_limit, allowed_mime_types) from storage.buckets where id = 'job-media'),
                '[false, 209715200, ["video/mp4", "video/quicktime"]]'::jsonb, 'job-media: private, 200 MiB, mp4 / quicktime');

create temp table p (key text primary key, path text not null);
grant select on p to anon, authenticated, service_role;
insert into p values
  ('a',      tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-walk.mp4'),
  ('a_mgr',  tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-final.mov'),
  ('a2',     tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/v-other.mp4'),
  ('noprefix', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/walk.mp4'),
  ('deep',   tests.fx('shop_a') || '/' || tests.fx('job_a') || '/x/v-deep.mp4'),
  ('b',      tests.fx('shop_b') || '/' || tests.fx('job_b') || '/v-b.mp4');

-- ============================================================ storage
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('job-media', (select path from p where key = 'a'), auth.uid(), auth.uid()::text)$$,
                   'the assigned technician uploads a video');
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('job-media', (select path from p where key = 'noprefix'), auth.uid(), auth.uid()::text)$$);
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'a2'), auth.uid())$$,
                    '42501', 'not to an unassigned job');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'deep'), auth.uid())$$,
                    '42501', 'directly inside the job folder only');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'b'), auth.uid())$$,
                    '42501', 'not into another shop');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'a_mgr'), auth.uid())$$,
                   'managers upload to any job');
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'a2'), auth.uid())$$);
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-media', (select path from p where key = 'b'), auth.uid())$$);
select tests.as_anon();
select tests.throws($$insert into storage.objects (bucket_id, name) values ('job-media', (select path from p where key = 'a') || '.x')$$,
                    '42501', 'anon cannot upload');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-media'$$), 0::bigint, 'nor read');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-media'$$), 3::bigint,
                'the technician reads the videos of assigned jobs');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'job-media' and name = (select path from p where key = 'a_mgr')$$),
                0::bigint, 'but cannot overwrite someone else''s');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'job-media' and name = (select path from p where key = 'a_mgr')$$),
                0::bigint, 'nor delete it');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'job-media' and name = (select path from p where key = 'noprefix')$$),
                1::bigint, 'the uploader deletes their own');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-media'$$), 1::bigint, 'the other technician only job_a2''s');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-media'$$), 1::bigint, 'shop B only its own');

select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster2.jpeg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.png', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/poster.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-in-wrong-bucket.mp4', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/photo.jpg', tests.fx('u_tech_a'));

-- ============================================================ rows
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a'), 'before', 'video')$$,
                    '23514', 'a video lives in job-media (bucket and media type agree)');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path, kind, bucket)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a'), 'before', 'job-media')$$,
                    '23514', 'and job-media holds videos only');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a'), 'before', 'audio')$$,
                    '23514', 'media types are image or video');
select tests.throws_like(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket)
                      values (%L, %L, %L, 'before', 'video', 'job-media')$$, tests.fx('shop_a'), tests.fx('job_a'),
                      tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-in-wrong-bucket.mp4'),
                         '23514', '%upload the video%', 'the object must exist in job-media, not job-photos');
select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('job-media', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/walk.mp4', tests.fx('u_tech_a'));
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'noprefix'), 'before', 'video', 'job-media')$$,
                         '23514', '%v-<file>%', 'video names start with v-');
select tests.throws_like($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a2'), 'before', 'video', 'job-media')$$,
                         '23514', '%<shop_id>/<job_id>/%', 'in the job''s own folder');
select tests.throws($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, duration_seconds)
                      values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a'), 'before', 'video', 'job-media', 601)$$,
                    '23514', 'at most 10 minutes');
select tests.throws_like(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, poster_path)
                      values (%L, %L, %L, 'before', 'video', 'job-media', %L)$$, tests.fx('shop_a'), tests.fx('job_a'),
                      (select path from p where key = 'a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.png'),
                         '23514', '%JPEG%', 'the poster is a JPEG');
select tests.throws_like(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, poster_path)
                      values (%L, %L, %L, 'before', 'video', 'job-media', %L)$$, tests.fx('shop_a'), tests.fx('job_a'),
                      (select path from p where key = 'a'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/poster.jpg'),
                         '23514', '%JPEG%', 'of the same job');
select tests.throws_like(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, poster_path)
                      values (%L, %L, %L, 'before', 'video', 'job-media', %L)$$, tests.fx('shop_a'), tests.fx('job_a'),
                      (select path from p where key = 'a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/missing.jpg'),
                         '23514', '%upload the poster%', 'that exists');
select tests.throws(format($$insert into public.job_photos (shop_id, job_id, storage_path, kind, poster_path)
                      values (%L, %L, %L, 'before', %L)$$, tests.fx('shop_a'), tests.fx('job_a'),
                      tests.fx('shop_a') || '/' || tests.fx('job_a') || '/photo.jpg', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.jpg'),
                    '23514', 'photos have no poster');
insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, duration_seconds, poster_path, caption)
  values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'a'), 'before', 'video', 'job-media', 95,
          tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.jpg', 'Walk-around')
  returning tests.fx_set('vid', id);
select tests.eq((select jsonb_build_array(media_type, bucket, duration_seconds, uploaded_by = tests.fx('u_tech_a'))
                   from public.job_photos where id = tests.fx('vid')),
                '["video", "job-media", 95, true]'::jsonb, 'the technician saves the video');
insert into public.job_photos (shop_id, job_id, storage_path, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/photo.jpg', 'before')
  returning tests.fx_set('img', id);
select tests.eq((select jsonb_build_array(media_type, bucket) from public.job_photos where id = tests.fx('img')),
                '["image", "job-photos"]'::jsonb, 'photos default to an image in job-photos');
select tests.throws($$update public.job_photos set media_type = 'image', bucket = 'job-photos', duration_seconds = null, poster_path = null
                      where id = tests.fx('vid')$$, '42501', 'the media type is fixed');
select tests.lives($$update public.job_photos set caption = 'Walk-around (driver side)', duration_seconds = 96 where id = tests.fx('vid')$$,
                   'the caption and length stay editable');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.job_photos where media_type = 'video'$$), 0::bigint,
                'another technician does not see the video');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_photos$$), 0::bigint, 'nor does shop B');

-- ============================================================ in use / purge
select tests.as_service();
select tests.ok(public.storage_object_in_use('job-media', (select path from p where key = 'a')), 'a saved video is in use');
select tests.ok(public.storage_object_in_use('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster.jpg'),
                'so is its poster');
select tests.ok(not public.storage_object_in_use('job-media', (select path from p where key = 'a_mgr')), 'an unsaved video is not');
select tests.ok(not public.storage_object_in_use('job-photos', (select path from p where key = 'a')),
                'the bucket matters: the same name in job-photos is not the video');
-- the public report lists the visible video and its poster
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_photo_visibility(array[tests.fx('vid')], true);
create temp table rep as select public.publish_job_report(tests.fx('job_a'), p_photo_kinds => '{before}') as r;
grant select on rep to service_role;
select tests.as_service();
select tests.eq((select array_agg(kind || ' ' || bucket order by kind) from public.job_report_media(((select r from rep) ->> 'token')::uuid)),
                array['poster job-photos', 'video job-media'], 'the report shows the video and its poster');

select tests.authenticate_as(tests.fx('u_tech_a'));
update public.job_photos set poster_path = tests.fx('shop_a') || '/' || tests.fx('job_a') || '/poster2.jpeg' where id = tests.fx('vid');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || replace(path, tests.fx('shop_a') || '/' || tests.fx('job_a') || '/', '') || ' ' || reason)
                   from public.storage_purge_requests),
                array['job-photos poster.jpg media_deleted'], 'a replaced poster is queued');
delete from public.storage_purge_requests;
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('img')$$), 1::bigint, 'the uploader deletes a photo');
select tests.eq(tests.row_count($$delete from public.job_photos where id = tests.fx('vid')$$), 1::bigint, 'and the video');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || replace(path, tests.fx('shop_a') || '/' || tests.fx('job_a') || '/', '') || ' ' || reason
                                  order by bucket_id)
                   from public.storage_purge_requests),
                array['job-media v-walk.mp4 media_deleted', 'job-photos poster2.jpeg media_deleted'],
                'a deleted video queues its file and poster (a deleted photo keeps its file, as before)');
delete from public.storage_purge_requests;
select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('job-media', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/v-left.mp4', tests.fx('u_manager_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/v-left.mp4', 'after', 'video', 'job-media');
delete from public.jobs where id = tests.fx('job_a2');
select tests.eq((select array_agg(bucket_id || ' ' || is_prefix::text || ' ' || reason order by bucket_id) from public.storage_purge_requests),
                array['documents true job_deleted', 'job-media true job_deleted', 'job-photos true job_deleted'],
                'a deleted job queues its folders (its video rows add nothing on top)');
select tests.as_service();
select tests.eq((select array_agg(object_name order by object_name) from public.claim_storage_purge(100, '2030-01-01Z') where bucket_id = 'job-media'),
                array[tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/v-left.mp4', (select path from p where key = 'a2')],
                'the worker removes the deleted job''s videos');
