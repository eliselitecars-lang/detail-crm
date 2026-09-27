-- 20 field ops: form and invoice link tokens are customer credentials
--   Whoever holds a form token can, without signing in, open the customer's
--   /f page, upload an image into <shop>/forms/<token>/ and sign the form as
--   the customer (signed_by null). Whoever holds an invoice token reads the
--   customer's invoice (name, lines, payments with card brand/last4) and can
--   open Checkout. Regression: an assigned technician read
--   form_submissions.public_token (form_submissions_select) and, with
--   techs_can_collect_payments on, invoices.public_token (invoices_select),
--   and kept using both after being taken off the job / deactivated /
--   losing the collect permission — including forging the customer's
--   waiver signature with no staff attribution. Now:
--   * authenticated has SELECT on every form_submissions / invoices column
--     except public_token (checked over the whole column set)
--   * owners/admins/managers get the links from form_link_token(id) /
--     invoice_link_token(id); technicians 42501; other shops / unknown ids
--     P0002; anon and service_role cannot call them
--   * public_sign_form refuses a signed-in technician of the form's shop
--     (42501): staff sign on device through sign_form_submission, which
--     attributes the signature to them
--   * technicians keep every operational path (reading the job's forms and
--     invoice columns, on-device signing, recording payments)
--   * the customer's own links keep working
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_a'), 'Liability waiver', 'I accept the risks.', 'manual') returning tests.fx_set('tpl', id);
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_a'), 'Pickup release', 'Vehicle returned in good order.', 'manual') returning tests.fx_set('tpl2', id);
select tests.authenticate_as(tests.fx('u_admin_b'));
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_b'), 'Waiver B', 'Shop B terms.', 'manual') returning tests.fx_set('tpl_b', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.form_submissions (shop_id, form_template_id, job_id)
                     values (tests.fx('shop_a'), tests.fx('tpl'), tests.fx('job_a')) returning tests.fx_set('sub', id)$$,
                   'managers attach forms (returning named columns) without the token column');
insert into public.form_submissions (shop_id, form_template_id, job_id)
  values (tests.fx('shop_a'), tests.fx('tpl2'), tests.fx('job_a')) returning tests.fx_set('sub2', id);
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.form_submissions (shop_id, form_template_id, job_id)
  values (tests.fx('shop_b'), tests.fx('tpl_b'), tests.fx('job_b')) returning tests.fx_set('sub_b', id);

select tests.as_superuser();
select tests.fx_set('tok', (select public_token from public.form_submissions where id = tests.fx('sub')));
select tests.fx_set('tok2', (select public_token from public.form_submissions where id = tests.fx('sub2')));
select tests.fx_set('tok_b', (select public_token from public.form_submissions where id = tests.fx('sub_b')));

-- ============================================================ the repro: the assigned technician copies the form credential
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select id from public.form_submissions where job_id = tests.fx('job_a')$$), 2::bigint,
                'tech: sees the forms of the assigned job');
select tests.throws($$select public_token from public.form_submissions where id = tests.fx('sub')$$, '42501',
                    'tech: the form token column is not readable');
select tests.throws($$select * from public.form_submissions where id = tests.fx('sub')$$, '42501',
                    'tech: select * cannot reach the token either');
select tests.throws($$select fs from public.form_submissions fs where fs.id = tests.fx('sub')$$, '42501',
                    'tech: nor a whole-row reference');
select tests.throws($$select count(*) from public.form_submissions where public_token = tests.fx('tok')$$, '42501',
                    'tech: nor filtering on the token (no guessing oracle)');
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, '42501', 'tech: form_link_token refuses technicians');
select tests.eq(tests.row_count($$select id, shop_id, form_template_id, job_id, customer_id, title, body_snapshot,
                                         requires_signature, signer_name, signature_path, signed_at, signer_ip, signed_by,
                                         created_at, updated_at
                                    from public.form_submissions where id = tests.fx('sub')$$), 1::bigint,
                'tech: every other column stays readable');

-- the technician is taken off the job and deactivated; a token they held is
-- refused while signed in, and they never get it signed-out (above)
select tests.as_superuser();
insert into storage.objects (bucket_id, name) values ('signatures', tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.public_sign_form(tests.fx('tok'), 'Alice Anders',
                                                            tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png')$$,
                         '42501', '%on their device%', 'a signed-in technician cannot sign as the customer through the link');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.public_sign_form(tests.fx('tok'), 'Alice Anders',
                                                      tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png')$$,
                    '42501', 'nor a technician who is not on the job');
select tests.as_superuser();
select tests.ok((select signed_at is null from public.form_submissions where id = tests.fx('sub')),
                'the customer''s form is still unsigned');

-- ============================================================ technicians keep the staff signing path (attributed)
select tests.authenticate_as(tests.fx('u_tech_a'));
insert into storage.objects (bucket_id, name, owner, owner_id)
  values ('signatures', tests.fx('shop_a') || '/device/pickup.png', auth.uid(), auth.uid()::text);
select tests.eq((public.sign_form_submission(tests.fx('sub2'), 'Alice Anders', tests.fx('shop_a') || '/device/pickup.png')).signed_by,
                tests.fx('u_tech_a'), 'tech: on-device signing works and records the technician');
select tests.as_superuser();
delete from public.job_assignments where job_id = tests.fx('job_a') and member_id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select id from public.form_submissions$$), 0::bigint, 'tech taken off the job: no forms');
select tests.throws($$select public.sign_form_submission(tests.fx('sub'), 'Alice Anders', null)$$, '42501',
                    'tech taken off the job: no on-device signing');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, 'P0002', 'deactivated tech: the form is not found');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('m_tech_a'));

