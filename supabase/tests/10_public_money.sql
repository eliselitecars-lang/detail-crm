-- 10 money: public_get_quote / public_respond_quote / public_get_invoice —
-- curated JSON (exact key sets, nothing internal), viewed marking, approval
-- with optional lines, decline, expiry, invoice payability.
\ir fixtures/two_shops.psql

create function pg_temp.keys(p jsonb) returns text language sql as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(p) k
$$;

select tests.as_superuser();
-- the platform binds the shop's SMS number first (comms, 0033), when that range is applied
do $$ begin
  if to_regclass('public.shop_sms_numbers') is not null then
    execute format('insert into public.shop_sms_numbers (phone_number, shop_id) values (%L, %L)', '+12055550199', tests.fx('shop_a'));
  end if;
end $$;
-- the logo is an uploaded object of the shop's own shop-assets folder (0001)
insert into storage.buckets (id, name, public) values ('shop-assets', 'shop-assets', true) on conflict (id) do nothing;
insert into storage.objects (bucket_id, name) values ('shop-assets', tests.fx('shop_a') || '/logo.png');
update public.shops set tax_rate_bps = 1000, logo_path = tests.fx('shop_a') || '/logo.png', brand_color = '#112233', email = 'hello@shop-a.test',
                        phone = '+12055550100', website = 'https://shop-a.test', address_line1 = '1 Main St', city = 'Birmingham',
                        region = 'AL', postal_code = '35203', review_url = 'https://g.page/shop-a', sms_from_number = '+12055550199'
 where id = tests.fx('shop_a');
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);

-- quote with a required line, two optional lines (one pre-selected), internal notes
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id, valid_until, notes, internal_notes)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2099-12-31', 'Includes hand wash', 'SECRET-INTERNAL-NOTE')
  returning tests.fx_set('q', id), tests.fx_set('q_token', public_token);
insert into public.quote_line_items (shop_id, quote_id, service_id, vehicle_id, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('q'), tests.fx('svc_a'), tests.fx('veh_a'), 20000, 1) returning tests.fx_set('ql_req', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional, sort)
  values (tests.fx('shop_a'), tests.fx('q'), 'Ceramic coating', 50000, true, 2) returning tests.fx_set('ql_opt1', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional, selected, taxable, sort)
  values (tests.fx('shop_a'), tests.fx('q'), 'Pet hair removal', 3000, true, true, false, 3) returning tests.fx_set('ql_opt2', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2'))
  returning tests.fx_set('q_draft', id), tests.fx_set('q_draft_token', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_draft'), 'Wash', 3000);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2'))
  returning tests.fx_set('q2', id), tests.fx_set('q2_token', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q2'), 'Wash', 3000);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2'))
  returning tests.fx_set('q3', id), tests.fx_set('q3_token', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional) values (tests.fx('shop_a'), tests.fx('q3'), 'Wax', 3000, true);
select public.mark_quote_sent(tests.fx('q'));
select public.mark_quote_sent(tests.fx('q2'));
select public.mark_quote_sent(tests.fx('q3'));
-- B has a quote with an optional line too
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b')) returning tests.fx_set('qb', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional) values (tests.fx('shop_b'), tests.fx('qb'), 'Wax', 3000, true)
  returning tests.fx_set('qbl_opt', id);

-- ------------------------------------------------------------ public_get_quote
select tests.as_anon();
select tests.throws($$select public.public_get_quote(tests.fx('q_draft_token'))$$, 'PT404', 'draft quotes are not published');
select tests.throws($$select public.public_get_quote(gen_random_uuid())$$, 'PT404', 'unknown token: not found');
select tests.throws($$select public.public_get_quote(null)$$, 'PT404', 'null token: not found');
create temp table got (doc jsonb);
grant all on got to anon, authenticated, service_role;
insert into got select public.public_get_quote(tests.fx('q_token'));
select tests.eq((select pg_temp.keys(doc) from got), 'customer,line_items,quote,shop,vehicle', 'quote document sections');
select tests.eq((select pg_temp.keys(doc -> 'quote') from got),
                'approved_at,approved_by_name,can_respond,declined_at,declined_reason,discount_cents,expired_at,expires_at,notes,number,'
                || 'sent_at,status,subtotal_cents,tax_cents,tax_rate_bps,terms,total_cents,valid_until,viewed_at',
                'quote keys (no internal notes, ids, tokens or creator)');
select tests.eq((select pg_temp.keys(doc -> 'shop') from got),
                'address_line1,address_line2,brand_color,city,country,currency,email,logo_path,name,phone,postal_code,region,review_url,slug,timezone,website',
                'shop branding keys only (no tax/SMS/Stripe settings)');
