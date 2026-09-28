-- 60 money: multi-job (grouped) invoices (P-7, 0063) — create_invoice_from_jobs
-- (lines per job + vehicles, job discounts carried as line discounts, deposits
-- attached, tax rounding bound), validation, invoice_jobs (backfill /
-- trigger / RLS), payments on grouped invoices, void + re-invoice, late
-- payments for a void grouped invoice, job_payment_summary v2, technician
-- visibility, unbilled_jobs, the public /i document and the merge bypasses.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 825, invoice_due_days = 30 where id = tests.fx('shop_a');
insert into public.vehicles (shop_id, customer_id, year, make, model) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), 2020, 'Ford', 'Transit') returning tests.fx_set('vf1', id);
insert into public.vehicles (shop_id, customer_id, year, make, model) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), 2021, 'Ford', 'Transit') returning tests.fx_set('vf2', id);
insert into public.vehicles (shop_id, customer_id, year, make, model) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), 2019, 'Ram', 'ProMaster') returning tests.fx_set('vf3', id);

create function pg_temp.it(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_cents)
  from public.invoices where id = p_id
$$;
grant execute on function pg_temp.it(uuid) to authenticated;

select tests.authenticate_as(tests.fx('u_manager_a'));
-- j1: Full Detail 20000 (taxable) + Interior shampoo 3333 (not taxable), $10.01 off
--     E 23333, ET 20000, taxable share round(1001 x 20000 / 23333) = 858; tax round(19142 x 8.25%) = 1579; total 23911
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('vf1'), '2025-07-01 15:00Z', '2025-07-01 17:00Z', 'fixed', 1001)
  returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable, sort) values
  (tests.fx('shop_a'), tests.fx('j1'), 'Full Detail', 20000, true, 1),
  (tests.fx('shop_a'), tests.fx('j1'), 'Interior shampoo', 3333, false, 2);
-- j2: Wash 5005 (on vf3) + Wax 2507, 10% off -> 751; tax round(6761 x 8.25%) = 558; total 7319
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('vf2'), '2025-07-02 15:00Z', '2025-07-02 17:00Z', 'percent', 1000)
  returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents, sort) values
  (tests.fx('shop_a'), tests.fx('j2'), tests.fx('vf3'), 'Wash', 5005, 1),
  (tests.fx('shop_a'), tests.fx('j2'), null, 'Wax', 2507, 2);
-- j3 (earliest): Ceramic 10001, no vehicle; tax 825; total 10826
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-30 15:00Z', '2025-06-30 17:00Z') returning tests.fx_set('j3', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('j3'), 'Ceramic', 10001);
-- j4: cancelled; j5: another customer's job
insert into public.jobs (shop_id, customer_id, status, cancel_reason) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'cancelled', 'Rain')
  returning tests.fx_set('j4', id);
select tests.eq((select string_agg(total_cents::text, ',' order by scheduled_start) from public.jobs where id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'))),
                '10826,23911,7319', 'job totals (j3, j1, j2)');

-- deposits paid before invoicing (card, recorded by the webhook)
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5000, 0, 'deposit', 'card', p_job_id => tests.fx('j1'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep3', 'succeeded', 2000, 0, 'deposit', 'card', p_job_id => tests.fx('j3'));

-- ============================================================ unbilled_jobs
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select string_agg(number::text || ':' || paid_cents::text || ':' || coalesce(vehicle_label, '-'), ',' order by scheduled_start)
                   from public.unbilled_jobs(tests.fx('cust_a3'))),
                (select string_agg(number::text || ':' || case id when tests.fx('j1') then '5000' when tests.fx('j3') then '2000' else '0' end
                                   || ':' || case id when tests.fx('j1') then '2020 Ford Transit' when tests.fx('j2') then '2021 Ford Transit' else '-' end,
                                   ',' order by scheduled_start)
                   from public.jobs where id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'))),
                'unbilled jobs: not cancelled, oldest first, with paid amounts and vehicles');

-- ============================================================ validation
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1')])$$, '22023',
                         '%between 2 and 100 jobs%', 'one job is not a grouped invoice');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j1')])$$, '22023',
                         '%between 2 and 100 jobs%', 'duplicates count once');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('job_a2')])$$, '22023',
                         '%belongs to another customer%', 'another customer''s job is refused');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j4')])$$, '22023',
                         '%cancelled%', 'cancelled jobs are refused');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), gen_random_uuid()])$$, '22023',
                         '%not found%', 'unknown jobs are refused');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('job_b')])$$, '22023',
                         '%not found%', 'another shop''s job is not found');
