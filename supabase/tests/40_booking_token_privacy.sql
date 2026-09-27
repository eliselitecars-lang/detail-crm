-- 40 integration: the job token (/booking/<token>) is a customer credential
--   Whoever holds it can, without signing in, read the booking page (invoice
--   link, paid total, balance) and cancel the appointment. Regression: an
--   assigned technician read jobs.public_token (jobs_select, 0006) and then,
--   signed out, opened the invoice/payments (bypassing
--   techs_can_collect_payments) and cancelled the job (bypassing the 42501
--   technician guard). Now:
--   * authenticated has SELECT on every jobs column except public_token
--     (checked over the whole column set, so a new column cannot silently
--     become unreadable and the token cannot silently become readable)
--   * owners/admins/managers get the token from job_booking_token(job_id);
--     technicians 42501; other shops / unknown jobs P0002; anon and
--     service_role cannot call it
--   * a technician's message preview labels link variables instead of
--     rendering the tokens
--   * the customer's token keeps working for the booking page and invoice
\ir fixtures/two_shops.psql
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test');

update public.jobs set scheduled_start = now() + interval '10 days', scheduled_end = now() + interval '10 days 2 hours'
 where id = tests.fx('job_a');
select tests.eq((select techs_can_collect_payments from public.shops where id = tests.fx('shop_a')), false,
                'shop A keeps the default: technicians do not collect payments');
select tests.fx_set('tok', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.fx_set('tok_b', (select public_token from public.jobs where id = tests.fx('job_b')));

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.record_manual_payment(tests.fx('inv'), 5000, 'cash', 0, null);

-- ============================================================ the repro: technician on job_a
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select 1 from public.invoices'), 0::bigint, 'tech: no invoices');
select tests.eq(tests.row_count('select 1 from public.payments'), 0::bigint, 'tech: no payments');
select tests.throws('select public.job_payment_summary(tests.fx(''job_a''))', '42501', 'tech: no payment summary');
select tests.throws($$select public_token from public.jobs where id = tests.fx('job_a')$$, '42501',
                    'tech: the job token column is not readable');
select tests.throws($$select * from public.jobs where id = tests.fx('job_a')$$, '42501',
                    'tech: select * cannot reach the token either');
select tests.throws($$select j from public.jobs j where j.id = tests.fx('job_a')$$, '42501',
                    'tech: nor a whole-row reference');
select tests.throws($$select count(*) from public.jobs where public_token = tests.fx('tok')$$, '42501',
                    'tech: nor filtering on the token (no guessing oracle)');
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, '42501',
                    'tech: job_booking_token refuses technicians');
select tests.eq(tests.row_count($$select id, number, status, scheduled_start, customer_id, total_cents
                                    from public.jobs where id = tests.fx('job_a')$$), 1::bigint,
                'tech: every other column of the assigned job stays readable');
select tests.eq(tests.row_count($$select id from public.jobs where id = tests.fx('job_a2')$$), 0::bigint,
                'tech: still no rows of jobs assigned to someone else');
-- a token the tech somehow holds is still refused while signed in (defence in depth)
select tests.throws('select public.public_cancel_booking(tests.fx(''tok''))', '42501', 'signed-in tech may not cancel');
-- the tech keeps the operational writes RLS allows on the assigned job
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'Gate code at the side door'
                                   where id = tests.fx('job_a') returning id$$),
                1::bigint, 'tech: allowed updates (returning id) still work without the token column');

-- ============================================================ technician message preview
select tests.authenticate_as(tests.fx('u_owner_a'));  -- templates are admin+
update public.message_templates
   set body = 'Done! Manage: {{booking_link}} Pay: {{invoice_link}} Quote: {{quote_link}} Review: {{review_link}}'
 where shop_id = tests.fx('shop_a') and key = 'job_completed' and channel = 'sms';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select body like '%/booking/' || tests.fx('tok')::text || '%'
                        and body like '%/i/' || public.invoice_link_token(tests.fx('inv'))::text || '%'
                   from public.preview_template_message(tests.fx('job_a'), 'job_completed', 'sms')),
                'manager preview renders the real booking and invoice links');