-- ============================================================ managers+ share the form link through the RPC
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.form_link_token(tests.fx('sub')), tests.fx('tok'), 'manager gets the form token');
select tests.throws($$select public_token from public.form_submissions where id = tests.fx('sub')$$, '42501',
                    'managers read the token only through the RPC too');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.form_link_token(tests.fx('sub')), tests.fx('tok'), 'owner gets the form token');
select tests.throws($$select public.form_link_token(gen_random_uuid())$$, 'P0002', 'unknown form: not found');
select tests.throws($$select public.form_link_token(tests.fx('sub_b'))$$, 'P0002', 'owner A cannot fetch shop B''s form token');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, 'P0002', 'manager B cannot fetch shop A''s form token');
select tests.eq(public.form_link_token(tests.fx('sub_b')), tests.fx('tok_b'), 'manager B gets their own shop''s form token');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, 'P0002', 'tech B: another shop''s form is not found');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, 'P0002', 'a signed-in outsider: not found');
select tests.as_anon();
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, '42501', 'anon cannot call form_link_token');
select tests.as_service();
select tests.throws($$select public.form_link_token(tests.fx('sub'))$$, '42501', 'service_role reads the column instead');
select tests.eq((select public_token from public.form_submissions where id = tests.fx('sub')), tests.fx('tok'),
                'service_role still resolves form tokens');

-- ============================================================ the customer's form link keeps working
select tests.as_anon();
select tests.eq(public.public_get_form(tests.fx('tok')) #>> '{form,status}', 'pending', 'the customer opens their form');
select tests.eq(public.public_sign_form(tests.fx('tok'), 'Alice Anders',
                                        tests.fx('shop_a') || '/forms/' || tests.fx('tok') || '/sig.png') #>> '{form,status}',
                'signed', 'and signs it');
select tests.as_superuser();
select tests.ok((select signed_by is null and signer_name = 'Alice Anders' from public.form_submissions where id = tests.fx('sub')),
                'recorded as the anonymous customer');

-- ============================================================ invoices: technicians who collect never see the link
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('inv_b', (public.create_invoice_from_job(tests.fx('job_b'))).id);
select tests.as_superuser();
select tests.fx_set('itok', (select public_token from public.invoices where id = tests.fx('inv')));
select tests.fx_set('itok_b', (select public_token from public.invoices where id = tests.fx('inv_b')));

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select id, number, status, total_cents, balance_cents from public.invoices
                                   where id = tests.fx('inv')$$), 1::bigint,
                'collecting tech: reads the assigned job''s invoice columns');
select tests.throws($$select public_token from public.invoices where id = tests.fx('inv')$$, '42501',
                    'collecting tech: the invoice token column is not readable');
select tests.throws($$select * from public.invoices where id = tests.fx('inv')$$, '42501',
                    'collecting tech: select * cannot reach the token either');
select tests.throws($$select i from public.invoices i where i.id = tests.fx('inv')$$, '42501', 'nor a whole-row reference');
select tests.throws($$select count(*) from public.invoices where public_token = tests.fx('itok')$$, '42501',
                    'nor filtering on the token');
select tests.throws($$select public.invoice_link_token(tests.fx('inv'))$$, '42501',
                    'collecting tech: invoice_link_token refuses technicians');
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 1000, 'cash', 0, null)$$,
                   'collecting tech: still records payments');
select tests.eq(tests.row_count($$select id, amount_cents from public.payments where invoice_id = tests.fx('inv')$$), 1::bigint,
                'and reads them');

-- ============================================================ managers+ share the invoice link through the RPC
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.invoice_link_token(tests.fx('inv')), tests.fx('itok'), 'manager gets the invoice token');
select tests.throws($$select public_token from public.invoices where id = tests.fx('inv')$$, '42501',
                    'managers read the invoice token only through the RPC too');
select tests.eq(tests.row_count($$update public.invoices set notes = 'Thanks for your business' where id = tests.fx('inv')
                                   returning id, notes$$), 1::bigint,
                'manager: invoice updates returning named columns still work');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(public.invoice_link_token(tests.fx('inv')), tests.fx('itok'), 'admin gets the invoice token');
