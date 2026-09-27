-- 20 field ops: form_templates, form_submissions — admin+ templates,
-- auto-attach on job insert (all_jobs / online_booking), body snapshots,
-- manual attach, public view/sign by token (anon), staff on-device signing,
-- sign-once, void forms, signer IP, immutability, cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ templates: admin+ write, members read
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Waiver', 'Text')$$, '42501',
                    'managers cannot create form templates (shop settings)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Waiver', 'Text')$$, '42501',
                    'technicians cannot create form templates');

select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_a'), '  Service agreement ', 'I authorize the work described.', 'all_jobs')
  returning tests.fx_set('tpl_all', id);
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_a'), 'Online booking terms', 'Deposit terms.', 'online_booking')
  returning tests.fx_set('tpl_online', id);
insert into public.form_templates (shop_id, name, body, attach_to, requires_signature)
  values (tests.fx('shop_a'), 'Care instructions', 'Do not wash for 7 days.', 'manual', false)
  returning tests.fx_set('tpl_manual', id);
insert into public.form_templates (shop_id, name, body, attach_to, active)
  values (tests.fx('shop_a'), 'Retired waiver', 'Old text.', 'all_jobs', false)
  returning tests.fx_set('tpl_inactive', id);
select tests.eq((select name from public.form_templates where id = tests.fx('tpl_all')), 'Service agreement', 'name trimmed');
select tests.throws($$insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Empty', '')$$, '23514',
                    'a body is required');
select tests.throws($$insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_b'), 'X', 'Y')$$, '42501',
                    'admins of A cannot create templates in B');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.form_templates$$), 4::bigint, 'technicians read form templates');
select tests.eq(tests.row_count($$update public.form_templates set body = 'x'$$), 0::bigint, 'technicians cannot edit templates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.form_templates set body = 'x'$$), 0::bigint, 'managers cannot edit templates');
select tests.eq(tests.row_count($$delete from public.form_templates$$), 0::bigint, 'managers cannot delete templates');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$select 1 from public.form_templates$$), 0::bigint, 'shop B sees none of A''s templates');

-- ------------------------------------------------------------ auto-attach on job insert
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-07-01 15:00Z', '2025-07-01 17:00Z')
  returning tests.fx_set('job_f', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_f'), tests.fx('m_tech_a'));
select tests.eq((select array_agg(title) from public.form_submissions where job_id = tests.fx('job_f')),
                array['Service agreement'], 'staff jobs get the active all_jobs forms only');
select tests.fx_set('sub_f', (select id from public.form_submissions where job_id = tests.fx('job_f')));
select tests.ok((select body_snapshot = 'I authorize the work described.' and requires_signature and customer_id = tests.fx('cust_a')
                   and form_template_id = tests.fx('tpl_all') and signed_at is null
                   from public.form_submissions where id = tests.fx('sub_f')), 'body snapshot, customer and template recorded');

insert into public.jobs (shop_id, customer_id, status, source) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', 'online_booking')
  returning tests.fx_set('job_online', id);
select tests.eq((select array_agg(title order by title) from public.form_submissions where job_id = tests.fx('job_online')),
                array['Online booking terms', 'Service agreement'], 'online bookings also get online_booking forms');

-- template edits never change snapshots
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.form_templates set body = 'Revised agreement text.' where id = tests.fx('tpl_all');
select tests.eq((select body_snapshot from public.form_submissions where id = tests.fx('sub_f')), 'I authorize the work described.',
                'existing submissions keep the text they were created with');

-- shop B jobs never get A's forms
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_b'), tests.fx('cust_b'), 'requested');
select tests.eq((select count(*) from public.form_submissions where shop_id = tests.fx('shop_b')), 0::bigint, 'no cross-shop forms');

-- ------------------------------------------------------------ manual attach (managers+)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.form_submissions (shop_id, form_template_id, job_id, title, body_snapshot, public_token, signer_name, signed_at,
                                     customer_id)
  values (tests.fx('shop_a'), tests.fx('tpl_manual'), tests.fx('job_f'), 'Forged', 'Forged body', '00000000-0000-0000-0000-000000000009',
          'Mallory', '2000-01-01Z', tests.fx('cust_a2'))
  returning tests.fx_set('sub_manual', id);
select tests.ok((select title = 'Care instructions' and body_snapshot = 'Do not wash for 7 days.' and not requires_signature
                   and public.form_link_token(id) <> '00000000-0000-0000-0000-000000000009' and signer_name is null and signed_at is null
                   and customer_id = tests.fx('cust_a')
                   from public.form_submissions where id = tests.fx('sub_manual')),
                'manual attach: content from the template, customer from the job, token and signing fields server-controlled');
select tests.throws($$insert into public.form_submissions (shop_id, form_template_id, job_id)
                      values (tests.fx('shop_a'), tests.fx('tpl_manual'), tests.fx('job_f'))$$, '23505',
                    'one submission per template per job');
select tests.throws($$insert into public.form_submissions (shop_id, job_id) values (tests.fx('shop_a'), tests.fx('job_f'))$$, '23502',
                    'a template is required for direct inserts');
select tests.throws($$insert into public.form_submissions (shop_id, form_template_id, job_id)
                      values (tests.fx('shop_b'), tests.fx('tpl_manual'), tests.fx('job_b'))$$, '42501',
                    'managers cannot attach forms in another shop');
select tests.as_service();
select tests.throws($$insert into public.form_submissions (shop_id, form_template_id, job_id, title, body_snapshot)
                      values (tests.fx('shop_b'), tests.fx('tpl_manual'), tests.fx('job_b'), 'T', 'B')$$, '23503',
                    'composite FK blocks another shop''s template');
select tests.throws($$insert into public.form_submissions (shop_id, job_id, title, body_snapshot)
                      values (tests.fx('shop_a'), tests.fx('job_b'), 'T', 'B')$$, '23503',
                    'composite FK blocks another shop''s job');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.form_submissions (shop_id, form_template_id, job_id)
                      values (tests.fx('shop_a'), tests.fx('tpl_online'), tests.fx('job_f'))$$, '42501',
                    'technicians cannot attach forms');
