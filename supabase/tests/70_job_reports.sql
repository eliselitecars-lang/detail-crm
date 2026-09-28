-- 70 ops: customer-facing job report (P-8) — publish (managers, technicians
-- on the job only when the shop allows it), one live report per job with
-- its own token (never the booking token), the link message, photo
-- visibility, the curated public JSON (no VIN, plate, phone, internal notes,
-- inspection notes or storage paths), first view stamping, remote
-- pre-inspection sign-off (storage folder, signature, lock, notification,
-- once only), signature reads, the media list for the public-media function
-- (service only), revoke, role denials and two-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.vehicles set vin = '1HGCM82633A004352', license_plate = 'ABC123', color = 'Blue' where id = tests.fx('veh_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/other-1.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/hidden-after.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/mark-dent.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/walk-poster.jpg', tests.fx('u_tech_a')),
  ('job-media', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-walkaround.mp4', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_b') || '/' || tests.fx('job_b') || '/b.jpg', tests.fx('u_tech_b')),
  ('documents', tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/warranty.pdf', tests.fx('u_manager_a')),
  ('documents', tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/internal.pdf', tests.fx('u_manager_a'));

select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind, caption) values
  (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/before-1.jpg', 'before', 'Hood before')
  returning tests.fx_set('ph_before', id);
insert into public.job_photos (shop_id, job_id, storage_path, kind, caption) values
  (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/after-1.jpg', 'after', 'Hood after')
  returning tests.fx_set('ph_after', id);
insert into public.job_photos (shop_id, job_id, storage_path, kind) values
  (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/other-1.jpg', 'other')
  returning tests.fx_set('ph_other', id);
insert into public.job_photos (shop_id, job_id, storage_path, kind) values
  (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/hidden-after.jpg', 'after')
  returning tests.fx_set('ph_hidden', id);
insert into public.job_photos (shop_id, job_id, storage_path, kind, media_type, bucket, duration_seconds, poster_path) values
  (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/' || tests.fx('job_a') || '/v-walkaround.mp4', 'after',
   'video', 'job-media', 42, tests.fx('shop_a') || '/' || tests.fx('job_a') || '/walk-poster.jpg')
  returning tests.fx_set('ph_video', id);
select tests.eq((select bool_or(customer_visible) from public.job_photos where job_id = tests.fx('job_a')), false,
                'photos start hidden from the customer');
insert into public.inspections (shop_id, job_id, vehicle_id, kind, mileage, fuel_level, notes)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre', 42000, 50, 'INTERNAL NOTE: customer argued')
  returning tests.fx_set('ins_pre', id);
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, note, photo_path)
  values (tests.fx('shop_a'), tests.fx('ins_pre'), 'front', 0.25, 0.5, 'dent', 'Small dent',
          tests.fx('shop_a') || '/' || tests.fx('job_a') || '/mark-dent.jpg')
  returning tests.fx_set('mark', id);
insert into public.inspections (shop_id, job_id, vehicle_id, kind)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'post') returning tests.fx_set('ins_post', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes, customer_visible)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/warranty.pdf',
          'Warranty.pdf', 'application/pdf', 1200, true) returning tests.fx_set('doc_vis', id);
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/internal.pdf',
          'Internal.pdf', 'application/pdf', 800) returning tests.fx_set('doc_hidden', id);

-- ============================================================ photo visibility
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.set_job_photo_visibility(array[tests.fx('ph_before'), tests.fx('ph_after'), tests.fx('ph_other'),
                                                      tests.fx('ph_video'), tests.fx('ph_before')], true), 4,
                'the technician on the job shows four photos/videos (duplicates counted once)');
select tests.eq((select array_agg(id order by created_at) from public.job_photos where customer_visible),
                array[tests.fx('ph_before'), tests.fx('ph_after'), tests.fx('ph_other'), tests.fx('ph_video')], 'visibility stored');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.set_job_photo_visibility(array[tests.fx('ph_hidden')], true)$$, '42501',
                    'a technician not on the job cannot');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.set_job_photo_visibility(array[tests.fx('ph_hidden')], true)$$, 'P0002',
                    'another shop''s photo is not found');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.set_job_photo_visibility('{}', true)$$, '22023', 'at least one id');
