-- 20 field ops: storage buckets and storage.objects policies — bucket
-- config (privacy, size, MIME), shop folder membership, job folder
-- assignment for technicians, uploader/manager deletes, public form
-- signature uploads by token, signature reads scoped to the technician's
-- jobs, signed evidence locked in storage, admin-only public shop assets.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ buckets
select tests.eq((select array_agg(id::text || ':' || public::text order by id) from storage.buckets
                  where id in ('job-photos', 'signatures', 'shop-assets')),
                array['job-photos:false', 'shop-assets:true', 'signatures:false'], 'buckets exist with the right visibility');
select tests.eq((select file_size_limit from storage.buckets where id = 'job-photos'), 20971520::bigint, 'job photos up to 20 MB');
select tests.eq((select file_size_limit from storage.buckets where id = 'signatures'), 2097152::bigint, 'signatures up to 2 MB');
select tests.eq((select file_size_limit from storage.buckets where id = 'shop-assets'), 5242880::bigint, 'shop assets up to 5 MB');
select tests.eq((select allowed_mime_types from storage.buckets where id = 'job-photos'),
                array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'], 'job photo types');
select tests.eq((select allowed_mime_types from storage.buckets where id = 'signatures'),
                array['image/png', 'image/jpeg', 'image/webp'], 'signature types');
select tests.eq((select allowed_mime_types from storage.buckets where id = 'shop-assets'),
                array['image/png', 'image/jpeg', 'image/webp'], 'shop asset types (no SVG)');
select tests.ok(not exists (select 1 from storage.buckets b, unnest(b.allowed_mime_types) t
                            where b.id in ('job-photos', 'signatures', 'shop-assets') and t like '%svg%'),
                'no scriptable image types are accepted');

-- helper: path of a job photo
create temporary table paths (key text primary key, path text not null);
grant select on paths to anon, authenticated, service_role;
insert into paths values
  ('a_job_a',     tests.fx('shop_a') || '/' || tests.fx('job_a')  || '/tech.jpg'),
  ('a_job_a_mgr', tests.fx('shop_a') || '/' || tests.fx('job_a')  || '/manager.jpg'),
  ('a_job_a2',    tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/tech2.jpg'),
  ('a_job_b',     tests.fx('shop_a') || '/' || tests.fx('job_b')  || '/x.jpg'),
  ('b_job_b',     tests.fx('shop_b') || '/' || tests.fx('job_b')  || '/b.jpg'),
  ('a_root',      tests.fx('shop_a') || '/loose.jpg'),
  ('a_traversal', tests.fx('shop_a') || '/' || tests.fx('job_a')  || '/../x.jpg'),
  ('not_uuid',    'shop-a/' || tests.fx('job_a') || '/x.jpg');

-- ------------------------------------------------------------ job-photos: upload
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id)
                     values ('job-photos', (select path from paths where key = 'a_job_a'), auth.uid(), auth.uid()::text)$$,
                   'assigned technician uploads to their job folder');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_job_a2'), auth.uid())$$,
                    '42501', 'not to an unassigned job');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'b_job_b'), auth.uid())$$,
                    '42501', 'not to another shop');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_root'), auth.uid())$$,
                    '42501', 'not outside a job folder');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_traversal'), auth.uid())$$,
                    '42501', 'no path traversal');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'not_uuid'), auth.uid())$$,
                    '42501', 'the first folder must be a shop id');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_job_a_mgr'), auth.uid())$$,
                   'managers upload to any job of the shop');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_job_b'), auth.uid())$$,
                    '42501', 'the job folder must be a job of that shop');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'b_job_b'), auth.uid())$$,
                    '42501', 'managers cannot upload into another shop');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'a_job_a2'), auth.uid())$$);
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('job-photos', (select path from paths where key = 'b_job_b'), auth.uid())$$);
select tests.as_anon();
select tests.throws($$insert into storage.objects (bucket_id, name) values ('job-photos', (select path from paths where key = 'a_job_a') || '.anon')$$,
                    '42501', 'anon cannot upload job photos');

-- ------------------------------------------------------------ job-photos: read
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 0::bigint, 'anon reads no job photos');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 2::bigint,
                'technician reads the photos of assigned jobs');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 1::bigint, 'the other technician only job_a2');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 3::bigint, 'managers read all of shop A');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 1::bigint, 'shop B reads only its own');

