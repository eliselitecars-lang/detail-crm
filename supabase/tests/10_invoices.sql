-- 10 money: invoices + invoice_line_items — create_invoice_from_job,
-- create_invoice, mark_invoice_sent, void_invoice, editability rules, status
-- automation, one-invoice-per-job, technician access, isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 825, invoice_due_days = 14, invoice_terms = 'Due in 14 days'
 where id = tests.fx('shop_a');
-- job_a: Full Detail 20000 (taxable) + Air freshener 2 x 500 - 100 (not taxable), $10 off, 8.25% tax
update public.jobs set tax_rate_bps = 825, discount_kind = 'fixed', discount_value = 1000 where id = tests.fx('job_a');
insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, discount_cents, taxable, sort)
  values (tests.fx('shop_a'), tests.fx('job_a'), 'Air freshener', 2, 500, 100, false, 2);

create function pg_temp.it(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_cents, tip_cents)
  from public.invoices where id = p_id
$$;

-- ------------------------------------------------------------ create_invoice_from_job
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select tests.fx_set('inv_a', (public.create_invoice_from_job(tests.fx('job_a'))).id)$$, 'manager invoices a job');
select tests.ok((select number = 1001 and job_id = tests.fx('job_a') and customer_id = tests.fx('cust_a') and issued_at = now()
                        and due_at = now() + interval '14 days' and terms = 'Due in 14 days' and created_by = tests.fx('u_manager_a')
                        and discount_kind = 'fixed' and discount_value = 1000 and tax_rate_bps = 825 and sent_at is null
                 from public.invoices where id = tests.fx('inv_a')),
                'invoice header: number, job, customer, issued now, due per shop setting, terms, discount, tax copied');
-- 20900 subtotal; taxable share of the $10 discount = round(1000 * 20000 / 20900) = 957; tax round(19043 * 8.25%) = 1571
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_a')),
                '20900/1000/1571/21471', 'job totals');
select tests.eq(pg_temp.it(tests.fx('inv_a')), 'open/20900/1000/1571/21471/0/21471/0', 'invoice totals equal job totals; open with full balance');
select tests.eq((select array_agg(concat_ws(':', name, quantity, unit_price_cents, discount_cents, taxable::text, sort, (service_id is not null)::text) order by sort)
                   from public.invoice_line_items where invoice_id = tests.fx('inv_a')),
                array['Full Detail:1.00:20000:0:true:1:true', 'Air freshener:2.00:500:100:false:2:false'], 'lines copied in order');
select tests.throws_like($$select public.create_invoice_from_job(tests.fx('job_a'))$$, '23505', '%already has invoice #1001%',
                         'a job has at most one non-void invoice');
select tests.throws_like($$select public.create_invoice_from_job(tests.fx('job_a2'))$$, '22023', '%no line items%',
                         'a job without lines cannot be invoiced');
select tests.throws($$select public.create_invoice_from_job(tests.fx('job_b'))$$, 'P0002', 'another shop''s job: not found');
select tests.throws($$select public.create_invoice_from_job(gen_random_uuid())$$, 'P0002', 'unknown job: not found');

-- ------------------------------------------------------------ direct writes (manager)
select tests.throws($$insert into public.invoices (shop_id, customer_id, tax_rate_bps) values (tests.fx('shop_a'), tests.fx('cust_a'), 0)$$,
                    '42501', 'invoices are created only through RPCs');
select tests.throws_like($$update public.invoices set status = 'paid' where id = tests.fx('inv_a')$$, '42501', '%automatic%',
                         'status cannot be set directly');
select tests.throws($$update public.invoices set number = 5 where id = tests.fx('inv_a')$$, '42501', 'number immutable');
select tests.throws($$update public.invoices set customer_id = tests.fx('cust_a2') where id = tests.fx('inv_a')$$, '42501', 'customer immutable');
select tests.throws($$update public.invoices set job_id = null where id = tests.fx('inv_a')$$, '42501', 'job immutable');
select tests.throws($$update public.invoices set public_token = gen_random_uuid() where id = tests.fx('inv_a')$$, '42501', 'token immutable');
update public.invoices set amount_paid_cents = 21471, balance_cents = 0, tip_cents = 5, total_cents = 1, subtotal_cents = 1,
                           issued_at = '2020-01-01Z', paid_at = now(), sent_at = now()
 where id = tests.fx('inv_a');