select tests.throws($$select public.invoice_link_token(gen_random_uuid())$$, 'P0002', 'unknown invoice: not found');
select tests.throws($$select public.invoice_link_token(tests.fx('inv_b'))$$, 'P0002', 'admin A cannot fetch shop B''s invoice token');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.invoice_link_token(tests.fx('inv'))$$, 'P0002', 'manager B cannot fetch shop A''s invoice token');
select tests.eq(public.invoice_link_token(tests.fx('inv_b')), tests.fx('itok_b'), 'manager B gets their own shop''s invoice token');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$select public.invoice_link_token(tests.fx('inv'))$$, 'P0002', 'tech B: another shop''s invoice is not found');
select tests.as_anon();
select tests.throws($$select public.invoice_link_token(tests.fx('inv'))$$, '42501', 'anon cannot call invoice_link_token');
select tests.throws($$select id from public.invoices$$, '42501', 'anon has no invoices access at all');
select tests.as_service();
select tests.throws($$select public.invoice_link_token(tests.fx('inv'))$$, '42501', 'service_role reads the column instead');
select tests.eq((select public_token from public.invoices where id = tests.fx('inv')), tests.fx('itok'),
                'service_role (edge functions) still resolves invoice tokens');

-- ============================================================ the customer's invoice link keeps working
select tests.as_anon();
select tests.ok(jsonb_array_length(public.public_get_invoice(tests.fx('itok')) -> 'payments') = 1,
                'the customer opens their invoice with its payment');

-- ============================================================ column-privilege invariants (whole column sets)
select tests.as_superuser();
select tests.eq((select array_agg(a.attname::text order by a.attnum)
                   from pg_catalog.pg_attribute a
                  where a.attrelid = 'public.form_submissions'::regclass and a.attnum > 0 and not a.attisdropped
                    and not has_column_privilege('authenticated', 'public.form_submissions', a.attname, 'SELECT')),
                array['public_token'],
                'authenticated can select every form_submissions column except public_token (grant new columns explicitly)');
select tests.eq((select array_agg(a.attname::text order by a.attnum)
                   from pg_catalog.pg_attribute a
                  where a.attrelid = 'public.invoices'::regclass and a.attnum > 0 and not a.attisdropped
                    and not has_column_privilege('authenticated', 'public.invoices', a.attname, 'SELECT')),
                array['public_token'],
                'authenticated can select every invoices column except public_token (grant new columns explicitly)');
select tests.ok(not has_table_privilege('authenticated', 'public.form_submissions', 'SELECT')
                and not has_table_privilege('authenticated', 'public.invoices', 'SELECT'),
                'no table-wide SELECT for authenticated (it would re-expose the tokens)');
select tests.ok(not has_column_privilege('anon', 'public.form_submissions', 'public_token', 'SELECT')
                and not has_column_privilege('anon', 'public.invoices', 'public_token', 'SELECT'),
                'anon cannot read either token');
select tests.ok(has_column_privilege('service_role', 'public.form_submissions', 'public_token', 'SELECT')
                and has_column_privilege('service_role', 'public.invoices', 'public_token', 'SELECT'),
                'service_role keeps both token columns');

-- ============================================================ RPC results never carry the tokens
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), 'Interior', 8000);
select tests.authenticate_as(tests.fx('u_tech2_a'));  -- assigned to job_a2, shop A lets technicians collect
select tests.ok((select i.id is not null and i.public_token is null
                   from public.create_invoice_from_job(tests.fx('job_a2')) i),
                'collecting tech: create_invoice_from_job returns the invoice without its token');
select tests.fx_set('inv2', (select id from public.invoices where job_id = tests.fx('job_a2')));
select tests.ok((select i.sent_at is not null and i.public_token is null from public.mark_invoice_sent(tests.fx('inv2')) i),
                'collecting tech: mark_invoice_sent returns the invoice without its token');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select i.id is not null and i.public_token is null
                   from public.create_invoice(tests.fx('cust_a3'), '[{"name":"Polish","unit_price_cents":1000}]') i),
                'create_invoice returns the invoice without its token');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.ok((select i.status = 'void' and i.public_token is null from public.void_invoice(tests.fx('inv2'), 'Duplicate') i),
                'void_invoice returns the invoice without its token');
select tests.as_superuser();
insert into public.form_submissions (shop_id, job_id, customer_id, title, body_snapshot, requires_signature)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('cust_a'), 'Keys handed over', 'Keys returned.', false)
  returning tests.fx_set('sub3', id);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.ok((select s.signed_at is not null and s.public_token is null
                   from public.sign_form_submission(tests.fx('sub3'), 'Alice Anders') s),
                'sign_form_submission returns the signed form without its token');
