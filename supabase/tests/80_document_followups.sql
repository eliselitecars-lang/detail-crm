-- 80 comms: document follow-ups (P-3, 0081/0083/0085) — quotes, deposits,
-- invoice reminders and overdue notices: due exactly once per attempt,
-- first / repeat spacing, max attempts, only the latest due attempt sent,
-- 24 h staleness, settings / template / pause switches, both channels,
-- suppressed addresses, variables (links, amounts, due dates, days overdue
-- across DST), withdrawal once the document is resolved, the status / pause
-- RPCs (roles), followup_settings RLS and cross-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100', invoice_due_days = 30 where id = tests.fx('shop_a');
-- follow-ups fall due only in waking hours (08:00-21:00 shop time, 0085):
-- shop A runs on a fixed-offset zone where it is about noon now, so the hour
-- offsets below land inside that window whatever time the suite runs
select case when o >= 0 then 'Etc/GMT-' || o else 'Etc/GMT+' || -o end as tz
  from (select 12 - extract(hour from now() at time zone 'UTC')::integer as o) x \gset
update public.shops set timezone = :'tz' where id = tests.fx('shop_a');
-- the rest of the queue is not this file's business
update public.messages set status = 'cancelled' where status = 'queued';

-- customers with both channels
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Quinn', 'quinn@example.com', '+12055550111') returning tests.fx_set('cust_q', id);
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Rae', 'rae@example.com', '+12055550112') returning tests.fx_set('cust_r', id);
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Dee', 'dee@example.com', '+12055550113') returning tests.fx_set('cust_d', id);
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_a'), 'Ivy', 'ivy@example.com', '+12055550114') returning tests.fx_set('cust_i', id);
insert into public.customers (shop_id, first_name, email, phone)
  values (tests.fx('shop_b'), 'Bea', 'bea@example.com', '+12055550115') returning tests.fx_set('cust_bb', id);

-- ============================================================ settings (RLS)
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.followup_settings$$), 0::bigint, 'technicians do not read follow-up settings');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.followup_settings$$), 1::bigint, 'managers read their shop''s settings');
select tests.eq(tests.row_count($$update public.followup_settings set quote_enabled = true$$), 0::bigint, 'managers cannot change them');
select tests.ok((select not quote_enabled and not deposit_enabled and not invoice_enabled and not overdue_enabled
                        and quote_first_after_hours = 48 and quote_repeat_every_hours = 72 and quote_max_attempts = 2
                   from public.followup_settings), 'seeded off with the default schedule');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.followup_settings
                                     set quote_enabled = true, deposit_enabled = true, invoice_enabled = true, overdue_enabled = true
                                   where shop_id = tests.fx('shop_a')$$), 1::bigint, 'admins turn follow-ups on');
select tests.eq(tests.row_count($$update public.followup_settings set quote_enabled = true where shop_id = tests.fx('shop_b')$$),
                0::bigint, 'not another shop''s');
select tests.throws($$update public.followup_settings set quote_max_attempts = 11$$, '23514', 'at most 10 attempts');
select tests.throws($$update public.followup_settings set overdue_repeat_every_days = 0$$, '23514', 'repeat at least 1');
select tests.throws($$insert into public.followup_settings (shop_id) values (tests.fx('shop_a'))$$, '42501', 'rows are seeded, not inserted');
select tests.throws($$delete from public.followup_settings$$, '42501', 'nor deleted');
-- the follow-up templates are seeded off: switch them on (both channels)
select tests.eq(tests.row_count($$update public.message_templates set enabled = true
                                   where shop_id = tests.fx('shop_a')
                                     and key in ('quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue')$$),
                8::bigint, 'sms + email wording for the four keys');
select tests.as_superuser();
update public.message_templates set enabled = true
 where shop_id = tests.fx('shop_b') and key in ('quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue');

-- ============================================================ quotes
create function pg_temp.quote_for(p_customer uuid, p_shop uuid default null) returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_shop uuid := coalesce(p_shop, tests.fx('shop_a'));
begin
  insert into public.quotes (shop_id, customer_id, valid_until) values (v_shop, p_customer, current_date + 30) returning id into v_id;
  insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (v_shop, v_id, 'Ceramic coating', 120000);
  return v_id;
