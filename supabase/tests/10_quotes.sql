-- 10 money: quotes + quote_line_items — role matrix, numbering, totals with
-- optional lines, status machine & stamps, mark_quote_sent,
-- convert_quote_to_job, expire_quotes, composite-FK isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 825, quote_terms = 'Quote terms A' where id = tests.fx('shop_a');

create function pg_temp.qt(p_id uuid) returns text language sql as $$
  select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.quotes where id = p_id
$$;

-- ------------------------------------------------------------ create (manager)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id, number, public_token, created_by, subtotal_cents, total_cents,
                           sent_at, approved_by_name, converted_job_id)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 7, '00000000-0000-0000-0000-000000000009',
          tests.fx('u_owner_b'), 999, 999, '2025-01-01Z', 'Forged', null)
  returning tests.fx_set('q1', id);
select tests.eq((select number from public.quotes where id = tests.fx('q1')), 1001::bigint, 'first quote number is 1001');
select tests.eq((select status::text from public.quotes where id = tests.fx('q1')), 'draft', 'new quotes are drafts');
select tests.ok((select public_token <> '00000000-0000-0000-0000-000000000009' from public.quotes where id = tests.fx('q1')),
                'client-sent public_token ignored');
select tests.eq((select created_by from public.quotes where id = tests.fx('q1')), tests.fx('u_manager_a'), 'created_by is the caller');
select tests.eq((select tax_rate_bps from public.quotes where id = tests.fx('q1')), 825, 'tax rate defaults from the shop');
select tests.eq((select terms from public.quotes where id = tests.fx('q1')), 'Quote terms A', 'terms default from shops.quote_terms');
select tests.eq(pg_temp.qt(tests.fx('q1')), '0/0/0/0', 'client-sent totals ignored');
select tests.ok((select sent_at is null and approved_by_name is null from public.quotes where id = tests.fx('q1')),
                'client-sent stamps ignored on insert');
select tests.throws_like($$insert into public.quotes (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a'), 'sent')$$,
                         '23514', '%start as drafts%', 'quotes cannot be created in a later status');

insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q2', id);
select tests.eq((select number from public.quotes where id = tests.fx('q2')), 1002::bigint, 'numbers increase');
select tests.as_superuser();
select tests.eq((select next_value from public.shop_counters where shop_id = tests.fx('shop_a') and kind = 'quote'), 1003::bigint,
                'numbers come from the shop quote counter');
select tests.eq((select next_value from public.shop_counters where shop_id = tests.fx('shop_a') and kind = 'job'), 1003::bigint,
                'the quote counter is separate from the job counter');

-- numbering: many inserts in one go stay unique and gapless; (shop_id, number) is a unique key
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) select tests.fx('shop_a'), tests.fx('cust_a3') from generate_series(1, 25);
select tests.eq((select count(distinct number) from public.quotes where shop_id = tests.fx('shop_a')), 27::bigint,
                'bulk insert: every quote got its own number');
select tests.eq((select max(number) - min(number) + 1 from public.quotes where shop_id = tests.fx('shop_a')), 27::bigint,
                'numbers are gapless within a statement');
select tests.as_superuser();
select tests.ok(exists (select 1 from pg_constraint where conname = 'quotes_shop_number_key' and contype = 'u'),
                'quotes (shop_id, number) is unique');
select tests.lives($$update public.quotes set number = 1 where id = tests.fx('q1')$$);
select tests.eq((select number from public.quotes where id = tests.fx('q1')), 1001::bigint, 'numbers are immutable even for trusted code');
delete from public.quotes where shop_id = tests.fx('shop_a') and customer_id = tests.fx('cust_a3');
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b')) returning tests.fx_set('qb', id);
select tests.eq((select number from public.quotes where id = tests.fx('qb')), 1001::bigint, 'numbering is per shop');
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_b'), tests.fx('qb'), 'Wash', 5000);

-- ------------------------------------------------------------ lines and totals (optional / selected)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quote_line_items (shop_id, quote_id, service_id, unit_price_cents, duration_minutes, sort)
  values (tests.fx('shop_a'), tests.fx('q1'), tests.fx('svc_a'), 10000, 120, 1) returning tests.fx_set('l_req', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional, taxable, sort)
  values (tests.fx('shop_a'), tests.fx('q1'), 'Ceramic upgrade', 5000, true, false, 2) returning tests.fx_set('l_opt', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional, selected, sort)
  values (tests.fx('shop_a'), tests.fx('q1'), 'Tire shine', 2000, true, true, 3) returning tests.fx_set('l_opt_sel', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional, selected, quantity, sort)
  values (tests.fx('shop_a'), tests.fx('q1'), 'Mats', 1000, false, false, 2, 4) returning tests.fx_set('l_req2', id);
