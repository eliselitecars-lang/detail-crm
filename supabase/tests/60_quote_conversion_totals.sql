-- 60 money: a converted quote keeps its per-line discount eligibility, so
-- the job (and its invoice and deposit) total equals the approved quote
-- (0067 convert_quote_to_job_core copies discount_eligible; 0062
-- job_line_items_60_money keeps it on a coupon-less job, stamps it from the
-- coupon otherwise, and ignores client writes). Self-scheduled conversion,
-- coupons added / removed later, client-context writes and roles.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 1000 where id = tests.fx('shop_a');

create function pg_temp.elig(p_job uuid) returns text language sql as $$
  select string_agg(name || ':' || discount_eligible::text, ',' order by sort, name) from public.job_line_items where job_id = p_job
$$;
grant execute on function pg_temp.elig(uuid) to authenticated;

-- ============================================================ staff conversion
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'percent', 1000) returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, discount_eligible, sort) values
  (tests.fx('shop_a'), tests.fx('q'), 'Detail', 10000, true, 1),
  (tests.fx('shop_a'), tests.fx('q'), 'Travel', 5000, false, 2);
select tests.eq((select total_cents from public.quotes where id = tests.fx('q')), 15400::bigint,
                'quote: 15000 - 10% of the Detail line (1000) + 10% tax of 14000');
select public.mark_quote_sent(tests.fx('q'));
select public.staff_record_quote_response(tests.fx('q'), 'approve', null, 'Al');
select tests.fx_set('j', (public.convert_quote_to_job(tests.fx('q'))).id);
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:false', 'the conversion copies each line''s eligibility');
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where id = tests.fx('j')),
                '15000/1000/1400/15400', 'job total equals the approved quote total');
-- the stored totals are the canonical function over the lines
select tests.ok((select j.total_cents = (public.compute_document_totals(
                   (select jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                        'taxable', li.taxable, 'discount_eligible', li.discount_eligible))
                      from public.job_line_items li where li.job_id = j.id),
                   j.discount_kind, j.discount_value, j.tax_rate_bps)).total_cents
                 from public.jobs j where j.id = tests.fx('j')), 'and compute_document_totals agrees');
-- the invoice copies it too
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('j'))).id);
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv')), 15400::bigint, 'so does the invoice');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv'), 'test');
select tests.authenticate_as(tests.fx('u_manager_a'));

-- ============================================================ client writes cannot change it
update public.job_line_items set discount_eligible = true where job_id = tests.fx('j') and name = 'Travel';
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:false', 'a client edit keeps the server''s value');
update public.job_line_items set unit_price_cents = 6000 where job_id = tests.fx('j') and name = 'Travel';
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:false', 'as does editing another column');
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, discount_eligible, sort)
  values (tests.fx('shop_a'), tests.fx('j'), 'Extra', 1000, false, 3);
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:false,Extra:true',
                'a new client line on a coupon-less job is eligible (client values ignored)');

-- ============================================================ a coupon takes over, removing it re-stamps all
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('j');
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:true,Extra:true', 'a coupon without a service list: every line');
update public.jobs set coupon_id = null where id = tests.fx('j');
select tests.eq(pg_temp.elig(tests.fx('j')), 'Detail:true,Travel:true,Extra:true', 'removing it leaves every line eligible');

-- ============================================================ self-scheduled conversion: deposit on the quote total
select tests.as_superuser();
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 5000, quote_self_schedule = true
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'percent', 1000) returning tests.fx_set('q2', id);
insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents, discount_eligible, duration_minutes, sort) values
  (tests.fx('shop_a'), tests.fx('q2'), tests.fx('svc_a'), 'Detail', 10000, true, 60, 1),
  (tests.fx('shop_a'), tests.fx('q2'), null, 'Travel', 5000, false, 0, 2);
select public.mark_quote_sent(tests.fx('q2'));
select tests.as_superuser();
select public_token as q2tok from public.quotes where id = tests.fx('q2') \gset
select ((now() at time zone 'America/Chicago')::date + 20)::text as d \gset
select tests.as_anon();
select public.public_respond_quote(:'q2tok', 'approve', 'Al');
select public.public_schedule_quote(:'q2tok', :'d' || 'T09:00:00') as r \gset
select tests.eq((:'r'::jsonb ->> 'total_cents')::bigint, 15400::bigint, 'the self-scheduled job equals the approved quote');
select tests.eq((:'r'::jsonb ->> 'deposit_required_cents')::bigint, 7700::bigint, 'and its 50% deposit is taken from that total');

-- ============================================================ isolation
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.job_line_items set discount_eligible = false where job_id = tests.fx('j')$$), 0::bigint,
                'another shop cannot touch the lines');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.convert_quote_to_job(tests.fx('q'))$$, null, 'technicians cannot convert quotes');
