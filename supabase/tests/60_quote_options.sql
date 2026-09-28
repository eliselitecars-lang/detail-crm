-- 60 money: proposal options on quotes (P-15, 0067) — option totals, what
-- the quote counts (selection, else the first option), the 4-option limit,
-- option / line / selection integrity, edit rules, the public document,
-- approving with an option (public_respond_quote v2), conversion copying
-- the chosen option only, staff responses, RLS and isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 1000 where id = tests.fx('shop_a');

create function pg_temp.qt(p_id uuid) returns text language sql as $$
  select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.quotes where id = p_id
$$;
create function pg_temp.ot(p_id uuid) returns text language sql as $$
  select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.quote_options where id = p_id
$$;
grant execute on function pg_temp.qt(uuid), pg_temp.ot(uuid) to authenticated;

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, discount_kind, discount_value)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'percent', 1000) returning tests.fx_set('q', id);
insert into public.quote_options (shop_id, quote_id, name, description, sort) values
  (tests.fx('shop_a'), tests.fx('q'), ' Good ', 'Sealant', 1) returning tests.fx_set('o_good', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values
  (tests.fx('shop_a'), tests.fx('q'), 'Better', 2) returning tests.fx_set('o_better', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values
  (tests.fx('shop_a'), tests.fx('q'), 'Best', 3) returning tests.fx_set('o_best', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, optional, sort) values
  (tests.fx('shop_a'), tests.fx('q'), null, 'Prep wash', 5000, false, 1),
  (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_good'), 'Sealant', 10000, false, 2),
  (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_better'), 'Ceramic 1 year', 30000, false, 3),
  (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_better'), 'Wheels', 5000, true, 4),
  (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_best'), 'Ceramic 5 years', 60000, false, 5);
select tests.eq((select name from public.quote_options where id = tests.fx('o_good')), 'Good', 'option names are trimmed');

-- ============================================================ totals
select tests.eq(pg_temp.ot(tests.fx('o_good')), '15000/1500/1350/14850', 'Good = shared + its line, 10% off, 10% tax');
select tests.eq(pg_temp.ot(tests.fx('o_better')), '35000/3500/3150/34650', 'Better: its optional line counts only when selected');
select tests.eq(pg_temp.ot(tests.fx('o_best')), '65000/6500/5850/64350', 'Best');
select tests.eq(pg_temp.qt(tests.fx('q')), '15000/1500/1350/14850', 'no selection yet: the quote counts its first option');
update public.quote_options set sort = 0 where id = tests.fx('o_best');
select tests.eq(pg_temp.qt(tests.fx('q')), '65000/6500/5850/64350', 'reordering changes the first option');
update public.quote_options set sort = 3 where id = tests.fx('o_best');
update public.quotes set selected_option_id = tests.fx('o_better') where id = tests.fx('q');
select tests.eq(pg_temp.qt(tests.fx('q')), '35000/3500/3150/34650', 'staff may preselect an option on a draft');
update public.quote_line_items set unit_price_cents = 6000 where quote_id = tests.fx('q') and name = 'Prep wash';
select tests.eq(pg_temp.ot(tests.fx('o_good')) || ' ' || pg_temp.ot(tests.fx('o_best')), '16000/1600/1440/15840 66000/6600/5940/65340',
                'a shared line change refreshes every option');
update public.quote_options set total_cents = 1, subtotal_cents = 1 where id = tests.fx('o_good');
select tests.eq(pg_temp.ot(tests.fx('o_good')), '16000/1600/1440/15840', 'option totals are server-maintained');
update public.quotes set discount_kind = 'none', discount_value = 0 where id = tests.fx('q');
select tests.eq(pg_temp.ot(tests.fx('o_better')), '36000/0/3600/39600', 'the quote''s discount applies to every option');
update public.quotes set discount_kind = 'percent', discount_value = 1000 where id = tests.fx('q');

-- ============================================================ integrity and limits
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q'), 'Premium', 4)
  returning tests.fx_set('o_prem', id);
select tests.throws_like($$insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q'), 'Fifth')$$,
                         '23514', '%at most 4 options%', 'at most 4 options per quote');
delete from public.quote_options where id = tests.fx('o_prem');
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q2', id);
insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q2'), 'Other') returning tests.fx_set('o_q2', id);
select tests.throws_like($$insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents)
                           values (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_q2'), 'X', 1)$$, '23514', '%another quote%',
                         'a line''s option belongs to its quote');
select tests.throws_like($$update public.quotes set selected_option_id = tests.fx('o_q2') where id = tests.fx('q')$$, '23514',
                         '%another quote%', 'a quote selects one of its own options');
select tests.throws($$update public.quote_options set quote_id = tests.fx('q2') where id = tests.fx('o_good')$$, '42501',
                    'options never move between quotes');
select tests.throws($$insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q'), '  ')$$, '23514',
                    'an option needs a name');
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_b'), tests.fx('cust_b')) returning tests.fx_set('qb', id);
insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_b'), tests.fx('qb'), 'B') returning tests.fx_set('o_b', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents)
                      values (tests.fx('shop_a'), tests.fx('q'), tests.fx('o_b'), 'X', 1)$$, '23503', 'composite FK: another shop''s option');
select tests.throws($$update public.quotes set selected_option_id = tests.fx('o_b') where id = tests.fx('q')$$, '23503',
                    'composite FK: another shop''s option cannot be selected');

-- ============================================================ sent: the customer chooses
select public.mark_quote_sent(tests.fx('q'));
update public.quotes set selected_option_id = tests.fx('o_best') where id = tests.fx('q');
select tests.eq((select selected_option_id from public.quotes where id = tests.fx('q')), tests.fx('o_better'),
                'once sent, staff cannot change the selection (the customer''s choice)');
select tests.lives($$update public.quote_options set description = 'Sealant, 6 months' where id = tests.fx('o_good')$$,
                   'options stay editable while sent / viewed (like lines)');
select public_token as qtok from public.quotes where id = tests.fx('q') \gset
select tests.as_anon();
select public.public_get_quote(:'qtok') as doc \gset
select tests.eq((select jsonb_build_array(d -> 'quote' -> 'has_options', d -> 'quote' ->> 'selected_option_id', jsonb_array_length(d -> 'options'))
                   from (select :'doc'::jsonb as d) x),
                jsonb_build_array(true, tests.fx('o_better'), 3), 'the /q page shows the options and the current choice');
select tests.eq((:'doc'::jsonb -> 'options' -> 0) - 'id',
                '{"name": "Good", "description": "Sealant, 6 months", "sort": 1, "subtotal_cents": 16000, "discount_cents": 1600, "tax_cents": 1440, "total_cents": 15840}'::jsonb,
                'option totals on the page');
select tests.eq((select count(*) from jsonb_array_elements(:'doc'::jsonb -> 'line_items') l where l ->> 'option_id' = tests.fx('o_better')::text),
                2::bigint, 'lines name their option');
select tests.throws_like($$select public.public_respond_quote($$ || quote_literal(:'qtok') || $$, 'approve', 'Alice Anders')$$, '22023',
                         '%choose one of the quote''s options%', 'approving needs an option');
select tests.throws_like($$select public.public_respond_quote($$ || quote_literal(:'qtok') || $$, 'approve', 'Alice Anders', '{}', null, $$
                           || quote_literal(tests.fx('o_q2')) || $$)$$, '22023', '%choose one of the quote''s options%',
                         'another quote''s option is refused');
select tests.as_superuser();
select id as wheels from public.quote_line_items where quote_id = tests.fx('q') and name = 'Wheels' \gset
select tests.as_anon();
select tests.throws_like($$select public.public_respond_quote($$ || quote_literal(:'qtok') || $$, 'approve', 'Alice Anders', array[$$
                           || quote_literal(:'wheels') || $$::uuid], null, $$ || quote_literal(tests.fx('o_best')) || $$)$$,
                         '22023', '%and of the chosen option%', 'optional lines of another option cannot be picked');
select public.public_respond_quote(:'qtok', 'approve', 'Alice Anders', array[:'wheels'::uuid], null, tests.fx('o_better')) as approved \gset
select tests.eq((select jsonb_build_array(d -> 'quote' ->> 'status', d -> 'quote' ->> 'selected_option_id', d -> 'quote' -> 'total_cents')
                   from (select :'approved'::jsonb as d) x),
                jsonb_build_array('approved', tests.fx('o_better'), 40590),
                'approved with Better + Wheels: 41000 - 4100 + 3690 tax = 40590');
select tests.as_superuser();
select tests.eq(pg_temp.ot(tests.fx('o_better')), '41000/4100/3690/40590', 'the chosen option''s totals include the picked optional line');
select tests.ok((select total_cents = 40590 and selected_option_id = tests.fx('o_better') from public.quotes where id = tests.fx('q')),
                'the quote counts the chosen option');

-- ============================================================ approved: frozen until revised
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.quote_options set name = 'Better+' where id = tests.fx('o_better')$$, '23514',
                         '%options of a approved quote%', 'options of an approved quote are frozen');
select tests.throws($$insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q'), 'Late')$$, '23514',
                    'no new options either');
select tests.throws($$delete from public.quote_options where id = tests.fx('o_best')$$, '23514', 'nor deletions');

-- ============================================================ conversion copies the chosen option
select tests.fx_set('job_q', (public.convert_quote_to_job(tests.fx('q'))).id);
select tests.eq((select array_agg(name || ':' || unit_price_cents order by sort) from public.job_line_items where job_id = tests.fx('job_q')),
                array['Prep wash:6000', 'Ceramic 1 year:30000', 'Wheels:5000'], 'shared lines + the chosen option (with its picked optional line)');
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_q')), 40590::bigint, 'the job total equals the approved quote');

-- ============================================================ staff-recorded responses and revising
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q3', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q3'), 'A', 1) returning tests.fx_set('o3a', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q3'), 'B', 2) returning tests.fx_set('o3b', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents) values
  (tests.fx('shop_a'), tests.fx('q3'), tests.fx('o3a'), 'A work', 1000),
  (tests.fx('shop_a'), tests.fx('q3'), tests.fx('o3b'), 'B work', 2000);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, optional, selected)
  values (tests.fx('shop_a'), tests.fx('q3'), tests.fx('o3a'), 'A extra', 300, true, false) returning tests.fx_set('l3a_opt', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, optional, selected)
  values (tests.fx('shop_a'), tests.fx('q3'), tests.fx('o3b'), 'B extra', 500, true, true) returning tests.fx_set('l3b_opt', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, optional, selected)
  values (tests.fx('shop_a'), tests.fx('q3'), null, 'Shared extra', 100, true, true) returning tests.fx_set('l3s_opt', id);
update public.quotes set selected_option_id = tests.fx('o3b') where id = tests.fx('q3');
select public.mark_quote_sent(tests.fx('q3'));
-- the customer chose A on the phone: staff cannot set the option on a sent quote directly...
update public.quotes set selected_option_id = tests.fx('o3a') where id = tests.fx('q3');
select tests.eq((select selected_option_id from public.quotes where id = tests.fx('q3')), tests.fx('o3b'),
                'staff writes to selected_option_id of a sent quote are ignored');
-- ...so the staff-recorded response names it, under the customer's rules
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q3'), 'approve', null, 'Alice on the phone')$$,
                         '22023', '%option%', 'approving a quote with options must name the option the customer chose');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q3'), 'approve', array[tests.fx('l3a_opt')], 'Alice')$$,
                         '22023', '%option%', 'also when optional lines are given');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q3'), 'approve', null, 'Alice',
                                                                        p_option_id => tests.fx('o_best'))$$,
                         '22023', '%option%', 'another quote''s option is refused');
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q3'), 'approve', array[tests.fx('l3b_opt')], 'Alice',
                                                                        p_option_id => tests.fx('o3a'))$$,
                         '22023', '%optional items of this quote (and of the chosen option)%',
                         'an optional line of another option cannot be selected with the chosen option');
