-- 10 money: moving a quote, a job or an unsigned form to another customer
-- (a staff "wrong customer picked" correction) issues a new public_token, so
-- the /q, /booking and /f links already delivered to the first customer stop
-- resolving; a sent/viewed quote returns to draft until it is sent to the
-- new customer. Unchanged customers keep their links.
-- Checks of RPCs from later ranges (0023 forms, 0042 booking) run only when
-- those migrations are applied (scripts/test_db.sh --ranges).
\ir fixtures/two_shops.psql

select to_regprocedure('public.public_get_booking(uuid, timestamptz)') is not null as has_booking \gset
select to_regprocedure('public.public_get_form(uuid)') is not null as has_forms \gset

-- ============================================================ quotes
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, vehicle_id) values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'))
  returning tests.fx_set('q', id), tests.fx_set('q_tok_alice', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('q'), 'Ceramic coating', 90000);
select public.mark_quote_sent(tests.fx('q'));
select tests.eq((select public_token from public.quotes where id = tests.fx('q')), tests.fx('q_tok_alice'),
                'sending keeps the token');
update public.quotes set notes = 'Two-year coating' where id = tests.fx('q');
select tests.ok((select public_token = tests.fx('q_tok_alice') and status = 'sent' from public.quotes where id = tests.fx('q')),
                'other edits of a sent quote keep its link and status');

select tests.as_anon();
select tests.eq(public.public_get_quote(tests.fx('q_tok_alice')) #>> '{customer,first_name}', 'Alice', 'Alice opens her quote');
select tests.as_superuser();
select tests.eq((select status::text from public.quotes where id = tests.fx('q')), 'viewed', 'now viewed');

-- the repro: staff move the viewed quote to Aaron
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.quotes set customer_id = tests.fx('cust_a2'), vehicle_id = null, status = 'approved'
                           where id = tests.fx('q')$$, '23514', '%on its own%',
                         'a customer change cannot be combined with approving');
update public.quotes set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('q');
select tests.ok((select public_token <> tests.fx('q_tok_alice') and status = 'draft' and sent_at is null and viewed_at is null
                   from public.quotes where id = tests.fx('q')),
                'new token; back to draft with the sent/viewed stamps cleared');

select tests.as_anon();
select tests.throws($$select public.public_get_quote(tests.fx('q_tok_alice'))$$, 'P0002',
                    'the link already delivered to Alice no longer shows Aaron''s quote');
select tests.throws($$select public.public_respond_quote(tests.fx('q_tok_alice'), 'approve', 'Alice')$$, 'P0002',
                    'Alice cannot approve Aaron''s quote');
select tests.throws($$select public.public_respond_quote(tests.fx('q_tok_alice'), 'decline')$$, 'P0002',
                    'Alice cannot decline Aaron''s quote');
select tests.as_superuser();
select tests.eq((select status::text from public.quotes where id = tests.fx('q')), 'draft', 'nothing changed through the old link');

-- sent again, to Aaron
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('q_tok_aaron', (public.mark_quote_sent(tests.fx('q'))).public_token);
select tests.as_anon();
select tests.eq(public.public_get_quote(tests.fx('q_tok_aaron')) #>> '{customer,first_name}', 'Aaron', 'Aaron''s new link works');

-- a draft quote gets a new token too (it may have been previewed / shared)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))
  returning tests.fx_set('q_draft', id), tests.fx_set('q_draft_tok', public_token);
update public.quotes set customer_id = tests.fx('cust_a3') where id = tests.fx('q_draft');
select tests.ok((select public_token <> tests.fx('q_draft_tok') and status = 'draft' from public.quotes where id = tests.fx('q_draft')),
                'draft: new token, still draft');

-- the rules that already applied still hold
select tests.throws($$update public.quotes set public_token = gen_random_uuid() where id = tests.fx('q')$$, '42501',
                    'staff cannot choose a token');
select tests.throws($$update public.quotes set customer_id = tests.fx('cust_b') where id = tests.fx('q')$$, '23503',
                    'a quote cannot move to another shop''s customer');
select tests.eq((select public_token from public.quotes where id = tests.fx('q')), tests.fx('q_tok_aaron'), 'failed moves keep the link');
select tests.as_anon();
select tests.lives($$select public.public_respond_quote(tests.fx('q_tok_aaron'), 'approve', 'Aaron Other')$$, 'Aaron approves');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.quotes set customer_id = tests.fx('cust_a') where id = tests.fx('q')$$, '23514',
                         '%revise it back to draft%', 'an approved quote keeps its customer');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.quotes set customer_id = tests.fx('cust_b') where id = tests.fx('q')$$), 0::bigint,
                'shop B cannot touch A''s quote');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.quotes set customer_id = tests.fx('cust_a') where id = tests.fx('q')$$), 0::bigint,
                'technicians cannot touch quotes');