end $$;
create function pg_temp.n_msgs(p_quote uuid, p_invoice uuid default null, p_job uuid default null, p_key text default null)
returns bigint language sql as $$
  select count(*) from public.messages m
   where (p_quote is null or m.quote_id = p_quote) and (p_invoice is null or m.invoice_id = p_invoice)
     and (p_job is null or m.job_id = p_job) and (p_key is null or m.template_key::text = p_key)
     and m.status = 'queued'
$$;

select tests.fx_set('q1', pg_temp.quote_for(tests.fx('cust_q')));
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.mark_quote_sent(tests.fx('q1'));
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '47 hours'), 0, 'not due before first_after');
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 2, 'attempt 1: both channels');
select tests.eq(public.enqueue_document_followups(now() + interval '49 hours'), 0, 'exactly once');
select tests.eq((select array_agg(channel::text order by channel) from public.messages where quote_id = tests.fx('q1')),
                array['sms', 'email'], 'sms and email');
select tests.ok((select bool_and(template_key = 'quote_reminder' and customer_id = tests.fx('cust_q') and job_id is null
                                 and send_after = now() + interval '48 hours')
                   from public.messages where quote_id = tests.fx('q1')), 'linked to the quote, sent at the due time');
select tests.ok((select body like '%Quote #' || q.number || E'\nTotal: $1,200.00\nValid until: %'
                        and body like '%https://app.example.test/q/' || q.public_token || '%'
                   from public.messages m join public.quotes q on q.id = m.quote_id
                  where m.quote_id = tests.fx('q1') and m.channel = 'email'), 'email: number, total, validity, link');
select tests.eq((select array[attempt::text, outcome, cardinality(message_ids)::text] from public.document_followup_log
                  where doc_kind = 'quote' and doc_id = tests.fx('q1')), array['1', 'queued', '2'], 'attempt logged');
select tests.eq(public.enqueue_document_followups(now() + interval '119 hours'), 0, 'repeat spacing: not before 48 + 72 h');
select tests.eq(public.enqueue_document_followups(now() + interval '120 hours'), 2, 'attempt 2 after 72 more hours');
select tests.eq(public.enqueue_document_followups(now() + interval '408 hours'), 0, 'max attempts (2) honoured');
select tests.eq(pg_temp.n_msgs(tests.fx('q1')), 4::bigint, 'four messages in all');

-- the status / pause RPCs
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_build_array(r -> 'kind', r -> 'stage', r -> 'enabled', r -> 'paused', r -> 'attempts_sent',
                                          r -> 'max_attempts', r -> 'next_at', (r ->> 'last_sent_at')::timestamptz = now() + interval '120 hours')
                   from (select public.document_followup_status('quote', tests.fx('q1')) as r) x),
                '["quote", "quote", true, false, 2, 2, null, true]'::jsonb, 'status: both attempts sent, none left');
select tests.as_superuser();
select tests.eq((select (public.document_followup_status('quote', tests.fx('q1'))) -> 'attempts_sent'), '2'::jsonb,
                'attempts sent = attempts that queued a message');
select tests.eq((select (public.document_followup_status('quote', tests.fx('q1'))) -> 'next_at'), 'null'::jsonb,
                'no attempts left: no next time');
select tests.fx_set('q2', pg_temp.quote_for(tests.fx('cust_r')));
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.mark_quote_sent(tests.fx('q2'));
select tests.ok((select (r ->> 'next_at')::timestamptz = now() + interval '48 hours' and (r -> 'enabled')::boolean
                   from (select public.document_followup_status('quote', tests.fx('q2')) as r) x), 'next attempt time');
select tests.eq((select r -> 'paused' from (select public.set_document_followups_paused('quote', tests.fx('q2'), true) as r) x),
                'true'::jsonb, 'paused');
select tests.eq((select r -> 'next_at' from (select public.document_followup_status('quote', tests.fx('q2')) as r) x),
                'null'::jsonb, 'a paused quote has no next attempt');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 0, 'paused: nothing sent');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_document_followups_paused('quote', tests.fx('q2'), false);