select tests.eq((select name from public.quote_line_items where id = tests.fx('l_req')), 'Full Detail', 'line name defaults to the service name');
select tests.eq((select selected from public.quote_line_items where id = tests.fx('l_opt')), false, 'optional lines start unselected');
select tests.eq((select selected from public.quote_line_items where id = tests.fx('l_opt_sel')), true, 'staff may pre-select an optional line');
select tests.eq((select selected from public.quote_line_items where id = tests.fx('l_req2')), true, 'required lines are always selected');
select tests.eq(pg_temp.qt(tests.fx('q1')), '14000/0/1155/15155',
                'only required + selected optional lines count (10000 + 2000 + 2x1000; 8.25% tax)');
update public.quote_line_items set selected = false where id = tests.fx('l_req');
select tests.eq((select selected from public.quote_line_items where id = tests.fx('l_req')), true, 'a required line cannot be unselected');
update public.quote_line_items set selected = true where id = tests.fx('l_opt');
select tests.eq(pg_temp.qt(tests.fx('q1')), '19000/0/1155/20155', 'selecting a non-taxable optional line adds it untaxed');
update public.quote_line_items set selected = false where id = tests.fx('l_opt');
update public.quotes set discount_kind = 'percent', discount_value = 1000 where id = tests.fx('q1');
select tests.eq(pg_temp.qt(tests.fx('q1')), '14000/1400/1040/13640', 'document discount prorated before tax');
select tests.ok((select q.subtotal_cents = r.subtotal_cents and q.discount_cents = r.discount_cents
                        and q.tax_cents = r.tax_cents and q.total_cents = r.total_cents
                 from public.quotes q
                 cross join lateral public.compute_document_totals(
                   (select jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                        'discount_cents', li.discount_cents, 'taxable', li.taxable))
                      from public.quote_line_items li where li.quote_id = q.id and (not li.optional or li.selected)),
                   q.discount_kind, q.discount_value, q.tax_rate_bps) r
                 where q.id = tests.fx('q1')),
                'stored quote totals equal the canonical function over counted lines');
update public.quotes set subtotal_cents = 1, total_cents = 1, tax_cents = 0, discount_cents = 0 where id = tests.fx('q1');
select tests.eq(pg_temp.qt(tests.fx('q1')), '14000/1400/1040/13640', 'client writes to totals are overwritten');
update public.quotes set discount_kind = 'none', discount_value = 0 where id = tests.fx('q1');
select tests.throws($$update public.quotes set discount_kind = 'none', discount_value = 5 where id = tests.fx('q1')$$, '23514',
                    'discount value must be 0 when kind is none');
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q1'), 'X', -1)$$,
                    '23514', 'negative price rejected');

-- ------------------------------------------------------------ integrity & composite FKs
select tests.throws($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_b'))$$, '23503',
                    'quote cannot reference another shop''s customer');
select tests.throws($$update public.quotes set vehicle_id = tests.fx('veh_b') where id = tests.fx('q1')$$, '23503',
                    'quote cannot reference another shop''s vehicle');
select tests.throws_like($$update public.quotes set vehicle_id = tests.fx('veh_a2') where id = tests.fx('q1')$$, '23514',
                         '%does not belong%', 'quote vehicle must belong to the quote customer');
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('qb'), 'X', 1)$$,
                    '23503', 'line cannot attach to another shop''s quote');
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('q1'), tests.fx('svc_b'), 'X', 1)$$, '23503', 'line cannot use another shop''s service');
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, vehicle_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('q1'), tests.fx('veh_b'), 'X', 1)$$, '23503', 'line cannot use another shop''s vehicle');
select tests.throws_like($$insert into public.quote_line_items (shop_id, quote_id, vehicle_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('q1'), tests.fx('veh_a2'), 'X', 1)$$, '23514', '%does not belong%',
                         'line vehicle must belong to the quote customer');
select tests.throws($$update public.quote_line_items set quote_id = tests.fx('q2') where id = tests.fx('l_req2')$$, '42501',
                    'lines cannot move between quotes');
select tests.throws($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b'))$$, '42501',
                    'manager of A cannot create quotes in B');