select tests.fx_set('inv_tok', public.invoice_link_token(tests.fx('inv')));
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select body from public.preview_template_message(tests.fx('job_a'), 'job_completed', 'sms')),
                'Done! Manage: [booking link] Pay: [invoice link] Quote:  Review:',
                'tech preview labels the links (no quote on the job stays empty) and carries no token');

-- ============================================================ managers+ share the link through the RPC
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.job_booking_token(tests.fx('job_a')), tests.fx('tok'), 'manager gets the booking token');
select tests.throws($$select public_token from public.jobs where id = tests.fx('job_a')$$, '42501',
                    'managers read the token only through the RPC too');
select tests.eq(tests.row_count($$select id from public.jobs where id = tests.fx('job_a')$$), 1::bigint,
                'manager: explicit column lists work');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.job_booking_token(tests.fx('job_a')), tests.fx('tok'), 'owner gets the booking token');
select tests.throws($$select public.job_booking_token(gen_random_uuid())$$, 'P0002', 'unknown job: not found');

-- ============================================================ cross-shop isolation
select tests.throws($$select public.job_booking_token(tests.fx('job_b'))$$, 'P0002', 'owner A cannot fetch shop B''s token');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, 'P0002', 'manager B cannot fetch shop A''s token');
select tests.eq(public.job_booking_token(tests.fx('job_b')), tests.fx('tok_b'), 'manager B gets their own shop''s token');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, 'P0002', 'tech B: another shop''s job is not found');

select tests.as_anon();
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, '42501', 'anon cannot call job_booking_token');
select tests.throws($$select id from public.jobs$$, '42501', 'anon has no jobs access at all');
select tests.as_service();
select tests.throws($$select public.job_booking_token(tests.fx('job_a'))$$, '42501', 'service_role reads the column instead');
select tests.eq((select public_token from public.jobs where id = tests.fx('job_a')), tests.fx('tok'),
                'service_role (edge functions) still resolves job tokens');

-- ============================================================ the customer's link keeps working
select tests.as_anon();
select tests.eq(public.public_get_booking(tests.fx('tok')) #>> '{invoice,token}', tests.fx('inv_tok')::text,
                'the customer''s booking page still links the invoice');
select tests.ok(jsonb_array_length(public.public_get_invoice(tests.fx('inv_tok')) -> 'payments') >= 1,
                'and the customer sees their payments');

-- ============================================================ column-privilege invariant (whole column set)
select tests.as_superuser();
select tests.eq((select array_agg(a.attname::text order by a.attnum)
                   from pg_catalog.pg_attribute a
                  where a.attrelid = 'public.jobs'::regclass and a.attnum > 0 and not a.attisdropped
                    and not has_column_privilege('authenticated', 'public.jobs', a.attname, 'SELECT')),
                array['public_token'],
                'authenticated can select every jobs column except public_token (grant new columns explicitly)');
select tests.ok(not has_table_privilege('authenticated', 'public.jobs', 'SELECT'),
                'no table-wide SELECT for authenticated (it would re-expose the token)');
select tests.ok(not has_column_privilege('anon', 'public.jobs', 'public_token', 'SELECT'), 'anon cannot read the token');
select tests.ok(has_column_privilege('service_role', 'public.jobs', 'public_token', 'SELECT'),
                'service_role keeps the token column');
select tests.ok(has_table_privilege('authenticated', 'public.jobs', 'INSERT')
                and has_table_privilege('authenticated', 'public.jobs', 'UPDATE')
                and has_table_privilege('authenticated', 'public.jobs', 'DELETE'),
                'writes are still governed by RLS policies, not by this grant');