-- ------------------------------------------------------------ job-photos: overwrite / delete
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update storage.objects set metadata = '{"size": 1}' where name = (select path from paths where key = 'a_job_a')$$),
                1::bigint, 'the uploader may overwrite their own object');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{"size": 1}' where name = (select path from paths where key = 'a_job_a_mgr')$$),
                0::bigint, 'but not someone else''s');
select tests.eq(tests.row_count($$delete from storage.objects where name = (select path from paths where key = 'a_job_a_mgr')$$), 0::bigint,
                'technicians cannot delete others'' photos');
select tests.throws($$update storage.objects set name = (select path from paths where key = 'a_job_a2') where name = (select path from paths where key = 'a_job_a')$$,
                    '42501', 'objects cannot be moved into an unassigned job folder');
-- unassigned uploaders still see and remove their own objects
select tests.as_superuser();
delete from public.job_assignments where job_id = tests.fx('job_a') and member_id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'job-photos'$$), 1::bigint,
                'after unassignment only own uploads remain visible');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where name = (select path from paths where key = 'a_job_a')$$),
                0::bigint, 'overwrite requires being on the job');
select tests.eq(tests.row_count($$delete from storage.objects where name = (select path from paths where key = 'a_job_a')$$), 1::bigint,
                'the uploader deletes their own photo');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from storage.objects where name = (select path from paths where key = 'a_job_a_mgr')$$), 0::bigint,
                'shop B deletes nothing of A');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from storage.objects where name = (select path from paths where key = 'a_job_a2')$$), 1::bigint,
                'managers delete any photo of the shop');

-- ------------------------------------------------------------ signatures: staff
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('signatures', tests.fx('shop_a') || '/device/s1.png', auth.uid())$$,
                   'any member uploads signatures under the shop folder');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('signatures', tests.fx('shop_b') || '/device/s1.png', auth.uid())$$,
                    '42501', 'not under another shop');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('signatures', 's1.png', auth.uid())$$,
                    '42501', 'not at the bucket root');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 1::bigint,
                'the uploader reads their own signature back');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures'$$), 0::bigint, 'technicians cannot delete signatures');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'signatures'$$), 0::bigint,
                'technicians cannot overwrite signatures');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint,
                'other technicians cannot list a member''s unreferenced signature uploads');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint, 'shop B reads none of A''s signatures');
select tests.as_anon();
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint, 'anon reads no signatures');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures'$$), 0::bigint, 'anon deletes no signatures');

-- ------------------------------------------------------------ signatures: public form signers
select tests.as_superuser();
insert into public.form_templates (shop_id, name, body, attach_to) values (tests.fx('shop_a'), 'Waiver', 'Waiver text.', 'all_jobs');
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested')
  returning tests.fx_set('job_form', id);
select tests.fx_set('tok', (select public_token from public.form_submissions where job_id = tests.fx('job_form')));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested')
  returning tests.fx_set('job_form2', id);
select tests.fx_set('tok2', (select public_token from public.form_submissions where job_id = tests.fx('job_form2')));

select tests.as_anon();
select tests.lives($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png')$$,
                   'anon uploads a signature into the token folder of an unsigned form');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || gen_random_uuid() || '/sig.png')$$,
                    '42501', 'unknown token folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_b') || '/forms/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'the token must belong to the shop folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/a/sig.png')$$,
                    '42501', 'files sit directly in the token folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/other/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'only the forms folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('job-photos', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'only the signatures bucket');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/device/x.png')$$,
                    '42501', 'anon cannot write elsewhere in the shop folder');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'signatures'$$), 0::bigint,
                'anon cannot overwrite (upsert) signatures');
select public.public_sign_form(tests.fx('tok'), 'Alice Anders', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/again.png')$$,
                    '42501', 'no uploads once the form is signed');
-- void forms accept no uploads
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled' where id = tests.fx('job_form2');
select tests.as_anon();
select tests.throws($$insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok2') || '/sig.png')$$,
                    '42501', 'no uploads for void forms');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'requested' where id = tests.fx('job_form2');
-- signed-in clients (portal) use the same token rule
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('client@example.com'));
select tests.authenticate_as(tests.fx('u_client'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok2') || '/sig.png', auth.uid())$$,
                   'a portal client uploads by token');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('signatures', tests.fx('shop_a') || '/device/c.png', auth.uid())$$,
                    '42501', 'clients are not staff');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint,
                'clients cannot read signatures back');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 3::bigint, 'staff read all shop signatures');