select tests.eq(pg_temp.it(tests.fx('inv_a')), 'open/20900/1000/1571/21471/0/21471/0', 'client writes to amounts are ignored');
select tests.ok((select issued_at = now() and paid_at is null and sent_at is null from public.invoices where id = tests.fx('inv_a')),
                'client writes to stamps are ignored');
select tests.lives($$update public.invoices set notes = 'Thanks!', internal_notes = 'Paid late last time', due_at = now() + interval '30 days'
                     where id = tests.fx('inv_a')$$, 'notes and due date are editable');

-- open invoice without payments: lines and pricing editable, totals follow
insert into public.invoice_line_items (shop_id, invoice_id, service_id, unit_price_cents) values (tests.fx('shop_a'), tests.fx('inv_a'), tests.fx('svc_a'), 1000)
  returning tests.fx_set('il_extra', id);
select tests.eq((select name from public.invoice_line_items where id = tests.fx('il_extra')), 'Full Detail', 'line name defaults to the service');
update public.invoice_line_items set quantity = 2 where id = tests.fx('il_extra');
update public.invoices set discount_kind = 'percent', discount_value = 500 where id = tests.fx('inv_a');
-- lines 20000 (tax) + 900 (no tax) + 2000 (tax) = 22900; 5% = 1145; taxable share round(1145*22000/22900) = 1100;
-- tax round(20900 * 8.25%) = round(1724.25) = 1724; total 22900 - 1145 + 1724 = 23479
select tests.eq(pg_temp.it(tests.fx('inv_a')), 'open/22900/1145/1724/23479/0/23479/0', 'line + percent discount recompute');
select tests.ok((select i.subtotal_cents = r.subtotal_cents and i.discount_cents = r.discount_cents and i.tax_cents = r.tax_cents
                        and i.total_cents = r.total_cents
                 from public.invoices i
                 cross join lateral public.compute_document_totals(
                   (select jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                        'discount_cents', li.discount_cents, 'taxable', li.taxable))
                      from public.invoice_line_items li where li.invoice_id = i.id),
                   i.discount_kind, i.discount_value, i.tax_rate_bps) r
                 where i.id = tests.fx('inv_a')), 'stored invoice totals equal the canonical function');
delete from public.invoice_line_items where id = tests.fx('il_extra');
update public.invoices set discount_kind = 'fixed', discount_value = 1000 where id = tests.fx('inv_a');
select tests.eq(pg_temp.it(tests.fx('inv_a')), 'open/20900/1000/1571/21471/0/21471/0', 'deleting a line recomputes');

-- ------------------------------------------------------------ composite FKs / integrity
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, service_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('inv_a'), tests.fx('svc_b'), 'X', 1)$$, '23503', 'line cannot use another shop''s service');
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, vehicle_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('inv_a'), tests.fx('veh_b'), 'X', 1)$$, '23503', 'line cannot use another shop''s vehicle');
select tests.throws_like($$insert into public.invoice_line_items (shop_id, invoice_id, vehicle_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('inv_a'), tests.fx('veh_a2'), 'X', 1)$$, '23514', '%does not belong%',
                         'line vehicle must belong to the invoice customer');
select tests.throws($$update public.invoices set shop_id = tests.fx('shop_b') where id = tests.fx('inv_a')$$, '42501', 'invoices cannot move shops');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_a')$$,
                         '23514', '%invoice or payments%', 'an invoiced job keeps its customer');
select tests.throws($$delete from public.jobs where id = tests.fx('job_a')$$, '23503', 'an invoiced job cannot be deleted');
select tests.as_superuser();
select tests.throws($$insert into public.invoices (shop_id, job_id, customer_id) values (tests.fx('shop_a'), tests.fx('job_b'), tests.fx('cust_a'))$$,
                    '23503', 'invoice cannot reference another shop''s job');
select tests.throws($$insert into public.invoices (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_b'))$$,
                    '23503', 'invoice cannot reference another shop''s customer');
select tests.throws_like($$insert into public.invoices (shop_id, job_id, customer_id) values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('cust_a'))$$,
                         '23514', '%job''s customer%', 'job invoice must be for the job''s customer');
select tests.throws($$insert into public.invoices (shop_id, job_id, customer_id) values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('cust_a'))$$,
                    '23505', 'unique index: one non-void invoice per job even for trusted code');