select tests.throws($$select public.create_invoice_from_jobs(tests.fx('cust_b'), array[tests.fx('j1'), tests.fx('j2')])$$, 'P0002',
                    'another shop''s customer: not found');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])$$, '42501',
                    'technicians cannot group invoices');
select tests.throws($$select * from public.unbilled_jobs(tests.fx('cust_a3'))$$, '42501', 'technicians cannot list unbilled jobs');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])$$, 'P0002',
                    'outsiders: not found');
select tests.throws($$select * from public.unbilled_jobs(tests.fx('cust_a3'))$$, 'P0002', 'outsiders: not found (unbilled)');

-- one tax rate per invoice: the jobs' own (a tax-exempt account stays exempt)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, tax_rate_bps) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested', 0)
  returning tests.fx_set('jx1', id);
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a2'), 'requested')
  returning tests.fx_set('jx2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('jx1'), 'Exempt work', 1000), (tests.fx('shop_a'), tests.fx('jx2'), 'Taxed work', 1000);
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a2'), array[tests.fx('jx1'), tests.fx('jx2')])$$, '22023',
                         '%different tax rates%', 'jobs with different tax rates cannot share an invoice');
update public.jobs set tax_rate_bps = 0 where id = tests.fx('jx2');
select tests.eq((select concat_ws('/', tax_rate_bps, tax_cents, total_cents)
                   from public.create_invoice_from_jobs(tests.fx('cust_a2'), array[tests.fx('jx1'), tests.fx('jx2')])),
                '0/0/2000', 'tax-exempt jobs make a tax-exempt grouped invoice (not the shop''s rate)');

-- ============================================================ the grouped invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j2'), tests.fx('j1'), tests.fx('j3')],
                                                             'Fleet work, June/July', 'Net 30 account')).id);
select tests.ok((select job_id is null and customer_id = tests.fx('cust_a3') and discount_kind = 'none' and tax_rate_bps = 825
                        and notes = 'Fleet work, June/July' and internal_notes = 'Net 30 account' and issued_at = now()
                        and due_at = (((now() at time zone 'America/Chicago')::date + 30)::timestamp + time '23:59:59') at time zone 'America/Chicago'
                 from public.invoices where id = tests.fx('ginv')),
                'grouped invoice: no single job, no document discount, shop tax rate, issued and due per shop');
select tests.eq((select count(*) from public.invoice_jobs where invoice_id = tests.fx('ginv') and not voided), 3::bigint,
                'one invoice_jobs row per job');
select tests.eq((select array_agg(concat_ws(':', li.name, j.number, coalesce((select concat_ws(' ', v.year, v.make, v.model) from public.vehicles v where v.id = li.vehicle_id), '-'),
                                            li.discount_cents, li.total_cents, li.taxable::text) order by li.sort)
                   from public.invoice_line_items li join public.jobs j on j.id = li.job_id
                  where li.invoice_id = tests.fx('ginv')),
                array[(select 'Ceramic:' || number || ':-:0:10001:true' from public.jobs where id = tests.fx('j3')),
                      (select 'Full Detail:' || number || ':2020 Ford Transit:858:19142:true' from public.jobs where id = tests.fx('j1')),
                      (select 'Interior shampoo:' || number || ':2020 Ford Transit:143:3190:false' from public.jobs where id = tests.fx('j1')),
                      (select 'Wash:' || number || ':2019 Ram ProMaster:500:4505:true' from public.jobs where id = tests.fx('j2')),
                      (select 'Wax:' || number || ':2021 Ford Transit:251:2256:true' from public.jobs where id = tests.fx('j2'))],
                'lines by job date then line order, with job, vehicle (line''s, else job''s) and the carried discounts '
                || '(taxable share 858 / 143; 751 split 500/251 by largest remainder)');
