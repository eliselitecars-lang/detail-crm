-- 80 comms: follow-ups, message variables and the jobs export count money
-- on the same basis as the customer pages.
--   * invoice reminders / overdue notices: balance minus payments in flight
--     (a clearing ACH debit or a card attempt pending < 1 hour) — candidates,
--     {{balance}}, send-time withdrawal, status RPC (comms_invoice_due_cents)
--   * deposit reminders: a job on a live invoice (single or grouped) is never
--     asked for more than that invoice still needs
--   * comms_job_vars: a job's invoice is found through invoice_jobs, so a job
--     on a grouped invoice renders its link, total and balance
--   * export_jobs: a grouped invoice's amounts are split per job and add up
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100', invoice_due_days = 30, tax_rate_bps = 0 where id = tests.fx('shop_a');
-- follow-ups fall due only in waking hours (08:00-21:00 shop time, 0085):
-- shop A runs on a fixed-offset zone where it is about noon now, so the hour
-- offsets below land inside that window whatever time the suite runs
select case when o >= 0 then 'Etc/GMT-' || o else 'Etc/GMT+' || -o end as tz
  from (select 12 - extract(hour from now() at time zone 'UTC')::integer as o) x \gset
update public.shops set timezone = :'tz' where id = tests.fx('shop_a');
update public.messages set status = 'cancelled' where status = 'queued';
update public.followup_settings set invoice_enabled = true, overdue_enabled = true, deposit_enabled = true
 where shop_id = tests.fx('shop_a');
update public.message_templates set enabled = true
 where shop_id = tests.fx('shop_a') and key in ('invoice_reminder', 'invoice_overdue', 'deposit_reminder');
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Ivy', 'ivy@example.com', '+12055550114') returning tests.fx_set('cust_i', id);
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Fleet', 'fleet@example.com', '+12055550141') returning tests.fx_set('cust_f', id);

-- =================================================================== invoices
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv1', (public.create_invoice(tests.fx('cust_i'), '[{"name": "Paint correction", "unit_price_cents": 30000}]'::jsonb)).id);
select tests.fx_set('inv2', (public.create_invoice(tests.fx('cust_i'), '[{"name": "Ceramic coating", "unit_price_cents": 30000}]'::jsonb)).id);
select tests.fx_set('inv3', (public.create_invoice(tests.fx('cust_i'), '[{"name": "Interior detail", "unit_price_cents": 30000}]'::jsonb)).id);
select public.mark_invoice_sent(tests.fx('inv1'));
select public.mark_invoice_sent(tests.fx('inv2'));
select public.mark_invoice_sent(tests.fx('inv3'));

-- inv3: a reminder queued before the customer pays by bank debit
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 6,
                'three sent invoices with a balance: a reminder on both channels each');
select tests.eq((select count(*) from public.messages where invoice_id = tests.fx('inv3') and status = 'queued'), 2::bigint,
                'inv3 has two queued reminders');
update public.messages set status = 'cancelled'
 where invoice_id in (tests.fx('inv1'), tests.fx('inv2')) and status = 'queued';
delete from public.document_followup_log where doc_id in (tests.fx('inv1'), tests.fx('inv2'));

-- inv1: the whole balance is a clearing ACH debit
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achfull1', 'processing', 30000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv1'), p_stripe_method_type => 'us_bank_account');
-- inv2: a third of it is clearing
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achpart2', 'processing', 10000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv2'), p_stripe_method_type => 'us_bank_account');
-- inv3: the whole balance is clearing after its reminder was queued
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achfull3', 'processing', 30000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv3'), p_stripe_method_type => 'us_bank_account');

select tests.eq((select concat_ws('/', status, balance_cents) from public.invoices where id = tests.fx('inv1')), 'open/30000',
                '(clearing money does not count as received)');