select tests.eq(tests.row_count($$delete from storage.objects where name = tests.fx('shop_a') || '/device/s1.png'$$), 1::bigint,
                'managers delete signatures');

-- ------------------------------------------------------------ shop-assets
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('shop-assets', tests.fx('shop_a') || '/logo.png', auth.uid())$$,
                   'admins upload shop assets');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('shop-assets', tests.fx('shop_b') || '/logo.png', auth.uid())$$,
                    '42501', 'not for another shop');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('shop-assets', tests.fx('shop_a') || '/services/wash.jpg', auth.uid())$$,
                   'owners upload shop assets');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('shop-assets', tests.fx('shop_a') || '/m.png', auth.uid())$$,
                    '42501', 'managers cannot upload shop assets');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint, 'managers cannot delete shop assets');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('shop-assets', tests.fx('shop_a') || '/t.png', auth.uid())$$,
                    '42501', 'technicians cannot upload shop assets');
select tests.as_anon();
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'shop-assets'$$), 2::bigint, 'shop assets are public');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('shop-assets', tests.fx('shop_a') || '/anon.png')$$,
                    '42501', 'anon cannot upload shop assets');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint, 'anon cannot delete shop assets');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'shop-assets'$$), 0::bigint,
                'admins of B cannot overwrite A''s assets');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'shop-assets'$$), 0::bigint,
                'admins of B cannot delete A''s assets');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update storage.objects set metadata = '{"v": 2}' where name = tests.fx('shop_a') || '/logo.png'$$), 1::bigint,
                'admins replace assets');
select tests.throws($$update storage.objects set name = tests.fx('shop_b') || '/logo.png' where name = tests.fx('shop_a') || '/logo.png'$$,
                    '42501', 'assets cannot be moved into another shop');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'shop-assets'$$), 2::bigint, 'admins delete assets');

-- ------------------------------------------------------------ signatures: technicians read only their jobs' signatures
-- Regression: a technician could list every object in the shop's signatures
-- folder, read public form tokens from '<shop>/forms/<token>/...' names and
-- open (or sign) forms of jobs not assigned to them.
select tests.authenticate_as(tests.fx('u_owner_a'));
insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Release', 'I agree')
  returning tests.fx_set('ft_leak', id);
-- a form on job_a2 (assigned to tech2_a only; customer Aaron Other) that the customer signs...
insert into public.form_submissions (shop_id, job_id, form_template_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('ft_leak'))
  returning tests.fx_set('fs_leak', id);
-- ...and one whose signature the customer uploaded but has not submitted yet
insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Pending release', 'I agree')
  returning tests.fx_set('ft_pending', id);
insert into public.form_submissions (shop_id, job_id, form_template_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('ft_pending'))
  returning tests.fx_set('fs_pending', id);
select tests.as_superuser();
select tests.fx_set('tok_leak', (select public_token from public.form_submissions where id = tests.fx('fs_leak')));
select tests.fx_set('tok_pending', (select public_token from public.form_submissions where id = tests.fx('fs_pending')));
select tests.as_anon();
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a')::text || '/forms/' || tests.fx('tok_leak')::text || '/sig.png');
select public.public_sign_form(tests.fx('tok_leak'), 'Aaron Other', tests.fx('shop_a')::text || '/forms/' || tests.fx('tok_leak')::text || '/sig.png');
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a')::text || '/forms/' || tests.fx('tok_pending')::text || '/sig.png');
-- a manager collects a signature on device for job_a2 (staff path, not the token folder)
select tests.as_superuser();
insert into public.form_submissions (shop_id, job_id, customer_id, title, body_snapshot)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a2'), 'Pickup', 'Returned')
  returning tests.fx_set('fs_device', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', tests.fx('shop_a') || '/device/job-a2.png', auth.uid(), auth.uid()::text);
select public.sign_form_submission(tests.fx('fs_device'), 'Aaron Other', tests.fx('shop_a') || '/device/job-a2.png');

select tests.authenticate_as(tests.fx('u_tech_a'));  -- not assigned to job_a2
select tests.eq(tests.row_count($$select 1 from public.customers where id = tests.fx('cust_a2')$$), 0::bigint, 'customer hidden from tech_a');
select tests.eq(tests.row_count($$select 1 from public.form_submissions where job_id = tests.fx('job_a2')$$), 0::bigint,
                'job_a2 forms hidden from tech_a');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name like '%/forms/%'$$), 0::bigint,
                'a technician cannot list/read signatures of customers on jobs not assigned to them');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'
                                  and name = tests.fx('shop_a') || '/device/job-a2.png'$$), 0::bigint,
                'nor a staff-collected signature of an unassigned job');
