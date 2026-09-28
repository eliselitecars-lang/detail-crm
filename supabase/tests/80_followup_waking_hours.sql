-- 80 comms: automatic document follow-ups (0085) are never texted in the
-- middle of the night. Hour schedules (quote, deposit and invoice reminders)
-- count from the moment a customer booked online or staff pressed Send, at
-- any hour; an attempt landing outside 08:00-21:00 shop time falls due when
-- that window next opens, and the run only queues inside the window (a late
-- run at night waits for the morning). Covers: the online booking at 01:30,
-- the status RPC's next time, attempts of one night collapsing into one
-- morning message (no burst), a late run, a quote sent at 23:30, spacing
-- kept inside the window, DST days and other zones, per-shop windows (two
-- shops in different zones), and the day schedules left at 10:00.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550200', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100', timezone = 'America/Chicago' where id = tests.fx('shop_a');
update public.shops set sms_from_number = '+12055550200', timezone = 'Asia/Tokyo' where id = tests.fx('shop_b');
update public.customers set phone = '+12055550201' where id = tests.fx('cust_b');
-- the rest of the queue is not this file's business
update public.messages set status = 'cancelled' where status = 'queued';
update public.followup_settings set deposit_enabled = true, quote_enabled = true
 where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'));
update public.message_templates set enabled = true
 where shop_id in (tests.fx('shop_a'), tests.fx('shop_b')) and key in ('deposit_reminder', 'quote_reminder') and channel = 'sms';

create function pg_temp.booking(p_shop uuid, p_customer uuid, p_booked_at timestamptz, p_start timestamptz) returns uuid
language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.jobs (shop_id, customer_id, status, source, scheduled_start, scheduled_end, deposit_required_cents)
    values (p_shop, p_customer, 'requested', 'online_booking', p_start, p_start + interval '2 hours', 5000) returning id into v_id;
  insert into public.job_line_items (shop_id, job_id, name, unit_price_cents) values (p_shop, v_id, 'Full Detail', 20000);
  update public.jobs set created_at = p_booked_at, appointment_set_at = p_booked_at where id = v_id;
  return v_id;
end $$;
create function pg_temp.n_job(p_job uuid) returns bigint language sql as $$
  select count(*) from public.messages m where m.job_id = p_job and m.template_key = 'deposit_reminder' and m.status = 'queued'
$$;
create function pg_temp.local(p_at timestamptz) returns text language sql as $$
  select to_char(p_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI')
$$;

-- ============================================================ an online booking at 01:30 local
-- booked Tue 2025-06-10 01:30 CDT (06:30 UTC) for Sat 2025-06-14; the
-- default deposit schedule (first after 24 h) lands at Wed 01:30 CDT
select tests.fx_set('job_n', pg_temp.booking(tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-10 06:30+00', '2025-06-14 15:00+00'));
-- shop B (Tokyo): booked at the same UTC moment, 15:30 local
select tests.fx_set('job_bn', pg_temp.booking(tests.fx('shop_b'), tests.fx('cust_b'), '2025-06-10 06:30+00', '2025-06-14 05:00+00'));

select tests.eq(public.comms_followup_due_at('2025-06-10 06:30+00', interval '24 hours', interval '48 hours', false,
                                             'America/Chicago', 1), '2025-06-11 13:00+00'::timestamptz,
                'due at 08:00 local the morning it would have fallen due (not 01:30)');
select tests.eq((select ((r ->> 'next_at')::timestamptz) from
                  (select public.comms_followup_status_json('deposit', tests.fx('job_n'), '2025-06-10 12:00+00') as r) x),
                '2025-06-11 13:00+00'::timestamptz, 'the status shows the real next send time (08:00 local)');

select tests.as_service();
select public.enqueue_document_followups('2025-06-11 06:31+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_n')), 0::bigint, '01:31 local: no deposit text queued in the middle of the night');
select tests.eq((select count(*) from public.document_followup_log where doc_id = tests.fx('job_n')), 0::bigint,
                '… and the attempt is not used up');
select tests.eq(pg_temp.n_job(tests.fx('job_bn')), 1::bigint,
                'the same run texts shop B''s customer: 15:31 in Tokyo (each shop''s own waking hours)');
select tests.eq((select to_char(send_after at time zone 'Asia/Tokyo', 'HH24:MI') from public.messages
                  where job_id = tests.fx('job_bn') and template_key = 'deposit_reminder'), '15:31', '(sent right away there)');
select public.enqueue_document_followups('2025-06-11 12:59+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_n')), 0::bigint, '07:59 local: still waiting');
select public.enqueue_document_followups('2025-06-11 13:00+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_n')), 1::bigint, '08:00 local: the deposit reminder is queued');
select tests.as_superuser();
select tests.ok((select ((m.send_after at time zone 'America/Chicago')::time between time '08:00' and time '21:00')
                   from public.messages m where m.job_id = tests.fx('job_n') and m.template_key = 'deposit_reminder'),
                'the automatic deposit reminder text is not sent in the middle of the night');