select tests.throws($$select public.set_job_photo_visibility(array[null]::uuid[], true)$$, '22023', 'no null ids');
select tests.throws($$select public.set_job_photo_visibility(array[tests.fx('ph_hidden')], null)$$, '22023', 'visible required');
select tests.throws($$select public.set_job_photo_visibility(array[gen_random_uuid()], true)$$, 'P0002', 'unknown photo');
select tests.throws($$select public.set_job_photo_visibility((select array_agg(gen_random_uuid()) from generate_series(1, 201)), true)$$,
                    '22023', 'at most 200 ids');
select tests.as_anon();
select tests.throws($$select public.set_job_photo_visibility(array[tests.fx('ph_hidden')], true)$$, '42501', 'anon cannot');

-- ============================================================ publish: roles
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.publish_job_report(tests.fx('job_a'))$$, '42501',
                    'technicians cannot share reports unless the shop allows it');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.publish_job_report(tests.fx('job_a'))$$, 'P0002', 'another shop''s job is not found');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.publish_job_report(tests.fx('job_a'))$$, 'P0002', 'an outsider gets not found');
select tests.as_anon();
select tests.throws($$select public.publish_job_report(tests.fx('job_a'))$$, '42501', 'anon cannot publish');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.publish_job_report(tests.fx('job_a'), p_message => repeat('x', 2001))$$, '22023',
                    'message is limited to 2000 characters');
select tests.throws($$select public.publish_job_report(tests.fx('job_a'), p_photo_kinds => null)$$, '22023', 'photo kinds required');
select tests.throws($$select public.publish_job_report(tests.fx('job_a'), p_photo_kinds => array[null]::public.job_photo_kind[])$$,
                    '22023', 'no null photo kinds');
create temp table pub1 as select public.publish_job_report(tests.fx('job_a'), true, '{after,before,after}', '  Thanks for choosing us!  ') as r;
grant select on pub1 to authenticated, anon, service_role;
select tests.fx_set('rep', ((select r from pub1) ->> 'report_id')::uuid);
select tests.fx_set('tok', ((select r from pub1) ->> 'token')::uuid);
select tests.eq((select r -> 'url' from pub1), 'null'::jsonb, 'no link while the platform has no app base URL');
select tests.eq((select r -> 'queued' from pub1), 'false'::jsonb, 'nothing queued');
select tests.eq((select jsonb_build_array(include_inspections, photo_kinds::text, message, published_by = tests.fx('u_manager_a'),
                                          revoked_at is null, first_viewed_at is null)
                   from public.job_reports where id = tests.fx('rep')),
                '[true, "{before,after}", "Thanks for choosing us!", true, true, true]'::jsonb,
                'kinds de-duplicated, message trimmed, publisher stamped');
select tests.as_superuser();
select tests.ok(tests.fx('tok') <> (select public_token from public.jobs where id = tests.fx('job_a')),
                'the report token is its own credential, not the booking token');

-- the shop lets technicians share: the assigned one may, another may not
update public.shops set techs_can_share_reports = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.publish_job_report(tests.fx('job_a'))$$, '42501', 'not a technician who is not on the job');
select tests.authenticate_as(tests.fx('u_tech_a'));
create temp table pub2 as select public.publish_job_report(tests.fx('job_a'), true, '{before,after}', null) as r;
select tests.eq(((select r from pub2) ->> 'report_id')::uuid, tests.fx('rep'), 'publishing again updates the live report');
select tests.eq(((select r from pub2) ->> 'token')::uuid, tests.fx('tok'), 'and keeps its link');
select tests.eq((select array[message is null, published_by = tests.fx('u_tech_a')] from public.job_reports where id = tests.fx('rep')),
                array[true, true], 'message cleared, publisher updated');
select tests.eq(tests.row_count($$select 1 from public.job_reports$$), 1::bigint, 'the sharing technician reads the report row');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.job_reports$$), 0::bigint, 'another technician does not');
select tests.as_superuser();
update public.shops set techs_can_share_reports = false where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_reports$$), 0::bigint,
                'without the setting technicians cannot read the token either');
