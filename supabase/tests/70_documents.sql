-- 70 ops: document uploads on customers and jobs (P-25) — bucket config,
-- storage policies per role (customer folders manager-only, job folders for
-- staff on the job), the documents table (RLS per role, server-set
-- uploader / customer, customer visibility a manager decision, only name and
-- visibility editable), path / object validation, documents following their
-- job's customer, the storage purge, the booking page / portal lists and
-- media lookups, and two-shop isolation.
\ir fixtures/two_shops.psql
delete from public.storage_purge_requests;

-- ============================================================ bucket
select tests.eq((select jsonb_build_array(public, file_size_limit, 'application/pdf' = any (allowed_mime_types),
                                          'image/heic' = any (allowed_mime_types), 'text/html' = any (allowed_mime_types))
                   from storage.buckets where id = 'documents'),
                '[false, 26214400, true, true, false]'::jsonb, 'documents: private, 25 MiB, documents and photos, no HTML');

create temp table p (key text primary key, path text not null);
grant select on p to anon, authenticated, service_role;
insert into p values
  ('cust_a',   tests.fx('shop_a') || '/customers/' || tests.fx('cust_a') || '/id.pdf'),
  ('cust_a_2', tests.fx('shop_a') || '/customers/' || tests.fx('cust_a') || '/id2.pdf'),
  ('job_a',    tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/tech.jpg'),
  ('job_a_m',  tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/manager.pdf'),
  ('job_a2',   tests.fx('shop_a') || '/jobs/' || tests.fx('job_a2') || '/other.pdf'),
  ('deep',     tests.fx('shop_a') || '/jobs/' || tests.fx('job_a') || '/x/deep.pdf'),
  ('loose',    tests.fx('shop_a') || '/loose.pdf'),
  ('job_b',    tests.fx('shop_b') || '/jobs/' || tests.fx('job_b') || '/b.pdf');

-- ============================================================ storage: upload
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', (select path from p where key = 'cust_a'), auth.uid(), auth.uid()::text)$$,
                   'managers upload customer files');
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', (select path from p where key = 'job_a_m'), auth.uid(), auth.uid()::text)$$,
                   'and job files');
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', (select path from p where key = 'job_a2'), auth.uid(), auth.uid()::text)$$);
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', (select path from p where key = 'cust_a_2'), auth.uid(), auth.uid()::text)$$);
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('documents', (select path from p where key = 'deep'), auth.uid())$$,
                    '42501', 'files sit directly in the folder');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('documents', (select path from p where key = 'loose'), auth.uid())$$,
                    '42501', 'only customer and job folders');
select tests.throws($$insert into storage.objects (bucket_id, name, owner) values ('documents', (select path from p where key = 'job_b'), auth.uid())$$,
                    '42501', 'not into another shop');
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner) values ('documents', '%s/jobs/%s/x.pdf', auth.uid())$$,
                           tests.fx('shop_a'), tests.fx('job_b')), '42501', 'the job folder must be a job of the shop');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner, owner_id) values ('documents', (select path from p where key = 'job_a'), auth.uid(), auth.uid()::text)$$,
                   'a technician uploads to the folder of an assigned job');
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner) values ('documents', '%s/customers/%s/t.pdf', auth.uid())$$,
                           tests.fx('shop_a'), tests.fx('cust_a')), '42501', 'but not to customer folders');
select tests.throws(format($$insert into storage.objects (bucket_id, name, owner) values ('documents', '%s/jobs/%s/t.pdf', auth.uid())$$,
                           tests.fx('shop_a'), tests.fx('job_a2')), '42501', 'nor to an unassigned job');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.lives($$insert into storage.objects (bucket_id, name, owner) values ('documents', (select path from p where key = 'job_b'), auth.uid())$$);
select tests.as_anon();
select tests.throws($$insert into storage.objects (bucket_id, name) values ('documents', (select path from p where key = 'job_a') || '.x')$$,
                    '42501', 'anon cannot upload');

-- ============================================================ storage: read / overwrite / delete
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'documents'$$), 0::bigint, 'anon reads nothing');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(name order by name) from storage.objects where bucket_id = 'documents'),
                (select array_agg(path order by path) from p where key in ('job_a', 'job_a_m')),
                'a technician reads the files of assigned jobs only');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'documents'$$), 0::bigint,
                'technicians cannot overwrite');
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'documents' and name = (select path from p where key = 'job_a_m')$$),
                0::bigint, 'nor delete someone else''s file');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'documents'$$), 5::bigint, 'managers read the shop''s files');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from storage.objects where bucket_id = 'documents'$$), 1::bigint, 'shop B reads only its own');

