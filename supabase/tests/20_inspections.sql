-- 20 field ops: inspections + inspection_marks — staff-on-job access,
-- vehicle/photo/signature validation, server-stamped signing, the signed
-- lock (manager+ un-sign only), cascade on job/shop delete, vehicles with
-- inspections cannot be deleted (RESTRICT), cross-shop isolation.
\ir fixtures/two_shops.psql

-- uploaded objects (the Storage API inserts these rows on upload)
select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('signatures', tests.fx('shop_a') || '/inspections/sig-1.png', tests.fx('u_tech_a')),
  ('signatures', tests.fx('shop_a') || '/inspections/sig-2.png', tests.fx('u_manager_a')),
  ('signatures', tests.fx('shop_b') || '/inspections/sig-b.png', tests.fx('u_tech_b')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a') || '/scratch.jpg', tests.fx('u_tech_a')),
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/other-job.jpg', tests.fx('u_tech2_a'));

-- ------------------------------------------------------------ create: staff on the job
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.inspections (shop_id, job_id, vehicle_id, kind, mileage, fuel_level, notes, created_by)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre', 42000, 50, 'Light swirls', tests.fx('u_owner_a'))
  returning tests.fx_set('insp_pre', id);
select tests.eq((select created_by from public.inspections where id = tests.fx('insp_pre')), tests.fx('u_tech_a'),
                'created_by is the acting user');
select tests.ok((select signed_at is null from public.inspections where id = tests.fx('insp_pre')), 'new inspection is unsigned');
select tests.throws($$insert into public.inspections (shop_id, job_id, vehicle_id, kind)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'pre')$$, '23505',
                    'one pre inspection per job and vehicle');
select tests.lives($$insert into public.inspections (shop_id, job_id, vehicle_id, kind)
                     values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a'), 'post')
                     returning tests.fx_set('insp_post', id)$$, 'a post inspection is separate');
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_a2'), 'pre')$$,
                    '42501', 'technicians cannot inspect unassigned jobs');
select tests.throws_like($$insert into public.inspections (shop_id, job_id, vehicle_id, kind)
                           values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_a2'), 'pre')$$, '23514',
                         '%not on this job%', 'the vehicle must be on the job');
select tests.throws($$insert into public.inspections (shop_id, job_id, vehicle_id, kind)
                      values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('veh_b'), 'pre')$$, '23503',
                    'another shop''s vehicle is rejected by the composite FK');
select tests.throws($$insert into public.inspections (shop_id, job_id, kind, mileage) values (tests.fx('shop_a'), tests.fx('job_a'), 'pre', -1)$$,
                    '23514', 'mileage cannot be negative');
select tests.throws($$insert into public.inspections (shop_id, job_id, kind, fuel_level) values (tests.fx('shop_a'), tests.fx('job_a'), 'pre', 101)$$,
                    '23514', 'fuel level is a percentage');
select tests.lives($$update public.inspections set mileage = 42010 where id = tests.fx('insp_pre')$$, 'technician edits an unsigned inspection');
select tests.throws($$update public.inspections set job_id = tests.fx('job_a2') where id = tests.fx('insp_pre')$$, '42501',
                    'inspections do not move between jobs');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.inspections$$), 0::bigint, 'unassigned technician sees no inspections of job_a');
select tests.eq(tests.row_count($$update public.inspections set notes = 'x'$$), 0::bigint, 'and cannot edit them');
select tests.eq(tests.row_count($$delete from public.inspections$$), 0::bigint, 'or delete them');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.inspections$$), 2::bigint, 'managers see all inspections of the shop');
select tests.lives($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_a2'), 'pre')
                     returning tests.fx_set('insp_a2', id)$$, 'managers inspect any job');
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_b'), 'pre')$$,
                    '42501', 'another shop''s job fails the policy');
select tests.as_service();
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_b'), 'pre')$$,
                    '23503', 'composite FK blocks another shop''s job even for trusted code');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_b'), tests.fx('insp_pre'), 'left', 0.5, 0.5, 'dent')$$, '23503',
                    'composite FK blocks marks pointing at another shop''s inspection');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_b'), tests.fx('job_b'), 'pre')$$,
                    '42501', 'managers cannot write into another shop');

-- ------------------------------------------------------------ marks
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, note)
  values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 0.25, 0.5, 'scratch', 'Door ding') returning tests.fx_set('mark_1', id);
select tests.lives($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
                     values (tests.fx('shop_a'), tests.fx('insp_pre'), 'front', 0, 1, 'chip',
                             tests.fx('shop_a') || '/' || tests.fx('job_a') || '/scratch.jpg')$$,
                   'a mark may reference an uploaded job photo');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 1.5, 0.5, 'dent')$$, '23514', 'x is within 0..1');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 0.5, -0.1, 'dent')$$, '23514', 'y is within 0..1');