select tests.eq((select pg_temp.keys(doc -> 'customer') from got), 'company,first_name,last_name', 'customer: name only');
select tests.eq((select pg_temp.keys(doc -> 'vehicle') from got), 'color,make,model,trim,year', 'vehicle description only');
select tests.eq((select pg_temp.keys(doc -> 'line_items' -> 0) from got),
                'description,discount_cents,id,name,optional,quantity,selected,taxable,total_cents,unit_price_cents,vehicle_label',
                'line keys (id kept so optional lines can be chosen)');
-- the shop id appears only as the public logo's storage folder (<shop_id>/..., SPEC §4.6)
select tests.eq((select doc -> 'shop' ->> 'logo_path' from got), tests.fx('shop_a') || '/logo.png', 'logo object name');
select tests.ok((select d::text not like '%SECRET-INTERNAL-NOTE%' and d::text not like '%' || tests.fx('shop_a') || '%'
                        and d::text not like '%' || tests.fx('cust_a') || '%' and d::text not like '%' || tests.fx('q_token') || '%'
                        and d::text not like '%+12055550199%' and d::text not like '%acct_%'
                   from (select doc #- '{shop,logo_path}' as d from got) g),
                'no internal notes, shop/customer ids, token, SMS number or Stripe account in the document');
select tests.ok((select doc -> 'quote' ->> 'status' = 'viewed' and (doc -> 'quote' ->> 'can_respond')::boolean
                        and doc -> 'quote' ->> 'number' = '1001' and doc -> 'quote' ->> 'notes' = 'Includes hand wash'
                        and (doc -> 'quote' ->> 'total_cents')::bigint = 25000
                        and doc -> 'shop' ->> 'name' = 'Shop A' and doc -> 'shop' ->> 'brand_color' = '#112233'
                        and doc -> 'customer' ->> 'first_name' = 'Alice' and doc -> 'vehicle' ->> 'make' = 'Honda'
                        and jsonb_array_length(doc -> 'line_items') = 3
                        and doc -> 'line_items' -> 0 ->> 'vehicle_label' = '2021 Honda Civic'
                        and doc -> 'line_items' -> 1 ->> 'name' = 'Ceramic coating' from got),
                'content: first open by a visitor marks it viewed; totals count required + pre-selected lines (23000 + 10% on 20000)');
select tests.as_superuser();
select tests.ok((select status = 'viewed' and viewed_at = now() from public.quotes where id = tests.fx('q')), 'viewed stamped');
-- staff previews don't count as a view
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.public_get_quote(tests.fx('q2_token')) -> 'quote' ->> 'status', 'sent', 'a staff preview does not mark viewed');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(public.public_get_quote(tests.fx('q2_token')) -> 'quote' ->> 'status', 'viewed', 'a signed-in non-member counts as a view');

-- ------------------------------------------------------------ public_respond_quote: approve with optional lines
select tests.as_anon();
select tests.throws_like($$select public.public_respond_quote(tests.fx('q_token'), 'accept', 'Alice')$$, '22023', '%approve or decline%', 'bad action');
select tests.throws_like($$select public.public_respond_quote(tests.fx('q_token'), 'approve', '   ')$$, '22023', '%full name%', 'signer required');
select tests.throws($$select public.public_respond_quote(tests.fx('q_token'), 'approve', repeat('x', 201))$$, '22023', 'signer length');
select tests.throws_like($$select public.public_respond_quote(tests.fx('q_token'), 'approve', 'Alice', array[tests.fx('ql_req')])$$, '22023',
                         '%optional items of this quote%', 'required lines cannot be "selected"');
select tests.throws_like($$select public.public_respond_quote(tests.fx('q_token'), 'approve', 'Alice', array[tests.fx('qbl_opt')])$$, '22023',
                         '%optional items of this quote%', 'another quote''s (other shop''s) optional line is rejected');
select tests.throws($$select public.public_respond_quote(tests.fx('q_draft_token'), 'approve', 'Alice')$$, 'PT404', 'drafts cannot be answered');
select tests.throws($$select public.public_respond_quote(gen_random_uuid(), 'approve', 'Alice')$$, 'PT404', 'unknown token');
truncate got;
insert into got select public.public_respond_quote(tests.fx('q_token'), ' Approve ', '  Alice Anders ', array[tests.fx('ql_opt1'), tests.fx('ql_opt1'), null]);
select tests.ok((select doc -> 'quote' ->> 'status' = 'approved' and doc -> 'quote' ->> 'approved_by_name' = 'Alice Anders'
                        and not (doc -> 'quote' ->> 'can_respond')::boolean from got), 'approved by the typed signer');
-- chosen: required 20000 (tax) + ceramic 50000 (tax); pet hair (pre-selected by staff) was not chosen
select tests.eq((select (doc -> 'quote' ->> 'total_cents')::bigint from got), 77000::bigint, 'totals recomputed with the chosen optional lines');
select tests.eq((select string_agg((li ->> 'name') || ':' || (li ->> 'selected'), ',') from got, jsonb_array_elements(doc -> 'line_items') li),
                'Full Detail:true,Ceramic coating:true,Pet hair removal:false', 'selection is exactly what the client chose');
select tests.as_superuser();
select tests.ok((select status = 'approved' and approved_at = now() and approved_by_name = 'Alice Anders' and total_cents = 77000
                 from public.quotes where id = tests.fx('q')), 'stored quote approved with server-computed totals');
select tests.as_anon();
select tests.throws_like($$select public.public_respond_quote(tests.fx('q_token'), 'decline')$$, '22023', '%no longer be answered%',
                         'an approved quote cannot be declined');
select tests.throws($$select public.public_respond_quote(tests.fx('q_token'), 'approve', 'Alice')$$, '22023', 'nor approved twice');

-- ------------------------------------------------------------ decline
select tests.throws($$select public.public_respond_quote(tests.fx('q2_token'), 'decline', null, '{}', repeat('x', 1001))$$, '22023', 'reason length');
select tests.eq(public.public_respond_quote(tests.fx('q2_token'), 'decline', null, '{}', '  Found a cheaper option ') -> 'quote' ->> 'declined_reason',
                'Found a cheaper option', 'declined with a reason');
select tests.as_superuser();
select tests.ok((select status = 'declined' and declined_at = now() from public.quotes where id = tests.fx('q2')), 'declined stamped');

-- ------------------------------------------------------------ expiry on public access
update public.quotes set valid_until = '2020-01-01' where id = tests.fx('q3');
select tests.as_anon();
select tests.throws_like($$select public.public_respond_quote(tests.fx('q3_token'), 'approve', 'Aaron')$$, '22023', '%expired%',
                         'an out-of-date quote cannot be approved');
select tests.ok((select doc -> 'quote' ->> 'status' = 'expired' and not (doc -> 'quote' ->> 'can_respond')::boolean
                        and doc -> 'vehicle' = 'null'::jsonb
                 from (select public.public_get_quote(tests.fx('q3_token')) as doc) x), 'opening it marks it expired (no vehicle -> null)');
select tests.as_superuser();
select tests.ok((select status = 'expired' and expired_at = now() from public.quotes where id = tests.fx('q3')), 'expired stamped');

-- converted quotes stay viewable
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.convert_quote_to_job(tests.fx('q'));
select tests.as_anon();
select tests.eq(public.public_get_quote(tests.fx('q_token')) -> 'quote' ->> 'status', 'converted', 'converted quotes stay viewable');

-- ------------------------------------------------------------ public_get_invoice
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
update public.invoices set internal_notes = 'SECRET-INVOICE-NOTE', notes = 'Thank you!' where id = tests.fx('inv');
select tests.fx_set('inv_token', public.invoice_link_token(tests.fx('inv')));
select tests.fx_set('inv_draft', (public.create_invoice(tests.fx('cust_a3'), '[{"name":"Polish","unit_price_cents":1000}]')).id);
select tests.fx_set('inv_draft_token', public.invoice_link_token(tests.fx('inv_draft')));
select public.record_manual_payment(tests.fx('inv'), 5000, 'cash', 700, 'SECRET-PAYMENT-NOTE');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pub1', 'succeeded', 10000, 0, p_invoice_id => tests.fx('inv'),
                                    p_charge_id => 'ch_pub1', p_card_brand => 'visa', p_card_last4 => '4242', p_paid_at => '2025-06-02Z');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pub2', 'pending', 1000, 0, p_invoice_id => tests.fx('inv'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pub3', 'failed', 1000, 0, p_invoice_id => tests.fx('inv'));