-- 39094 subtotal (taxable 35904) -> tax round(2962.08) = 2962 = the jobs'' 1579 + 558 + 825; deposits 7000 attached
select tests.eq(pg_temp.it(tests.fx('ginv')), 'partially_paid/39094/0/2962/42056/7000/35056',
                'total = sum of the job totals (42056); both deposits attached');
select tests.eq((select count(*) from public.payments where invoice_id = tests.fx('ginv') and kind = 'deposit'), 2::bigint,
                'deposits keep their kind and job');
select tests.ok((select bool_and(x.inv_taxable = x.job_taxable)
                 from (select j.id,
                              (select sum(li.total_cents) from public.invoice_line_items li
                                where li.invoice_id = tests.fx('ginv') and li.job_id = j.id and li.taxable) as inv_taxable,
                              (select t.taxable_subtotal_cents - t.taxable_discount_cents
                                 from public.compute_document_totals(
                                   (select jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                                        'discount_cents', li.discount_cents, 'taxable', li.taxable,
                                                                        'discount_eligible', li.discount_eligible))
                                      from public.job_line_items li where li.job_id = j.id),
                                   j.discount_kind, j.discount_value, j.tax_rate_bps) t) as job_taxable
                         from public.jobs j where j.id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'))) x),
                'each job''s taxable base on the invoice equals the job''s own taxable base');
select tests.throws_like($$select public.create_invoice_from_job(tests.fx('j1'))$$, '23505', '%already has invoice%',
                         'a job on a grouped invoice cannot get a single invoice');
select tests.throws_like($$select public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])$$, '22023',
                         '%already billed on invoice%', 'nor another grouped one');
select tests.eq((select count(*) from public.unbilled_jobs(tests.fx('cust_a3'))), 0::bigint, 'nothing left unbilled');

-- ============================================================ job_payment_summary v2
select tests.eq((select concat_ws('/', invoice_id = tests.fx('ginv'), invoice_job_count, total_cents, balance_cents, paid_cents, deposit_paid_cents)
                   from public.job_payment_summary(tests.fx('j1'))),
                't/3/42056/35056/5000/5000', 'a job on a grouped invoice: the invoice''s total and balance, flagged by the job count');
select tests.eq((select concat_ws('/', invoice_id = tests.fx('ginv'), invoice_job_count, paid_cents) from public.job_payment_summary(tests.fx('j2'))),
                't/3/0', 'j2 has no own payments yet');
select tests.eq((select concat_ws('/', coalesce(invoice_id::text, 'none'), invoice_job_count) from public.job_payment_summary(tests.fx('job_a'))),
                'none/0', 'a job without an invoice: count 0');

-- ============================================================ payments on the grouped invoice
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_j2', 'succeeded', 1000, 0, 'payment', 'card', p_job_id => tests.fx('j2'));
select tests.eq((select concat_ws('/', invoice_id = tests.fx('ginv'), job_id = tests.fx('j2')) from public.payments where stripe_payment_intent_id = 'pi_j2'),
                't/t', 'a job payment attaches to the job''s grouped invoice and keeps its job');
select tests.throws_like($$select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_wrongjob', 'succeeded', 100, 0, 'payment', 'card',
                                                               p_invoice_id => tests.fx('ginv'), p_job_id => tests.fx('job_a'))$$,
                         '23514', '%not one of the invoice''s jobs%', 'a payment for a job the invoice does not bill is refused');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_manual_payment(tests.fx('ginv'), 500, 'cash') as cash \gset
select tests.eq((select job_id from public.payments where id = (:'cash'::public.payments).id), null::uuid,
                'a payment for the whole grouped invoice has no job');
select tests.eq(pg_temp.it(tests.fx('ginv')), 'partially_paid/39094/0/2962/42056/8500/33556', 'balance follows');
select tests.eq((select paid_cents from public.job_payment_summary(tests.fx('j2'))), 1000::bigint, 'j2''s own payment');