select tests.eq((public.money_public_invoice_json(tests.fx('inv1')) #>> '{invoice,payable}'), 'false',
                'the /i page treats inv1 as covered');
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv1')), 0::bigint, 'inv1: nothing left to ask for');
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv2')), 20000::bigint, 'inv2: the part not clearing');
select tests.eq(public.comms_invoice_due_cents(gen_random_uuid()), null::bigint, 'unknown invoice: null');

select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '72 hours', 'invoice', tests.fx('inv1'))),
                0::bigint, 'inv1 is no follow-up candidate while its balance clears');
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 2,
                'only inv2 is reminded (both channels), not inv1');
select tests.eq((select count(*) from public.messages where invoice_id = tests.fx('inv1') and status = 'queued'), 0::bigint,
                'no "please pay" message for inv1');
select tests.ok((select body like '%Balance due: $200.00%' from public.messages
                  where invoice_id = tests.fx('inv2') and channel = 'sms' and status = 'queued'),
                'inv2''s {{balance}} is what is still to pay ($300 - $100 clearing)');
select tests.eq(public.comms_invoice_vars(tests.fx('inv2'), now()) ->> 'balance', '$200.00', 'comms_invoice_vars: same basis');
select tests.eq(public.comms_invoice_vars(tests.fx('inv1'), now()) ->> 'balance', '$0.00', 'comms_invoice_vars: never negative');

-- inv3: its queued reminder is withdrawn at send time
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '72 hours') from public.messages m
                  where m.invoice_id = tests.fx('inv3') and m.channel = 'sms' and m.status = 'queued'),
                'a payment for the invoice balance is on its way', 'a queued reminder is withdrawn once the balance is clearing');

-- the status RPC agrees
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.document_followup_status('invoice', tests.fx('inv1')) -> 'next_at', 'null'::jsonb,
                'status: no next reminder for inv1');
select tests.ok(public.document_followup_status('invoice', tests.fx('inv2')) ->> 'next_at' is not null,
                'status: inv2 still has a next reminder');

-- the debit fails: the balance is chased again
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achfull3', 'failed', 30000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv3'), p_stripe_method_type => 'us_bank_account');
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv3')), 30000::bigint, 'a failed debit is no longer in flight');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '72 hours') from public.messages m
                  where m.invoice_id = tests.fx('inv3') and m.channel = 'sms' and m.status = 'queued'),
                null, 'the queued reminder goes out after all');
-- the debit settles: paid
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achfull1', 'succeeded', 30000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv1'), p_stripe_method_type => 'us_bank_account');
select tests.eq((select status::text from public.invoices where id = tests.fx('inv1')), 'paid', 'inv1 settled');
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv1')), 0::bigint, 'paid: nothing due');

-- a card attempt pending for under an hour is in flight; an abandoned one is not
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv4', (public.create_invoice(tests.fx('cust_i'), '[{"name": "Wash", "unit_price_cents": 5000}]'::jsonb)).id);
select public.mark_invoice_sent(tests.fx('inv4'));
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_card4', 'pending', 5000, 0, 'payment', 'card', tests.fx('inv4'));
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv4'), now()), 0::bigint, 'a card payment in progress is in flight');
select tests.eq(public.comms_invoice_due_cents(tests.fx('inv4'), now() + interval '2 hours'), 5000::bigint,
                'an abandoned attempt (over an hour) is not');
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '72 hours', 'invoice', tests.fx('inv4'))),
                1::bigint, 'so the invoice is chased again later');

-- overdue: a past-due invoice whose balance is clearing gets no overdue notice
select tests.as_superuser();
update public.invoices set issued_at = now() - interval '33 days', due_at = now() - interval '3 days' where id = tests.fx('inv2');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achrest2', 'processing', 20000, 0, 'payment', 'ach_debit',
                                    tests.fx('inv2'), p_stripe_method_type => 'us_bank_account');
select tests.eq((select count(*) from public.comms_followup_candidates(now(), 'invoice', tests.fx('inv2'))), 0::bigint,
                'no overdue notice while the rest clears');
select tests.eq((select public.comms_withdraw_reason(m, now()) from public.messages m
                  where m.invoice_id = tests.fx('inv2') and m.channel = 'sms' and m.status = 'queued'),
                'a payment for the invoice balance is on its way', 'nor the queued reminder');