select tests.eq(tests.row_count($$select 1 from public.form_submissions$$), 2::bigint, 'technicians see forms of assigned jobs');
select tests.throws($$update public.form_submissions set signer_name = 'Me' where id = tests.fx('sub_f')$$, '42501',
                    'no direct updates: signing goes through the RPCs');
select tests.eq(tests.row_count($$delete from public.form_submissions$$), 0::bigint, 'technicians cannot delete forms');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.form_submissions where job_id = tests.fx('job_f')$$), 0::bigint,
                'unassigned technicians cannot see the job''s forms');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.form_submissions$$), 0::bigint, 'shop B sees none of A''s forms');
select tests.eq(tests.row_count($$delete from public.form_submissions$$), 0::bigint, 'shop B deletes none of A''s forms');

-- ------------------------------------------------------------ public_get_form (anon)
select tests.as_superuser();
select tests.fx_set('tok_f', (select public_token from public.form_submissions where id = tests.fx('sub_f')));
select tests.fx_set('tok_manual', (select public_token from public.form_submissions where id = tests.fx('sub_manual')));
select tests.as_anon();
select tests.eq((select jsonb_object_keys_agg from (select array_agg(k order by k) as jsonb_object_keys_agg
                   from jsonb_object_keys(public.public_get_form(tests.fx('tok_f'))) k) x),
                array['customer', 'form', 'job', 'shop', 'signature_upload_prefix'], 'curated top-level keys');
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(public.public_get_form(tests.fx('tok_f')) -> 'form') k),
                array['body', 'requires_signature', 'signed_at', 'signer_name', 'status', 'title'], 'curated form keys');
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(public.public_get_form(tests.fx('tok_f')) -> 'shop') k),
                array['brand_color', 'logo_path', 'name', 'slug', 'timezone'], 'curated shop keys');
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(public.public_get_form(tests.fx('tok_f')) -> 'job') k),
                array['number', 'scheduled_end', 'scheduled_start', 'vehicle'], 'curated job keys (no internal notes)');