select tests.eq((select pg_temp.local(m.send_after) from public.messages m
                  where m.job_id = tests.fx('job_n') and m.template_key = 'deposit_reminder'),
                '2025-06-11 08:00', 'sent at 08:00 local');
select tests.eq((select array[attempt::text, outcome, pg_temp.local(due_at)] from public.document_followup_log
                  where doc_id = tests.fx('job_n')), array['1', 'queued', '2025-06-11 08:00'], 'logged with its waking due time');
select tests.ok((select body like '%Deposit due: $50.00%' from public.messages
                  where job_id = tests.fx('job_n') and template_key = 'deposit_reminder'), '(rendered when queued: current amount)');
-- the next attempt (48 h later, 01:30 again) also waits for the morning
select tests.as_service();
select public.enqueue_document_followups('2025-06-13 06:31+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_n')), 1::bigint, 'attempt 2 is not texted at 01:31 either');
select public.enqueue_document_followups('2025-06-13 13:00+00') \g /dev/null
select tests.eq((select array_agg(pg_temp.local(send_after) order by send_after) from public.messages
                  where job_id = tests.fx('job_n') and template_key = 'deposit_reminder'),
                array['2025-06-11 08:00', '2025-06-13 08:00'], 'attempt 2 at 08:00 two days later');
select tests.as_superuser();
update public.jobs set deposit_followups_paused = true where id in (tests.fx('job_n'), tests.fx('job_bn'));

-- ============================================================ one night's attempts: one morning message
-- every 3 hours from an hour after a 20:30 booking: 21:30, 00:30, 03:30 and
-- 06:30 all fall at night; the customer gets ONE text at 08:00, not four
update public.followup_settings
   set deposit_first_after_hours = 1, deposit_repeat_every_hours = 3, deposit_max_attempts = 5
 where shop_id = tests.fx('shop_a');
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Nia', '+12055550131')
  returning tests.fx_set('cust_nia', id);
select tests.fx_set('job_night', pg_temp.booking(tests.fx('shop_a'), tests.fx('cust_nia'), '2025-06-20 01:30+00', '2025-06-25 15:00+00'));
select tests.as_service();
select count(public.enqueue_document_followups('2025-06-20 01:30+00'::timestamptz + make_interval(mins => 15 * q)))
  from generate_series(0, 4 * 24) q \g /dev/null
select tests.eq((select array_agg(pg_temp.local(send_after) order by send_after) from public.messages
                  where job_id = tests.fx('job_night') and template_key = 'deposit_reminder'),
                array['2025-06-20 08:00', '2025-06-20 09:30'],
                'a scheduler every 15 minutes: one text at 08:00 for the night''s four attempts, then 09:30 (attempt 5)');
select tests.eq((select array_agg(attempt::text || ':' || outcome order by attempt) from public.document_followup_log
                  where doc_id = tests.fx('job_night')),
                array['1:skipped', '2:skipped', '3:skipped', '4:queued', '5:queued'],
                'the night''s earlier attempts are superseded (logged skipped), never sent in a burst');
select tests.ok((select bool_and((send_after at time zone 'America/Chicago')::time >= time '08:00'
                                 and (send_after at time zone 'America/Chicago')::time < time '21:00')
                   from public.messages where shop_id = tests.fx('shop_a') and template_key = 'deposit_reminder'),
                'every deposit reminder of the shop went out between 08:00 and 21:00');

-- ============================================================ a late run at night
-- attempt 1 is due 20:30 (inside the window) but the scheduler only runs
-- again at 21:05: it waits for the morning instead of texting at night
select tests.as_superuser();
update public.jobs set deposit_followups_paused = true where id = tests.fx('job_night');
update public.followup_settings set deposit_max_attempts = 1 where shop_id = tests.fx('shop_a');
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Oto', '+12055550132')
  returning tests.fx_set('cust_oto', id);
select tests.fx_set('job_late', pg_temp.booking(tests.fx('shop_a'), tests.fx('cust_oto'), '2025-07-01 00:30+00', '2025-07-05 15:00+00'));
select tests.eq(pg_temp.local(public.comms_followup_due_at('2025-07-01 00:30+00', interval '1 hour', interval '3 hours', false,
                                                           'America/Chicago', 1)), '2025-06-30 20:30', '(due 20:30 local)');
select tests.as_service();
select public.enqueue_document_followups('2025-07-01 02:05+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_late')), 0::bigint, 'a run at 21:05 local queues nothing');
select tests.eq((select count(*) from public.document_followup_log where doc_id = tests.fx('job_late')), 0::bigint,
                '… and keeps the attempt for the morning');