-- ============================================================ deposits, grouped
select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';
update public.followup_settings set invoice_enabled = false, overdue_enabled = false where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_f'), now() + interval '10 days', now() + interval '10 days 2 hours')
  returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j1'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_f'), now() + interval '11 days', now() + interval '11 days 2 hours')
  returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j2'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_f'), now() + interval '12 days', now() + interval '12 days 2 hours')
  returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_f'), now() + interval '13 days', now() + interval '13 days 2 hours')
  returning tests.fx_set('j4', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j4'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_f'), now() + interval '14 days', now() + interval '14 days 2 hours')
  returning tests.fx_set('j5', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j5'), 'Wash', 10000);
update public.jobs set deposit_required_cents = 2500
 where id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'), tests.fx('j4'), tests.fx('j5'));

select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '24 hours'), 10,
                'five upcoming jobs with a deposit due: a reminder on both channels each');

-- j1 + j2 on one fleet invoice, paid in full (whole-invoice payment, no job_id)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_f'), array[tests.fx('j1'), tests.fx('j2')])).id);
select public.mark_invoice_sent(tests.fx('ginv'));
select public.record_manual_payment(tests.fx('ginv'), 20000, 'check');
select tests.eq((select concat_ws('/', status, balance_cents) from public.invoices where id = tests.fx('ginv')), 'paid/0',
                'the fleet invoice is paid in full');
-- j3 + j4 on another, partly paid: the rest could still use the deposits
select tests.fx_set('ginv2', (public.create_invoice_from_jobs(tests.fx('cust_f'), array[tests.fx('j3'), tests.fx('j4')])).id);
select public.mark_invoice_sent(tests.fx('ginv2'));
select public.record_manual_payment(tests.fx('ginv2'), 5000, 'cash');
-- j5 on its own invoice with nothing paid: its deposit is still due
select tests.fx_set('inv5', (public.create_invoice_from_job(tests.fx('j5'))).id);

select tests.as_service();
select tests.eq(public.comms_deposit_due_cents(tests.fx('j1')), 0::bigint, 'grouped invoice paid: no deposit due on j1');
select tests.eq(public.comms_deposit_due_cents(tests.fx('j2')), 0::bigint, '… nor on j2');
select tests.eq(public.comms_deposit_due_cents(tests.fx('j3')), 2500::bigint, 'partly paid grouped invoice: deposit still due');
select tests.eq(public.comms_deposit_due_cents(tests.fx('j5')), 2500::bigint, 'single-job invoice, unpaid: deposit still due');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '24 hours') from public.messages m
                  where m.job_id = tests.fx('j1') and m.channel = 'sms' and m.status = 'queued'
                    and m.template_key = 'deposit_reminder'),
                'the deposit was paid', 'j1''s queued deposit reminder is withdrawn');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '24 hours') from public.messages m
                  where m.job_id = tests.fx('j3') and m.channel = 'sms' and m.status = 'queued'
                    and m.template_key = 'deposit_reminder'),
                null, 'j3''s stays');
update public.messages set status = 'cancelled' where status = 'queued';
select tests.eq((select array_agg(doc_id order by doc_id) from public.comms_followup_candidates(now() + interval '4 days', 'deposit')
                  where doc_id in (tests.fx('j1'), tests.fx('j2'))), null::uuid[],
                'no deposit follow-ups for the jobs of the paid fleet invoice');
-- the rest of ginv2 is clearing by bank debit: its jobs' deposits are covered
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achg2', 'processing', 15000, 0, 'payment', 'ach_debit',
                                    tests.fx('ginv2'), p_stripe_method_type => 'us_bank_account');
select tests.eq(public.comms_deposit_due_cents(tests.fx('j4')), 0::bigint, 'a clearing grouped payment covers the deposit');
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '4 days', 'deposit')
                  where doc_id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'), tests.fx('j4'))), 0::bigint,
                'none of the fleet jobs is chased');
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 2, 'only j5 is reminded (both channels)');
select tests.eq((select count(distinct job_id) from public.messages where status = 'queued' and template_key = 'deposit_reminder'),
                1::bigint, '(one job)');