select tests.throws($$select public.set_document_followups_paused('quote', tests.fx('q2'), null)$$, '22023', 'paused must be given');
select tests.throws($$select public.document_followup_status('estimate', tests.fx('q2'))$$, '22023', 'unknown kind');
select tests.throws($$select public.document_followup_status('quote', gen_random_uuid())$$, 'P0002', 'unknown quote');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.document_followup_status('quote', tests.fx('q2'))$$, '42501', 'technicians: no status');
select tests.throws($$select public.set_document_followups_paused('quote', tests.fx('q2'), true)$$, '42501', 'technicians: no pause');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.document_followup_status('quote', tests.fx('q2'))$$, 'P0002', 'another shop''s quote: not found');
select tests.throws($$select public.set_document_followups_paused('deposit', tests.fx('job_a'), true)$$, 'P0002',
                    'another shop''s job: not found');
select tests.as_anon();
select tests.throws($$select public.document_followup_status('quote', tests.fx('q2'))$$, '42501', 'anon: no access');

-- only the latest due attempt is sent; stale attempts are skipped
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '121 hours'), 2,
                'both attempts due at once: only one message per channel');
select tests.eq((select array_agg(attempt::text || ':' || outcome order by attempt) from public.document_followup_log
                  where doc_id = tests.fx('q2')), array['1:skipped', '2:queued'], 'the superseded attempt is logged skipped');
select tests.as_superuser();
select tests.fx_set('q3', pg_temp.quote_for(tests.fx('cust_r')));
update public.quotes set status = 'sent', sent_at = now() - interval '200 hours' where id = tests.fx('q3');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now()), 0, 'due more than 24 hours ago: skipped, never sent');
select tests.eq((select count(*) from public.document_followup_log where doc_id = tests.fx('q3') and outcome = 'skipped'), 2::bigint,
                'both attempts logged skipped');

-- a template switched off entirely: the quote is not processed at all
select tests.as_superuser();
select tests.fx_set('q4', pg_temp.quote_for(tests.fx('cust_q')));
update public.quotes set status = 'sent', sent_at = now() where id = tests.fx('q4');
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'quote_reminder';
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 0, 'no enabled wording: nothing');
select tests.eq((select count(*) from public.document_followup_log where doc_id = tests.fx('q4')), 0::bigint,
                '… and nothing logged (enabling it later still catches up)');
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'quote_reminder' and channel = 'sms';
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '50 hours'), 1, 'only the enabled channel');
select tests.as_superuser();
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'quote_reminder';

-- a suppressed address gets nothing on that channel
select tests.fx_set('q5', pg_temp.quote_for(tests.fx('cust_r')));
update public.quotes set status = 'sent', sent_at = now() where id = tests.fx('q5');
select public.comms_suppress(tests.fx('shop_a'), 'email', 'rae@example.com');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 1, 'suppressed email: sms only');
select tests.eq((select array_agg(channel::text) from public.messages where quote_id = tests.fx('q5') and status = 'queued'),
                array['sms'], 'no email to a suppressed address');

-- the switch in followup_settings: shop B is off
select tests.as_superuser();
select tests.fx_set('qb', pg_temp.quote_for(tests.fx('cust_bb'), tests.fx('shop_b')));
update public.quotes set status = 'sent', sent_at = now() where id = tests.fx('qb');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '48 hours'), 0, 'follow-ups off (shop B): nothing');

-- ============================================================ withdrawal (quotes)
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.staff_record_quote_response(tests.fx('q2'), 'approve');
select tests.as_service();
select tests.eq((select array_agg(distinct public.comms_withdraw_reason(m, now() + interval '121 hours'))
                   from public.messages m where m.quote_id = tests.fx('q2') and m.status = 'queued'),
                array['the quote was already answered'], 'approved: queued reminders are withdrawn at send time');
select tests.as_superuser();
update public.quotes set valid_until = (now() at time zone :'tz')::date - 1 where id = tests.fx('q5');
select tests.as_service();
select tests.eq((select public.comms_withdraw_reason(m, now()) from public.messages m where m.quote_id = tests.fx('q5') and m.status = 'queued'),
                'the quote has expired', 'expired');