select tests.throws($$update public.invoices set status = 'draft' where id = tests.fx('inv_a')$$, '23514', 'issued invoices never return to draft');

-- ------------------------------------------------------------ technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.invoices$$), 0::bigint, 'collecting disabled: technicians see no invoices');
select tests.eq(tests.row_count($$select * from public.invoice_line_items$$), 0::bigint, 'collecting disabled: no invoice lines');
select tests.throws($$select public.mark_invoice_sent(tests.fx('inv_a'))$$, '42501', 'collecting disabled: cannot send');
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_a2'), 'Wash', 4000);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.invoices where id = tests.fx('inv_a')$$), 1::bigint,
                'collecting enabled: technician reads the invoice of an assigned job');
select tests.eq(tests.row_count($$select * from public.invoice_line_items where invoice_id = tests.fx('inv_a')$$), 2::bigint,
                'and its lines');
select tests.throws($$select public.create_invoice_from_job(tests.fx('job_a2'))$$, '42501', 'technician cannot invoice an unassigned job');
select tests.eq(tests.row_count($$update public.invoices set notes = 'x' where id = tests.fx('inv_a')$$), 0::bigint, 'technicians cannot edit invoices');
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('inv_a'), 'X', 1)$$,
                    '42501', 'technicians cannot add invoice lines');
select tests.throws($$select public.void_invoice(tests.fx('inv_a'))$$, '42501', 'technicians cannot void');
select tests.throws($$select public.create_invoice(tests.fx('cust_a'))$$, '42501', 'technicians cannot create ad-hoc invoices');
select tests.lives($$select public.mark_invoice_sent(tests.fx('inv_a'))$$, 'collecting technician sends the invoice link');
select tests.eq((select sent_at from public.invoices where id = tests.fx('inv_a')), now(), 'sent_at stamped');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.invoices where id = tests.fx('inv_a')$$), 0::bigint,
                'another technician does not see it');
select tests.lives($$select tests.fx_set('inv_a2', (public.create_invoice_from_job(tests.fx('job_a2'))).id)$$,
                   'collecting technician invoices their assigned job');
select tests.eq((select created_by from public.invoices where id = tests.fx('inv_a2')), tests.fx('u_tech2_a'), 'created_by is the technician');
select tests.eq(tests.row_count($$select 1 from public.invoices$$), 1::bigint, 'technician sees only invoices of assigned jobs');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.throws($$select public.mark_invoice_sent(tests.fx('inv_a'))$$, 'P0002', 'technician of B: not found');

-- ------------------------------------------------------------ create_invoice (ad-hoc) + mark_invoice_sent
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.create_invoice(tests.fx('cust_b'))$$, 'P0002', 'another shop''s customer: not found');
select tests.throws_like($$select public.create_invoice(tests.fx('cust_a3'), '{"a":1}')$$, '22023', '%array%', 'lines must be an array');
select tests.throws_like($$select public.create_invoice(tests.fx('cust_a3'), '[1]')$$, '22023', '%object%', 'each line must be an object');
select tests.throws_like($$select public.create_invoice(tests.fx('cust_a3'), '[{"name":"Labor"}]')$$, '22023', '%unit price%',
                         'custom lines need a price');
select tests.throws_like($$select public.create_invoice(tests.fx('cust_a3'), '[{"unit_price_cents":100}]')$$, '22023', '%needs a name%',
                         'custom lines need a name');