-- the grouped debit fails: the deposits are due again
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_achg2', 'failed', 15000, 0, 'payment', 'ach_debit',
                                    tests.fx('ginv2'), p_stripe_method_type => 'us_bank_account');
select tests.eq(public.comms_deposit_due_cents(tests.fx('j4')), 2500::bigint, 'the debit failed: due again');

-- ====================================================== job variables, grouped
select tests.as_superuser();
update public.shops set timezone = 'America/Chicago' where id = tests.fx('shop_a');   -- (fixed-date jobs below)
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-01 15:00Z', '2025-07-01 17:00Z') returning tests.fx_set('v1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('v1'), 'A', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-02 15:00Z', '2025-07-02 17:00Z') returning tests.fx_set('v2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('v2'), 'B', 10000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.template_vars_for_job(tests.fx('v1')) as v0 \gset
select tests.eq((:'v0'::jsonb) ->> 'balance', '$100.00', 'not invoiced yet: the job''s own balance');
select tests.eq((:'v0'::jsonb) -> 'invoice_link', 'null'::jsonb, '… and no invoice link');

select tests.fx_set('vinv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('v1'), tests.fx('v2')])).id);
select public.invoice_link_token(tests.fx('vinv')) as vtok \gset
select public.template_vars_for_job(tests.fx('v1')) as v1 \gset
select tests.eq((:'v1'::jsonb) ->> 'invoice_link', 'https://app.example.test/i/' || :'vtok',
                'a job on a grouped invoice links to that invoice');
select tests.eq((:'v1'::jsonb) ->> 'amount', '$200.00', '{{amount}} is the invoice''s total (what the link shows)');
select tests.eq((:'v1'::jsonb) ->> 'balance', '$200.00', '{{balance}} is the invoice''s balance');
select tests.eq(public.template_vars_for_job(tests.fx('v2')) ->> 'invoice_link', 'https://app.example.test/i/' || :'vtok',
                'the other job too');

select public.record_manual_payment(tests.fx('vinv'), 5000, 'cash');
select tests.eq(public.template_vars_for_job(tests.fx('v2')) ->> 'balance', '$150.00', 'a whole-invoice payment counts');
select public.record_manual_payment(tests.fx('vinv'), 15000, 'cash');
select tests.eq((select balance_cents from public.job_payment_summary(tests.fx('v1'))), 0::bigint, 'job_payment_summary: nothing due');
select public.template_vars_for_job(tests.fx('v1')) as v2 \gset
select tests.eq((:'v2'::jsonb) ->> 'balance', '$0.00', 'message variables: a job on a paid grouped invoice owes nothing');

-- a voided grouped invoice releases its jobs: back to the job's own figures
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-03 15:00Z', '2025-07-03 17:00Z') returning tests.fx_set('v3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('v3'), 'C', 7000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-04 15:00Z', '2025-07-04 17:00Z') returning tests.fx_set('v4', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('v4'), 'D', 3000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('vinv2', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('v3'), tests.fx('v4')])).id);
select tests.eq(public.template_vars_for_job(tests.fx('v3')) ->> 'amount', '$100.00', '(grouped: invoice total)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('vinv2'));
select tests.eq(public.template_vars_for_job(tests.fx('v3')) ->> 'amount', '$70.00', 'voided: the job''s own total');
select tests.eq(public.template_vars_for_job(tests.fx('v3')) -> 'invoice_link', 'null'::jsonb, 'voided: no invoice link');

-- another shop's manager cannot read them
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.template_vars_for_job(tests.fx('v1'))$$, 'P0002', 'shop B cannot read shop A''s variables');

-- ================================================================ export_jobs
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select total_cents from public.invoices where id = tests.fx('vinv')), 20000::bigint, 'one $200 invoice for v1 + v2');
select tests.eq((select sum(total_cents) from public.export_jobs(tests.fx('shop_a'), '2025-07-01', '2025-07-02')
                  where number in (select number from public.jobs where id in (tests.fx('v1'), tests.fx('v2')))),
                20000::numeric, 'exported job totals add up to what was billed');
