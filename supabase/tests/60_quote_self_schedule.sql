-- 60 money: customers schedule their approved quote (P-16, 0067) —
-- public_quote_slots / public_schedule_quote preconditions, slots from the
-- online booking engine (duration of the counted lines, capacity), the
-- conversion (status per auto-confirm, deposit rule, location, seller),
-- notifications, the /q self_schedule block (job token only for customer
-- scheduling; payment_pending while an ACH deposit clears), double scheduling, disabled switches, mobile addresses,
-- unknown tokens and grants.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- a day a month ahead (shop-local), so the server clock anon callers use
-- never makes it the past
select ((now() at time zone 'America/Chicago')::date + 30)::text as d \gset

select tests.as_superuser();
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 5000
 where shop_id = tests.fx('shop_a');

create function pg_temp.approved_quote(p_customer uuid, p_minutes integer[]) returns uuid language plpgsql as $$
declare
  v_q uuid;
  v_m integer;
  v_i integer := 0;
begin
  insert into public.quotes (shop_id, customer_id, vehicle_id) values (tests.fx('shop_a'), p_customer,
    case when p_customer = tests.fx('cust_a') then tests.fx('veh_a') end) returning id into v_q;
  foreach v_m in array p_minutes loop
    v_i := v_i + 1;
    insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents, duration_minutes, sort)
    values (tests.fx('shop_a'), v_q, case when v_i = 1 then tests.fx('svc_a') else tests.fx('svc_wash') end,
            'Work ' || v_i, 10000, v_m, v_i);
  end loop;
  perform public.mark_quote_sent(v_q);
  update public.quotes set status = 'approved', approved_by_name = 'Customer' where id = v_q;
  return v_q;
end $$;
grant execute on function pg_temp.approved_quote(uuid, integer[]) to authenticated;

create function pg_temp.token(p_q uuid) returns uuid language sql security definer as $$
  select public_token from public.quotes where id = p_q
$$;
grant execute on function pg_temp.token(uuid) to anon, authenticated, service_role;

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('q1', pg_temp.approved_quote(tests.fx('cust_a'), array[120, 60]));

-- ============================================================ preconditions
select tests.as_anon();
select tests.throws_like(format('select * from public.public_quote_slots(%L, %L, %L)', pg_temp.token(tests.fx('q1')), :'d', :'d'),
                         '22023', '%online scheduling is not available%', 'the shop has not turned quote scheduling on');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.booking_settings set quote_self_schedule = true where shop_id = tests.fx('shop_a')$$),
                0::bigint, 'managers cannot turn it on (booking settings are admin+)');
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.booking_settings set quote_self_schedule = true where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_draft', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents, duration_minutes) values
  (tests.fx('shop_a'), tests.fx('q_draft'), 'Wash', 5000, 60);
select tests.as_anon();
select tests.throws(format('select * from public.public_quote_slots(%L, %L, %L)', pg_temp.token(tests.fx('q_draft')), :'d', :'d'),
                    'PT404', 'a draft quote is not published');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.mark_quote_sent(tests.fx('q_draft'));
select tests.as_anon();
select tests.throws_like(format('select * from public.public_quote_slots(%L, %L, %L)', pg_temp.token(tests.fx('q_draft')), :'d', :'d'),
                         '22023', '%approve the quote%', 'only approved quotes can be scheduled');
select tests.throws(format('select * from public.public_quote_slots(%L, %L, %L)', gen_random_uuid(), :'d', :'d'), 'PT404', 'unknown token');

-- ============================================================ slots
-- 120 + 60 minutes = 3 h; open 08-17 on a 60-minute grid, capacity 1 -> starts 08:00 .. 14:00
select tests.eq((select count(*) from public.public_quote_slots(pg_temp.token(tests.fx('q1')), :'d'::date, :'d'::date)), 7::bigint,
                'seven 3-hour starts in the day');