select tests.as_superuser();
update public.quotes set valid_until = current_date + 30, followups_paused = true where id = tests.fx('q4');
select tests.as_service();
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '50 hours') from public.messages m
                  where m.quote_id = tests.fx('q4') and m.status = 'queued'), 'follow-ups were paused for this quote', 'paused');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '48 hours' + interval '25 hours') from public.messages m
                  where m.quote_id = tests.fx('q1') and m.status = 'queued' and m.channel = 'sms'
                  order by m.send_after limit 1), 'the message is too old to send', 'stale after 24 hours');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '120 hours') from public.messages m
                  where m.quote_id = tests.fx('q1') and m.status = 'queued' and m.send_after = now() + interval '120 hours'
                    and m.channel = 'email'), null, 'a live reminder is sent');
-- and the claim settles them
select tests.as_service();
select * from public.claim_queued_messages(500, now() + interval '121 hours') \g /dev/null
select tests.eq((select array_agg(distinct status::text) from public.messages where quote_id = tests.fx('q2')), array['cancelled'],
                'the claim cancels the approved quote''s reminders');

-- ============================================================ deposits
select tests.as_superuser();
update public.messages set status = 'cancelled' where status in ('queued', 'sending');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_d'), now() + interval '5 days', now() + interval '5 days 2 hours')
  returning tests.fx_set('job_d', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_d'), 'Full Detail', 20000);
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_d');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '23 hours'), 0, 'not before 24 hours');
select tests.eq(public.enqueue_document_followups(now() + interval '24 hours'), 2, 'deposit reminder on both channels');
select tests.ok((select bool_and(m.job_id = tests.fx('job_d') and m.body like '%Deposit due: $50.00%'
                                 and m.body like '%https://app.example.test/booking/' || j.public_token || '%')
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where m.template_key = 'deposit_reminder'), 'amount due and the booking page to pay it');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '24 hours') from public.messages m
                  where m.job_id = tests.fx('job_d') and m.channel = 'sms' and m.template_key = 'deposit_reminder'), null, 'still due: sent');
-- a received deposit pays it (the receipt goes out as usual)
select tests.as_superuser();
insert into public.payments (shop_id, customer_id, job_id, kind, method, status, amount_cents, paid_at)
  values (tests.fx('shop_a'), tests.fx('cust_d'), tests.fx('job_d'), 'deposit', 'cash', 'succeeded', 5000, now());
select tests.as_service();
select tests.eq(public.comms_deposit_due_cents(tests.fx('job_d')), 0::bigint, 'the deposit is covered');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '24 hours') from public.messages m
                  where m.job_id = tests.fx('job_d') and m.channel = 'sms' and m.template_key = 'deposit_reminder'), 'the deposit was paid', 'paid: withdrawn');
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 0, 'no further attempts once paid');
-- cancelled / started appointments and requested jobs without a time
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_d'), 'requested')
  returning tests.fx_set('job_r', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_r'), 'Wash', 8000);
update public.jobs set deposit_required_cents = 2000 where id = tests.fx('job_r');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '24 hours'), 2, 'a requested job without a time counts from its creation');
select tests.ok((select bool_and(body not like '%Appointment:%') from public.messages where job_id = tests.fx('job_r') and channel = 'sms'),
                'no appointment line without a time');
select tests.as_superuser();
update public.jobs set status = 'cancelled' where id = tests.fx('job_r');
select tests.as_service();
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '24 hours') from public.messages m
                  where m.job_id = tests.fx('job_r') and m.channel = 'sms' and m.template_key = 'deposit_reminder'), 'the appointment was cancelled', 'cancelled: withdrawn');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select r -> 'next_at' from (select public.document_followup_status('deposit', tests.fx('job_r')) as r) x),
                'null'::jsonb, 'a cancelled job has no next attempt');
select tests.eq((select r -> 'attempts_sent' from (select public.document_followup_status('deposit', tests.fx('job_r')) as r) x),
                '1'::jsonb, 'but its sent attempt is counted');
