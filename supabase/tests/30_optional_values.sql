-- 30 comms: optional values never go out blank.
-- Regression: the seeded default wording used {{shop_phone}} ("... or call
-- {{shop_phone}}.", "Questions? Call us at {{shop_phone}}.") and
-- {{vehicle}} ("your {{vehicle}} is all done!"), but a shop's phone is
-- optional (create_shop p_phone) and a job's vehicle is nullable; only
-- unavailable LINK lines were left out, so reminders, confirmations,
-- welcomes and job-complete texts reached customers as "Visit https://...
-- or call .", "Questions? Call us at ." and "your  is all done!".
-- Now a line whose optional value is missing is left out like a line whose
-- link is unavailable (comms_omit_unavailable_values), on every path that
-- renders a template (automations, staff sends, re-renders, the preview),
-- and the default wording keeps optional values on lines of their own.
\ir fixtures/two_shops.psql

insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id)
  values ('+12055550100', tests.fx('shop_a')), ('+13125550199', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100', phone = null where id = tests.fx('shop_a');  -- create_shop's p_phone is optional
update public.shops set sms_from_number = '+13125550199', phone = '+13125550100' where id = tests.fx('shop_b');
update public.customers set phone = '+13125550101', email = 'bob@example.com' where id = tests.fx('cust_b');

-- ============================================================ pure helpers
select tests.eq(public.comms_unavailable_values(
                  'Call {{shop_phone}} about {{ vehicle }} ({{services}}), {{job_number}} {{amount}} {{invoice_link}} {{customer_name}}',
                  '{"shop_phone": null, "vehicle": "  ", "services": {"a": 1}, "job_number": 1001, "amount": "$5.00",
                    "invoice_link": null}'),
                array['customer_name', 'invoice_link', 'services', 'shop_phone', 'vehicle'],
                'missing, null, blank and non-scalar values are unavailable (with links); numbers are values; sorted, distinct');
select tests.eq(public.comms_unavailable_values('{{shop_phone}} {{invoice_link}}', '{}', false), array['shop_phone'],
                'p_links false: only values');
select tests.eq(public.comms_unavailable_values('{{shop_name}} {{customer_first_name}} {{unsubscribe_link}} {{invite_link}} {{nope}}', '{}'),
                '{}'::text[], 'always-set, by-design-empty, sender-supplied and unknown names never count');
select tests.eq(public.comms_unavailable_values(null, '{}'), '{}'::text[], 'null text');
select tests.eq(public.comms_unavailable_values('{{vehicle}}', '[1]'), array['vehicle'], 'non-object vars');

select tests.eq(public.comms_omit_unavailable_values(
                  E'Hi,\n\nVehicle: {{vehicle}}\nServices: {{services}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
                  '{"vehicle": null, "services": "Full Detail", "shop_phone": ""}'),
                E'Hi,\n\nServices: {{services}}\n\n{{shop_name}}', 'value lines are left out with the blank line after them');
select tests.eq(public.comms_omit_unavailable_values(E'A {{vehicle}}\nB {{quote_link}}', '{}', false), E'B {{quote_link}}',
                'p_links false keeps a line whose only gap is a link');
select tests.eq(public.comms_omit_unavailable_values(E'A {{vehicle}}\nB', '{"vehicle": "2021 Honda Civic"}'), E'A {{vehicle}}\nB',
                'unchanged when every value is there');

-- the seeded wording keeps optional values on lines of their own
select tests.eq((select count(*) from public.default_message_templates() d, unnest(string_to_array(d.body, E'\n')) l
                  where l ~ '\{\{(shop_phone|vehicle)\}\}'
                    and l !~ '^(Questions\? Call( us at)? \{\{shop_phone\}\}\.|Vehicle: \{\{vehicle\}\})$'),
                0::bigint, 'every default line with {{shop_phone}} / {{vehicle}} is a stand-alone detail line');

-- ============================================================ automatic reminder of a shop without a phone (repro)
update public.jobs set status = 'scheduled', scheduled_start = '2025-08-10 15:00Z', scheduled_end = '2025-08-10 17:00Z',
       appointment_set_at = '2025-08-01 12:00Z' where id = tests.fx('job_a');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-09 15:01Z'), 2, 'reminder queued on sms + email');
select tests.ok(not exists (select 1 from public.messages m where m.job_id = tests.fx('job_a')
                              and (m.body ilike '%call .%' or m.body ilike '%call us at .%')),
                'no default message tells the customer to "call ." with a blank phone number');
select tests.eq((select body from public.messages where job_id = tests.fx('job_a') and template_key = 'appointment_reminder'
                                                   and channel = 'sms'),
                'Reminder: your appointment with Shop A is on Sunday, August 10 at 10:00 AM. Need to make a change? Visit https://app.example.test/booking/'
                  || (select public_token::text from public.jobs where id = tests.fx('job_a')),
                'the SMS reminder keeps the booking link and leaves out the phone line');
select tests.ok((select body like E'%Vehicle: 2021 Honda Civic\nServices: Full Detail\n\nNeed to make a change? Visit https://%\n\nShop A'
                   from public.messages where job_id = tests.fx('job_a') and template_key = 'appointment_reminder'
                                         and channel = 'email'),
                'the email reminder reads cleanly without the phone line');

-- shop B has a phone: its reminder keeps the line (the rule is per shop)
select tests.as_superuser();
update public.jobs set status = 'scheduled', scheduled_start = '2025-08-10 15:00Z', scheduled_end = '2025-08-10 16:00Z',
       appointment_set_at = '2025-08-01 12:00Z' where id = tests.fx('job_b');
select tests.as_service();
select tests.eq(public.enqueue_due_automations('2025-08-09 15:02Z'), 2, 'shop B reminded on sms + email');
select tests.ok((select bool_and(body like '%Questions? Call%(312) 555-0100.%') and count(*) = 2
                   from public.messages where job_id = tests.fx('job_b') and template_key = 'appointment_reminder'),
                'shop B''s reminders tell the customer its phone number');
select tests.ok(not exists (select 1 from public.messages where job_id = tests.fx('job_b') and body like '%555-01%' and body like '%Shop A%'),
                'shop A''s details never reach shop B''s customer');

-- ============================================================ a job without a vehicle
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'scheduled', '2025-08-20 15:00Z', '2025-08-20 17:00Z')
  returning tests.fx_set('job_nv', id);
