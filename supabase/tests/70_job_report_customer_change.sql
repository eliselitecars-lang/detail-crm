-- 70 ops: a job report link (P-8) belongs to the job's customer. Moving the
-- job to another customer revokes the live report (jobs_ops_report_
-- customer_change, 0072): the previous customer's link returns PT404 and
-- shows no media, cannot sign off an inspection created for the new
-- customer, its queued 'job_report' messages are withdrawn (and a retried
-- one too), and its signature folder is queued for the purge. A merge keeps
-- the link (same person); a client cannot fake the merge setting; other
-- edits of the job keep it; publishing again issues a new link; shop B is
-- untouched.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550170', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550170' where id = tests.fx('shop_a');
delete from public.message_templates where shop_id = tests.fx('shop_a') and key = 'job_report';
insert into public.message_templates (shop_id, key, channel, body)
  values (tests.fx('shop_a'), 'job_report', 'sms', 'Your job report is ready: {{report_link}}');
update public.customers set phone = '+12055550199' where id = tests.fx('cust_a2');
insert into public.vehicles (shop_id, customer_id, year, make, model, color)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), 2022, 'Porsche', 'Taycan', 'Blue') returning tests.fx_set('veh_new', id);
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), now() + interval '2 days', now() + interval '2 days 2 hours')
  returning tests.fx_set('job_r', id);
insert into storage.objects (bucket_id, name, owner) values
  ('job-photos', tests.fx('shop_a') || '/' || tests.fx('job_r') || '/after-1.jpg', tests.fx('u_tech_a'));
insert into public.job_photos (shop_id, job_id, storage_path, kind, customer_visible)
  values (tests.fx('shop_a'), tests.fx('job_r'), tests.fx('shop_a') || '/' || tests.fx('job_r') || '/after-1.jpg', 'after', true)
  returning tests.fx_set('ph', id);

-- ============================================================ publish to Alice
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pub1 as select public.publish_job_report(tests.fx('job_r'), p_send => true, p_channel => 'sms') as r;
select tests.fx_set('tok', ((select r from pub1) ->> 'token')::uuid);
select tests.fx_set('rep', ((select r from pub1) ->> 'report_id')::uuid);
select tests.eq((select r -> 'queued' from pub1), 'true'::jsonb, 'the link is texted to Alice');
select tests.fx_set('msg_q', (select id from public.messages where job_id = tests.fx('job_r') and template_key = 'job_report'));
select tests.eq((select array[to_address, status::text] from public.messages where id = tests.fx('msg_q')),
                array['+12055550101', 'queued'], 'queued to Alice');
select tests.as_anon();
select tests.eq((select public.public_get_job_report(tests.fx('tok')) #>> '{vehicle,model}'), 'Civic', 'Alice sees her Civic');

-- a second copy is already with the sender when the job moves
select tests.as_superuser();
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status, template_key,
                             claimed_at, attempts)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_r'), 'outbound', 'sms', '+12055550101',
          'Your job report is ready: https://app.example.test/r/' || tests.fx('tok'), 'sending', 'job_report', now(), 1)
  returning tests.fx_set('msg_s', id);
-- an unrelated free-form message on the job is not touched
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, body, status)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('job_r'), 'outbound', 'sms', '+12055550101', 'See you soon', 'queued')
  returning tests.fx_set('msg_free', id);

-- shop B has a live report of its own
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('tok_b', ((public.publish_job_report(tests.fx('job_b'))) ->> 'token')::uuid);

-- ============================================================ other edits keep the link
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set notes = 'Park in the drive' where id = tests.fx('job_r');
select tests.as_anon();
select tests.lives($$select public.public_get_job_report(tests.fx('tok'))$$, 'editing the job keeps the link');

-- ============================================================ the job moves to Aaron
select tests.as_superuser();
delete from public.storage_purge_requests where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
-- a client cannot borrow the merge bypass
select set_config('detailcrm.customer_merge', 'on', true);
update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_new') where id = tests.fx('job_r');
select set_config('detailcrm.customer_merge', '', true);
select tests.eq((select customer_id from public.jobs where id = tests.fx('job_r')), tests.fx('cust_a2'),
                'moved (allowed: no inspection, signed form or invoice)');

select tests.as_anon();
select tests.throws($$select public.public_get_job_report(tests.fx('tok'))$$, 'PT404',
                    'the previous customer''s report link stops working once the job belongs to someone else');
select tests.as_superuser();
select tests.ok((select revoked_at is not null from public.job_reports where id = tests.fx('rep')), 'the report is revoked (kept)');
select tests.eq((select array[status::text, error] from public.messages where id = tests.fx('msg_q')),
                array['cancelled', 'the job report link was withdrawn'], 'the queued link message to Alice is withdrawn');
select tests.eq((select status::text from public.messages where id = tests.fx('msg_free')), 'queued',
                'a free-form message is not a report link');
select tests.eq((select status::text from public.messages where id = tests.fx('msg_s')), 'sending',
                'a message already with the sender is not touched');