select tests.throws($$insert into public.job_reports (shop_id, job_id) values (tests.fx('shop_a'), tests.fx('job_a'))$$, '42501',
                    'no direct writes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.job_reports (shop_id, job_id) values (tests.fx('shop_a'), tests.fx('job_a2'))$$, '42501',
                    'not even for managers');
select tests.throws($$update public.job_reports set revoked_at = now()$$, '42501', 'nor direct updates');
select tests.eq(tests.row_count($$select 1 from public.job_reports$$), 1::bigint, 'managers read reports');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_reports$$), 0::bigint, 'shop B reads none of A''s reports');

-- ============================================================ public JSON
select tests.as_anon();
create temp table rep1 as select public.public_get_job_report(tests.fx('tok')) as j;
select tests.eq((select j -> 'shop' ->> 'name' from rep1), 'Shop A', 'shop name');
select tests.as_superuser();
select tests.eq((select j -> 'job' from rep1) - 'completed_at' - 'local_date',
                jsonb_build_object('number', (select number from public.jobs where id = tests.fx('job_a')), 'status', 'completed'),
                'job number and status');
select tests.as_anon();
select tests.ok((select (j -> 'job' ->> 'local_date')::date is not null and j -> 'job' ->> 'completed_at' is not null from rep1),
                'completion time and local date');
select tests.eq((select j -> 'vehicle' from rep1), '{"year": 2021, "make": "Honda", "model": "Civic", "color": "Blue"}'::jsonb,
                'vehicle without VIN or plate');
select tests.eq((select j -> 'services' from rep1), '["Full Detail"]'::jsonb, 'services by line name');
select tests.eq((select array_agg(p ->> 'id' order by p ->> 'id') from rep1, jsonb_array_elements(j -> 'photos') p),
                (select array_agg(x::text order by x::text) from unnest(array[tests.fx('ph_before'), tests.fx('ph_after'), tests.fx('ph_video')]) x),
                'only customer-visible photos of the chosen kinds (the "other" photo and the hidden one are left out)');
select tests.eq((select p - 'id' - 'created_at' from rep1, jsonb_array_elements(j -> 'photos') p where p ->> 'id' = tests.fx('ph_video')::text),
                '{"kind": "after", "caption": null, "media_type": "video", "duration_seconds": 42, "has_poster": true}'::jsonb,
                'a video entry');
select tests.eq((select jsonb_array_length(j -> 'inspections') from rep1), 2, 'both inspections included');
select tests.eq((select i - 'id' - 'marks' from rep1, jsonb_array_elements(j -> 'inspections') i where i ->> 'kind' = 'pre'),
                '{"kind": "pre", "mileage": 42000, "fuel_level": 50, "signed_at": null, "signed_by_name": null,
                  "signed_remotely": false, "can_acknowledge": true}'::jsonb, 'the pre inspection can be acknowledged');
select tests.eq((select i -> 'can_acknowledge' from rep1, jsonb_array_elements(j -> 'inspections') i where i ->> 'kind' = 'post'),
                'false'::jsonb, 'the post inspection cannot');
select tests.eq((select i -> 'marks' from rep1, jsonb_array_elements(j -> 'inspections') i where i ->> 'kind' = 'pre'),
                jsonb_build_array(jsonb_build_object('id', tests.fx('mark'), 'view', 'front', 'x', 0.25, 'y', 0.5, 'damage', 'dent',
                                                     'note', 'Small dent', 'has_photo', true)),
                'marks with a has_photo flag');
select tests.eq((select j -> 'documents' from rep1),
                jsonb_build_array(jsonb_build_object('id', tests.fx('doc_vis'), 'file_name', 'Warranty.pdf',
                                                     'content_type', 'application/pdf', 'size_bytes', 1200)),
                'only customer-visible documents');