select tests.throws_like($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
                           values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 0.5, 0.5, 'dent',
                                   tests.fx('shop_a') || '/' || tests.fx('job_a2') || '/other-job.jpg')$$, '23514',
                         '%<shop_id>/<job_id>/%', 'mark photos must belong to the inspection''s job');
select tests.throws_like($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
                           values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 0.5, 0.5, 'dent',
                                   tests.fx('shop_a') || '/' || tests.fx('job_a') || '/missing.jpg')$$, '23514',
                         '%upload the photo%', 'mark photos must be uploaded first');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage, photo_path)
                      values (tests.fx('shop_a'), tests.fx('insp_pre'), 'left', 0.5, 0.5, 'dent',
                              tests.fx('shop_a') || '/' || tests.fx('job_a') || '/../x.jpg')$$, '23514', 'unsafe paths are rejected');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_a'), tests.fx('insp_a2'), 'left', 0.5, 0.5, 'dent')$$, '42501',
                    'technicians cannot mark inspections of unassigned jobs');
select tests.lives($$update public.inspection_marks set note = 'Door ding, 2cm' where id = tests.fx('mark_1')$$, 'technician edits a mark');
select tests.throws($$update public.inspection_marks set inspection_id = tests.fx('insp_post') where id = tests.fx('mark_1')$$, '42501',
                    'marks do not move between inspections');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.inspection_marks$$), 0::bigint, 'unassigned technicians see no marks');
select tests.eq(tests.row_count($$update public.inspection_marks set note = 'x'$$), 0::bigint, 'nor edit them');
select tests.eq(tests.row_count($$delete from public.inspection_marks$$), 0::bigint, 'nor delete them');

select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.inspection_marks$$), 0::bigint, 'shop B sees none of A''s marks');
select tests.eq(tests.row_count($$select 1 from public.inspections$$), 0::bigint, 'shop B sees none of A''s inspections');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_b'), tests.fx('insp_pre'), 'left', 0.5, 0.5, 'dent')$$, '42501',
                    'shop B cannot mark A''s inspection');

-- ------------------------------------------------------------ signing
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.inspections set signed_by_name = 'Alice Anders' where id = tests.fx('insp_pre')$$, '23514',
                    'a signature needs the image and the name');
select tests.throws_like($$update public.inspections set signed_by_name = 'Alice', customer_signature_path = tests.fx('shop_b') || '/inspections/sig-b.png'
                           where id = tests.fx('insp_pre')$$, '23514', '%this shop%', 'the signature must be in the shop''s folder');
select tests.throws_like($$update public.inspections set signed_by_name = 'Alice', customer_signature_path = tests.fx('shop_a') || '/inspections/nope.png'
                           where id = tests.fx('insp_pre')$$, '23514', '%upload the signature%', 'the signature must be uploaded');
select tests.lives($$update public.inspections
                        set signed_by_name = '  Alice Anders ', customer_signature_path = tests.fx('shop_a') || '/inspections/sig-1.png',
                            signed_at = '2000-01-01Z'
                      where id = tests.fx('insp_pre')$$, 'the assigned technician collects the customer signature');
select tests.ok((select signed_at = now() and signed_by_name = 'Alice Anders' from public.inspections where id = tests.fx('insp_pre')),
                'signed_at is stamped by the server; name trimmed');

-- ------------------------------------------------------------ the signed lock
select tests.throws($$update public.inspections set notes = 'changed' where id = tests.fx('insp_pre')$$, '42501',
                    'signed inspections are locked for technicians');
select tests.throws($$update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null
                      where id = tests.fx('insp_pre')$$, '42501', 'technicians cannot un-sign');
select tests.throws($$delete from public.inspections where id = tests.fx('insp_pre')$$, '42501', 'signed inspections cannot be deleted');
select tests.throws($$insert into public.inspection_marks (shop_id, inspection_id, view, x, y, damage)
                      values (tests.fx('shop_a'), tests.fx('insp_pre'), 'rear', 0.5, 0.5, 'dent')$$, '42501',
                    'no new marks on a signed inspection');
select tests.throws($$update public.inspection_marks set note = 'edited' where id = tests.fx('mark_1')$$, '42501',
                    'marks of a signed inspection are locked');
select tests.throws($$delete from public.inspection_marks where id = tests.fx('mark_1')$$, '42501',
                    'marks of a signed inspection cannot be deleted');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.inspections set notes = 'manager edit' where id = tests.fx('insp_pre')$$, '42501',
                    'managers cannot edit a signed inspection either');
