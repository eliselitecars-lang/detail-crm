-- 90 integration: server-rendered quote_sent / invoice_sent messages —
-- comms_document_vars (internal), enqueue_document_message and
-- preview_document_message (manager+): variables of quotes and invoices with
-- and without a job, the link only once the document is sent / issued, lines
-- with missing values left out, the role matrix, cross-shop isolation and
-- request_nonce idempotency.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100', phone = null where id = tests.fx('shop_a');

-- documents: a quote (draft), an invoice without a job, an invoice of job_a
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))
  returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('q'), 'Ceramic coating', 120000, false);
select tests.fx_set('inv', (public.create_invoice(tests.fx('cust_a'),
                              '[{"name":"Paint correction","unit_price_cents":45000,"taxable":false}]')).id);
select tests.fx_set('inv_job', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.as_superuser();   -- staff may not read document tokens directly (0015)
select tests.fx_set('q_tok', (select public_token from public.quotes where id = tests.fx('q')));
select tests.fx_set('inv_tok', (select public_token from public.invoices where id = tests.fx('inv')));
select tests.fx_set('inv_job_tok', (select public_token from public.invoices where id = tests.fx('inv_job')));
-- shop B's quote
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b')) returning tests.fx_set('q_b', id);

-- ============================================================ comms_document_vars (internal)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.comms_document_vars(tests.fx('q'))$$, '42501', 'staff cannot call the internal builder');
select tests.as_anon();
select tests.throws($$select public.comms_document_vars(tests.fx('q'))$$, '42501', 'nor anon');
select tests.as_service();
select tests.throws_like($$select public.comms_document_vars()$$, '22023', '%exactly one%', 'one document is required');
select tests.throws_like($$select public.comms_document_vars(tests.fx('q'), tests.fx('inv'))$$, '22023', '%exactly one%',
                         'not two');
select tests.throws($$select public.comms_document_vars(gen_random_uuid())$$, 'P0002', 'unknown quote');
select tests.throws($$select public.comms_document_vars(null, gen_random_uuid())$$, 'P0002', 'unknown invoice');
select tests.eq((select jsonb_build_array(v -> 'quote_link', v ->> 'amount', v -> 'balance', v ->> 'customer_first_name', v ? 'job_number')
                   from (select public.comms_document_vars(tests.fx('q')) as v) x),
                '[null, "$1,200.00", null, "Alice", false]'::jsonb,
                'draft quote: no link yet, the quote total, no balance, customer variables');
select tests.eq((select jsonb_build_array(v ->> 'invoice_link', v ->> 'amount', v ->> 'balance')
                   from (select public.comms_document_vars(null, tests.fx('inv')) as v) x),
                '[null, "$450.00", "$450.00"]'::jsonb, 'draft invoice: no link yet');

-- ============================================================ enqueue_document_message: role matrix
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.enqueue_document_message(tests.fx('q'))$$, '42501', 'technicians cannot send quotes');
select tests.throws($$select public.enqueue_document_message(null, tests.fx('inv_job'))$$, '42501',
                    'nor invoices, not even of their assigned job');
select tests.throws($$select * from public.preview_document_message(tests.fx('q'))$$, '42501', 'nor preview them');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.enqueue_document_message(tests.fx('q'))$$, 'P0002', 'another shop''s quote is not found');
select tests.throws($$select * from public.preview_document_message(null, tests.fx('inv'))$$, 'P0002',
                    'another shop''s invoice is not found');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.enqueue_document_message(tests.fx('q'))$$, 'P0002', 'a non-member finds nothing');
select tests.as_anon();
select tests.throws($$select public.enqueue_document_message(tests.fx('q'))$$, '42501', 'anon cannot send');
select tests.throws($$select * from public.preview_document_message(tests.fx('q'))$$, '42501', 'anon cannot preview');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.enqueue_document_message(gen_random_uuid())$$, 'P0002', 'unknown quote');
select tests.throws($$select public.enqueue_document_message()$$, '22023', 'a document is required');
select tests.throws($$select public.enqueue_document_message(tests.fx('q'), null, null)$$, '22023', 'a channel is required');