-- ============================================================ invoice_jobs: RLS, no client writes, backfill / trigger
select tests.throws($$insert into public.invoice_jobs (shop_id, invoice_id, job_id) values (tests.fx('shop_a'), tests.fx('ginv'), tests.fx('job_a'))$$,
                    '42501', 'no client writes on invoice_jobs');
select tests.throws($$update public.invoice_jobs set voided = true where invoice_id = tests.fx('ginv')$$, '42501', 'no client updates');
select tests.eq((select count(*) from public.invoice_jobs where invoice_id = tests.fx('ginv')), 3::bigint, 'managers read invoice_jobs');
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('m_tech_a'));
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.invoice_jobs where invoice_id = tests.fx('ginv')), 1::bigint,
                'a collecting technician sees only their assigned job''s row');
select tests.eq((select count(*) from public.invoices where id = tests.fx('ginv')), 0::bigint,
                'but never the grouped invoice itself');
select tests.eq((select count(*) from public.invoice_line_items where invoice_id = tests.fx('ginv')), 0::bigint, 'nor its lines');
select tests.eq((select concat_ws('/', coalesce(invoice_id::text, 'hidden'), invoice_job_count, total_cents, balance_cents)
                   from public.job_payment_summary(tests.fx('j1'))),
                'hidden/3/23911/0', 'the technician sees the job as billed (no invoice details, nothing to collect)');
select tests.throws($$select public.record_manual_payment(tests.fx('ginv'), 100, 'cash')$$, '42501',
                    'technicians cannot collect a grouped invoice');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.invoice_jobs where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops see nothing');
-- single-job invoices get their row from the trigger (and the backfill for older ones)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 3000);
select tests.fx_set('sinv', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select tests.eq((select concat_ws('/', count(*), bool_and(not voided), min(job_id::text) = tests.fx('job_a2')::text)
                   from public.invoice_jobs where invoice_id = tests.fx('sinv')), '1/t/t', 'single invoice row');
select tests.eq((select job_id from public.invoice_line_items where invoice_id = tests.fx('sinv')), tests.fx('job_a2'),
                'single invoice lines carry their job');
select tests.eq((select invoice_job_count from public.job_payment_summary(tests.fx('job_a2'))), 1, 'single invoice: count 1');
select tests.as_superuser();
select tests.eq((select count(*) from public.invoices i
                  where i.job_id is not null and i.shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))
                    and not exists (select 1 from public.invoice_jobs ij where ij.invoice_id = i.id and ij.job_id = i.job_id
                                      and ij.voided = (i.status = 'void'))), 0::bigint,
                'every job invoice has its invoice_jobs row with the right voided flag');

-- a line's job must be one of the invoice's jobs
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('adhoc', (public.create_invoice(tests.fx('cust_a3'), '[]')).id);
select tests.throws_like($$insert into public.invoice_line_items (shop_id, invoice_id, job_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('adhoc'), tests.fx('j3'), 'X', 100)$$, '23514',
                         '%not one of this invoice''s jobs%', 'lines cannot point at jobs the invoice does not bill');
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, job_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('adhoc'), tests.fx('job_b'), 'X', 100)$$, '23503',
                    'composite FK: another shop''s job');

-- ============================================================ jobs on a live grouped invoice keep their customer
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('j2')$$, '23514',
                         '%invoice or payments%', 'a job on a grouped invoice keeps its customer');

-- ============================================================ the public /i document
select public.invoice_link_token(tests.fx('ginv')) as gtok \gset
select jsonb_agg(number::text order by scheduled_start) as job_numbers from public.jobs
 where id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3')) \gset
select tests.as_anon();
select tests.eq((select jsonb_agg(e ->> 'number' order by o)
                   from jsonb_array_elements(public.public_get_invoice(:'gtok') -> 'jobs') with ordinality as t(e, o)),
                :'job_numbers'::jsonb, 'the grouped invoice lists its jobs');