select tests.eq((select sum(paid_cents) from public.export_jobs(tests.fx('shop_a'), '2025-07-01', '2025-07-02')
                  where number in (select number from public.jobs where id in (tests.fx('v1'), tests.fx('v2')))),
                20000::numeric, '… and so does what was received');
select tests.eq((select sum(balance_cents) from public.export_jobs(tests.fx('shop_a'), '2025-07-01', '2025-07-02')
                  where number in (select number from public.jobs where id in (tests.fx('v1'), tests.fx('v2')))),
                0::numeric, '… and the balance');

-- a partly paid grouped invoice with a deposit taken on the second job before billing
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-08-01 15:00Z', '2025-08-01 17:00Z') returning tests.fx_set('e1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('e1'), 'Wash', 10000);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-08-02 15:00Z', '2025-08-02 17:00Z') returning tests.fx_set('e2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('e2'), 'Wash', 10000);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_depe2', 'succeeded', 2500, 0, 'deposit', 'card',
                                    p_job_id => tests.fx('e2'), p_paid_at => '2025-07-20 12:00Z');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('einv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('e1'), tests.fx('e2')])).id);
select public.record_manual_payment(tests.fx('einv'), 5000, 'cash');
select tests.eq((select concat_ws('/', total_cents, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('einv')),
                '20000/7500/12500', '(the invoice: deposit carried over + a whole-invoice payment)');
select tests.eq((select string_agg(concat_ws('/', total_cents, paid_cents, balance_cents), ' ' order by number)
                   from public.export_jobs(tests.fx('shop_a'), '2025-08-01', '2025-08-02')),
                '10000/5000/5000 10000/2500/7500',
                'per job: its own deposit stays on it, the whole-invoice payment fills the jobs in order');

-- tax rounded once on the invoice: the last job takes the difference
select tests.as_superuser();
update public.shops set tax_rate_bps = 1000 where id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-09-01 15:00Z', '2025-09-01 17:00Z') returning tests.fx_set('t1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('t1'), 'Wash', 3333);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-09-02 15:00Z', '2025-09-02 17:00Z') returning tests.fx_set('t2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('t2'), 'Wash', 3333);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-09-03 15:00Z', '2025-09-03 17:00Z') returning tests.fx_set('t3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('t3'), 'Wash', 3333);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('tinv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('t1'), tests.fx('t2'), tests.fx('t3')])).id);
select tests.eq((select sum(total_cents) from public.export_jobs(tests.fx('shop_a'), '2025-09-01', '2025-09-03')),
                (select total_cents from public.invoices where id = tests.fx('tinv'))::numeric,
                'the exported totals equal the invoice total, tax rounding included');
select tests.eq((select sum(balance_cents) from public.export_jobs(tests.fx('shop_a'), '2025-09-01', '2025-09-03')),
                (select balance_cents from public.invoices where id = tests.fx('tinv'))::numeric, 'so do the balances');
select tests.eq((select array_agg(total_cents order by number) from public.export_jobs(tests.fx('shop_a'), '2025-09-01', '2025-09-02')),
                (select array_agg(total_cents order by number) from public.jobs where id in (tests.fx('t1'), tests.fx('t2'))),
                'earlier jobs keep their own totals');
-- an export covering only part of the fleet still shows each job's share
select tests.eq((select count(*) from public.export_jobs(tests.fx('shop_a'), '2025-09-02', '2025-09-02')), 1::bigint,
                '(one job of the three in range)');
select tests.eq((select total_cents from public.export_jobs(tests.fx('shop_a'), '2025-09-02', '2025-09-02')),
                (select total_cents from public.jobs where id = tests.fx('t2')), 'its own share, not the invoice total');

-- the split is internal
select tests.throws($$select * from public.comms_grouped_invoice_job_amounts(tests.fx('tinv'))$$, '42501', 'the split helper is internal');
select tests.throws($$select public.comms_invoice_due_cents(tests.fx('tinv'))$$, '42501', 'the invoice due helper is internal');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.export_jobs(tests.fx('shop_a'), '2025-09-01', '2025-09-03')$$, '42501',
                    'technicians cannot export');