select tests.throws($$update public.quotes set shop_id = tests.fx('shop_b') where id = tests.fx('q1')$$, '42501', 'quotes cannot move shops');
select tests.throws($$update public.quotes set number = 5 where id = tests.fx('q1')$$, '42501', 'numbers immutable');
select tests.throws($$update public.quotes set public_token = gen_random_uuid() where id = tests.fx('q1')$$, '42501', 'token immutable');
select tests.eq(tests.row_count($$select * from public.quotes where shop_id = tests.fx('shop_b')$$), 0::bigint, 'cannot read B''s quotes');
select tests.eq(tests.row_count($$select * from public.quote_line_items where shop_id = tests.fx('shop_b')$$), 0::bigint, 'cannot read B''s quote lines');
select tests.eq(tests.row_count($$update public.quotes set notes = 'x' where id = tests.fx('qb')$$), 0::bigint, 'cannot update B''s quotes');
select tests.eq(tests.row_count($$delete from public.quote_line_items where shop_id = tests.fx('shop_b')$$), 0::bigint, 'cannot delete B''s lines');
select tests.throws($$select public.mark_quote_sent(tests.fx('qb'))$$, 'P0002', 'mark_quote_sent on another shop''s quote: not found');
select tests.throws($$select public.convert_quote_to_job(tests.fx('qb'))$$, 'P0002', 'convert on another shop''s quote: not found');

-- ------------------------------------------------------------ role matrix
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select * from public.quotes where shop_id = tests.fx('shop_a')$$), 2::bigint, 'owner reads quotes');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select * from public.quote_line_items where quote_id = tests.fx('q1')$$), 4::bigint, 'admin reads quote lines');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select * from public.quotes$$), 0::bigint, 'technicians see no quotes');
select tests.eq(tests.row_count($$select * from public.quote_line_items$$), 0::bigint, 'technicians see no quote lines');
select tests.throws($$insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))$$, '42501',
                    'technicians cannot create quotes');
select tests.throws($$select public.mark_quote_sent(tests.fx('q1'))$$, '42501', 'technicians cannot send quotes');
select tests.throws($$select public.convert_quote_to_job(tests.fx('q1'))$$, '42501', 'technicians cannot convert quotes');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.mark_quote_sent(tests.fx('q1'))$$, 'P0002', 'outsiders: not found');
select tests.as_anon();
select tests.throws($$select public.mark_quote_sent(tests.fx('q1'))$$, '42501', 'anon cannot call mark_quote_sent');

-- ------------------------------------------------------------ status machine: send
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.mark_quote_sent(tests.fx('q2'))$$, '22023', '%at least one line%', 'cannot send an empty quote');
select tests.throws_like($$update public.quotes set status = 'sent' where id = tests.fx('q1')$$, '42501', '%mark_quote_sent%',
                         'direct draft -> sent is refused');
update public.quotes set valid_until = '2020-01-01' where id = tests.fx('q1');
select tests.throws_like($$select public.mark_quote_sent(tests.fx('q1'))$$, '22023', '%valid-until%', 'cannot send an already-expired quote');
update public.quotes set valid_until = '2099-12-31' where id = tests.fx('q1');
select tests.eq((public.mark_quote_sent(tests.fx('q1'))).status::text, 'sent', 'mark_quote_sent: draft -> sent');
select tests.eq((select sent_at from public.quotes where id = tests.fx('q1')), now(), 'sent_at stamped');
update public.quotes set sent_at = '2020-01-01Z', viewed_at = '2020-01-01Z', converted_job_id = tests.fx('job_a') where id = tests.fx('q1');
select tests.ok((select sent_at = now() and viewed_at is null and converted_job_id is null from public.quotes where id = tests.fx('q1')),
                'clients cannot forge stamps or the converted job');
select tests.eq((public.mark_quote_sent(tests.fx('q1'))).status::text, 'sent', 're-sending keeps the status');
select tests.throws_like($$update public.quotes set status = 'viewed' where id = tests.fx('q1')$$, '42501', '%client quote page%',
                         'staff cannot mark a quote viewed');
select tests.throws_like($$update public.quotes set status = 'expired' where id = tests.fx('q1')$$, '42501', '%expiry%',
                         'staff cannot expire a quote directly');
select tests.throws_like($$update public.quotes set status = 'converted' where id = tests.fx('q1')$$, '23514', '%invalid quote status%',
                         'sent -> converted is not a transition');
-- sent quotes are still editable (price corrections before the customer answers)
select tests.lives($$update public.quotes set notes = 'Includes pickup' where id = tests.fx('q1')$$, 'sent quotes stay editable');
select tests.lives($$update public.quote_line_items set unit_price_cents = 10000 where id = tests.fx('l_req')$$, 'sent quote lines editable');