select tests.throws_like($$select public.create_invoice(tests.fx('cust_a3'), jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_b'))))$$,
                         '22023', '%service not found%', 'another shop''s service is rejected');
select tests.throws($$select public.create_invoice(tests.fx('cust_a3'), jsonb_build_array(jsonb_build_object('name', 'X', 'unit_price_cents', -5)))$$,
                    '23514', 'negative prices rejected');
select tests.lives($$select tests.fx_set('inv_adhoc', (public.create_invoice(
                       tests.fx('cust_a'),
                       jsonb_build_array(
                         jsonb_build_object('service_id', tests.fx('svc_a'), 'vehicle_id', tests.fx('veh_a')),
                         jsonb_build_object('name', ' Headlight restore ', 'unit_price_cents', 7500, 'taxable', false, 'quantity', 2,
                                            'discount_cents', 500)),
                       ' Walk-in ', 'Cash customer')).id)$$, 'manager creates an ad-hoc invoice with lines');
select tests.ok((select status = 'draft' and job_id is null and issued_at is null and due_at is null and notes = 'Walk-in'
                        and internal_notes = 'Cash customer' and number = 1003
                 from public.invoices where id = tests.fx('inv_adhoc')), 'ad-hoc invoices start as numbered drafts');
select tests.eq((select array_agg(concat_ws(':', name, quantity, unit_price_cents, discount_cents, taxable::text, sort) order by sort)
                   from public.invoice_line_items where invoice_id = tests.fx('inv_adhoc')),
                array['Full Detail:1.00:20000:0:true:1', 'Headlight restore:2.00:7500:500:false:2'],
                'service line priced from the catalog; custom line as given');
select tests.eq(pg_temp.it(tests.fx('inv_adhoc')), 'draft/34500/0/1650/36150/0/36150/0', 'draft totals');
select tests.as_anon();
select tests.throws($$select public.create_invoice(tests.fx('cust_a'))$$, '42501', 'anon cannot create invoices');
select tests.authenticate_as(tests.fx('u_manager_a'));
-- drafts are fully editable
select tests.lives($$update public.invoices set tax_rate_bps = 0 where id = tests.fx('inv_adhoc')$$, 'draft pricing editable');
update public.invoices set tax_rate_bps = 825, due_at = '2020-01-01Z' where id = tests.fx('inv_adhoc');
select tests.throws_like($$select public.mark_invoice_sent(tests.fx('inv_adhoc'))$$, '22023', '%due date is in the past%',
                         'cannot issue with a past due date');
update public.invoices set due_at = null where id = tests.fx('inv_adhoc');
select tests.lives($$select public.mark_invoice_sent(tests.fx('inv_adhoc'))$$, 'issue + send');
select tests.ok((select status = 'open' and issued_at = now() and sent_at = now() and due_at = now() + interval '14 days'
                 from public.invoices where id = tests.fx('inv_adhoc')), 'draft -> open, issued and due dates stamped');
select tests.eq((public.mark_invoice_sent(tests.fx('inv_adhoc'))).status::text, 'open', 're-sending keeps the status');
select tests.lives($$select tests.fx_set('inv_empty', (public.create_invoice(tests.fx('cust_a3'))).id)$$);
select tests.throws_like($$select public.mark_invoice_sent(tests.fx('inv_empty'))$$, '22023', '%at least one line%',
                         'an empty draft cannot be issued');
-- drafts can be deleted; issued invoices cannot
select tests.eq(tests.row_count($$delete from public.invoices where id = tests.fx('inv_empty')$$), 1::bigint, 'drafts can be deleted');
select tests.eq(tests.row_count($$delete from public.invoices where id = tests.fx('inv_adhoc')$$), 0::bigint, 'issued invoices cannot be deleted');

-- ------------------------------------------------------------ zero-total invoices
select tests.lives($$select tests.fx_set('inv_zero', (public.create_invoice(tests.fx('cust_a3'),
                       '[{"name":"Warranty touch-up","unit_price_cents":0}]')).id)$$);
select public.mark_invoice_sent(tests.fx('inv_zero'));
select tests.ok((select status = 'paid' and paid_at = issued_at and balance_cents = 0 from public.invoices where id = tests.fx('inv_zero')),
                'an issued zero-total invoice is paid');
select tests.as_superuser();
select tests.fx_set('inv_zero2', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Goodwill wash","unit_price_cents":0}]')).id)
  from (select tests.authenticate_as(tests.fx('u_manager_a'))) x;
select tests.as_superuser();
update public.invoices set status = 'open', issued_at = '2025-01-10 15:00Z' where id = tests.fx('inv_zero2');
select tests.eq((select concat_ws('/', status, paid_at, due_at) from public.invoices where id = tests.fx('inv_zero2')),
                'paid/2025-01-10 15:00:00+00/2025-01-24 15:00:00+00', 'zero-total: paid_at = issued_at; due = issued + 14 days');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents)
                     values (tests.fx('shop_a'), tests.fx('inv_zero'), 'Extra', 1000)$$,
                   'a paid invoice with no money received stays editable');
select tests.ok((select status = 'open' and paid_at is null and balance_cents = 1083 from public.invoices where id = tests.fx('inv_zero')),
                'adding a priced line reopens it');