select public.set_document_followups_paused('deposit', tests.fx('job_d'), true);
select tests.as_superuser();
select tests.ok((select deposit_followups_paused from public.jobs where id = tests.fx('job_d')), 'deposit follow-ups paused on the job');

-- the appointment moves to another customer (allowed while no invoice or
-- received payment exists — exactly while a deposit is still due): the
-- queued reminder carries the job's /booking link, so it must never reach
-- the previous customer
select tests.as_superuser();
update public.messages set status = 'cancelled' where status in ('queued', 'sending');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_d'), now() + interval '6 days', now() + interval '6 days 2 hours')
  returning tests.fx_set('job_m', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('job_m'), 'Full Detail', 20000);
update public.jobs set deposit_required_cents = 5000 where id = tests.fx('job_m');
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '24 hours'), 2, 'deposit reminder queued for Dee');
select tests.eq((select array_agg(to_address order by channel) from public.messages
                  where job_id = tests.fx('job_m') and template_key = 'deposit_reminder'),
                array['+12055550113', 'dee@example.com'], '(to Dee on both channels)');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set customer_id = tests.fx('cust_r'), vehicle_id = null where id = tests.fx('job_m');
select tests.as_service();
select tests.ok((select customer_id from public.jobs where id = tests.fx('job_m')) = tests.fx('cust_r'), '(the job moved to Rae)');
select tests.eq((select array_agg(distinct public.comms_withdraw_reason(m, now() + interval '24 hours')) from public.messages m
                  where m.job_id = tests.fx('job_m') and m.template_key = 'deposit_reminder' and m.status = 'queued'),
                array['the appointment now belongs to another customer'], 'moved: the old customer''s reminders are withdrawn');
select * from public.claim_queued_messages(500, now() + interval '24 hours') \g /dev/null
select tests.eq((select array_agg(status::text order by channel) from public.messages
                  where job_id = tests.fx('job_m') and template_key = 'deposit_reminder' and customer_id = tests.fx('cust_d')),
                array['cancelled', 'cancelled'], 'the claim cancels deposit reminders to the old customer (nothing is sent)');
select tests.eq((select count(*) from public.messages
                  where job_id = tests.fx('job_m') and status in ('sending', 'sent') and to_address in ('+12055550113', 'dee@example.com')),
                0::bigint, 'nothing about the moved job reaches the old customer');
-- the next attempt goes to the new customer
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 1, 'the next attempt is queued …');
select tests.eq((select array_agg(to_address order by channel) from public.messages
                  where job_id = tests.fx('job_m') and template_key = 'deposit_reminder' and status = 'queued'),
                array['+12055550112'], '… for the new customer (Rae''s email is suppressed above)');
select tests.eq((select array_agg(distinct coalesce(public.comms_withdraw_reason(m, now() + interval '72 hours'), 'send'))
                   from public.messages m
                  where m.job_id = tests.fx('job_m') and m.template_key = 'deposit_reminder' and m.status = 'queued'),
                array['send'], 'and is sent');
select tests.as_superuser();
update public.messages set status = 'cancelled' where job_id = tests.fx('job_m') and status in ('queued', 'sending');
update public.jobs set deposit_followups_paused = true where id = tests.fx('job_m');

-- ============================================================ invoices
select tests.as_superuser();
update public.messages set status = 'cancelled' where status in ('queued', 'sending');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv1', (select (public.create_invoice(tests.fx('cust_i'),
                                      '[{"name": "Paint correction", "unit_price_cents": 30000}]'::jsonb)).id));
select public.mark_invoice_sent(tests.fx('inv1'));
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '71 hours'), 0, 'not before 72 hours');
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 2, 'invoice reminder while not yet due');
select tests.ok((select bool_and(m.invoice_id = tests.fx('inv1') and m.template_key = 'invoice_reminder'
                                 and m.body like '%Invoice #' || i.number || E'\nBalance due: $300.00\nDue date: '
                                                 || to_char(i.due_at at time zone :'tz', 'FMMonth FMDD, YYYY') || '%'
                                 and m.body like '%https://app.example.test/i/' || i.public_token || '%')
                   from public.messages m join public.invoices i on i.id = m.invoice_id
                  where m.invoice_id = tests.fx('inv1') and m.channel = 'email'),
                'email: number, balance, due date and pay link');