-- ------------------------------------------------------------ staff-recorded approval, locking, revise
update public.quotes set status = 'approved', approved_by_name = '  In person: Alice ', declined_reason = 'nope'
 where id = tests.fx('q1');
select tests.ok((select status = 'approved' and approved_at = now() and approved_by_name = 'In person: Alice' and declined_reason is null
                 from public.quotes where id = tests.fx('q1')), 'staff approval stamps approved_at and keeps the trimmed name only');
select tests.throws_like($$update public.quotes set notes = 'changed' where id = tests.fx('q1')$$, '23514', '%revise it back to draft%',
                         'approved quotes are locked');
select tests.throws_like($$update public.quote_line_items set unit_price_cents = 1 where id = tests.fx('l_req')$$, '23514',
                         '%revise it back to draft%', 'approved quote lines are locked');
select tests.throws($$delete from public.quote_line_items where id = tests.fx('l_req2')$$, '23514', 'approved quote lines cannot be deleted');
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q1'), 'Y', 1)$$,
                    '23514', 'no new lines on approved quotes');
select tests.lives($$update public.quotes set internal_notes = 'VIP' where id = tests.fx('q1')$$, 'internal notes stay editable');
update public.quotes set approved_by_name = 'Someone else' where id = tests.fx('q1');
select tests.eq((select approved_by_name from public.quotes where id = tests.fx('q1')), 'In person: Alice', 'signer name is not editable afterwards');
select tests.throws($$update public.quotes set status = 'declined' where id = tests.fx('q1')$$, '23514', 'approved -> declined is not a transition');
-- revise: back to draft clears the answer
update public.quotes set status = 'draft', notes = 'Revised' where id = tests.fx('q1');
select tests.ok((select status = 'draft' and sent_at is null and approved_at is null and approved_by_name is null and notes = 'Revised'
                 from public.quotes where id = tests.fx('q1')), 'revise to draft clears stamps and allows edits');
select tests.lives($$select public.mark_quote_sent(tests.fx('q1'))$$);
update public.quotes set status = 'declined', declined_reason = ' Too pricey ' where id = tests.fx('q1');
select tests.ok((select status = 'declined' and declined_at = now() and declined_reason = 'Too pricey' from public.quotes where id = tests.fx('q1')),
                'staff-recorded decline stamps declined_at');
select tests.throws($$update public.quotes set status = 'approved' where id = tests.fx('q1')$$, '23514', 'declined -> approved is not a transition');
update public.quotes set status = 'draft' where id = tests.fx('q1');
select tests.lives($$select public.mark_quote_sent(tests.fx('q1'))$$);
update public.quotes set status = 'approved' where id = tests.fx('q1');

-- ------------------------------------------------------------ convert_quote_to_job
select tests.throws_like($$select public.convert_quote_to_job(tests.fx('q2'))$$, '22023', '%only approved%', 'draft quotes cannot be converted');
select tests.throws_like($$select public.convert_quote_to_job(tests.fx('q1'), '2025-08-01 15:00Z', null)$$, '22023', '%both%',
                         'start and end come together');
select tests.throws_like($$select public.convert_quote_to_job(tests.fx('q1'), '2025-08-01 15:00Z', '2025-08-01 15:00Z')$$, '22023',
                         '%after the start%', 'end must be after start');
select tests.lives($$select tests.fx_set('job_q1', (public.convert_quote_to_job(tests.fx('q1'), '2025-08-01 15:00Z', '2025-08-01 17:00Z')).id)$$,
                   'manager converts an approved quote');
select tests.ok((select source = 'quote' and quote_id = tests.fx('q1') and status = 'scheduled' and customer_id = tests.fx('cust_a')
                        and vehicle_id = tests.fx('veh_a') and scheduled_start = '2025-08-01 15:00Z' and notes = 'Revised'
                        and internal_notes = 'VIP' and created_by = tests.fx('u_manager_a')
                 from public.jobs where id = tests.fx('job_q1')), 'job copies quote header, links back, is scheduled');
select tests.eq((select array_agg(name || ':' || quantity::text || ':' || unit_price_cents order by sort) from public.job_line_items
                  where job_id = tests.fx('job_q1')),
                array['Full Detail:1.00:10000', 'Tire shine:1.00:2000', 'Mats:2.00:1000'],
                'only counted lines are copied (unselected optional line left out), in order');
select tests.eq((select duration_minutes from public.job_line_items where job_id = tests.fx('job_q1') and name = 'Full Detail'), 120,
                'line durations copied');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('job_q1')),
                pg_temp.qt(tests.fx('q1')), 'job totals equal the quote totals');