select public.enqueue_document_followups('2025-07-01 12:30+00') \g /dev/null
select tests.eq(pg_temp.n_job(tests.fx('job_late')), 0::bigint, '07:30 local: not yet');
select public.enqueue_document_followups('2025-07-01 13:05+00') \g /dev/null
select tests.eq((select array_agg(pg_temp.local(send_after)) from public.messages
                  where job_id = tests.fx('job_late') and template_key = 'deposit_reminder'),
                array['2025-07-01 08:05'], 'the first morning run sends it (within 24 hours of its due time)');

-- ============================================================ a quote sent at 23:30
select tests.as_superuser();
insert into public.quotes (shop_id, customer_id, valid_until) values (tests.fx('shop_a'), tests.fx('cust_a'), null)
  returning tests.fx_set('q_late', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('q_late'), 'Ceramic coating', 120000);
update public.quotes set status = 'sent', sent_at = '2025-08-05 04:30+00' where id = tests.fx('q_late');   -- Mon Aug 4 23:30 CDT
select tests.as_service();
select public.enqueue_document_followups('2025-08-07 04:31+00') \g /dev/null   -- 48 h later: Wed 23:31 CDT
select tests.eq((select count(*) from public.messages where quote_id = tests.fx('q_late')), 0::bigint,
                'quote reminder: not at 23:31 (the time staff pressed Send)');
select public.enqueue_document_followups('2025-08-07 13:00+00') \g /dev/null
select tests.eq((select array_agg(pg_temp.local(send_after)) from public.messages where quote_id = tests.fx('q_late')),
                array['2025-08-07 08:00'], 'but at 08:00 the next morning');

-- ============================================================ the schedule function
-- (hour schedules; day schedules keep 10:00, see 80_document_followups)
select tests.eq(public.comms_followup_due_at('2025-06-10 11:59+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-06-10 13:00+00'::timestamptz, '07:59 -> 08:00 the same morning');
select tests.eq(public.comms_followup_due_at('2025-06-10 12:00+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-06-10 13:00+00'::timestamptz, '08:00 stays');
select tests.eq(public.comms_followup_due_at('2025-06-11 00:59:59+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-06-11 01:59:59+00'::timestamptz, '20:59:59 stays');
select tests.eq(public.comms_followup_due_at('2025-06-11 01:00+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-06-11 13:00+00'::timestamptz, '21:00 -> 08:00 the next morning');
select tests.eq(public.comms_followup_due_at('2025-08-05 04:30+00', interval '72 hours', interval '168 hours', false,
                                             'America/Chicago', 1), '2025-08-08 13:00+00'::timestamptz,
                'an invoice sent at 23:30: the 72-hour reminder at 08:00');
select tests.eq(public.comms_followup_due_at('2025-08-05 17:00+00', interval '48 hours', interval '72 hours', false,
                                             'America/Chicago', 2), '2025-08-10 17:00+00'::timestamptz,
                'daytime attempts keep their exact spacing (12:00 + 48 h + 72 h)');
select tests.eq(public.comms_followup_due_at('2025-03-09 07:30+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-03-09 13:00+00'::timestamptz,
                'the night DST starts: 03:30 CDT -> 08:00 CDT');
select tests.eq(public.comms_followup_due_at('2025-11-02 05:30+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-11-02 14:00+00'::timestamptz,
                'the night DST ends (01:30 CDT, the repeated hour): 08:00 CST');
select tests.eq(public.comms_followup_due_at('2025-11-02 01:30+00', interval '1 hour', interval '1 hour', false,
                                             'America/Chicago', 1), '2025-11-02 14:00+00'::timestamptz,
                '21:30 CDT the evening before: 08:00 CST the next morning');
select tests.eq(public.comms_followup_due_at('2025-07-01 09:00+00', interval '1 hour', interval '1 hour', false,
                                             'Pacific/Auckland', 1), '2025-07-01 20:00+00'::timestamptz,
                'other zones: 22:00 NZST -> 08:00 NZST the next day');
select tests.ok((select bool_and(public.comms_followup_due_at('2025-06-10 05:00+00', interval '1 hour', interval '1 hour', false,
                                                             'America/Chicago', n + 1)
                                 >= public.comms_followup_due_at('2025-06-10 05:00+00', interval '1 hour', interval '1 hour', false,
                                                                 'America/Chicago', n))
                   from generate_series(1, 9) n), 'attempts never go backwards');
select tests.eq(public.comms_followup_due_at('2025-03-09 05:59:59+00', interval '1 day', interval '7 days', true,
                                             'America/Chicago', 1), '2025-03-09 15:00+00'::timestamptz,
                'day schedules unchanged: 10:00 local');

-- ============================================================ privileges
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.enqueue_document_followups('2025-06-11 13:00+00')$$, '42501', 'owners cannot run the queue');
select tests.throws($$select public.comms_followup_due_at(now(), interval '1 hour', interval '1 hour', false, 'UTC', 1)$$, '42501',
                    'the schedule function is internal');
select tests.as_anon();
select tests.throws($$select public.enqueue_document_followups()$$, '42501', 'anon: no access');