-- ============================================================ table: insert
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes, customer_visible, uploaded_by)
  values (tests.fx('shop_a'), tests.fx('cust_a'), (select path from p where key = 'cust_a'), '  ID scan.pdf ', ' Application/PDF ',
          5000, true, tests.fx('u_owner_a'))
  returning tests.fx_set('doc_cust', id);
select tests.eq((select jsonb_build_array(file_name, content_type, uploaded_by = tests.fx('u_manager_a'), job_id, customer_visible)
                   from public.documents where id = tests.fx('doc_cust')),
                '["ID scan.pdf", "application/pdf", true, null, true]'::jsonb, 'normalized; the uploader is the acting user');
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes, customer_visible)
  values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'job_a_m'), 'Estimate.pdf', 'application/pdf', 900, true)
  returning tests.fx_set('doc_job_m', id);
select tests.eq((select customer_id from public.documents where id = tests.fx('doc_job_m')), tests.fx('cust_a'),
                'a job file belongs to the job''s customer');
select tests.throws_like($$insert into public.documents (shop_id, job_id, customer_id, storage_path, file_name, content_type, size_bytes)
                           values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a'), (select path from p where key = 'job_a2'), 'x', 'application/pdf', 1)$$,
                         '23514', '%job''s customer%', 'not another customer''s');
select tests.throws_like($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                           values (tests.fx('shop_a'), tests.fx('job_a2'), (select path from p where key = 'job_a'), 'x', 'application/pdf', 1)$$,
                         '23514', '%stored under%', 'a job file lives in its job''s folder');
select tests.throws_like($$insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
                           values (tests.fx('shop_a'), tests.fx('cust_a2'), (select path from p where key = 'cust_a_2'), 'x', 'application/pdf', 1)$$,
                         '23514', '%stored under%', 'a customer file lives in its customer''s folder');
select tests.throws_like(format($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                           values (%L, %L, %L, 'x', 'application/pdf', 1)$$, tests.fx('shop_a'), tests.fx('job_a2'),
                                tests.fx('shop_a') || '/jobs/' || tests.fx('job_a2') || '/missing.pdf'),
                         '23514', '%upload the file%', 'the object must exist');
select tests.throws($$insert into public.documents (shop_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), (select path from p where key = 'job_a2'), 'x', 'application/pdf', 1)$$,
                    '23514', 'a document belongs to a customer or a job');
select tests.throws($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), (select path from p where key = 'job_a2'), 'x', 'application/pdf', 26214401)$$,
                    '23514', 'at most 25 MiB');
select tests.throws($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_b'), tests.fx('job_b'), (select path from p where key = 'job_b'), 'x', 'application/pdf', 1)$$,
                    '42501', 'not into another shop');
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('job_a2'), (select path from p where key = 'job_a2'), 'Other.pdf', 'application/pdf', 10)
  returning tests.fx_set('doc_a2', id);

select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes, customer_visible)
  values (tests.fx('shop_a'), tests.fx('job_a'), (select path from p where key = 'job_a'), 'Scratch photo', 'image/jpeg', 300, true)
  returning tests.fx_set('doc_tech', id);
select tests.eq((select jsonb_build_array(customer_id = tests.fx('cust_a'), customer_visible, uploaded_by = tests.fx('u_tech_a'))
                   from public.documents where id = tests.fx('doc_tech')),
                '[true, false, true]'::jsonb, 'a technician''s file: the job''s customer, hidden from the customer');
select tests.throws($$insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), (select path from p where key = 'cust_a'), 'x', 'application/pdf', 1)$$,
                    '42501', 'technicians cannot add customer files');
select tests.throws($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), tests.fx('job_a2'), (select path from p where key = 'job_a2'), 'x', 'application/pdf', 1)$$,
                    '42501', 'nor files of an unassigned job');
select tests.as_service();
select tests.throws($$insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), tests.fx('job_b'), (select path from p where key = 'job_b'), 'x', 'application/pdf', 1)$$,
                    '23503', 'composite FK: another shop''s job');