select tests.eq((select array_agg(bucket_id || ' ' || replace(path, tests.fx('shop_a')::text, 'S') || ' ' || reason)
                   from public.storage_purge_requests where shop_id = tests.fx('shop_a')),
                array['signatures S/reports/' || tests.fx('tok') || '/ report_revoked'],
                'its sign-off folder is queued for the purge');
select tests.as_service();
select tests.eq(tests.row_count($$select * from public.job_report_media(tests.fx('tok'))$$), 0::bigint,
                'the old link lists no media of Aaron''s job');
-- the copy that was with the sender fails and comes back for a retry: withdrawn
select tests.eq((select array[status::text, error]
                   from public.mark_message_result(tests.fx('msg_s'), 'queued', null, 'Twilio 429')),
                array['cancelled', 'the job report link was withdrawn'], 'a retried link message for the revoked report is withdrawn');

-- an inspection created for Aaron cannot be signed off through Alice's link
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.inspections (shop_id, job_id, vehicle_id, kind)
  values (tests.fx('shop_a'), tests.fx('job_r'), tests.fx('veh_new'), 'pre') returning tests.fx_set('ins', id);
select tests.as_anon();
select tests.ok(not public.public_report_signature_upload_allowed(
                  tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png'),
                'no upload into the revoked report''s folder');
select tests.throws($$select public.public_ack_inspection(tests.fx('tok'), tests.fx('ins'), 'Alice',
                                                           tests.fx('shop_a') || '/reports/' || tests.fx('tok') || '/sig.png')$$,
                    'PT404', 'no sign-off through the old link');
select tests.as_superuser();
select tests.eq((select signed_at from public.inspections where id = tests.fx('ins')), null::timestamptz, 'still unsigned');

-- publishing again issues Aaron a new link
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pub2 as select public.publish_job_report(tests.fx('job_r'), p_send => true, p_channel => 'sms') as r;
select tests.fx_set('tok2', ((select r from pub2) ->> 'token')::uuid);
select tests.ok(tests.fx('tok2') <> tests.fx('tok'), 'a new token');
select tests.eq((select array_agg(to_address) from public.messages
                  where job_id = tests.fx('job_r') and template_key = 'job_report' and status = 'queued'),
                array['+12055550199'], 'texted to Aaron');
select tests.as_anon();
select tests.eq((select public.public_get_job_report(tests.fx('tok2')) #>> '{vehicle,model}'), 'Taycan', 'Aaron sees his Taycan');
select tests.throws($$select public.public_get_job_report(tests.fx('tok'))$$, 'PT404', 'Alice''s link stays dead');

-- a retry of a message for the live report is kept
select tests.as_superuser();
update public.messages set status = 'sending', claimed_at = now(), attempts = 1
 where job_id = tests.fx('job_r') and template_key = 'job_report' and status = 'queued'
returning tests.fx_set('msg_live', id);
select tests.as_service();
select tests.eq((select status::text from public.mark_message_result(tests.fx('msg_live'), 'queued', null, 'Twilio 429')),
                'queued', 'a retried link message for the live report goes out again');

-- moving the job back does not resurrect Alice's old link
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.inspections where id = tests.fx('ins');
update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('job_r');
select tests.as_anon();
select tests.throws($$select public.public_get_job_report(tests.fx('tok'))$$, 'PT404', 'moving back: the first link stays dead');
select tests.throws($$select public.public_get_job_report(tests.fx('tok2'))$$, 'PT404', 'and Aaron''s link is revoked in turn');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_reports where job_id = tests.fx('job_r') and revoked_at is null), 0::bigint,
                'no live report until staff publish again');
select tests.eq((select status::text from public.messages where id = tests.fx('msg_live')), 'cancelled',
                'the retried copy to Aaron is withdrawn with his link');

-- ============================================================ merges keep the link
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), null, now() + interval '3 days', now() + interval '3 days 1 hour')
  returning tests.fx_set('job_m', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('tok_m', ((public.publish_job_report(tests.fx('job_m'))) ->> 'token')::uuid);
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.merge_customers(tests.fx('cust_a3'), tests.fx('cust_a2'));
select tests.as_superuser();
select tests.eq((select customer_id from public.jobs where id = tests.fx('job_m')), tests.fx('cust_a2'), 'the merge moved the job');
select tests.as_anon();
select tests.lives($$select public.public_get_job_report(tests.fx('tok_m'))$$,
                   'a merge keeps the report link (the survivor is the same person)');
select tests.eq(current_setting('detailcrm.customer_merge', true), '', 'the merge setting is cleared afterwards');

-- ============================================================ shop B is untouched
select tests.lives($$select public.public_get_job_report(tests.fx('tok_b'))$$, 'shop B''s report stays live');
select tests.as_superuser();
select tests.eq((select count(*) from public.storage_purge_requests
                  where shop_id = tests.fx('shop_b') and reason = 'report_revoked'), 0::bigint, 'nothing of shop B is purged');

-- ============================================================ direct writes stay closed
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.job_reports set revoked_at = null where id = tests.fx('rep')$$, '42501',
                    'a revoked report cannot be revived directly');
select tests.throws($$select public.job_reports_ops_revoked()$$, '42501', 'trigger functions are not callable');
select tests.throws($$select public.jobs_ops_report_customer_change()$$, '42501', 'nor this one');