select tests.ok((select status = 'converted' and converted_job_id = tests.fx('job_q1') and converted_at = now() from public.quotes
                 where id = tests.fx('q1')), 'quote is converted and linked to the job');
select tests.throws_like($$select public.convert_quote_to_job(tests.fx('q1'))$$, '22023', '%already converted to job #%',
                         'a quote converts only once');
select tests.throws($$update public.quotes set status = 'draft' where id = tests.fx('q1')$$, '23514', 'converted quotes cannot be revised');
select tests.eq(tests.row_count($$delete from public.quotes where id = tests.fx('q1')$$), 0::bigint, 'converted quotes cannot be deleted');
select tests.throws($$update public.quote_line_items set sort = 9 where id = tests.fx('l_req')$$, '23514', 'converted quote lines are locked');
-- unscheduled conversion -> requested job
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q3', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q3'), 'Wax', 3000);
select public.mark_quote_sent(tests.fx('q3'));
update public.quotes set status = 'approved' where id = tests.fx('q3');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.convert_quote_to_job(tests.fx('q3'))).status::text, 'requested', 'no times -> requested job (admin may convert)');
-- deleting the job keeps the quote converted but unlinked
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_q1');
select tests.ok((select status = 'converted' and converted_job_id is null from public.quotes where id = tests.fx('q1')),
                'deleted job: quote stays converted without a link');

-- ------------------------------------------------------------ delete
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q4', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q4'), 'Wax', 3000);
select public.mark_quote_sent(tests.fx('q4'));
update public.quotes set status = 'approved' where id = tests.fx('q4');
select tests.eq(tests.row_count($$delete from public.quotes where id = tests.fx('q4')$$), 1::bigint,
                'an approved (not converted) quote can be deleted; its locked lines cascade');
select tests.eq((select count(*) from public.quote_line_items where quote_id = tests.fx('q4')), 0::bigint, 'lines deleted with the quote');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.quotes where id = tests.fx('q2')$$), 0::bigint, 'technicians cannot delete quotes');

-- ------------------------------------------------------------ expire_quotes (service_role / cron)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.expire_quotes()$$, '42501', 'authenticated cannot run expire_quotes');
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('qe1', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('qe2', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('qe3', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents)
  select tests.fx('shop_a'), x, 'Wash', 1000 from unnest(array[tests.fx('qe1'), tests.fx('qe2'), tests.fx('qe3')]) x;
select public.mark_quote_sent(tests.fx('qe1'));
select public.mark_quote_sent(tests.fx('qe2'));
select tests.as_superuser();
-- sent quote valid through 2025-03-10 (Chicago; CDT from 2025-03-09) -> ends 2025-03-11 05:00Z
update public.quotes set valid_until = '2025-03-10' where id in (tests.fx('qe1'), tests.fx('qe3'));
update public.quotes set status = 'viewed', valid_until = '2025-03-12' where id = tests.fx('qe2');
select tests.eq(public.quote_validity_end('2025-03-10', 'America/Chicago'), '2025-03-11 05:00Z'::timestamptz,
                'validity ends at the next local midnight (DST-aware)');
select tests.eq(public.quote_validity_end('2025-01-10', 'America/Chicago'), '2025-01-11 06:00Z'::timestamptz, 'CST offset in winter');
select tests.as_service();
select tests.eq(public.expire_quotes('2025-03-11 04:59:59Z'), 0, 'not expired one second before the end of the valid day');
select tests.eq(public.expire_quotes('2025-03-11 05:00Z'), 1, 'expired at the local midnight after valid_until');
select tests.ok((select status = 'expired' and expired_at = '2025-03-11 05:00Z' from public.quotes where id = tests.fx('qe1')),
                'expired_at = p_now');
select tests.eq((select status::text from public.quotes where id = tests.fx('qe3')), 'draft', 'drafts never expire');
select tests.eq(public.expire_quotes('2025-03-11 05:00Z'), 0, 'expire_quotes is idempotent');
select tests.eq(public.expire_quotes('2025-03-13 06:00Z'), 1, 'viewed quotes expire too');
select tests.eq((select count(*) from public.quotes where status = 'expired' and shop_id = tests.fx('shop_a')), 2::bigint, 'two expired');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.mark_quote_sent(tests.fx('qe1'))$$, '22023', '%revise it back to draft%',
                         'expired quotes must be revised before re-sending');
update public.quotes set status = 'draft', valid_until = '2099-01-01' where id = tests.fx('qe1');
select tests.eq((public.mark_quote_sent(tests.fx('qe1'))).status::text, 'sent', 'revised expired quote can be re-sent');