select tests.eq((select min(starts_at) at time zone 'America/Chicago' from public.public_quote_slots(pg_temp.token(tests.fx('q1')), :'d'::date, :'d'::date)),
                (:'d' || ' 08:00')::timestamp, 'from opening time');
select tests.eq((select max(ends_at - starts_at) from public.public_quote_slots(pg_temp.token(tests.fx('q1')), :'d'::date, :'d'::date)),
                interval '3 hours', 'each as long as the quote''s work');

-- ============================================================ scheduling
select public.public_schedule_quote(pg_temp.token(tests.fx('q1')), :'d' || 'T09:00:00') as r1 \gset
select tests.eq(:'r1'::jsonb - 'job_token' - 'job_number',
                '{"status": "requested", "total_cents": 22000, "deposit_required_cents": 11000, "deposit_due_cents": 11000}'::jsonb,
                'scheduled: a requested job (no auto-confirm; 20000 + 10% tax) with the shop''s 50% deposit');
select tests.as_superuser();
select id as job1 from public.jobs where public_token = (:'r1'::jsonb ->> 'job_token')::uuid \gset
select tests.ok((select j.source = 'quote' and j.quote_id = tests.fx('q1') and j.customer_id = tests.fx('cust_a') and j.vehicle_id = tests.fx('veh_a')
                        and j.scheduled_start = (:'d' || ' 09:00')::timestamp at time zone 'America/Chicago'
                        and j.scheduled_end = (:'d' || ' 12:00')::timestamp at time zone 'America/Chicago'
                        and j.location_type = 'shop' and j.sold_by_member_id = tests.fx('m_manager_a')
                 from public.jobs j where j.id = :'job1'::uuid),
                'the job: from the quote, at the chosen time, sold by the quote''s author');
select tests.eq((select count(*) from public.job_line_items where job_id = :'job1'::uuid), 2::bigint, 'with the quote''s lines');
select tests.ok((select status = 'converted' and converted_job_id = :'job1'::uuid and self_scheduled_at = now()
                 from public.quotes where id = tests.fx('q1')), 'the quote is converted, scheduled by the customer');
select tests.eq((select count(*) from public.notifications where job_id = :'job1'::uuid and kind = 'new_booking'), 3::bigint,
                'owners, admins and managers are notified like an online booking');
select tests.eq((select count(*) from public.messages where job_id = :'job1'::uuid and template_key = 'booking_request_received'), 2::bigint,
                'the customer gets the booking request message (sms + email)');
select tests.as_anon();
select tests.eq((select jsonb_build_object('available', d -> 'available', 'converted', d -> 'converted', 'deposit', d -> 'deposit_due_cents',
                                           'job_token_ok', (d ->> 'job_token') = (:'r1'::jsonb ->> 'job_token'))
                   from (select public.public_get_quote(pg_temp.token(tests.fx('q1'))) -> 'self_schedule' as d) x),
                '{"available": false, "converted": true, "deposit": 11000, "job_token_ok": true}'::jsonb,
                'the /q page links the booking (to pay the deposit)');
select tests.eq(public.public_get_quote(pg_temp.token(tests.fx('q1'))) #> '{self_schedule,payment_pending}', 'false'::jsonb,
                'no payment on its way yet');
-- an ACH / pay-later deposit clears for days ('processing'): it is not
-- received (the deposit is still due) but it is on its way, so neither page
-- may ask for the deposit again (the payments edge refuses on payment_pending)
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_qachdep1', 'processing', 11000, 0, 'deposit', 'ach_debit',
                                    null, :'job1'::uuid, null, null, null, 'cs_qachdep1', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq((select jsonb_build_object('due', d -> 'deposit_due_cents', 'pending', d -> 'payment_pending')
                   from (select public.public_get_quote(pg_temp.token(tests.fx('q1'))) -> 'self_schedule' as d) x),
                '{"due": 11000, "pending": true}'::jsonb, 'the /q page: deposit not received yet, but a payment is on its way');