-- ============================================================ quotes
select tests.eq(public.enqueue_document_message(tests.fx('q')), null::uuid, 'a draft quote has no link: nothing is queued');
select tests.eq((select body from public.preview_document_message(tests.fx('q'))),
                'Hi Alice, Shop A sent you a quote. Review and approve it here: https://app.example.test/q/' || tests.fx('q_tok'),
                'the preview shows the link as it will read once the quote is sent');
select public.mark_quote_sent(tests.fx('q'));
select tests.fx_set('m_q', public.enqueue_document_message(tests.fx('q'), null, 'sms', 'send-quote-001'));
select tests.ok((select template_key = 'quote_sent' and channel = 'sms' and to_address = '+12055550101' and job_id is null
                        and customer_id = tests.fx('cust_a') and sent_by = tests.fx('u_manager_a') and status = 'queued'
                        and body = 'Hi Alice, Shop A sent you a quote. Review and approve it here: https://app.example.test/q/'
                                   || tests.fx('q_tok')
                   from public.messages where id = tests.fx('m_q')), 'the sent quote is texted with its link');
select tests.eq(public.enqueue_document_message(tests.fx('q'), null, 'sms', 'send-quote-001'), tests.fx('m_q'),
                'a retried send with the same nonce returns the same message');
select tests.eq((select count(*) from public.messages where template_key = 'quote_sent' and shop_id = tests.fx('shop_a')), 1::bigint,
                'queued once');
-- the shop has no phone: the email's "Questions? Call us at ..." line is left out
select tests.fx_set('m_qe', public.enqueue_document_message(tests.fx('q'), null, 'email'));
select tests.ok((select subject = 'Your quote from Shop A' and body not like '%Call us at%'
                        and body like '%Review and approve it here: https://app.example.test/q/' || tests.fx('q_tok') || '%'
                   from public.messages where id = tests.fx('m_qe')), 'no shop phone: the call-us line is dropped');
select tests.ok((select body not like '%Call us at%' and subject = 'Your quote from Shop A' and to_address = 'alice@example.com'
                   from public.preview_document_message(tests.fx('q'), null, 'email')), 'the preview drops it too');
select tests.as_superuser();
update public.shops set phone = '+12055550199' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select body like '%Questions? Call us at (205) 555-0199.%' from public.preview_document_message(tests.fx('q'), null, 'email')),
                'with a phone the line is back');
-- another sender, same nonce: a message of their own
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.ok(public.enqueue_document_message(tests.fx('q'), null, 'sms', 'send-quote-001') <> tests.fx('m_q'),
                'another user''s nonce is independent');
-- a converted quote uses its job's variables
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))
  returning tests.fx_set('q2', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('q2'), 'Tint', 30000, false);
select public.mark_quote_sent(tests.fx('q2'));
select public.staff_record_quote_response(tests.fx('q2'), 'approve', null, 'Alice');
select tests.fx_set('q2_job', (public.convert_quote_to_job(tests.fx('q2'))).id);
select tests.as_service();
select tests.eq((select jsonb_build_array(v ->> 'job_number' is not null, v ->> 'amount', v -> 'balance')
                   from (select public.comms_document_vars(tests.fx('q2')) as v) x),
                '[true, "$300.00", null]'::jsonb, 'a converted quote carries its job''s variables, the quote''s own amount');

-- ============================================================ invoices
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.enqueue_document_message(null, tests.fx('inv')), null::uuid, 'a draft invoice is not sent');
select public.mark_invoice_sent(tests.fx('inv'));
select tests.fx_set('m_i', public.enqueue_document_message(null, tests.fx('inv'), 'email'));
select tests.ok((select template_key = 'invoice_sent' and job_id is null and subject = 'Your invoice from Shop A'
                        and body like '%Total: $450.00' || E'\n' || 'Balance due: $450.00%'
                        and body like '%View and pay online: https://app.example.test/i/' || tests.fx('inv_tok') || '%'
                   from public.messages where id = tests.fx('m_i')),
                'an invoice without a job gets its link, amount and balance');