select tests.as_anon();
select tests.throws($$select public.public_get_invoice(tests.fx('inv_draft_token'))$$, 'PT404', 'draft invoices are not published');
select tests.throws($$select public.public_get_invoice(gen_random_uuid())$$, 'PT404', 'unknown token');
truncate got;
insert into got select public.public_get_invoice(tests.fx('inv_token'));
select tests.eq((select pg_temp.keys(doc) from got), 'customer,invoice,job,line_items,payments,shop,vehicle', 'invoice document sections');
select tests.eq((select pg_temp.keys(doc -> 'invoice') from got),
                'amount_paid_cents,balance_cents,card_payments_enabled,discount_cents,due_at,issued_at,notes,number,paid_at,payable,'
                || 'status,subtotal_cents,tax_cents,tax_rate_bps,terms,tip_cents,total_cents,voided_at',
                'invoice keys (no internal notes, void reason, ids, tokens)');
select tests.eq((select pg_temp.keys(doc -> 'job') from got), 'number,scheduled_end,scheduled_start', 'job: number and time only');
select tests.eq((select pg_temp.keys(doc -> 'line_items' -> 0) from got),
                'description,discount_cents,name,quantity,taxable,total_cents,unit_price_cents,vehicle_label', 'invoice line keys');
select tests.eq((select pg_temp.keys(doc -> 'payments' -> 0) from got),
                'amount_cents,card_brand,card_last4,kind,method,paid_at,refunded_cents,status,tip_cents', 'payment keys (no Stripe ids, notes, staff)');