select tests.eq((select j ->> 'signature_upload_prefix' from rep1),
                tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/', 'where to upload a sign-off');
select tests.ok((select j::text not like '%1HGCM82633A004352%' and j::text not like '%ABC123%'
                        and j::text not like '%2055550101%' and j::text not like '%INTERNAL NOTE%'
                        and j::text not like '%Gate code%' and j::text not like '%picky%'
                        and j::text not like '%.jpg%' and j::text not like '%.mp4%' and j::text not like '%/jobs/%'
                        and j::text not like '%' || tests.fx('job_a')::text || '%'
                        and j::text not like '%alice@example.com%' from rep1),
                'no VIN, plate, customer phone or email, internal/job notes, inspection notes, storage paths or job id');
select tests.as_superuser();
select tests.ok((select first_viewed_at is not null from public.job_reports where id = tests.fx('rep')),
                'the customer''s first view is stamped');
update public.job_reports set first_viewed_at = null where id = tests.fx('rep');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.public_get_job_report(tests.fx('tok'))$$, 'staff may preview the report');
select tests.as_superuser();
select tests.ok((select first_viewed_at is null from public.job_reports where id = tests.fx('rep')), 'a staff preview is not a view');
select tests.as_anon();
select tests.throws_like($$select public.public_get_job_report(gen_random_uuid())$$, 'PT404', '%not found%', 'unknown token');
select tests.throws($$select public.public_get_job_report(null)$$, 'PT404', 'null token');
select tests.throws($$select public.public_get_job_report((select public_token from public.jobs limit 1))$$, '42501',
                    'anon cannot even read the jobs table');

-- inspections left out of a report hide them (and their media)
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.publish_job_report(tests.fx('job_a'), false, '{after}');
select tests.as_anon();
select tests.eq((select jsonb_build_array(jsonb_array_length(j -> 'inspections'), jsonb_array_length(j -> 'photos'),
                                          j -> 'signature_upload_prefix')
                   from (select public.public_get_job_report(tests.fx('tok')) as j) x),
                jsonb_build_array(0, 2, null), 'no inspections, only "after" media');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'no sign-off upload while inspections are not part of the report');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice', 'x')$$, '22023',
                         '%not part of the job report%', 'no sign-off either');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.publish_job_report(tests.fx('job_a'));

-- ============================================================ media list (public-media function)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select * from public.job_report_media(tests.fx('tok'))$$, '42501', 'staff cannot call the media list');
select tests.as_anon();
select tests.throws($$select * from public.job_report_media(tests.fx('tok'))$$, '42501', 'nor anon');
select tests.as_service();
select tests.eq((select array_agg(kind || ' ' || bucket || ' ' || replace(path, tests.fx('shop_a') || '/', '') order by kind, path)
                   from public.job_report_media(tests.fx('tok'))),
                array['document documents jobs/' || tests.fx('job_a') || '/warranty.pdf',
                      'mark_photo job-photos ' || tests.fx('job_a') || '/mark-dent.jpg',
                      'photo job-photos ' || tests.fx('job_a') || '/after-1.jpg',
                      'photo job-photos ' || tests.fx('job_a') || '/before-1.jpg',
                      'poster job-photos ' || tests.fx('job_a') || '/walk-poster.jpg',
                      'video job-media ' || tests.fx('job_a') || '/v-walkaround.mp4'],
                'visible photos, the video and its poster, mark photos and visible documents');
select tests.eq((select ref_id from public.job_report_media(tests.fx('tok')) where kind = 'poster'), tests.fx('ph_video'),
                'a poster is referenced by its video');
select tests.eq(tests.row_count($$select * from public.job_report_media(gen_random_uuid())$$), 0::bigint, 'unknown token: nothing');