select tests.ok(not exists (select 1 from storage.objects where bucket_id = 'signatures'
                            and public.storage_path_uuid(name, 3) in (tests.fx('tok_leak'), tests.fx('tok_pending'))),
                'form tokens of unassigned jobs cannot be harvested from object names');
-- the original repro: the name of a customer on an unassigned job is not reachable through a harvested token
select tests.ok((select public.public_get_form(public.storage_path_uuid(name, 3)) -> 'customer' ->> 'last_name'
                   from storage.objects where bucket_id = 'signatures' and name like '%/forms/%' limit 1) is distinct from 'Other',
                'a technician must not reach the name of a customer on a job not assigned to them');

select tests.authenticate_as(tests.fx('u_tech2_a'));  -- assigned to job_a2
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name like '%/forms/%'$$), 2::bigint,
                'the assigned technician reads the signature uploads of their job''s forms (signed and pending)');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'
                                  and name = tests.fx('shop_a') || '/device/job-a2.png'$$), 1::bigint,
                'and signatures referenced by their job''s forms');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint,
                'deactivated members read no signatures, not even their own uploads');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech2_a');
delete from public.job_assignments where job_id = tests.fx('job_a2') and member_id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name like '%/forms/%'$$), 0::bigint,
                'unassigned from the job: its signatures are no longer readable');
select tests.as_superuser();
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('m_tech2_a'));

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'
                                  and name in (tests.fx('shop_a') || '/forms/' || tests.fx('tok_leak') || '/sig.png',
                                               tests.fx('shop_a') || '/forms/' || tests.fx('tok_pending') || '/sig.png',
                                               tests.fx('shop_a') || '/device/job-a2.png')$$), 3::bigint,
                'managers read every signature of the shop');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint,
                'another shop''s technician reads no signatures of shop A');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures'$$), 0::bigint,
                'another shop''s manager reads no signatures of shop A');

-- signed forms: their signature images are permanent evidence, even for managers
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update storage.objects set version = 'replaced' where bucket_id = 'signatures'
                                  and name = tests.fx('shop_a') || '/forms/' || tests.fx('tok_leak') || '/sig.png'$$), 0::bigint,
                'the signature image of a signed form cannot be overwritten');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures'
                                  and name in (tests.fx('shop_a') || '/forms/' || tests.fx('tok_leak') || '/sig.png',
                                               tests.fx('shop_a') || '/device/job-a2.png')$$), 0::bigint,
                'nor deleted');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures'
                                  and name = tests.fx('shop_a') || '/forms/' || tests.fx('tok_pending') || '/sig.png'$$), 1::bigint,
                'an upload not yet used by a signature can still be removed by a manager');