select tests.eq((select jsonb_build_object('status', d -> 'status', 'due', d -> 'due_cents', 'pending', d -> 'payment_pending')
                   from (select public.public_get_booking((:'r1'::jsonb ->> 'job_token')::uuid) -> 'deposit' as d) x),
                '{"status": "due", "due": 11000, "pending": true}'::jsonb, 'and so does the booking page it links');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_qachdep1', 'failed', 11000, 0, 'deposit', 'ach_debit',
                                    null, :'job1'::uuid, null, null, null, 'cs_qachdep1', null, null, null, 'us_bank_account');
select tests.as_anon();
select tests.eq(public.public_get_quote(pg_temp.token(tests.fx('q1'))) #> '{self_schedule,payment_pending}', 'false'::jsonb,
                'an ACH return (failed after processing) is no longer on its way: the deposit can be asked for again');
select tests.throws_like(format('select public.public_schedule_quote(%L, %L)', pg_temp.token(tests.fx('q1')), :'d' || 'T14:00:00'),
                         '22023', '%already been scheduled%', 'a quote is scheduled once');

-- capacity: the 09-12 slot is taken now
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('q2', pg_temp.approved_quote(tests.fx('cust_a2'), array[60]));
select tests.as_anon();
select tests.eq((select string_agg(to_char(starts_at at time zone 'America/Chicago', 'HH24:MI'), ',' order by starts_at)
                   from public.public_quote_slots(pg_temp.token(tests.fx('q2')), :'d'::date, :'d'::date)),
                '08:00,12:00,13:00,14:00,15:00,16:00', 'one hour of work: every free hour');
select tests.throws(format('select public.public_schedule_quote(%L, %L)', pg_temp.token(tests.fx('q2')), :'d' || 'T10:00:00'),
                    '23P01', 'a taken slot is refused');
select tests.throws(format('select public.public_schedule_quote(%L, %L)', pg_temp.token(tests.fx('q2')), :'d' || 'T12:30:00'),
                    '23P01', 'so is a time that is not a slot');
select tests.throws_like(format('select public.public_schedule_quote(%L, %L)', pg_temp.token(tests.fx('q2')), 'tomorrow'),
                         '22023', '%starts_at%', 'starts_at must be a date and time');

-- mobile service: address required, inside the service area
select tests.as_superuser();
update public.booking_settings set service_area_postal_codes = array['35203'], auto_confirm = true,
                                   deposit_type = 'fixed', deposit_value = 99999 where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.throws_like(format('select public.public_schedule_quote(%L, %L, %L)', pg_temp.token(tests.fx('q2')), :'d' || 'T12:00:00',
                                '{"type":"mobile"}'), '22023', '%street address is required%', 'mobile needs the address');
select tests.throws_like(format('select public.public_schedule_quote(%L, %L, %L)', pg_temp.token(tests.fx('q2')), :'d' || 'T12:00:00',
                                '{"type":"mobile","address_line1":"9 Elm","city":"Hoover","postal_code":"35244"}'),
                         '22023', '%outside our service area%', 'inside the service area');
select public.public_schedule_quote(pg_temp.token(tests.fx('q2')), :'d' || 'T12:00:00',
                                    '{"type":"mobile","address_line1":"9 Elm St","city":"Birmingham","postal_code":"35203"}') as r2 \gset
select tests.eq(:'r2'::jsonb - 'job_token' - 'job_number',
                '{"status": "scheduled", "total_cents": 11000, "deposit_required_cents": 11000, "deposit_due_cents": 11000}'::jsonb,
                'auto-confirmed; a fixed deposit is capped at the job total');
select tests.as_superuser();
select tests.ok((select location_type = 'mobile' and service_address_line1 = '9 Elm St' and service_postal_code = '35203'
                 from public.jobs where public_token = (:'r2'::jsonb ->> 'job_token')::uuid), 'mobile job with the service address');