select tests.throws($$insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
                      values (tests.fx('shop_a'), tests.fx('cust_b'), (select path from p where key = 'job_b'), 'x', 'application/pdf', 1)$$,
                    '23503', 'composite FK: another shop''s customer');

-- ============================================================ table: read / update / delete
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(id order by file_name) from public.documents),
                array[tests.fx('doc_job_m'), tests.fx('doc_tech')], 'a technician reads the files of assigned jobs only');
select tests.eq(tests.row_count($$update public.documents set file_name = 'x' where id = tests.fx('doc_tech')$$), 0::bigint,
                'technicians cannot rename, not even their own');
select tests.throws($$update public.documents set storage_path = 'x' where id = tests.fx('doc_tech')$$, '42501',
                    'the file itself is not editable');
select tests.eq(tests.row_count($$delete from public.documents where id = tests.fx('doc_job_m')$$), 0::bigint,
                'technicians cannot delete a manager''s file');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq((select array_agg(id) from public.documents), array[tests.fx('doc_a2')], 'the other technician sees job_a2''s file');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.documents set file_name = 'Estimate v2.pdf', customer_visible = false where id = tests.fx('doc_job_m')$$),
                1::bigint, 'managers rename and hide');
select tests.throws($$update public.documents set job_id = tests.fx('job_a2') where id = tests.fx('doc_job_m')$$, '42501',
                    'a file cannot move to another job');
select tests.throws($$update public.documents set customer_id = tests.fx('cust_a2') where id = tests.fx('doc_cust')$$, '42501',
                    'nor to another customer');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.documents$$), 0::bigint, 'shop B reads none of A''s files');
select tests.eq(tests.row_count($$update public.documents set file_name = 'x'$$), 0::bigint, 'nor renames them');
select tests.eq(tests.row_count($$delete from public.documents$$), 0::bigint, 'nor deletes them');
select tests.as_anon();
select tests.throws($$select 1 from public.documents$$, '42501', 'anon has no table access');

-- a job's files follow its customer
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('job_a2');
select tests.eq((select customer_id from public.documents where id = tests.fx('doc_a2')), tests.fx('cust_a3'),
                'moving a job moves its files to the new customer');

-- ============================================================ customer-facing lists
select tests.as_superuser();
select tests.fx_set('job_a_tok', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.as_anon();
select tests.eq(public.public_booking_documents(tests.fx('job_a_tok')), '[]'::jsonb, 'nothing visible yet on the booking page');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.documents set customer_visible = true where id in (tests.fx('doc_job_m'), tests.fx('doc_tech'));
select tests.as_anon();
select tests.eq((select jsonb_agg(d -> 'file_name' order by d ->> 'file_name') from jsonb_array_elements(public.public_booking_documents(tests.fx('job_a_tok'))) d),
                '["Estimate v2.pdf", "Scratch photo"]'::jsonb, 'the booking page lists the job''s visible files');
select tests.ok(public.public_booking_documents(tests.fx('job_a_tok'))::text not like '%/jobs/%', 'without storage paths');
select tests.throws_like($$select public.public_booking_documents(gen_random_uuid())$$, 'PT404', '%not found%', 'unknown booking');
select tests.throws($$select * from public.booking_document_media(tests.fx('job_a_tok'))$$, '42501', 'anon cannot resolve files');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select * from public.booking_document_media(tests.fx('job_a_tok'))$$, '42501', 'nor staff');
select tests.as_service();
select tests.eq((select array_agg(path order by path) from public.booking_document_media(tests.fx('job_a_tok'))),
                (select array_agg(path order by path) from p where key in ('job_a', 'job_a_m')), 'the media function resolves them');
select tests.eq(tests.row_count($$select * from public.booking_document_media(gen_random_uuid())$$), 0::bigint, 'nothing for an unknown token');

-- client portal
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('alice@example.com'));
select tests.fx_set('u_stranger', tests.create_user('stranger@example.com'));
update public.customers set portal_user_id = tests.fx('u_client') where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq((select jsonb_agg(jsonb_build_array(d ->> 'file_name', d ->> 'shop_name', d ->> 'job_number' is not null)
                                  order by d ->> 'file_name')
                   from jsonb_array_elements(public.portal_documents()) d),
                '[["Estimate v2.pdf", "Shop A", true], ["ID scan.pdf", "Shop A", false], ["Scratch photo", "Shop A", true]]'::jsonb,
                'the linked client sees the visible files of the customer and its jobs');