select tests.throws($$update public.inspections set customer_signature_path = tests.fx('shop_a') || '/inspections/sig-2.png'
                      where id = tests.fx('insp_pre')$$, '42501', 'a signature cannot be swapped');
select tests.throws($$update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null, notes = 'x'
                      where id = tests.fx('insp_pre')$$, '42501', 'un-signing cannot be combined with other edits');
select tests.throws($$update public.inspections set customer_signature_path = null where id = tests.fx('insp_pre')$$, '42501',
                    'a partial un-sign is rejected');
select tests.throws($$delete from public.inspections where id = tests.fx('insp_pre')$$, '42501', 'managers cannot delete signed inspections');
select tests.lives($$update public.inspections set customer_signature_path = null, signed_by_name = null, signed_at = null
                     where id = tests.fx('insp_pre')$$, 'a manager un-signs');
select tests.ok((select signed_at is null and customer_signature_path is null and signed_by_name is null
                   from public.inspections where id = tests.fx('insp_pre')), 'signature cleared');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$update public.inspection_marks set note = 'after un-sign' where id = tests.fx('mark_1')$$,
                   'an un-signed inspection is editable again');
select tests.lives($$update public.inspections set signed_by_name = 'Alice Anders',
                            customer_signature_path = tests.fx('shop_a') || '/inspections/sig-2.png'
                      where id = tests.fx('insp_pre')$$, 're-sign with a new signature');

-- trusted code (service_role) is not subject to the client lock
select tests.as_service();
select tests.lives($$update public.inspections set notes = 'service correction' where id = tests.fx('insp_pre')$$,
                   'service_role may correct a signed inspection');

-- signing on insert is stamped too
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.inspections (shop_id, job_id, kind, signed_by_name, customer_signature_path, signed_at)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'post', 'Aaron Other', tests.fx('shop_a') || '/inspections/sig-2.png', '1999-01-01Z')
  returning tests.fx_set('insp_signed_insert', id);
select tests.eq((select signed_at from public.inspections where id = tests.fx('insp_signed_insert')), now(),
                'signed_at stamped on insert');

-- ------------------------------------------------------------ cascades
-- deleting a job removes its (even signed) inspections and marks
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('job_a')$$), 1::bigint,
                'a manager deletes a job with a signed inspection');
select tests.as_superuser();
select tests.eq((select count(*) from public.inspections where job_id = tests.fx('job_a')), 0::bigint, 'inspections cascade');
select tests.eq((select count(*) from public.inspection_marks where inspection_id = tests.fx('insp_pre')), 0::bigint, 'marks cascade');

-- ------------------------------------------------------------ vehicles with inspections are kept
-- An inspection is evidence about one specific car, and there is at most one
-- inspection of each kind per job and vehicle, the vehicle-less slot
-- included. The vehicle FK is ON DELETE RESTRICT: with SET NULL, deleting
-- the vehicles of a multi-vehicle job (or one vehicle of a job that also
-- has a vehicle-less inspection) collided on that unique key (23505) and the
-- vehicle could not be deleted at all. Now the refusal is deliberate: a
-- clear FK error, and the vehicle is archived instead.
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.inspections set vehicle_id = tests.fx('veh_a2') where id = tests.fx('insp_a2');
select tests.eq((select vehicle_id from public.inspections where id = tests.fx('insp_a2')), tests.fx('veh_a2'),
                'a vehicle can be attached to an unsigned inspection');
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, make, model) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'Ford', 'F-150')
  returning tests.fx_set('veh_a2_2', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('veh_a2_2'), 'Truck wash', 5000);
insert into public.inspections (shop_id, job_id, vehicle_id, kind)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('veh_a2_2'), 'pre')
  returning tests.fx_set('insp_a2_truck', id);
insert into public.inspections (shop_id, job_id, kind)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'pre')
  returning tests.fx_set('insp_a2_none', id);
select tests.eq((select string_agg(coalesce(vehicle_id::text, 'none'), ',' order by vehicle_id nulls last)
                   from public.inspections where job_id = tests.fx('job_a2') and kind = 'pre'),
                concat_ws(',', least(tests.fx('veh_a2')::text, tests.fx('veh_a2_2')::text),
                               greatest(tests.fx('veh_a2')::text, tests.fx('veh_a2_2')::text), 'none'),
                'job_a2 has a pre inspection per vehicle plus a vehicle-less one');
select tests.throws($$insert into public.inspections (shop_id, job_id, kind) values (tests.fx('shop_a'), tests.fx('job_a2'), 'pre')$$,
                    '23505', 'still one vehicle-less pre inspection per job');

