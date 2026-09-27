-- 90 integration: staff_record_quote_response — staff record a customer's
-- approval (with the optional lines they chose) or decline in one atomic
-- call: status rules shared with public_respond_quote, validity, optional
-- line validation, role matrix and cross-shop isolation.
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('q'), 'Coating', 100000, false);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable, optional)
  values (tests.fx('shop_a'), tests.fx('q'), 'Wheels', 20000, false, true) returning tests.fx_set('opt1', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable, optional, selected)
  values (tests.fx('shop_a'), tests.fx('q'), 'Glass', 10000, false, true, true) returning tests.fx_set('opt2', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('q'), 'Prep', 5000, false) returning tests.fx_set('req', id);
select tests.eq((select total_cents from public.quotes where id = tests.fx('q')), 115000::bigint,
                'total: required lines + the pre-selected option');
-- another quote of the shop, and one of shop B
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_other', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, optional)
  values (tests.fx('shop_a'), tests.fx('q_other'), 'Other option', 999, true) returning tests.fx_set('other_opt', id);
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b')) returning tests.fx_set('q_b', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_b'), tests.fx('q_b'), 'Wash', 5000);
select public.mark_quote_sent(tests.fx('q_b'));

-- ------------------------------------------------------------ only sent / viewed quotes
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'approve')$$, '22023',
                         'this quote can no longer be answered (it is draft)', 'a draft cannot be answered');
select public.mark_quote_sent(tests.fx('q'));
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'accept')$$, '22023', '%approve or decline%',
                         'unknown action');
select tests.throws($$select public.staff_record_quote_response(tests.fx('q'), null)$$, '22023', 'null action');

-- ------------------------------------------------------------ optional lines are validated
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'approve', array[tests.fx('req')])$$, '22023',
                         '%optional items of this quote%', 'a required line is not an option');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'approve', array[tests.fx('other_opt')])$$, '22023',
                         '%optional items of this quote%', 'another quote''s option');
select tests.throws($$select public.staff_record_quote_response(tests.fx('q'), 'approve', array[gen_random_uuid()])$$, '22023',
                    'an unknown line');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'approve', null, repeat('n', 201))$$, '22023',
                         '%too long%', 'approver name length');
select tests.eq((select concat_ws('/', q.status, (select string_agg(li.name || '=' || li.selected, ',' order by li.name)
                                                   from public.quote_line_items li where li.quote_id = q.id and li.optional))
                   from public.quotes q where q.id = tests.fx('q')), 'sent/Glass=true,Wheels=false',
                'refused calls changed nothing (all in one transaction)');

-- ------------------------------------------------------------ approve with the chosen options
select tests.eq((select concat_ws('/', status, approved_by_name, approved_at is not null, total_cents)
                   from public.staff_record_quote_response(tests.fx('q'), 'approve', array[tests.fx('opt1'), tests.fx('opt1')],
                                                           '  Alice Anders (phone)  ')),
                'approved/Alice Anders (phone)/t/125000',
                'approved: the returned quote carries the status, trimmed name and the recomputed total');
select tests.eq((select string_agg(name || '=' || selected, ',' order by name) from public.quote_line_items
                  where quote_id = tests.fx('q') and optional), 'Glass=false,Wheels=true', 'exactly the chosen options are selected');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q'), 'decline')$$, '22023', '%(it is approved)%',
                         'an approved quote cannot be answered again');

-- null keeps the current selections; a blank name is stored as null
select public.mark_quote_sent(tests.fx('q_other'));
select tests.eq((select concat_ws('/', status, coalesce(approved_by_name, '-'))
                   from public.staff_record_quote_response(tests.fx('q_other'), 'APPROVE', null, '   ')), 'approved/-',
                'actions are case-insensitive; a blank name is null');
select tests.eq((select selected from public.quote_line_items where id = tests.fx('other_opt')), false, 'null keeps the selections');

-- ------------------------------------------------------------ decline, viewed, expired
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_d', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_d'), 'Tint', 30000);
select public.mark_quote_sent(tests.fx('q_d'));
select tests.as_superuser();
update public.quotes set status = 'viewed' where id = tests.fx('q_d');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q_d'), 'decline', null, null, repeat('r', 1001))$$,
                         '22023', '%too long%', 'reason length');
select tests.eq((select concat_ws('/', status, declined_reason, declined_at is not null)
                   from public.staff_record_quote_response(tests.fx('q_d'), 'decline', null, null, ' Went elsewhere ')),
                'declined/Went elsewhere/t', 'a viewed quote is declined with the trimmed reason');
insert into public.quotes (shop_id, customer_id, valid_until) values (tests.fx('shop_a'), tests.fx('cust_a'), '2030-01-01')
  returning tests.fx_set('q_x', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_x'), 'Tint', 30000);
select public.mark_quote_sent(tests.fx('q_x'));
select tests.as_superuser();
update public.quotes set valid_until = (now() at time zone 'America/Chicago')::date - 1 where id = tests.fx('q_x');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q_x'), 'approve')$$, '22023', 'this quote has expired',
                         'an expired quote cannot be approved');

-- the recorder is not notified about their own action; the others are
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'quote_approved' and quote_id = tests.fx('q')), 2::bigint,
                'owner and admin are notified, not the manager who recorded it');

-- ------------------------------------------------------------ roles and isolation
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.staff_record_quote_response(tests.fx('q_b'), 'approve')$$, 'P0002', 'technician: other shop not found');
select tests.as_superuser();
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_t', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_t'), 'Tint', 30000);
update public.quotes set status = 'sent', sent_at = now() where id = tests.fx('q_t');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.staff_record_quote_response(tests.fx('q_t'), 'approve')$$, '42501', 'technicians cannot record responses');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.staff_record_quote_response(tests.fx('q_t'), 'approve')$$, 'P0002', 'another shop''s quote is not found');
select tests.throws($$select public.staff_record_quote_response(gen_random_uuid(), 'approve')$$, 'P0002', 'unknown quote');
select tests.eq((select status::text from public.staff_record_quote_response(tests.fx('q_b'), 'approve')), 'approved',
                'shop B approves its own quote');
select tests.as_anon();
select tests.throws($$select public.staff_record_quote_response(tests.fx('q_t'), 'approve')$$, '42501', 'anon cannot execute');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select status::text from public.staff_record_quote_response(tests.fx('q_t'), 'decline')), 'declined', 'owners may');
select tests.as_superuser();
select tests.eq((select status::text from public.quotes where id = tests.fx('q_t')), 'declined', 'the denied calls changed nothing first');