select tests.ok((select to_char(due_at at time zone :'tz', 'HH24:MI:SS') = '23:59:59' from public.invoices
                  where id = tests.fx('inv1')), '(due at the end of the local due date)');
-- past due: overdue notices in days
select tests.as_superuser();
-- due at the end of yesterday (local): the first notice is today at 10:00 local
update public.invoices
   set issued_at = now() - interval '40 days',
       due_at = ((now() at time zone :'tz')::date + time '00:00' - interval '1 second') at time zone :'tz'
 where id = tests.fx('inv1');
select (((now() at time zone :'tz')::date + time '10:00') at time zone :'tz') as t1 \gset
select tests.as_service();
select tests.eq(public.enqueue_document_followups(:'t1'::timestamptz - interval '1 minute'), 0,
                'not at midnight: the first overdue notice waits for 10:00 local');
select tests.eq(public.enqueue_document_followups(:'t1'::timestamptz), 2, 'overdue notice the day after the due date, at 10:00');
select tests.eq((select array_agg(distinct template_key::text) from public.messages
                  where invoice_id = tests.fx('inv1') and send_after = :'t1'::timestamptz),
                array['invoice_overdue'], 'the overdue wording');
select tests.eq(public.enqueue_document_followups(:'t1'::timestamptz + interval '6 days 23 hours'), 0, 'the next one a week later');
select tests.eq(public.enqueue_document_followups(:'t1'::timestamptz + interval '7 days'), 2, 'second overdue notice');
select tests.ok((select bool_and(to_char(send_after at time zone :'tz', 'HH24:MI') = '10:00') from public.messages
                  where invoice_id = tests.fx('inv1') and template_key = 'invoice_overdue'),
                'every overdue notice goes out at 10:00 shop time');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_build_array(r -> 'stage', r -> 'attempts_sent', r -> 'max_attempts')
                   from (select public.document_followup_status('invoice', tests.fx('inv1')) as r) x),
                '["invoice_overdue", 2, 3]'::jsonb, 'status follows the overdue stage');
-- paid: withdrawn, nothing more
select public.record_manual_payment(tests.fx('inv1'), 30000, 'cash');
select tests.as_service();
select tests.eq((select array_agg(distinct public.comms_withdraw_reason(m, now() + interval '7 days')) from public.messages m
                  where m.invoice_id = tests.fx('inv1') and m.status = 'queued'), array['the invoice was paid'], 'paid: withdrawn');
select tests.eq(public.enqueue_document_followups(now() + interval '14 days'), 0, 'a paid invoice gets no more notices');
-- void
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv2', (select (public.create_invoice(tests.fx('cust_i'),
                                      '[{"name": "Wash", "unit_price_cents": 5000}]'::jsonb)).id));
select public.mark_invoice_sent(tests.fx('inv2'));
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 2, 'second invoice reminded');
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv2'), 'duplicate');
select tests.as_service();
select tests.eq((select array_agg(distinct public.comms_withdraw_reason(m, now() + interval '72 hours')) from public.messages m
                  where m.invoice_id = tests.fx('inv2') and m.status = 'queued'), array['the invoice was voided'], 'voided: withdrawn');
-- a draft invoice is never chased
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv3', (select (public.create_invoice(tests.fx('cust_i'),
                                      '[{"name": "Wash", "unit_price_cents": 5000}]'::jsonb)).id));
select tests.as_service();
select tests.eq(public.enqueue_document_followups(now() + interval '72 hours'), 0, 'drafts are not chased');

-- ============================================================ variables across DST
select tests.as_superuser();
update public.shops set timezone = 'America/Chicago' where id = tests.fx('shop_a');
update public.invoices set due_at = '2025-03-09 05:59:59+00' where id = tests.fx('inv3');   -- Sat Mar 8 23:59:59 CST
select tests.eq((select array[v ->> 'due_date', v ->> 'days_overdue'] from
                  (select public.comms_invoice_vars(tests.fx('inv3'), '2025-03-10 12:00+00') as v) x),
                array['March 8, 2025', '2'], 'due date and whole local days past it (across the DST change)');