select tests.throws_like($$delete from public.vehicles where id = tests.fx('veh_a2_2')$$, '23503', '%inspections_vehicle_fk%',
                         'a vehicle with an inspection cannot be deleted (clear FK error, not a unique-key collision)');
select tests.throws_like($$delete from public.vehicles where id = tests.fx('veh_a2')$$, '23503', '%inspections_vehicle_fk%',
                         'nor the other vehicle of the multi-vehicle job');
select tests.as_service();
select tests.throws($$delete from public.vehicles where id = tests.fx('veh_a2')$$, '23503',
                    'trusted code cannot orphan inspection evidence either');
select tests.as_superuser();
select tests.eq((select count(*) from public.inspections
                  where id in (tests.fx('insp_a2'), tests.fx('insp_a2_truck'))
                    and vehicle_id in (tests.fx('veh_a2'), tests.fx('veh_a2_2'))), 2::bigint,
                'the inspections keep their vehicles');
select tests.eq((select count(*) from public.vehicles where id in (tests.fx('veh_a2'), tests.fx('veh_a2_2'))), 2::bigint,
                'both vehicles still exist');

-- the way out: archive; or remove the (unsigned) inspection, then the vehicle
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.vehicles set archived_at = now() where id = tests.fx('veh_a2_2')$$,
                   'a vehicle with inspections is archived instead');
select tests.eq(tests.row_count($$delete from public.inspections where id = tests.fx('insp_a2_truck')$$), 1::bigint,
                'a manager deletes the unsigned inspection');
select tests.eq(tests.row_count($$delete from public.vehicles where id = tests.fx('veh_a2_2')$$), 1::bigint,
                'then the vehicle can be deleted');
select tests.ok((select bool_and(vehicle_id is null) from public.job_line_items
                  where job_id = tests.fx('job_a2') and name = 'Truck wash'),
                'its line item loses the vehicle as before');

-- a signed inspection pins its vehicle until a manager removes the signature
update public.inspections set signed_by_name = 'Aaron Other',
                              customer_signature_path = tests.fx('shop_a') || '/inspections/sig-2.png'
 where id = tests.fx('insp_a2');
select tests.ok((select signed_at is not null from public.inspections where id = tests.fx('insp_a2')), 'veh_a2 inspection signed');
select tests.throws($$delete from public.inspections where id = tests.fx('insp_a2')$$, '42501',
                    'the signed inspection cannot be deleted');
select tests.throws_like($$delete from public.vehicles where id = tests.fx('veh_a2')$$, '23503', '%inspections_vehicle_fk%',
                         'so its vehicle cannot be deleted either');

-- cross-shop: B's staff cannot touch A's vehicles; A's staff cannot touch B's
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from public.vehicles where id = tests.fx('veh_a2')$$), 0::bigint,
                'shop B cannot delete A''s inspected vehicle');
select tests.eq(tests.row_count($$update public.inspections set vehicle_id = null where id = tests.fx('insp_a2_none')$$), 0::bigint,
                'nor edit A''s inspections');
insert into public.inspections (shop_id, job_id, vehicle_id, kind, signed_by_name, customer_signature_path)
  values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('veh_b'), 'pre', 'Bob Burns', tests.fx('shop_b') || '/inspections/sig-b.png')
  returning tests.fx_set('insp_b_signed', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$delete from public.vehicles where id = tests.fx('veh_b')$$), 0::bigint,
                'shop A cannot delete B''s vehicle');
select tests.as_superuser();
select tests.eq((select vehicle_id from public.inspections where id = tests.fx('insp_a2')), tests.fx('veh_a2'),
                'A''s signed inspection still names its vehicle');

-- deleting the whole shop still cascades through signed, vehicle-bound inspections
select tests.as_service();  -- payments delete_shop (0117)
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 1::bigint,
                'shop B is deleted with a signed inspection on a vehicle');
select tests.as_superuser();
select tests.eq((select count(*) from public.inspections where shop_id = tests.fx('shop_b')), 0::bigint,
                'shop B''s inspections are gone');
select tests.eq((select count(*) from public.inspections where shop_id = tests.fx('shop_a') and job_id = tests.fx('job_a2')), 3::bigint,
                'shop A''s inspections are untouched');

-- ------------------------------------------------------------ privileges
select tests.ok(not has_table_privilege('anon', 'public.inspections', 'select'), 'anon has no inspection access');
select tests.ok(not has_table_privilege('anon', 'public.inspection_marks', 'insert'), 'anon has no mark access');
select tests.ok(not has_function_privilege('authenticated', 'public.storage_object_exists(text, text)', 'execute'),
                'clients cannot probe storage object names');