select tests.as_superuser();
select tests.eq((select public_token from public.quotes where id = tests.fx('q')), tests.fx('q_tok_aaron'),
                'denied writes change nothing');

-- ============================================================ jobs (/booking link)
select tests.fx_set('job_tok_alice', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set internal_notes = 'Call first', scheduled_end = '2025-06-02 17:30+00' where id = tests.fx('job_a');
select tests.eq((select public_token from public.jobs where id = tests.fx('job_a')), tests.fx('job_tok_alice'),
                'other job edits keep the booking link');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = null where id = tests.fx('job_a')$$, '42501',
                    'technicians cannot move a job to another customer');

-- the repro: the job moves to Aaron, now a mobile job at his address
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2'), location_type = 'mobile',
       service_address_line1 = '9 Aaron Way', service_city = 'Hoover' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.fx_set('job_tok_aaron', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.ok(tests.fx('job_tok_aaron') <> tests.fx('job_tok_alice'), 'the job got a new token');
select tests.eq((select count(*) from public.jobs where public_token = tests.fx('job_tok_alice')), 0::bigint,
                'the token delivered to Alice resolves to no job');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$update public.jobs set public_token = gen_random_uuid() where id = tests.fx('job_a')$$, '42501',
                    'staff still cannot choose a job token');
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_b'), vehicle_id = null where id = tests.fx('job_a')$$, '23503',
                    'a job cannot move to another shop''s customer');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.jobs set customer_id = tests.fx('cust_b') where id = tests.fx('job_a')$$), 0::bigint,
                'shop B cannot touch A''s job');
select tests.as_superuser();
select tests.eq((select public_token from public.jobs where id = tests.fx('job_a')), tests.fx('job_tok_aaron'),
                'failed or denied writes keep the new token');

\if :has_booking
select tests.as_anon();
select tests.throws($$select public.public_get_booking(tests.fx('job_tok_alice'))$$, 'P0002',
                    'the booking link already delivered to Alice no longer shows Aaron''s service address');
select tests.throws($$select public.public_cancel_booking(tests.fx('job_tok_alice'), 'not mine', '2025-05-01 12:00Z')$$, 'P0002',
                    'Alice cannot cancel Aaron''s booking');
select tests.eq(public.public_get_booking(tests.fx('job_tok_aaron'), '2025-05-01 12:00Z') #>> '{booking,service_address,address_line1}',
                '9 Aaron Way', 'Aaron''s new link shows his booking');
select tests.as_superuser();
select tests.eq((select status::text from public.jobs where id = tests.fx('job_a')), 'scheduled', 'the booking was not cancelled');
\endif

-- ============================================================ unsigned forms (/f link)
\if :has_forms
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body, attach_to)
  values (tests.fx('shop_a'), 'Service agreement', 'I authorize the work.', 'all_jobs');
insert into public.form_templates (shop_id, name, body, attach_to, requires_signature)
  values (tests.fx('shop_a'), 'Care instructions', 'Do not wash for 7 days.', 'all_jobs', false);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-07-01 15:00Z', '2025-07-01 17:00Z')
  returning tests.fx_set('job_f', id);
select tests.as_superuser();
select tests.fx_set('form_tok_unsigned', (select public_token from public.form_submissions
                                           where job_id = tests.fx('job_f') and title = 'Service agreement'));
select tests.fx_set('form_tok_signed', (select public_token from public.form_submissions
                                         where job_id = tests.fx('job_f') and title = 'Care instructions'));
select tests.as_anon();
select tests.lives($$select public.public_sign_form(tests.fx('form_tok_signed'), 'Alice Anders', null)$$, 'Alice signs one form');
select tests.eq(public.public_get_form(tests.fx('form_tok_unsigned')) #>> '{job,vehicle}', '2021 Honda Civic',
                'Alice''s unsigned form link shows her job');

select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_a2'), vehicle_id = tests.fx('veh_a2') where id = tests.fx('job_f');
select tests.as_superuser();
select tests.ok((select public_token <> tests.fx('form_tok_unsigned') and customer_id = tests.fx('cust_a2')
                   from public.form_submissions where job_id = tests.fx('job_f') and title = 'Service agreement'),
                'the unsigned form follows the new customer under a new token');
select tests.ok((select public_token = tests.fx('form_tok_signed') and customer_id = tests.fx('cust_a')
                   from public.form_submissions where job_id = tests.fx('job_f') and title = 'Care instructions'),
                'the signed form stays Alice''s record, link unchanged');
select tests.as_anon();
select tests.throws($$select public.public_get_form(tests.fx('form_tok_unsigned'))$$, 'P0002',
                    'the form link already delivered to Alice no longer shows Aaron''s job');
select tests.throws($$select public.public_sign_form(tests.fx('form_tok_unsigned'), 'Alice Anders', null)$$, 'P0002',
                    'Alice cannot sign Aaron''s form');
\endif