select tests.eq(public.comms_invoice_vars(tests.fx('inv3'), '2025-03-09 05:00+00') -> 'days_overdue', 'null'::jsonb,
                'not yet due: no days overdue');
-- day schedules: 10:00 local on the local due date + n days (never around
-- midnight, although due_at is 23:59:59 local), across DST
select tests.eq(public.comms_followup_due_at('2025-03-09 05:59:59+00', interval '1 day', interval '7 days', true,
                                             'America/Chicago', 1), '2025-03-09 15:00+00'::timestamptz,
                'overdue attempt 1: Sun Mar 9 10:00 CDT (the day DST starts)');
select tests.eq(public.comms_followup_due_at('2025-03-09 05:59:59+00', interval '1 day', interval '7 days', true,
                                             'America/Chicago', 2), '2025-03-16 15:00+00'::timestamptz, 'attempt 2: a week later, 10:00 CDT');
select tests.eq(public.comms_followup_due_at('2025-03-09 05:59:59+00', interval '0 days', interval '1 day', true,
                                             'America/Chicago', 1), '2025-03-09 15:00+00'::timestamptz,
                'first = 0 days: the next 10:00 after the due time (never before the invoice is overdue)');
select tests.eq(public.comms_followup_due_at('2025-03-09 05:59:59+00', interval '0 days', interval '1 day', true,
                                             'America/Chicago', 2), '2025-03-10 15:00+00'::timestamptz,
                '… and the attempts stay a repeat apart');
select tests.eq(public.comms_followup_due_at('2025-03-08 14:00+00', interval '0 days', interval '7 days', true,
                                             'America/Chicago', 1), '2025-03-08 16:00+00'::timestamptz,
                'a due time set before 10:00: 10:00 the same local day');
select tests.eq(public.comms_followup_due_at('2025-03-08 16:00+00', interval '0 days', interval '7 days', true,
                                             'America/Chicago', 1), '2025-03-09 15:00+00'::timestamptz,
                'exactly 10:00 is not after the due time: the next day');
select tests.eq(public.comms_followup_due_at('2025-11-02 04:59:59+00', interval '1 day', interval '7 days', true,
                                             'America/Chicago', 1), '2025-11-02 16:00+00'::timestamptz,
                'the day DST ends: 10:00 CST');
select tests.eq(public.comms_followup_due_at('2025-06-30 23:59:59+00', interval '2 days', interval '7 days', true,
                                             'Pacific/Auckland', 1), '2025-07-02 22:00+00'::timestamptz,
                'other zones: local date + days at 10:00 local');

-- hourly scheduler over 10 days with the real due date: every overdue
-- notice is queued at a waking hour
select tests.as_superuser();
update public.messages set status = 'cancelled' where status in ('queued', 'sending');
update public.shops set invoice_due_days = 7 where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv4', (select (public.create_invoice(tests.fx('cust_i'),
                                      '[{"name": "Wash", "unit_price_cents": 5000}]'::jsonb)).id));
select public.mark_invoice_sent(tests.fx('inv4'));
select tests.as_service();
select count(public.enqueue_document_followups(now() + make_interval(hours => h))) from generate_series(0, 24 * 10) h \g /dev/null
select tests.eq((select count(*) from public.messages where invoice_id = tests.fx('inv4') and template_key = 'invoice_overdue'),
                2::bigint, 'the first overdue notice went out (both channels)');
