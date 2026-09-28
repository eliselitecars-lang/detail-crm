-- 60 money: preset fees (P-21, 0068) — fee settings (owners/admins write,
-- members read names), auto-apply by location type on new jobs and on a
-- location change, online bookings (total and deposit include the fee),
-- quote conversion (no duplicates), add_fee_line on jobs / quotes /
-- invoices under each document's rules, cross-shop ids, deleting a fee.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

create function pg_temp.lines(p_job uuid) returns text language sql as $$
  select string_agg(name || ':' || unit_price_cents || ':' || sort, ',' order by sort, name) from public.job_line_items where job_id = p_job
$$;
grant execute on function pg_temp.lines(uuid) to authenticated, service_role;

-- ============================================================ settings
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, sort) values
  (tests.fx('shop_a'), ' Travel ', 2500, 'mobile', 1) returning tests.fx_set('f_travel', id);
insert into public.shop_fees (shop_id, name, amount_cents, taxable, auto_apply, sort) values
  (tests.fx('shop_a'), 'Shop supplies', 500, true, 'shop', 2) returning tests.fx_set('f_supplies', id);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, sort) values
  (tests.fx('shop_a'), 'Eco fee', 300, 'both', 3) returning tests.fx_set('f_eco', id);
insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), 'Rush', 5000) returning tests.fx_set('f_rush', id);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, archived_at) values
  (tests.fx('shop_a'), 'Old fee', 100, 'both', now()) returning tests.fx_set('f_old', id);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, active) values
  (tests.fx('shop_a'), 'Paused fee', 100, 'both', false) returning tests.fx_set('f_paused', id);
select tests.eq((select name from public.shop_fees where id = tests.fx('f_travel')), 'Travel', 'names are trimmed');
select tests.throws($$insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), 'Free', 0)$$, '23514',
                    'a fee has an amount (entered by the shop)');
select tests.throws($$insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), ' ', 100)$$, '23514',
                    'and a name');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), 'Mgr', 100)$$, '42501',
                    'managers cannot create fees');
select tests.eq(tests.row_count($$update public.shop_fees set amount_cents = 1 where id = tests.fx('f_travel')$$), 0::bigint,
                'nor change them');
select tests.eq((select count(*) from public.shop_fees where shop_id = tests.fx('shop_a')), 6::bigint, 'but read them');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select name from public.shop_fees where id = tests.fx('f_eco')), 'Eco fee', 'technicians read fee names (shown on documents)');
select tests.throws($$insert into public.shop_fees (shop_id, name, amount_cents) values (tests.fx('shop_a'), 'T', 100)$$, '42501',
                    'technicians cannot create fees');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq((select count(*) from public.shop_fees where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops see nothing');
select tests.eq(tests.row_count($$delete from public.shop_fees where shop_id = tests.fx('shop_a')$$), 0::bigint, 'nor delete');
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply) values (tests.fx('shop_b'), 'B travel', 1000, 'both')
  returning tests.fx_set('f_b', id);

-- ============================================================ auto-apply on new jobs
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, status, location_type) values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', 'shop')
  returning tests.fx_set('j_shop', id);
select tests.eq(pg_temp.lines(tests.fx('j_shop')), 'Shop supplies:500:1001,Eco fee:300:1002',
                'an in-shop job gets the shop and "both" fees (active, not archived) after the work lines');
insert into public.jobs (shop_id, customer_id, status, location_type, service_address_line1, service_city, service_postal_code)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', 'mobile', '1 Elm', 'Birmingham', '35203') returning tests.fx_set('j_mob', id);
select tests.eq(pg_temp.lines(tests.fx('j_mob')), 'Travel:2500:1001,Eco fee:300:1002', 'a mobile job gets the travel fee');
select tests.ok((select bool_and(fee_id is not null) from public.job_line_items where job_id = tests.fx('j_mob')), 'lines link their fee');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('j_mob'), tests.fx('svc_a'), 'Full Detail', 20000, 1);
-- 20000 + 2500 + 300 = 22800; 10% tax on the taxable lines (Full Detail) only: 2000
select tests.eq((select concat_ws('/', subtotal_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('j_mob')),
                '22800/2000/24800', 'fees are ordinary lines in the totals (the travel fee is not taxable)');

-- location changes swap the auto fees
update public.jobs set location_type = 'shop' where id = tests.fx('j_mob');
select tests.eq(pg_temp.lines(tests.fx('j_mob')), 'Full Detail:20000:1,Shop supplies:500:1001,Eco fee:300:1002',
                'moving to the shop: travel removed, shop supplies added, the "both" fee kept once');
select tests.lives($$select public.add_fee_line('job', tests.fx('j_mob'), tests.fx('f_rush'))$$, 'a manual fee');
update public.jobs set location_type = 'mobile', service_address_line1 = '1 Elm', service_city = 'Birmingham', service_postal_code = '35203'
 where id = tests.fx('j_mob');
select tests.eq((select string_agg(name, ',' order by name) from public.job_line_items where job_id = tests.fx('j_mob') and fee_id is not null),
                'Eco fee,Rush,Travel', 'back to mobile; manually added fees without auto-apply stay');
-- billed jobs keep their lines
select public.create_invoice_from_job(tests.fx('j_mob'));
update public.jobs set location_type = 'shop' where id = tests.fx('j_mob');
select tests.eq((select string_agg(name, ',' order by name) from public.job_line_items where job_id = tests.fx('j_mob') and fee_id is not null),
                'Eco fee,Rush,Travel', 'a job with a live invoice keeps its fees when its location changes');
select tests.eq((select count(*) from public.invoice_line_items li join public.invoices i on i.id = li.invoice_id
                  where i.job_id = tests.fx('j_mob') and li.fee_id is not null), 3::bigint, 'invoices copy the fee links');

-- ============================================================ online bookings
select tests.as_superuser();
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 5000 where shop_id = tests.fx('shop_a');
select tests.as_service();
select public.create_online_booking('shop-a',
         pg_temp.booking('{"location":{"type":"mobile","address_line1":"9 Oak St","city":"Birmingham","postal_code":"35203"}}'),
         '2025-06-01Z') as ob \gset
-- Full Detail 20000 + Travel 2500 + Eco 300 = 22800; tax 2000 -> 24800; 50% deposit 12400
select tests.eq(:'ob'::jsonb - 'job_token' - 'job_number' - 'status', '{"total_cents": 24800, "deposit_required_cents": 12400}'::jsonb,
                'an online booking''s total and deposit include the fees');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.public_token = (:'ob'::jsonb ->> 'job_token')::uuid and li.fee_id is not null), 2::bigint, 'two fee lines');