-- ============================================================ remote sign-off
-- the upload folder: exactly <shop>/reports/<token>/<file> of a live report
select tests.as_anon();
select tests.ok(public.public_report_signature_upload_allowed(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'the report folder accepts a sign-off upload');
select tests.ok(not public.public_report_signature_upload_allowed(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/x/sig.png'),
                'not in a sub-folder');
select tests.ok(not public.public_report_signature_upload_allowed(tests.fx('shop_b') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'not under another shop');
select tests.ok(not public.public_report_signature_upload_allowed(tests.fx('shop_a') || '/reports/' || gen_random_uuid() || '/sig.png'),
                'not for an unknown token');
select tests.ok(not public.public_report_signature_upload_allowed(tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png'),
                'not in the forms folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/reports/' || gen_random_uuid() || '/sig.png')$$,
                    '42501', 'anon cannot upload under another token');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('job-photos', tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'nor into another bucket');
select tests.lives($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$,
                   'the customer uploads the signature image');

-- technicians (the report folder carries the token)
select tests.as_superuser();
update public.shops set techs_can_share_reports = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok(public.can_read_signature_object(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'a technician on the job who may share reports reads the pending sign-off');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.ok(not public.can_read_signature_object(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'a technician not on the job cannot');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name like '%/reports/%'$$), 0::bigint,
                'nor list it');
select tests.as_superuser();
update public.shops set techs_can_share_reports = false where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok(not public.can_read_signature_object(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'nor one who may not share reports');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(public.can_read_signature_object(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'managers read it');
-- staff below manager never sign as the customer through the link
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice',
                        tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '42501',
                    'a technician cannot sign as the customer');

select tests.as_anon();
select tests.throws_like($$select public.public_ack_inspection(gen_random_uuid(), tests.fx('ins_pre'), 'Alice', 'x')$$,
                         'PT404', '%not found%', 'unknown token');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_post'), 'Alice',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '22023', '%pre-service%',
                         'only the pre inspection');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), gen_random_uuid(), 'Alice',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '22023', '%not part%',
                         'not another inspection');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), '  ',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '22023', '%signer name%',
                         'a name is required');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice',
                            tests.fx('shop_a') || '/sig.png')$$, '22023', '%directly under%', 'outside the report folder');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/missing.png')$$, '22023', '%upload the signature%',
                         'the image must be uploaded first');
create temp table ack as
  select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), ' Alice Anders ',
                                      tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png') as j;
select tests.eq((select i -> 'can_acknowledge' from ack, jsonb_array_elements(j -> 'inspections') i where i ->> 'kind' = 'pre'),
                'false'::jsonb, 'the returned report shows the inspection signed');
select tests.eq((select j -> 'signature_upload_prefix' from ack), 'null'::jsonb, 'and no more uploads');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(customer_signature_path, signed_by_name, signed_at is not null, signed_remotely)
                   from public.inspections where id = tests.fx('ins_pre')),
                jsonb_build_array(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png', 'Alice Anders', true, true),
                'signature stored, signed remotely');
select tests.eq((select array_agg(u.email::text order by u.email)
                   from public.notifications n join auth.users u on u.id = n.user_id
                  where n.shop_id = tests.fx('shop_a') and n.kind = 'inspection_acknowledged'
                    and n.job_id = tests.fx('job_a') and n.customer_id = tests.fx('cust_a')),
                array['admin-a@test.local', 'manager-a@test.local', 'owner-a@test.local'],
                'owners, admins and managers are notified');
select tests.as_anon();
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '22023', '%already been signed%',
                         'the sign-off cannot repeat');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig2.png')$$,
                    '42501', 'the folder is closed once nothing is left to sign');