select tests.eq((select concat_ws('/', status, selected_option_id = tests.fx('o3b')) from public.quotes where id = tests.fx('q3')),
                'sent/t', 'refused calls change nothing');
select tests.eq((public.staff_record_quote_response(tests.fx('q3'), 'approve', array[tests.fx('l3a_opt'), tests.fx('l3s_opt')],
                                                    'Alice on the phone', p_option_id => tests.fx('o3a'))).total_cents,
                1540::bigint, 'the chosen option A with its extra and the shared extra: (1000 + 300 + 100) + 10% tax');
select tests.eq((select concat_ws('/', status, selected_option_id = tests.fx('o3a'), approved_by_name) from public.quotes where id = tests.fx('q3')),
                'approved/t/Alice on the phone', 'the choice is recorded as the quote''s option');
select tests.eq((select string_agg(name || ':' || selected, ',' order by name) from public.quote_line_items
                 where quote_id = tests.fx('q3') and optional),
                'A extra:true,B extra:false,Shared extra:true', 'exactly the chosen optional lines are selected');
update public.quotes set status = 'draft' where id = tests.fx('q3');
select tests.lives($$update public.quote_options set name = 'B (revised)' where id = tests.fx('o3b')$$, 'revised to draft: editable again');
delete from public.quote_options where id = tests.fx('o3a');
select tests.eq((select concat_ws('/', coalesce(selected_option_id::text, 'none'), total_cents) from public.quotes where id = tests.fx('q3')),
                'none/2310', 'deleting the selected option (and its lines) falls back to the first option (B 2000 + shared extra 100 + tax)');