select tests.eq(public.public_get_invoice(:'gtok') -> 'jobs' -> 1 ->> 'vehicle_label', '2020 Ford Transit', 'with their vehicles');
select tests.eq(public.public_get_invoice(:'gtok') -> 'jobs' -> 1 ->> 'date', '2025-07-01', 'and local dates');
select tests.ok((select bool_and(e ? 'job_number' and (e ->> 'job_number') is not null)
                   from jsonb_array_elements(public.public_get_invoice(:'gtok') -> 'line_items') e),
                'every line names its job number');
select tests.eq(public.public_get_invoice(:'gtok') -> 'job', 'null'::jsonb, 'no single job section');

-- ============================================================ void + re-invoice
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('ginv'))$$, '22023', '%refund the payments%',
                         'money for the whole invoice (no job) must be refunded first');
select public.refund_manual_payment((:'cash'::public.payments).id, 500);
select tests.lives($$select public.void_invoice(tests.fx('ginv'), 'Split per vehicle')$$, 'then the grouped invoice can be voided');
select tests.eq((select count(*) from public.invoice_jobs where invoice_id = tests.fx('ginv') and voided), 3::bigint,
                'its jobs are released');
select tests.eq((select string_agg(stripe_payment_intent_id, ',' order by stripe_payment_intent_id) from public.payments
                  where invoice_id is null and job_id in (tests.fx('j1'), tests.fx('j2'), tests.fx('j3'))),
                'pi_dep1,pi_dep3,pi_j2', 'each job''s payments went back to its job');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ginv2', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j1'), tests.fx('j2')])).id);
select tests.eq((select sum(amount_cents) from public.payments where invoice_id = tests.fx('ginv2')), 6000::numeric,
                'the new grouped invoice picks up j1''s deposit and j2''s payment');
select tests.fx_set('sinv3', (public.create_invoice_from_job(tests.fx('j3'))).id);
select tests.eq((select sum(amount_cents) from public.payments where invoice_id = tests.fx('sinv3')), 2000::numeric,
                'j3''s single invoice picks up its deposit');
-- money that still arrives for the void grouped invoice is re-routed
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_latej2', 'succeeded', 300, 0, 'payment', 'card',
                                    p_invoice_id => tests.fx('ginv'), p_job_id => tests.fx('j2'));
select tests.eq((select concat_ws('/', invoice_id = tests.fx('ginv2'), job_id = tests.fx('j2')) from public.payments
                  where stripe_payment_intent_id = 'pi_latej2'), 't/t',
                'a late job payment for the void grouped invoice lands on the job''s new invoice');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_lateall', 'succeeded', 400, 0, 'payment', 'card',
                                    p_invoice_id => tests.fx('ginv'));
select tests.ok((select invoice_id is null and job_id is null and customer_id = tests.fx('cust_a3') and note like 'Received for void invoice #%'
                 from public.payments where stripe_payment_intent_id = 'pi_lateall'),
                'a late whole-invoice payment stays with the customer, unapplied, with a note');

-- ============================================================ tax rounding bound (shop B, 10%)
select tests.as_superuser();
update public.shops set tax_rate_bps = 1000 where id = tests.fx('shop_b');
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.jobs (shop_id, customer_id, status) select tests.fx('shop_b'), tests.fx('cust_b'), 'requested' from generate_series(1, 3);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  select tests.fx('shop_b'), j.id, 'Spot', 5 from public.jobs j where j.shop_id = tests.fx('shop_b') and j.status = 'requested';
select tests.eq((select sum(total_cents) from public.jobs where shop_id = tests.fx('shop_b') and status = 'requested'), 18::numeric,
                'three 5-cent jobs: tax 0.5 rounds up to 1 each -> 18');
select tests.fx_set('binv', (public.create_invoice_from_jobs(tests.fx('cust_b'),
                                                              array(select id from public.jobs where shop_id = tests.fx('shop_b') and status = 'requested'))).id);
select tests.eq((select concat_ws('/', subtotal_cents, tax_cents, total_cents) from public.invoices where id = tests.fx('binv')), '15/2/17',
                'grouped: tax rounded once (1.5 -> 2): differs from the sum of job totals by 1 cent (<= 1 per job)');