-- the existing signed-inspection lock applies
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.inspections set mileage = 1 where id = tests.fx('ins_pre')$$, '42501', 'signed and locked');
select tests.ok(public.can_read_signature_object(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'the signed image is readable by the technician on the job (through the inspection)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null
                     where id = tests.fx('ins_pre')$$, 'a manager can remove the signature');
select tests.eq((select signed_remotely from public.inspections where id = tests.fx('ins_pre')), false,
                'which clears signed_remotely');
-- signed_remotely is server-set
select tests.lives($$update public.inspections set signed_remotely = true where id = tests.fx('ins_post')$$);
select tests.eq((select signed_remotely from public.inspections where id = tests.fx('ins_post')), false,
                'clients cannot set signed_remotely');
select tests.as_service();
update public.inspections set signed_remotely = true where id = tests.fx('ins_post');
select tests.eq((select signed_remotely from public.inspections where id = tests.fx('ins_post')), false,
                'an unsigned inspection is never signed remotely, whoever writes it');

-- a cancelled job's pre-inspection cannot be acknowledged
select tests.as_superuser();
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
update public.jobs set status = 'cancelled' where id = tests.fx('job_a');
select tests.as_anon();
select tests.ok(not public.public_report_signature_upload_allowed(tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig3.png'),
                'no uploads for a cancelled appointment');
select tests.throws_like($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins_pre'), 'Alice',
                            tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$, '22023', '%cancelled%',
                         'no sign-off either');

-- ============================================================ sending the link
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550170', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550170' where id = tests.fx('shop_a');
-- a shop without job_report wording (comms 0083 seeds it; removed here)
delete from public.message_templates where shop_id = tests.fx('shop_a') and key = 'job_report';
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pub3 as select public.publish_job_report(tests.fx('job_a'), p_send => true) as r;
select tests.eq((select r ->> 'url' from pub3), 'https://app.example.test/r/' || tests.fx('tok'), 'the link');
select tests.eq((select r -> 'queued' from pub3), 'false'::jsonb, 'no job_report template yet: nothing queued, no error');
select tests.as_superuser();
insert into public.message_templates (shop_id, key, channel, body)
  values (tests.fx('shop_a'), 'job_report', 'sms', 'Your job report is ready: {{report_link}}');
insert into public.message_templates (shop_id, key, channel, subject, body)
  values (tests.fx('shop_a'), 'job_report', 'email', 'Your job report', 'See {{report_link}}');
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pub4 as select public.publish_job_report(tests.fx('job_a'), p_send => true, p_channel => 'sms') as r;
select tests.eq((select r -> 'queued' from pub4), 'true'::jsonb, 'queued by SMS');
select tests.eq((select array_agg(channel::text || ' ' || to_address || ' ' || body order by channel)
                   from public.messages where shop_id = tests.fx('shop_a') and template_key = 'job_report'),
                array['sms +12055550101 Your job report is ready: https://app.example.test/r/' || tests.fx('tok')],
                'the customer gets the report link');
select public.publish_job_report(tests.fx('job_a'), p_send => true);
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_a') and template_key = 'job_report'),
                3::bigint, 'without a channel every enabled channel is used');
select tests.eq((select sent_by from public.messages where template_key = 'job_report' and channel = 'email'),
                tests.fx('u_manager_a'), 'sent by the publisher');

-- ============================================================ revoke
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.revoke_job_report(tests.fx('rep'))$$, '42501', 'technicians cannot revoke');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.revoke_job_report(tests.fx('rep'))$$, 'P0002', 'another shop cannot');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.revoke_job_report(gen_random_uuid())$$, 'P0002', 'unknown report');
select tests.as_superuser();
delete from public.storage_purge_requests where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.revoke_job_report(tests.fx('rep'))$$, 'managers revoke');
select tests.lives($$select public.revoke_job_report(tests.fx('rep'))$$, 'revoking twice is harmless');
select tests.eq((select array_agg(distinct status::text || ' ' || error) from public.messages
                  where shop_id = tests.fx('shop_a') and template_key = 'job_report'),
                array['cancelled the job report link was withdrawn'], 'the queued link messages are withdrawn with it');
select tests.as_anon();
select tests.throws($$select public.public_get_job_report(tests.fx('tok'))$$, 'PT404', 'a revoked link is dead');
select tests.as_service();
select tests.eq(tests.row_count($$select * from public.job_report_media(tests.fx('tok'))$$), 0::bigint, 'and shows no media');
select tests.eq((select array_agg(bucket_id || ' ' || replace(path, tests.fx('shop_a')::text, 'S') || ' ' || reason)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a')),
                array['signatures S/reports/' || tests.fx('tok') || '/ report_revoked'], 'its sign-off folder is queued for the purge');
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pub5 as select public.publish_job_report(tests.fx('job_a')) as r;
select tests.ok(((select r from pub5) ->> 'token')::uuid <> tests.fx('tok'), 'publishing after a revoke issues a new link');
select tests.eq((select count(*) from public.job_reports where job_id = tests.fx('job_a')), 2::bigint, 'the revoked one is kept');

-- deleting the job removes its reports and queues their folders
select tests.as_superuser();
delete from public.storage_purge_requests where shop_id = tests.fx('shop_a');
delete from public.job_assignments where job_id = tests.fx('job_a');
delete from public.inspection_marks where inspection_id in (select id from public.inspections where job_id = tests.fx('job_a'));
delete from public.inspections where job_id = tests.fx('job_a');
delete from public.messages where job_id = tests.fx('job_a');
delete from public.jobs where id = tests.fx('job_a');
select tests.eq((select count(*) from public.storage_purge_requests
                  where shop_id = tests.fx('shop_a') and bucket_id = 'signatures' and path like '%/reports/%' and reason = 'job_deleted'),
                2::bigint, 'both report folders of the deleted job are queued');