select tests.as_service();
select tests.fx_set('done_sms', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_completed', 'sms',
                                                                 tests.fx('job_nv')));
select tests.fx_set('done_email', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_completed', 'email',
                                                                   tests.fx('job_nv')));
select tests.fx_set('started_sms', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_started', 'sms',
                                                                    tests.fx('job_nv')));
select tests.as_superuser();
select tests.eq((select body from public.messages where id = tests.fx('done_sms')),
                'Hi Alice, your vehicle is all done! Thank you for choosing Shop A.', 'job-complete text without a vehicle on file');
select tests.eq((select body from public.messages where id = tests.fx('done_email')),
                E'Hi Alice,\n\nGood news: the work on your vehicle is complete.\n\nThank you for choosing Shop A.\n\nShop A',
                'job-complete email: no blank vehicle, services or phone lines');
select tests.ok((select body like 'Hi Alice, we have started work on your vehicle.%' from public.messages where id = tests.fx('started_sms')),
                'job-started text without a vehicle on file');
select tests.ok(not exists (select 1 from public.messages where job_id = tests.fx('job_nv') and (body like '%  %' or body ~ ': ?(\n|$)')),
                'no double spaces or dangling labels');
-- with a vehicle the email names it on its own line
select tests.as_service();
select tests.fx_set('done_a', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_completed', 'email',
                                                               tests.fx('job_a')));
select tests.as_superuser();
select tests.ok((select body like E'%complete.\n\nVehicle: 2021 Honda Civic\nServices: Full Detail\n\nThank you%'
                   from public.messages where id = tests.fx('done_a')), 'the vehicle is named when the job has one');

-- ============================================================ SMS defaults that used to end in "call ."
select tests.as_service();
select tests.fx_set('welcome', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'sms'));
select tests.eq((select body from public.messages where id = tests.fx('welcome')),
                'Hi Alice, welcome to your Shop A membership! We are glad to have you.',
                'membership welcome text without a shop phone');
select tests.fx_set('welcome_b', public.enqueue_customer_template(tests.fx('shop_b'), tests.fx('cust_b'), 'membership_welcome', 'sms'));
select tests.eq((select body from public.messages where id = tests.fx('welcome_b')),
                E'Hi Bob, welcome to your Shop B membership! We are glad to have you.\nQuestions? Call (312) 555-0100.',
                'with a shop phone the line is there');
-- a receipt for a payment on no job / invoice (no balance to state) still thanks the customer
select tests.fx_set('rcpt', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'payment_receipt', 'sms',
                                                             null, '{"amount": "$40.00"}'));
select tests.eq((select body from public.messages where id = tests.fx('rcpt')),
                'Thank you, Alice! Shop A received your payment of $40.00.', 'receipt text without a balance line');

-- ============================================================ staff sends, re-renders and the preview
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('staff_conf', public.enqueue_template_message(tests.fx('job_nv'), 'booking_confirmed', null, 'email'));
select tests.as_superuser();
select tests.ok((select body not like '%Vehicle:%' and body not like '%Call us at%' and body not like '%Services:%'
                        and body like '%Date: Wednesday, August 20%'
                   from public.messages where id = tests.fx('staff_conf')),
                'a staff-sent confirmation leaves out the vehicle, services and phone lines it has no value for');
-- a reschedule re-renders by the same rule
update public.jobs set scheduled_start = '2025-08-21 15:00Z', scheduled_end = '2025-08-21 17:00Z' where id = tests.fx('job_nv');
select tests.ok((select body like '%Date: Thursday, August 21%' and body not like '%Vehicle:%' and body not like '%Call us at%'
                   from public.messages where id = tests.fx('staff_conf')),
                're-rendered for the new date, still without the blank lines');
-- the preview shows exactly that; a missing LINK still renders blank so staff see it (the send refuses it)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select p.body not like '%Vehicle:%' and p.body not like '%Call us at%'
                   from public.preview_template_message(tests.fx('job_nv'), 'booking_confirmed', 'email') p),
                'the preview leaves out the same lines');
select tests.ok((select p.body like '%Review and approve it here: ' || E'\n%' and p.body not like '%Call us at%'
                   from public.preview_template_message(tests.fx('job_nv'), 'quote_sent', 'email') p),
                'the preview keeps a blank quote link visible but drops the blank phone line');

-- ============================================================ access
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.preview_template_message(tests.fx('job_nv'), 'booking_confirmed', 'email')$$, '42501',
                    'a technician cannot preview another job''s confirmation');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.preview_template_message(tests.fx('job_nv'), 'booking_confirmed', 'email')$$, 'P0002',
                    'another shop cannot preview shop A''s job');
select tests.as_anon();
select tests.throws($$select public.comms_omit_unavailable_values('x', '{}')$$, '42501', 'anon cannot call the render helpers');