-- ============================================================ customer-merge bypasses (P-20 contract)
select tests.as_superuser();
select public.void_invoice(tests.fx('ginv2')) from (select tests.authenticate_as(tests.fx('u_admin_a'))) x;
select tests.as_superuser();
select public_token as tok_before from public.jobs where id = tests.fx('j3') \gset
select set_config('detailcrm.customer_merge', 'on', true);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('j3')$$,
                   'during a merge a job with an invoice and payments moves to the surviving customer');
select tests.eq((select public_token from public.jobs where id = tests.fx('j3')), :'tok_before'::uuid,
                'and keeps its booking link (same person)');
select set_config('detailcrm.customer_merge', '', true);
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3') where id = tests.fx('j3')$$, '23514',
                         '%invoice or payments%', 'outside a merge the money guard applies');
select public_token as tok_a2 from public.jobs where id = tests.fx('job_a') \gset
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('job_a');
select tests.as_superuser();
select tests.ok((select public_token <> :'tok_a2'::uuid from public.jobs where id = tests.fx('job_a')),
                'a normal customer change still issues a new booking link');

-- grants
select tests.as_superuser();
select tests.ok(has_function_privilege('authenticated', 'public.create_invoice_from_jobs(uuid, uuid[], text, text)', 'execute')
                and not has_function_privilege('anon', 'public.create_invoice_from_jobs(uuid, uuid[], text, text)', 'execute')
                and has_function_privilege('authenticated', 'public.unbilled_jobs(uuid)', 'execute')
                and not has_function_privilege('anon', 'public.unbilled_jobs(uuid)', 'execute')
                and has_function_privilege('authenticated', 'public.job_payment_summary(uuid)', 'execute')
                and not has_function_privilege('anon', 'public.job_payment_summary(uuid)', 'execute'),
                'staff RPCs: authenticated (role-checked inside), never anon');
select tests.eq((select count(*) from pg_proc where proname = 'job_payment_summary'), 1::bigint, 'job_payment_summary: one signature');

-- ============================================================ coupon freeze covers grouped invoices
-- A grouped invoice (invoices.job_id null) carries each job's coupon discount
-- as line discounts: the job's coupon is frozen like on a single-job invoice
-- (jobs_apply_coupon, 0062), so its redemption is never released while billed.
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Fleet Two') returning tests.fx_set('cust_g', id);
insert into public.coupons (shop_id, code, kind, value, max_redemptions)
  values (tests.fx('shop_a'), 'GROUP10', 'percent', 1000, 1) returning tests.fx_set('cp_g', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, coupon_id, status) values (tests.fx('shop_a'), tests.fx('cust_g'), tests.fx('cp_g'), 'requested')
  returning tests.fx_set('gj1', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('gj1'), 'Detail', 20000);
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_g'), 'requested')
  returning tests.fx_set('gj2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('gj2'), 'Wash', 5000);
set constraints all immediate;
select tests.fx_set('ginv', (public.create_invoice_from_jobs(tests.fx('cust_g'), array[tests.fx('gj1'), tests.fx('gj2')])).id);
select tests.eq((select discount_cents from public.jobs where id = tests.fx('gj1')), 2000::bigint, 'the coupon discount was billed');
select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('gj1')$$, '23514', '%billed on invoice%',
                         'a job on a live grouped invoice keeps its coupon (the redemption was billed)');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('gj1')$$, '23514', '%billed%',
                         'nor can it swap it');
select tests.throws_like($$update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('gj2')$$, '23514', '%billed%',
                         'nor can another job of the invoice take one');
select tests.as_superuser();
select tests.eq((select concat_ws('/', c.redemptions, (select count(*) from public.coupon_redemptions r where r.job_id = tests.fx('gj1')),
                                  (select discount_cents from public.jobs where id = tests.fx('gj1')))
                 from public.coupons c where c.id = tests.fx('cp_g')),
                '1/1/2000', 'redemption, its row and the job discount are unchanged');
-- voiding the grouped invoice releases the jobs: the coupon may change again
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('ginv'), 'rebill');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set coupon_id = null where id = tests.fx('gj1')$$, 'after the void the coupon can be removed');
select tests.as_superuser();
select tests.eq((select redemptions from public.coupons where id = tests.fx('cp_g')), 0, 'and its redemption is given back');