select tests.eq(public.portal_job_reports(), '[]'::jsonb, 'no job reports yet');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.publish_job_report(tests.fx('job_a2'));
create temp table rep as select public.publish_job_report(tests.fx('job_a')) as r;
grant select on rep to authenticated;
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq((select jsonb_agg(jsonb_build_array(d ->> 'shop_name', d ->> 'report_path'))
                   from jsonb_array_elements(public.portal_job_reports()) d),
                jsonb_build_array(jsonb_build_array('Shop A', '/r/' || ((select r from rep) ->> 'token'))),
                'the client sees the live report of their job only');
select tests.authenticate_as(tests.fx('u_stranger'));
select tests.eq(public.portal_documents(), '[]'::jsonb, 'an unlinked account sees nothing');
select tests.eq(public.portal_job_reports(), '[]'::jsonb, 'and no reports');
select tests.as_anon();
select tests.throws($$select public.portal_documents()$$, '42501', 'anon cannot use the portal');
select tests.as_service();
select tests.eq(public.portal_document_media(tests.fx('doc_cust'), tests.fx('u_client')),
                jsonb_build_object('bucket', 'documents', 'path', (select path from p where key = 'cust_a')),
                'the media function resolves a file the client may see');
select tests.eq(public.portal_document_media(tests.fx('doc_cust'), tests.fx('u_stranger')), null::jsonb, 'not for another user');
select tests.eq(public.portal_document_media(tests.fx('doc_a2'), tests.fx('u_client')), null::jsonb, 'not a hidden file');
select tests.eq(public.portal_document_media(tests.fx('doc_cust'), null), null::jsonb, 'not without a user');
select tests.authenticate_as(tests.fx('u_client'));
select tests.throws($$select public.portal_document_media(tests.fx('doc_cust'), auth.uid())$$, '42501', 'clients cannot call it directly');
select tests.as_superuser();
update public.customers set archived_at = now() where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq(public.portal_documents(), '[]'::jsonb, 'an archived customer''s files leave the portal');

-- ============================================================ storage purge
select tests.as_superuser();
update public.customers set archived_at = null where id = tests.fx('cust_a');
delete from public.storage_purge_requests;
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.documents where id = tests.fx('doc_tech')$$), 1::bigint,
                'the technician deletes their own file on the job');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || reason) from public.storage_purge_requests),
                array['documents ' || (select path from p where key = 'job_a') || ' document_deleted'],
                'a deleted document''s object is queued');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from storage.objects where bucket_id = 'documents' and name = (select path from p where key = 'job_a')$$),
                1::bigint, 'and its uploader may remove the object');
select tests.as_superuser();
delete from public.storage_purge_requests;
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Temp') returning tests.fx_set('cust_tmp', id);
insert into storage.objects (bucket_id, name) values ('documents', tests.fx('shop_a') || '/customers/' || tests.fx('cust_tmp') || '/a.pdf');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('cust_tmp'), tests.fx('shop_a') || '/customers/' || tests.fx('cust_tmp') || '/a.pdf', 'a.pdf',
          'application/pdf', 1);
select tests.as_service();   -- 0125: deletes go through erase_customer (service role)
delete from public.customers where id = tests.fx('cust_tmp');
select tests.as_superuser();
select tests.eq((select array_agg(bucket_id || ' ' || path || ' ' || is_prefix::text || ' ' || reason order by path) from public.storage_purge_requests),
                array['documents ' || tests.fx('shop_a') || '/customers/' || tests.fx('cust_tmp') || '/ true customer_deleted',
                      'documents ' || tests.fx('shop_a') || '/customers/' || tests.fx('cust_tmp') || '/a.pdf false document_deleted'],
                'deleting a customer queues its folder (and its files)');
select tests.as_service();
select tests.eq((select array_agg(distinct object_name) from public.claim_storage_purge(100, '2030-01-01Z') where bucket_id = 'documents'),
                array[tests.fx('shop_a') || '/customers/' || tests.fx('cust_tmp') || '/a.pdf'], 'the worker removes the file');
select tests.eq(public.storage_object_in_use('documents', (select path from p where key = 'cust_a')), true,
                'a registered document is in use (never purged)');
select tests.eq(public.storage_object_in_use('documents', (select path from p where key = 'job_a')), false,
                'an unregistered one is not');