-- ============================================================ quotes: fees by hand; conversion does not duplicate
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q'), 'Coating', 50000);
select tests.fx_set('q_fee_line', public.add_fee_line('quote', tests.fx('q'), tests.fx('f_eco')));
select tests.eq((select concat_ws('/', name, unit_price_cents, taxable, fee_id = tests.fx('f_eco')) from public.quote_line_items where id = tests.fx('q_fee_line')),
                'Eco fee/300/f/t', 'a quote fee line');
select public.mark_quote_sent(tests.fx('q'));
update public.quotes set status = 'approved' where id = tests.fx('q');
select tests.throws_like($$select public.add_fee_line('quote', tests.fx('q'), tests.fx('f_rush'))$$, '22023', '%revise it back to draft%',
                         'not on an approved quote');
select tests.fx_set('j_q', (public.convert_quote_to_job(tests.fx('q'))).id);
select tests.eq(pg_temp.lines(tests.fx('j_q')), 'Coating:50000:1,Eco fee:300:2', 'the quote''s fee is copied once; no auto fees on conversions');

-- ============================================================ add_fee_line on invoices and the rules
select tests.fx_set('inv', (public.create_invoice(tests.fx('cust_a2'), '[{"name":"Wash","unit_price_cents":4000}]')).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.lives($$select public.add_fee_line('invoice', tests.fx('inv'), tests.fx('f_travel'))$$, 'an open invoice without money takes a fee');
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv')), 6900::bigint, 'and its total follows (4000 + 400 tax + 2500)');
select public.record_manual_payment(tests.fx('inv'), 100, 'cash');
select tests.throws_like($$select public.add_fee_line('invoice', tests.fx('inv'), tests.fx('f_rush'))$$, '23514', '%payments have been received%',
                         'not once money is on it');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('j_shop'), tests.fx('f_old'))$$, '22023', '%not available%', 'archived fees');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('j_shop'), tests.fx('f_paused'))$$, '22023', '%not available%', 'inactive fees');
select tests.throws_like($$select public.add_fee_line('job', tests.fx('j_shop'), tests.fx('f_b'))$$, '22023', '%not available%',
                         'another shop''s fee');
select tests.throws($$select public.add_fee_line('estimate', tests.fx('j_shop'), tests.fx('f_rush'))$$, '22023', 'document kind');
select tests.throws($$select public.add_fee_line('job', gen_random_uuid(), tests.fx('f_rush'))$$, 'P0002', 'unknown document');
select tests.throws($$insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, fee_id)
                      values (tests.fx('shop_a'), tests.fx('j_shop'), 'X', 1, tests.fx('f_b'))$$, '23503', 'composite FK: another shop''s fee');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.add_fee_line('job', tests.fx('job_a'), tests.fx('f_rush'))$$, '42501', 'technicians cannot add fees');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.add_fee_line('job', tests.fx('j_shop'), tests.fx('f_rush'))$$, 'P0002', 'other shops: not found');

-- ============================================================ deleting a fee keeps the lines
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$delete from public.shop_fees where id = tests.fx('f_travel')$$, 'a fee used on a paid-into invoice can be deleted');
select tests.eq((select count(*) from public.invoice_line_items where invoice_id = tests.fx('inv') and name = 'Travel' and fee_id is null), 1::bigint,
                'the invoice line stays, only its link is cleared');
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv')), 6900::bigint, 'totals unchanged');
select tests.as_superuser();
select tests.ok(has_function_privilege('authenticated', 'public.add_fee_line(text, uuid, uuid, text)', 'execute')
                and not has_function_privilege('anon', 'public.add_fee_line(text, uuid, uuid, text)', 'execute'), 'add_fee_line: staff only');