select tests.eq(public.public_get_form(tests.fx('tok_f')) #>> '{form,status}', 'pending', 'unsigned form is pending');
select tests.eq(public.public_get_form(tests.fx('tok_f')) #>> '{form,body}', 'I authorize the work described.', 'body is the snapshot');
select tests.eq(public.public_get_form(tests.fx('tok_f')) #>> '{job,vehicle}', '2021 Honda Civic', 'vehicle label');
select tests.eq(public.public_get_form(tests.fx('tok_f')) ->> 'signature_upload_prefix',
                tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/', 'upload prefix for the signature image');
select tests.ok(public.public_get_form(tests.fx('tok_f'))::text not like '%internal%'
                and public.public_get_form(tests.fx('tok_f'))::text not like '%alice@example.com%',
                'no internal notes or customer contact details');
select tests.throws($$select public.public_get_form(gen_random_uuid())$$, 'P0002', 'unknown token');
select tests.throws($$select * from public.form_submissions$$, '42501', 'anon has no direct table access');
select tests.throws($$select public.sign_form_submission(tests.fx('sub_f'), 'Alice', null)$$, '42501',
                    'anon cannot use the staff signing RPC');

-- ------------------------------------------------------------ public_sign_form (anon)
select tests.as_superuser();
insert into storage.objects (bucket_id, name) values
  ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/sig.png'),
  ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/nested/sig.png'),
  ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_manual') || '/other-form.png'),
  ('signatures', tests.fx('shop_b') || '/forms/' || tests.fx('tok_f') || '/sig.png'),
  ('job-photos', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/photo.png');
select tests.as_anon();
-- the first X-Forwarded-For hop is whatever the client sent; only the hop the proxy appended counts
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.77, 203.0.113.9", "user-agent": "test"}', true);
select tests.throws_like($$select public.public_sign_form(tests.fx('tok_f'), 'Alice Anders', null)$$, '22023',
                         '%signature is required%', 'a required signature cannot be skipped');
select tests.throws_like($$select public.public_sign_form(tests.fx('tok_f'), '   ', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/sig.png')$$,
                         '22023', '%signer name%', 'the signer name is required');
select tests.throws($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_manual') || '/other-form.png')$$,
                    '22023', 'another form''s upload folder is rejected');
select tests.throws($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_b') || '/forms/' || tests.fx('tok_f') || '/sig.png')$$,
                    '22023', 'another shop''s folder is rejected');
select tests.throws($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/nested/sig.png')$$,
                    '22023', 'the image must sit directly in the token folder');
select tests.throws($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/photo.png')$$,
                    '22023', 'the image must be in the signatures bucket');
select tests.throws_like($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/missing.png')$$,
                         '22023', '%upload the signature%', 'the image must be uploaded first');
select tests.throws($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/../x/sig.png')$$,
                    '22023', 'unsafe paths are rejected');
select tests.throws($$select public.public_sign_form(gen_random_uuid(), 'Alice', 'x')$$, 'P0002', 'wrong token');

select tests.eq(public.public_sign_form(tests.fx('tok_f'), '  Alice Anders ', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/sig.png')
                  #>> '{form,status}', 'signed', 'anon signs with a valid token and uploaded signature');
select tests.throws_like($$select public.public_sign_form(tests.fx('tok_f'), 'Alice', tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/sig.png')$$,
                         '22023', '%already been signed%', 'a form is signed only once');
select tests.eq(public.public_get_form(tests.fx('tok_f')) #>> '{form,signer_name}', 'Alice Anders', 'signer name shown, trimmed');
select tests.eq(public.public_get_form(tests.fx('tok_f')) -> 'signature_upload_prefix', 'null'::jsonb,
                'no upload prefix once signed');
select tests.as_superuser();
select tests.ok((select signed_at = now() and signer_ip = '203.0.113.9'::inet and signed_by is null
                        and signature_path = tests.fx('shop_a') || '/forms/' || tests.fx('tok_f') || '/sig.png'
                   from public.form_submissions where id = tests.fx('sub_f')),
                'signed_at, proxy-appended (right-most) forwarded IP and signature path recorded; anonymous signer has no user');

-- a form that does not require a signature can be acknowledged by name; bad header JSON is ignored
select tests.as_anon();
select set_config('request.headers', 'not json', true);
select tests.eq(public.public_sign_form(tests.fx('tok_manual'), 'Alice Anders') #>> '{form,status}', 'signed',
                'acknowledgement without a signature image');
select tests.as_superuser();
select tests.ok((select signature_path is null and signer_ip is null from public.form_submissions where id = tests.fx('sub_manual')),
                'no image, no IP when headers are unusable');

-- portal (authenticated, non-member) signer is recorded
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('client@example.com'));
select tests.fx_set('tok_online', (select public_token from public.form_submissions
                                    where job_id = tests.fx('job_online') and form_template_id = tests.fx('tpl_online')));
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_online') || '/s.png');
select tests.authenticate_as(tests.fx('u_client'));
select set_config('request.headers', '{"x-real-ip": "198.51.100.7"}', true);
select tests.lives($$select public.public_sign_form(tests.fx('tok_online'), 'Aaron Other', tests.fx('shop_a') || '/forms/' || tests.fx('tok_online') || '/s.png')$$,
                   'a signed-in client signs through the public RPC');
select tests.as_superuser();
select tests.ok((select signed_by = tests.fx('u_client') and signer_ip = '198.51.100.7'::inet from public.form_submissions
                  where public_token = tests.fx('tok_online')), 'portal signer and x-real-ip recorded');

-- ------------------------------------------------------------ void forms (cancelled / no-show jobs)
select tests.fx_set('tok_online_all', (select public_token from public.form_submissions
                                        where job_id = tests.fx('job_online') and form_template_id = tests.fx('tpl_all')));
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok_online_all') || '/s.png');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'cancelled', cancel_reason = 'Customer rescheduled' where id = tests.fx('job_online');
select tests.as_anon();
select tests.eq(public.public_get_form(tests.fx('tok_online_all')) #>> '{form,status}', 'void', 'forms of cancelled jobs are void');
select tests.throws_like($$select public.public_sign_form(tests.fx('tok_online_all'), 'Aaron', tests.fx('shop_a') || '/forms/' || tests.fx('tok_online_all') || '/s.png')$$,
                         '22023', '%void%', 'void forms cannot be signed');
select tests.eq(public.public_get_form(tests.fx('tok_online')) #>> '{form,status}', 'signed', 'signed forms stay signed');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'requested' where id = tests.fx('job_online');
select tests.as_anon();
select tests.eq(public.public_get_form(tests.fx('tok_online_all')) #>> '{form,status}', 'pending', 'reinstated job: pending again');

-- ------------------------------------------------------------ staff signing on device
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body) values (tests.fx('shop_a'), 'Pickup release', 'Vehicle returned in good order.')
  returning tests.fx_set('tpl_release', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.form_submissions (shop_id, form_template_id, job_id) values (tests.fx('shop_a'), tests.fx('tpl_release'), tests.fx('job_f'))
  returning tests.fx_set('sub_release', id);
select tests.as_superuser();
insert into storage.objects (bucket_id, name, owner) values
  ('signatures', tests.fx('shop_a') || '/device/release.png', tests.fx('u_tech_a')),
  ('signatures', tests.fx('shop_b') || '/device/release.png', tests.fx('u_tech_b'));
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.sign_form_submission(tests.fx('sub_release'), 'Alice', tests.fx('shop_a') || '/device/release.png')$$,
                    '42501', 'unassigned technicians cannot collect signatures');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.sign_form_submission(tests.fx('sub_release'), 'Alice', tests.fx('shop_b') || '/device/release.png')$$,
                    'P0002', 'other shops cannot find the form');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.sign_form_submission(tests.fx('sub_release'), 'Alice', tests.fx('shop_b') || '/device/release.png')$$,
                    '22023', 'the image must be in this shop''s folder');
select tests.throws($$select public.sign_form_submission(tests.fx('sub_release'), 'Alice', null)$$, '22023', 'signature required');
select tests.eq((public.sign_form_submission(tests.fx('sub_release'), 'Alice Anders', tests.fx('shop_a') || '/device/release.png')).signed_by,
                tests.fx('u_tech_a'), 'the assigned technician collects the signature on device');
select tests.throws($$select public.sign_form_submission(tests.fx('sub_release'), 'Alice Anders', tests.fx('shop_a') || '/device/release.png')$$,
                    '22023', 'staff cannot sign twice either');
select tests.throws($$select public.sign_form_submission(gen_random_uuid(), 'Alice', null)$$, 'P0002', 'unknown submission');

-- ------------------------------------------------------------ immutability, customer sync, deletes
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.form_submissions where id = tests.fx('sub_release')$$, '42501', 'signed forms cannot be deleted');
insert into public.form_submissions (shop_id, form_template_id, job_id) values (tests.fx('shop_a'), tests.fx('tpl_online'), tests.fx('job_f'))
  returning tests.fx_set('sub_unsigned', id);
-- a job carrying a form its customer signed keeps that customer (moves of
-- jobs with only unsigned forms: 20_job_customer_records.sql)
insert into public.vehicles (shop_id, customer_id, make) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'Van') returning tests.fx_set('veh_a3', id);
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = tests.fx('veh_a3') where id = tests.fx('job_f')$$,
                         '23514', '%form signed by its customer%', 'a job with a signed form keeps its customer');
select tests.eq((select customer_id from public.form_submissions where id = tests.fx('sub_unsigned')), tests.fx('cust_a'),
                'nothing moved: the unsigned form stays with the job''s customer');
select tests.eq((select customer_id from public.form_submissions where id = tests.fx('sub_release')), tests.fx('cust_a'),
                'signed forms keep the customer who signed');
select tests.eq(tests.row_count($$delete from public.form_submissions where id = tests.fx('sub_unsigned')$$), 1::bigint,
                'unsigned forms can be removed by managers');
select tests.authenticate_as(tests.fx('u_admin_a'));
delete from public.form_templates where id = tests.fx('tpl_release');
select tests.ok((select form_template_id is null and body_snapshot = 'Vehicle returned in good order.'
                   from public.form_submissions where id = tests.fx('sub_release')), 'deleting a template keeps signed snapshots');
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_f');
select tests.as_superuser();
select tests.eq((select count(*) from public.form_submissions where job_id = tests.fx('job_f')), 0::bigint,
                'deleting the job removes its forms, signed or not');

-- ------------------------------------------------------------ signer IP comes from proxy-set headers only
-- Regression: form_signer_ip() took the client-controlled first
-- X-Forwarded-For entry, so a public signer could record any IP they chose.
select tests.as_superuser();
insert into public.form_templates (shop_id, name, body, requires_signature) values (tests.fx('shop_a'), 'IP waiver', 'I agree', false)
  returning tests.fx_set('tpl_ip', id);
insert into public.form_submissions (shop_id, form_template_id, job_id, customer_id, title, body_snapshot, requires_signature)
  values (tests.fx('shop_a'), tests.fx('tpl_ip'), tests.fx('job_a'), tests.fx('cust_a'), 'IP waiver', 'I agree', false)
  returning tests.fx_set('sub_ip', id);
select tests.fx_set('tok_ip', (select public_token from public.form_submissions where id = tests.fx('sub_ip')));
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.77, 203.0.113.9", "x-real-ip": "203.0.113.9"}', true);
select public.public_sign_form(tests.fx('tok_ip'), 'Alice Anders', null);
select tests.as_superuser();
select tests.ok((select signer_ip from public.form_submissions where id = tests.fx('sub_ip')) <> '198.51.100.77'::inet,
                'signer_ip must not be the client-controlled first X-Forwarded-For hop');
select tests.eq((select signer_ip from public.form_submissions where id = tests.fx('sub_ip')), '203.0.113.9'::inet,
                'the proxy-set x-real-ip is recorded');

-- source priority: cf-connecting-ip, then x-real-ip, then the right-most X-Forwarded-For hop
select set_config('request.headers', '{"cf-connecting-ip": "192.0.2.10", "x-real-ip": "203.0.113.9", "x-forwarded-for": "198.51.100.77"}', true);
select tests.eq(public.form_signer_ip(), '192.0.2.10'::inet, 'cf-connecting-ip wins');
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.77, 10.1.2.3 , 203.0.113.44 "}', true);
select tests.eq(public.form_signer_ip(), '203.0.113.44'::inet, 'without proxy headers the right-most forwarded hop is used');
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.77"}', true);
select tests.eq(public.form_signer_ip(), '198.51.100.77'::inet, 'a single forwarded hop is the one the proxy appended');
select set_config('request.headers', '{"cf-connecting-ip": "not-an-ip", "x-real-ip": "2001:db8::5", "x-forwarded-for": "198.51.100.77"}', true);
select tests.eq(public.form_signer_ip(), '2001:db8::5'::inet, 'a malformed header is skipped; IPv6 accepted');
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.77, garbage"}', true);
select tests.eq(public.form_signer_ip(), null::inet, 'a malformed right-most hop never falls back to a client-chosen hop');
select set_config('request.headers', '{"x-real-ip": "203.0.113.9/24"}', true);
select tests.eq(public.form_signer_ip(), '203.0.113.9'::inet, 'a netmask is stripped to the host address');
select set_config('request.headers', '[]', true);
select tests.eq(public.form_signer_ip(), null::inet, 'non-object header JSON yields no IP');
select set_config('request.headers', '', true);
select tests.eq(public.form_signer_ip(), null::inet, 'no headers, no IP');
select tests.ok(not has_function_privilege('anon', 'public.form_signer_ip()', 'execute')
                and not has_function_privilege('authenticated', 'public.form_signer_ip()', 'execute'),
                'API roles cannot call the IP helper directly');

-- ------------------------------------------------------------ privileges
select tests.ok(has_function_privilege('anon', 'public.public_get_form(uuid)', 'execute'), 'anon may view forms by token');
select tests.ok(has_function_privilege('anon', 'public.public_sign_form(uuid, text, text)', 'execute'), 'anon may sign forms by token');
select tests.ok(not has_function_privilege('anon', 'public.sign_form_submission(uuid, text, text)', 'execute'), 'staff RPC is not anon');
select tests.ok(not has_function_privilege('authenticated', 'public.form_submission_sign(uuid, text, text, text)', 'execute'),
                'the internal signing helper is not callable by clients');
select tests.ok(not has_function_privilege('anon', 'public.form_submission_public_json(uuid)', 'execute'),
                'the internal JSON helper is not callable by clients');
select tests.ok(not has_table_privilege('authenticated', 'public.form_submissions', 'update'), 'no direct updates of submissions');