select tests.ok((select doc::text not like '%SECRET-%' and doc::text not like '%pi_pub%' and doc::text not like '%ch_pub%'
                        and doc::text not like '%' || tests.fx('u_manager_a') || '%' and doc::text not like '%' || tests.fx('inv_token') || '%'
                 from got), 'no internal notes, payment notes, Stripe ids, staff ids or token');
-- job_a: 20000 at 0% tax (fixture job); paid 5000 cash + 10000 card; pending/failed not listed
select tests.ok((select doc -> 'invoice' ->> 'status' = 'partially_paid' and (doc -> 'invoice' ->> 'total_cents')::bigint = 20000
                        and (doc -> 'invoice' ->> 'amount_paid_cents')::bigint = 15000 and (doc -> 'invoice' ->> 'balance_cents')::bigint = 5000
                        and (doc -> 'invoice' ->> 'tip_cents')::bigint = 700 and (doc -> 'invoice' ->> 'payable')::boolean
                        and (doc -> 'invoice' ->> 'card_payments_enabled')::boolean and doc -> 'invoice' ->> 'notes' = 'Thank you!'
                        and jsonb_array_length(doc -> 'payments') = 2 and doc -> 'payments' -> 0 ->> 'card_last4' = '4242' and doc -> 'payments' -> 1 ->> 'method' = 'cash'
                        and doc -> 'vehicle' ->> 'model' = 'Civic' and doc -> 'shop' ->> 'review_url' = 'https://g.page/shop-a'
                 from got), 'balance, tip, payability and received payments only');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_pub2', 'succeeded', 5000, 0, p_invoice_id => tests.fx('inv'));
select tests.as_anon();
select tests.ok((select doc -> 'invoice' ->> 'status' = 'paid' and not (doc -> 'invoice' ->> 'payable')::boolean
                        and doc -> 'invoice' ->> 'paid_at' is not null
                 from (select public.public_get_invoice(tests.fx('inv_token')) as doc) x), 'paid invoices are not payable');
-- void invoices are shown as void and not payable; ad-hoc invoices have no job/vehicle
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.mark_invoice_sent(tests.fx('inv_draft'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv_draft'), 'SECRET-VOID-REASON');
select tests.as_anon();
select tests.ok((select doc -> 'invoice' ->> 'status' = 'void' and not (doc -> 'invoice' ->> 'payable')::boolean
                        and doc -> 'invoice' ->> 'voided_at' is not null and doc::text not like '%SECRET-VOID%'
                        and doc -> 'job' = 'null'::jsonb and doc -> 'vehicle' = 'null'::jsonb
                 from (select public.public_get_invoice(tests.fx('inv_draft_token')) as doc) x), 'void invoices: shown, not payable, no reason');
-- a shop without a connected Stripe account cannot take card payments online
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('inv_b', (public.create_invoice_from_job(tests.fx('job_b'))).id);
select tests.fx_set('inv_b_token', public.invoice_link_token(tests.fx('inv_b')));
select tests.as_anon();
select tests.ok((select (doc -> 'invoice' ->> 'payable')::boolean and not (doc -> 'invoice' ->> 'card_payments_enabled')::boolean
                        and doc -> 'shop' ->> 'name' = 'Shop B'
                 from (select public.public_get_invoice(tests.fx('inv_b_token')) as doc) x), 'card_payments_enabled follows the Stripe account');