-- ------------------------------------------------------------ signed inspection evidence is locked in storage
-- Regression: the uploader (and managers) could overwrite or delete the
-- photo behind a mark of a signed inspection, swapping the evidence the
-- customer signed off on.
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'requested')
  returning tests.fx_set('job_ev', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_ev'), tests.fx('m_tech_a'));
create temporary table ev (key text primary key, path text not null);
grant select on ev to anon, authenticated, service_role;
insert into ev values
  ('dent',  tests.fx('shop_a') || '/' || tests.fx('job_ev') || '/dent.jpg'),
  ('chip',  tests.fx('shop_a') || '/' || tests.fx('job_ev') || '/chip.jpg'),
  ('plain', tests.fx('shop_a') || '/' || tests.fx('job_ev') || '/after.jpg'),
  ('isig',  tests.fx('shop_a') || '/inspections/ev-sig.png');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into storage.objects (bucket_id, name, owner, owner_id) values ('signatures', (select path from ev where key = 'isig'), auth.uid(), auth.uid()::text);
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('job-photos', (select path from ev where key = 'dent'),  auth.uid(), auth.uid()::text),
  ('job-photos', (select path from ev where key = 'chip'),  auth.uid(), auth.uid()::text),
  ('job-photos', (select path from ev where key = 'plain'), auth.uid(), auth.uid()::text);
insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_ev'), 'pre') returning tests.fx_set('insp_ev', id);
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
  values (tests.fx('shop_a'), tests.fx('insp_ev'), 'front', 0.5, 0.5, 'dent', (select path from ev where key = 'dent'));
insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_ev'), 'post') returning tests.fx_set('insp_ev_post', id);
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
  values (tests.fx('shop_a'), tests.fx('insp_ev_post'), 'left', 0.2, 0.3, 'chip', (select path from ev where key = 'chip'));
update public.inspections set customer_signature_path = (select path from ev where key = 'isig'), signed_by_name = 'Alice Anders'
 where id = tests.fx('insp_ev');
select tests.ok((select signed_at is not null from public.inspections where id = tests.fx('insp_ev')), 'inspection signed and locked');
select tests.throws($$delete from public.inspection_marks where inspection_id = tests.fx('insp_ev')$$, '42501', 'marks locked');
select tests.eq(tests.row_count($$update storage.objects set version = 'replaced' where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                0::bigint, 'a technician must not overwrite the photo of a signed inspection mark');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                0::bigint, 'a technician must not delete the photo of a signed inspection mark');
select tests.eq(tests.row_count($$update storage.objects set name = (select path from ev where key = 'dent') || '.moved'
                                  where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                0::bigint, 'nor move it away');
select tests.eq(tests.row_count($$update storage.objects set version = 'v2' where bucket_id = 'job-photos' and name = (select path from ev where key = 'chip')$$),
                1::bigint, 'the photo of an unsigned inspection''s mark can still be replaced by its uploader');
select tests.eq(tests.row_count($$update storage.objects set version = 'v2' where bucket_id = 'job-photos' and name = (select path from ev where key = 'plain')$$),
                1::bigint, 'ordinary job photos are unaffected');
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name = (select path from ev where key = 'isig')$$),
                1::bigint, 'the assigned technician reads the inspection signature of their job (uploaded by someone else)');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'signatures' and name = (select path from ev where key = 'isig')$$),
                0::bigint, 'a technician not on the job cannot read it');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update storage.objects set version = 'replaced' where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                0::bigint, 'managers cannot overwrite signed evidence either');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                0::bigint, 'managers cannot delete signed evidence');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures' and name = (select path from ev where key = 'isig')$$),
                0::bigint, 'managers cannot delete the signature of a signed inspection');
select tests.eq(tests.row_count($$update storage.objects set version = 'replaced' where bucket_id = 'signatures' and name = (select path from ev where key = 'isig')$$),
                0::bigint, 'nor overwrite it');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from storage.objects where name in (select path from ev)$$), 0::bigint,
                'another shop touches none of the evidence');
select tests.as_superuser();
select tests.ok(not public.is_signed_evidence('job-photos', (select path from ev where key = 'dent')),
                'the lock helper says nothing about shops the caller is not in');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.ok(not public.is_signed_evidence('job-photos', (select path from ev where key = 'dent')),
                'nor to members of other shops (no cross-tenant path oracle)');

-- a manager removes the signature: the evidence unlocks
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null where id = tests.fx('insp_ev');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update storage.objects set version = 'retake' where bucket_id = 'job-photos' and name = (select path from ev where key = 'dent')$$),
                1::bigint, 'after un-signing the uploader may replace the photo again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'signatures' and name = (select path from ev where key = 'isig')$$),
                1::bigint, 'and a manager may remove the old signature image');

-- ------------------------------------------------------------ helper privileges
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_form_signature_upload_allowed(text)', 'execute'),
                'the public upload check is callable by anon (storage policy)');
select tests.ok(not has_function_privilege('anon', 'public.can_work_job(uuid, uuid)', 'execute'), 'can_work_job is not anon');
select tests.eq(public.storage_path_uuid('not-a-uuid/x/y.png', 1), null::uuid, 'non-uuid folders parse to null');
select tests.eq(public.storage_path_uuid(tests.fx('shop_a')::text || '/file.png', 1), tests.fx('shop_a'), 'folder uuid parsed');
select tests.eq(public.storage_path_uuid(tests.fx('shop_a')::text, 1), null::uuid, 'the file name is not a folder');
select tests.ok(not public.is_safe_storage_path('a//b.png') and not public.is_safe_storage_path('a/./b.png')
                and not public.is_safe_storage_path('a/b/') and not public.is_safe_storage_path(E'a/b\\c.png')
                and not public.is_safe_storage_path(E'a/b\nc.png') and public.is_safe_storage_path('a/b-c_d.e.png'),
                'safe path rules');