-- null optional ids keep the current selections of the counted lines only
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q6', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q6'), 'X', 1) returning tests.fx_set('o6x', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q6'), 'Y', 2) returning tests.fx_set('o6y', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, optional, selected) values
  (tests.fx('shop_a'), tests.fx('q6'), tests.fx('o6x'), 'X work', 1000, false, true),
  (tests.fx('shop_a'), tests.fx('q6'), tests.fx('o6x'), 'X extra', 400, true, true),
  (tests.fx('shop_a'), tests.fx('q6'), tests.fx('o6y'), 'Y work', 3000, false, true),
  (tests.fx('shop_a'), tests.fx('q6'), null, 'Shared extra', 100, true, true);
select public.mark_quote_sent(tests.fx('q6'));
select tests.eq((public.staff_record_quote_response(tests.fx('q6'), 'approve', p_option_id => tests.fx('o6y'))).total_cents,
                3410::bigint, 'option Y with the kept shared extra: (3000 + 100) + 10% tax');
select tests.eq((select string_agg(name || ':' || selected, ',' order by name) from public.quote_line_items
                 where quote_id = tests.fx('q6') and optional),
                'Shared extra:true,X extra:false', 'the other option''s selected extra no longer reads as chosen');
select tests.fx_set('job_q6', (public.convert_quote_to_job(tests.fx('q6'))).id);
select tests.eq((select array_agg(name order by name) from public.job_line_items where job_id = tests.fx('job_q6')),
                array['Shared extra', 'Y work'], 'the conversion bills the recorded option');
select tests.eq((select total_cents from public.jobs where id = tests.fx('job_q6')), 3410::bigint, 'at the approved total');
-- declining needs no option; an option given with a decline is ignored
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q7', id);
insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q7'), 'Only') returning tests.fx_set('o7', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q7'), tests.fx('o7'), 'Z', 100);
select public.mark_quote_sent(tests.fx('q7'));
select tests.eq((public.staff_record_quote_response(tests.fx('q7'), 'decline', p_declined_reason => 'too pricey')).status::text,
                'declined', 'a decline needs no option');