-- ------------------------------------------------------------ payments lock lines/pricing
select tests.lives($$select public.record_manual_payment(tests.fx('inv_adhoc'), 1000, 'cash')$$);
select tests.eq(pg_temp.it(tests.fx('inv_adhoc')), 'partially_paid/34500/0/1650/36150/1000/35150/0', 'partial payment');
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 1 where invoice_id = tests.fx('inv_adhoc')$$, '23514',
                         '%payments have been received%', 'lines locked once money is received');
select tests.throws_like($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('inv_adhoc'), 'X', 1)$$, '23514', '%payments%', 'no new lines');
select tests.throws($$delete from public.invoice_line_items where invoice_id = tests.fx('inv_adhoc')$$, '23514', 'no deleting lines');
select tests.throws_like($$update public.invoices set discount_kind = 'fixed', discount_value = 100 where id = tests.fx('inv_adhoc')$$,
                         '23514', '%pricing%', 'pricing locked once money is received');
select tests.lives($$update public.invoices set notes = 'Balance due on pickup' where id = tests.fx('inv_adhoc')$$, 'notes stay editable');

-- ------------------------------------------------------------ void_invoice
select tests.throws($$select public.void_invoice(tests.fx('inv_a'))$$, '42501', 'managers cannot void');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.void_invoice(tests.fx('inv_a'))$$, 'P0002', 'admin of B: not found');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.void_invoice(tests.fx('inv_adhoc'))$$, '22023', '%refund the payments%',
                         'cannot void an ad-hoc invoice holding money');
select tests.throws($$select public.void_invoice(tests.fx('inv_a'), repeat('x', 1001))$$, '22023', 'void reason length');
select tests.lives($$select public.void_invoice(tests.fx('inv_a'), '  Wrong services  ')$$, 'admin voids an invoice without money');
select tests.ok((select status = 'void' and voided_at = now() and void_reason = 'Wrong services' and balance_cents = total_cents
                 from public.invoices where id = tests.fx('inv_a')), 'void stamps voided_at and reason');
select tests.throws_like($$select public.void_invoice(tests.fx('inv_a'))$$, '22023', '%already void%', 'void is terminal');
select tests.throws_like($$select public.mark_invoice_sent(tests.fx('inv_a'))$$, '22023', '%void%', 'void invoices cannot be sent');
select tests.throws_like($$select public.record_manual_payment(tests.fx('inv_a'), 100, 'cash')$$, '22023', '%void%',
                         'void invoices take no payments');
select tests.throws_like($$update public.invoice_line_items set unit_price_cents = 1 where invoice_id = tests.fx('inv_a')$$, '23514', '%void%',
                         'void invoice lines are locked');
select tests.throws_like($$update public.invoices set notes = 'x' where id = tests.fx('inv_a')$$, '23514', '%void%', 'void invoices are locked');
select tests.lives($$update public.invoices set internal_notes = 'Replaced by the next invoice' where id = tests.fx('inv_a')$$,
                   'internal notes stay editable on void invoices');
select tests.as_superuser();
select tests.throws($$update public.invoices set status = 'open', voided_at = null where id = tests.fx('inv_a')$$, '23514',
                    'void invoices can never be reopened');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select tests.fx_set('inv_a_new', (public.create_invoice_from_job(tests.fx('job_a'))).id)$$,
                   'after voiding, the job can be invoiced again');
select tests.eq((select number from public.invoices where id = tests.fx('inv_a_new')), 1007::bigint, 'replacement gets a new number');
select tests.eq((select count(*) from public.invoices where job_id = tests.fx('job_a')), 2::bigint, 'void invoice kept as history');

-- ------------------------------------------------------------ isolation (manager of B)
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.invoices where shop_id = tests.fx('shop_a')$$), 0::bigint, 'B cannot read A''s invoices');
select tests.eq(tests.row_count($$select * from public.invoice_line_items where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor lines');
select tests.eq(tests.row_count($$update public.invoices set notes = 'x' where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor update');
select tests.eq(tests.row_count($$delete from public.invoice_line_items where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor delete lines');
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('inv_a_new'), 'X', 1)$$,
                    '42501', 'B cannot add lines to A''s invoice');
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents) values (tests.fx('shop_b'), tests.fx('inv_a_new'), 'X', 1)$$,
                    '23503', 'B cannot attach its lines to A''s invoice');
select tests.throws($$select public.create_invoice(tests.fx('cust_a'))$$, 'P0002', 'B cannot invoice A''s customer');