select tests.ok((select bool_and(extract(hour from send_after at time zone 'America/Chicago') between 8 and 20)
                   from public.messages where invoice_id = tests.fx('inv4') and template_key = 'invoice_overdue'),
                'overdue notices go out at a waking hour, got local times: ' ||
                coalesce((select string_agg(to_char(send_after at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI'), ', ')
                            from public.messages where invoice_id = tests.fx('inv4') and template_key = 'invoice_overdue'), '-'));
select tests.eq((select (min(send_after) at time zone 'America/Chicago')::date
                   from public.messages where invoice_id = tests.fx('inv4') and template_key = 'invoice_overdue'),
                (select (due_at at time zone 'America/Chicago')::date + 1 from public.invoices where id = tests.fx('inv4')),
                'on the first local day after the due date');
update public.invoices set followups_paused = true where id = tests.fx('inv4');

-- every follow-up carries a public document link: a message queued for a
-- customer the document no longer belongs to is withdrawn
select tests.eq((select public.comms_withdraw_reason(jsonb_populate_record(m, jsonb_build_object('customer_id', tests.fx('cust_q'),
                                                                                             'to_address', '+12055550111')),
                                                     m.send_after)
                   from public.messages m where m.invoice_id = tests.fx('inv4') and m.channel = 'sms'
                   order by m.send_after limit 1),
                'the invoice now belongs to another customer', 'invoice follow-up for another customer: withdrawn');
select tests.eq(public.comms_followup_due_at('2025-03-08 18:00+00', interval '48 hours', interval '72 hours', false,
                                             'America/Chicago', 2), '2025-03-13 18:00+00'::timestamptz,
                'hour schedules are elapsed time (13:00 CDT: across the DST change, still 120 hours)');
select tests.eq(public.comms_quote_vars(tests.fx('q1')) ->> 'quote_total', '$1,200.00', 'quote total');
select tests.eq(public.comms_quote_vars(gen_random_uuid()), null, 'unknown quote: no variables');

-- ============================================================ automations hook, isolation, privileges
select tests.as_superuser();
update public.shops set timezone = :'tz' where id = tests.fx('shop_a');
update public.messages set status = 'cancelled' where status in ('queued', 'sending');
select tests.fx_set('q6', pg_temp.quote_for(tests.fx('cust_q')));
update public.quotes set status = 'sent', sent_at = now() where id = tests.fx('q6');
select tests.as_service();
select tests.eq(public.enqueue_due_automations(now() + interval '48 hours'), 2, 'enqueue_due_automations runs the follow-ups');
select tests.eq((select public.comms_withdraw_reason(m, now() + interval '48 hours') from public.messages m
                  where m.quote_id = tests.fx('q6') and m.channel = 'sms' and m.status = 'queued'), null, '(a live quote reminder)');
select tests.eq((select public.comms_withdraw_reason(jsonb_populate_record(m, jsonb_build_object('customer_id', tests.fx('cust_r'),
                                                                                                 'to_address', '+12055550112')),
                                                     now() + interval '48 hours')
                   from public.messages m where m.quote_id = tests.fx('q6') and m.channel = 'sms' and m.status = 'queued'),
                'the quote now belongs to another customer', 'quote follow-up for a customer the quote no longer belongs to: withdrawn');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.document_followup_log where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B managers do not see shop A''s follow-up log');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(tests.row_count($$select 1 from public.document_followup_log$$) > 0, 'managers read their shop''s log');
select tests.throws($$insert into public.document_followup_log (shop_id, doc_kind, doc_id, attempt, due_at, processed_at, outcome)
                      values (tests.fx('shop_a'), 'quote', gen_random_uuid(), 1, now(), now(), 'skipped')$$, '42501', 'the log is server-written');
select tests.throws($$select public.enqueue_document_followups()$$, '42501', 'the run is service-only');
select tests.throws($$select public.comms_quote_vars(tests.fx('q1'))$$, '42501', 'variables are internal');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.document_followup_log$$), 0::bigint, 'technicians do not read the log');
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'deposit_followups_paused', 'SELECT')
                and has_column_privilege('authenticated', 'public.invoices', 'followups_paused', 'SELECT'),
                'the pause flags are readable');
select tests.as_superuser();
select tests.throws($$insert into public.messages (shop_id, customer_id, quote_id, direction, channel, to_address, body, status)
                      values (tests.fx('shop_b'), tests.fx('cust_bb'), tests.fx('q1'), 'outbound', 'sms', '+12055550115', 'x', 'queued')$$,
                    '23503', 'a message cannot point at another shop''s quote');