-- a quote without options takes no option on the staff path either
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q8', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q8'), 'Wash', 3000);
select public.mark_quote_sent(tests.fx('q8'));
select tests.throws_like($$select public.staff_record_quote_response(tests.fx('q8'), 'approve', p_option_id => tests.fx('o7'))$$,
                         '22023', '%no options%', 'staff: a quote without options takes no option');
select tests.eq((public.staff_record_quote_response(tests.fx('q8'), 'approve')).status::text, 'approved',
                'and approves as before');
-- a quote without options: no option may be given
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q4', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q4'), 'Wash', 3000);
select public.mark_quote_sent(tests.fx('q4'));
select tests.as_superuser();
select public_token as q4tok from public.quotes where id = tests.fx('q4') \gset
select tests.as_anon();
select tests.throws_like($$select public.public_respond_quote($$ || quote_literal(:'q4tok') || $$, 'approve', 'Al', '{}', null, $$
                           || quote_literal(tests.fx('o3a')) || $$)$$, '22023', '%no options%', 'a quote without options takes no option');
select tests.eq(public.public_respond_quote(:'q4tok', 'approve', 'Al') -> 'quote' ->> 'status', 'approved',
                'and approves as before (named-argument callers unaffected)');
select tests.eq(public.public_get_quote(:'q4tok') -> 'quote' -> 'has_options', 'false'::jsonb, 'has_options false');

-- ============================================================ RLS and privileges
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.quote_options), 0::bigint, 'technicians see no options');
select tests.throws($$insert into public.quote_options (shop_id, quote_id, name) values (tests.fx('shop_a'), tests.fx('q2'), 'T')$$, '42501',
                    'nor write them');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.quote_options where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops see nothing');
select tests.eq(tests.row_count($$delete from public.quote_options where id = tests.fx('o_q2')$$), 0::bigint, 'nor delete');
select tests.as_superuser();
select tests.eq((select count(*) from pg_proc where proname = 'public_respond_quote'), 1::bigint, 'public_respond_quote: one signature');
select tests.ok(has_function_privilege('anon', 'public.public_respond_quote(uuid, text, text, uuid[], text, uuid)', 'execute'),
                'anon may respond to quotes');
select tests.ok(not has_function_privilege('authenticated', 'public.convert_quote_to_job_core(uuid, timestamptz, timestamptz, public.job_status, jsonb)', 'execute')
                and not has_function_privilege('anon', 'public.convert_quote_to_job_core(uuid, timestamptz, timestamptz, public.job_status, jsonb)', 'execute'),
                'the conversion core is internal');
