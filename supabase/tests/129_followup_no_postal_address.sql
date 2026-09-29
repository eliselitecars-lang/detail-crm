-- 129 (0129): a marketing follow-up email held back only because the shop
-- has no postal address on file (0119) is logged as 'no_postal_address'
-- (not a plain 'skipped'), nothing is queued, and it is not sent late once
-- the address is added.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
update public.shops set address_line1 = null, city = null where id = tests.fx('shop_a');
update public.shops set address_line1 = '1 B St', city = 'Hoover', region = 'AL', postal_code = '35216' where id = tests.fx('shop_b');
update public.message_templates set enabled = true
 where shop_id in (tests.fx('shop_a'), tests.fx('shop_b')) and key in ('follow_up', 'service_followup') and channel = 'email';
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
-- Alice's open fixture job has the service too (it would stand in for a follow-up)
update public.jobs set status = 'cancelled' where id = tests.fx('job_a');
update public.customers set email = 'bob@example.com', email_opt_in = true where id = tests.fx('cust_b');
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'Nora', 'nora@example.com')
  returning tests.fx_set('cust_nora', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, completed_at) values
  (tests.fx('shop_a'), tests.fx('cust_a'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_nora'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z'),
  (tests.fx('shop_b'), tests.fx('cust_b'), 'completed', '2025-05-01 14:00Z', '2025-05-01 16:00Z', '2025-05-01 16:00Z');
select tests.fx_set(k, (select id from public.jobs where customer_id = tests.fx(c) and completed_at = '2025-05-01 16:00Z'))
  from (values ('j_alice', 'cust_a'), ('j_nora', 'cust_nora'), ('j_bob', 'cust_b')) v(k, c);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j_alice'), tests.fx('svc_a'), 'Full Detail', 20000);
insert into public.service_followups (shop_id, service_id, channel, offset_days, subject, body)
  values (tests.fx('shop_a'), tests.fx('svc_a'), 'email', 10, 'Time again', 'Hi {{customer_first_name}}, book again: {{rebook_link}}')
  returning tests.fx_set('sfu', id);

select tests.ok(public.comms_marketing_email_needs_address(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up'),
                'helper: Alice''s follow-up needs only the address');
select tests.ok(not public.comms_marketing_email_needs_address(tests.fx('shop_a'), tests.fx('cust_nora'), 'follow_up'),
                'helper: Nora never consented');
select tests.ok(not public.comms_marketing_email_needs_address(tests.fx('shop_a'), tests.fx('cust_a'), 'review_request'),
                'helper: not for transactional keys');

-- ============================================================ follow_up (30 days after completion)
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-05-31 16:01Z'), 1, 'only shop B''s follow-up is queued');
select tests.as_superuser();
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('j_alice') and key = 'follow_up'),
                'no_postal_address', 'Alice''s follow-up: held back for the missing address, and says so');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('j_alice') and template_key = 'follow_up'), 0::bigint,
                'nothing was queued');
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('j_nora') and key = 'follow_up'),
                'skipped', 'no consent: plain skipped');
select tests.eq((select outcome from public.job_automation_log where job_id = tests.fx('j_bob') and key = 'follow_up'),
                'queued', 'a shop with an address: queued');

-- ============================================================ per-service follow-up (10 days, 10:00 local)
select tests.as_service();
select tests.eq(public.enqueue_service_followups('2025-05-11 15:00Z'), 0, 'nothing queued');
select tests.as_superuser();
select tests.eq((select outcome from public.job_automation_log
                  where job_id = tests.fx('j_alice') and key = 'service_followup' and service_followup_id = tests.fx('sfu')),
                'no_postal_address', 'the service follow-up says why too');

-- ============================================================ not sent late
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id = tests.fx('shop_a');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-05-31 18:00Z'), 0, 'adding the address later sends nothing late');
select tests.eq(public.enqueue_service_followups('2025-05-11 16:00Z'), 0, 'nor the service follow-up');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where job_id = tests.fx('j_alice')), 0::bigint, 'still nothing for Alice');

-- staff can count them (managers read the log)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.job_automation_log where shop_id = tests.fx('shop_a') and outcome = 'no_postal_address'),
                2::bigint, 'managers count the follow-ups held back');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.job_automation_log where shop_id = tests.fx('shop_a')), 0::bigint, 'not another shop');

-- the outcome check
select tests.as_superuser();
select tests.throws($$update public.job_automation_log set outcome = 'bogus' where job_id = tests.fx('j_nora')$$, '23514',
                    'outcome is one of queued / skipped / no_postal_address');
select tests.ok(not has_function_privilege('authenticated', 'public.comms_marketing_email_needs_address(uuid, uuid, public.message_template_key)', 'execute'),
                'the helper is internal');