-- ============================================================ switches and staff conversions
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('q3', pg_temp.approved_quote(tests.fx('cust_a3'), array[60]));
update public.quotes set self_schedule = false where id = tests.fx('q3');
select tests.as_anon();
select tests.throws_like(format('select * from public.public_quote_slots(%L, %L, %L)', pg_temp.token(tests.fx('q3')), :'d', :'d'),
                         '22023', '%cannot be scheduled online%', 'a quote staff opted out');
select tests.eq(public.public_get_quote(pg_temp.token(tests.fx('q3'))) -> 'self_schedule' -> 'available', 'false'::jsonb, 'not offered on the page');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.quotes set self_schedule = true where id = tests.fx('q3');
select public.convert_quote_to_job(tests.fx('q3'), (:'d' || ' 16:00')::timestamp at time zone 'America/Chicago',
                                   (:'d' || ' 17:00')::timestamp at time zone 'America/Chicago');
select tests.as_anon();
select tests.eq(public.public_get_quote(pg_temp.token(tests.fx('q3'))) -> 'self_schedule',
                '{"available": false, "converted": true, "job_token": null, "deposit_due_cents": null, "payment_pending": null}'::jsonb,
                'a staff conversion never exposes the booking link on the quote page');
select tests.as_superuser();
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('q4', pg_temp.approved_quote(tests.fx('cust_a3'), array[60]));
select tests.as_anon();
select tests.throws_like(format('select public.public_schedule_quote(%L, %L)', pg_temp.token(tests.fx('q4')), :'d' || 'T08:00:00'),
                         '22023', '%not available%', 'online booking off: no self-scheduling');
-- a fixed-location shop never takes mobile work
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
update public.shops set business_type = 'fixed' where id = tests.fx('shop_a');
select tests.as_anon();
select tests.throws_like(format('select * from public.public_quote_slots(%L, %L, %L, %L)', pg_temp.token(tests.fx('q4')), :'d', :'d', 'mobile'),
                         '22023', '%does not offer mobile%', 'mobile at a fixed shop is refused');

-- ============================================================ options: only the chosen option's work counts
select tests.as_superuser();
update public.shops set business_type = 'both' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q5', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q5'), 'Short', 1) returning tests.fx_set('o5s', id);
insert into public.quote_options (shop_id, quote_id, name, sort) values (tests.fx('shop_a'), tests.fx('q5'), 'Long', 2) returning tests.fx_set('o5l', id);
insert into public.quote_line_items (shop_id, quote_id, option_id, name, unit_price_cents, duration_minutes) values
  (tests.fx('shop_a'), tests.fx('q5'), tests.fx('o5s'), 'Quick', 1000, 60),
  (tests.fx('shop_a'), tests.fx('q5'), tests.fx('o5l'), 'Slow', 5000, 480);
select public.mark_quote_sent(tests.fx('q5'));
select tests.as_anon();
select public.public_respond_quote(pg_temp.token(tests.fx('q5')), 'approve', 'Aaron', '{}', null, tests.fx('o5l'));
select tests.eq((select max(ends_at - starts_at) from public.public_quote_slots(pg_temp.token(tests.fx('q5')), :'d'::date + 1, :'d'::date + 1)),
                interval '8 hours', 'the chosen (long) option decides the length');

-- ============================================================ grants
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_quote_slots(uuid, date, date, public.location_type)', 'execute')
                and has_function_privilege('anon', 'public.public_schedule_quote(uuid, text, jsonb, timestamptz)', 'execute')
                and has_function_privilege('authenticated', 'public.public_schedule_quote(uuid, text, jsonb, timestamptz)', 'execute'),
                'anyone holding the quote link may schedule it');
select tests.ok(not has_function_privilege('anon', 'public.quote_self_schedule_reason(public.quotes)', 'execute')
                and not has_function_privilege('authenticated', 'public.quote_schedule_needs(public.quotes)', 'execute'),
                'helpers are internal');