select tests.ok((select body = 'Hi Alice, here is your invoice from Shop A. Balance due: $450.00. View and pay online: https://app.example.test/i/'
                                || tests.fx('inv_tok')
                   from public.preview_document_message(null, tests.fx('inv'))), 'sms preview');
select public.record_manual_payment(tests.fx('inv'), 20000, 'cash');
select tests.ok((select body like '%Balance due: $250.00%' from public.preview_document_message(null, tests.fx('inv'))),
                'the balance follows payments');
-- the job's invoice
select public.mark_invoice_sent(tests.fx('inv_job'));
select tests.fx_set('m_ij', public.enqueue_document_message(null, tests.fx('inv_job')));
select tests.ok((select job_id = tests.fx('job_a') and body like '%/i/' || tests.fx('inv_job_tok')
                   from public.messages where id = tests.fx('m_ij')), 'a job invoice is linked to its job');
-- a void invoice is never sent
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_void', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Wash","unit_price_cents":3000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_void'));
select public.void_invoice(tests.fx('inv_void'), 'duplicate');
select tests.eq(public.enqueue_document_message(null, tests.fx('inv_void')), null::uuid, 'a void invoice is not sent');
select tests.as_service();
select tests.eq((public.comms_document_vars(null, tests.fx('inv_void')) -> 'invoice_link'), 'null'::jsonb, 'void: no link');

-- ============================================================ refusals the sender diagnoses
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'invoice_sent' and channel = 'sms';
select tests.eq(public.enqueue_document_message(null, tests.fx('inv')), null::uuid, 'a disabled template queues nothing');
select tests.eq((select enabled from public.preview_document_message(null, tests.fx('inv'))), false, 'the preview says it is off');
delete from public.message_templates where shop_id = tests.fx('shop_a') and key = 'invoice_sent' and channel = 'sms';
select tests.throws_like($$select * from public.preview_document_message(null, tests.fx('inv'))$$, 'P0002', '%template not found%',
                         'missing template');
select tests.eq(public.enqueue_document_message(null, tests.fx('inv')), null::uuid, 'and nothing is queued without it');
update public.customers set email = null where id = tests.fx('cust_a');
select tests.eq(public.enqueue_document_message(tests.fx('q'), null, 'email'), null::uuid, 'no address: nothing queued');
select tests.as_superuser();
delete from public.platform_config where key = 'app_base_url';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.enqueue_document_message(tests.fx('q'))$$, '55000', '%customer links are not set up%',
                         'no app URL: a clear refusal instead of a message with a blank link');

-- ============================================================ grants
select tests.as_superuser();
select tests.ok(has_function_privilege('authenticated', 'public.enqueue_document_message(uuid, uuid, public.message_channel, text)', 'execute')
                and has_function_privilege('service_role', 'public.enqueue_document_message(uuid, uuid, public.message_channel, text)', 'execute')
                and not has_function_privilege('anon', 'public.enqueue_document_message(uuid, uuid, public.message_channel, text)', 'execute'),
                'enqueue_document_message: authenticated + service_role');
select tests.ok(has_function_privilege('authenticated', 'public.preview_document_message(uuid, uuid, public.message_channel)', 'execute')
                and not has_function_privilege('anon', 'public.preview_document_message(uuid, uuid, public.message_channel)', 'execute'),
                'preview_document_message: authenticated');
select tests.ok(has_function_privilege('service_role', 'public.comms_document_vars(uuid, uuid)', 'execute')
                and not has_function_privilege('authenticated', 'public.comms_document_vars(uuid, uuid)', 'execute')
                and not has_function_privilege('anon', 'public.comms_document_vars(uuid, uuid)', 'execute'),
                'comms_document_vars: service_role only');
