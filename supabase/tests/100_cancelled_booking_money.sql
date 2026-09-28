-- 100 (0109): a cancelled appointment stops asking for money — its invoice
-- gets no follow-ups (queued ones are withdrawn), /i stops offering to pay
-- it, the edge cannot hold a pay link for it, and managers are told the
-- invoice is still live (a no-show keeps its invoice chasing; a grouped
-- invoice with live jobs keeps going). A cancelled / no-show booking gives
-- its coupon redemption back, so limited coupons are not drained by
-- book-and-cancel.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- ============================================================ the invoice of a cancelled booking
select tests.as_superuser();
update public.jobs set scheduled_start = now() + interval '7 days', scheduled_end = now() + interval '7 days 2 hours', status = 'scheduled'
 where id = tests.fx('job_a');
update public.followup_settings set invoice_enabled = true, invoice_first_after_hours = 1, overdue_enabled = true
 where shop_id = tests.fx('shop_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key in ('invoice_reminder', 'invoice_overdue');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv'));
select tests.as_superuser();
select tests.fx_set('inv_tok', (select public_token from public.invoices where id = tests.fx('inv')));
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv')),
                1::bigint, 'before: the sent invoice gets reminders');
insert into public.messages (shop_id, customer_id, invoice_id, direction, channel, to_address, subject, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('inv'), 'outbound', 'email', 'alice@example.com', 'Reminder', 'Please pay',
          'queued', 'invoice_reminder', now())
  returning tests.fx_set('msg', id);
select tests.ok((select public.comms_withdraw_reason(m, now()) is null from public.messages m where m.id = tests.fx('msg')),
                'before: a queued reminder would be sent');
select tests.as_anon();
select tests.eq((public.public_get_invoice(tests.fx('inv_tok')) #>> '{invoice,payable}'), 'true', 'before: /i offers to pay');

-- the customer cancels the booking online
select tests.as_superuser();
select tests.fx_set('tok', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.as_anon();
select public.public_cancel_booking(tests.fx('tok'), 'moving away') is not null;
select tests.as_superuser();
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv')),
                0::bigint, 'no reminders for the invoice of a cancelled booking');
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '30 days') where doc_id = tests.fx('inv')),
                0::bigint, 'nor overdue notices');
select tests.eq((select public.comms_withdraw_reason(m, now()) from public.messages m where m.id = tests.fx('msg')),
                'the appointment was cancelled', 'a queued reminder is withdrawn at send time');
select tests.as_anon();
select tests.eq((select jsonb_build_array(d #>> '{invoice,status}', d #>> '{invoice,payable}', d #>> '{invoice,gift_card_redeemable}')
                   from (select public.public_get_invoice(tests.fx('inv_tok')) as d) x),
                '["open", "false", "false"]'::jsonb, '/i still shows the invoice but no longer offers to pay it');
select tests.as_service();
select tests.throws_like($$select public.payments_hold_invoice_checkout(tests.fx('shop_a'), tests.fx('inv'), 'cs_test_cancelled1', now() + interval '35 minutes')$$,
                         '55000', '%appointment on this invoice was cancelled%', 'the edge cannot hold a pay link for it');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications n
                  where n.kind = 'booking_cancelled' and n.invoice_id = tests.fx('inv') and n.job_id = tests.fx('job_a')
                    and n.title = 'Job #' || (select number from public.jobs where id = tests.fx('job_a'))
                                  || ' was cancelled; invoice #' || (select number from public.invoices where id = tests.fx('inv'))
                                  || ' is still open'
                    and n.body = 'Payment reminders and online payment have stopped. Void the invoice if nothing is owed.'),
                3::bigint, 'owner, admin and manager are told the invoice is still open');
select tests.eq((select status::text from public.invoices where id = tests.fx('inv')), 'open', 'the invoice is not voided behind the owner''s back');

-- ============================================================ staff cancel a partly paid job
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select public.mark_invoice_sent(tests.fx('inv2'));
select public.record_manual_payment(tests.fx('inv2'), 5000, 'cash');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_status(tests.fx('job_a2'), 'cancelled');
select tests.as_superuser();
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv2')),
                0::bigint, 'a staff cancel stops the reminders too');
select tests.eq((select count(*) from public.notifications n
                  where n.invoice_id = tests.fx('inv2') and n.body like '$50.00 was paid on it.%refund it or keep it as a cancellation fee%'),
                3::bigint, 'the notice says what was paid');

-- ============================================================ a no-show keeps its invoice
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() - interval '1 day', now() - interval '23 hours')
  returning tests.fx_set('job_ns', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_ns'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_ns', (public.create_invoice_from_job(tests.fx('job_ns'))).id);
select public.mark_invoice_sent(tests.fx('inv_ns'));
select tests.as_superuser();
update public.jobs set status = 'no_show' where id = tests.fx('job_ns');
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv_ns')),
                1::bigint, 'a no-show''s invoice is still chased (shops bill no-shows)');

-- ============================================================ a grouped invoice with a live job keeps going
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '3 days', now() + interval '3 days 2 hours'),
         (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '4 days', now() + interval '4 days 2 hours');
select tests.fx_set('job_g1', (select id from public.jobs where customer_id = tests.fx('cust_a') and scheduled_start = now() + interval '3 days'));
select tests.fx_set('job_g2', (select id from public.jobs where customer_id = tests.fx('cust_a') and scheduled_start = now() + interval '4 days'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_g1'), tests.fx('svc_a'), 'Full Detail', 20000),
         (tests.fx('shop_a'), tests.fx('job_g2'), tests.fx('svc_a'), 'Full Detail', 20000);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_g', (public.create_invoice_from_jobs(tests.fx('cust_a'), array[tests.fx('job_g1'), tests.fx('job_g2')])).id);
select public.mark_invoice_sent(tests.fx('inv_g'));
select public.set_job_status(tests.fx('job_g1'), 'cancelled');
select tests.as_superuser();
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv_g')),
                1::bigint, 'one cancelled job of a grouped invoice does not stop it');
select tests.eq((select count(*) from public.notifications n where n.invoice_id = tests.fx('inv_g') and n.body like 'The invoice also bills other jobs%'),
                3::bigint, 'the notice asks to take the cancelled work off it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.set_job_status(tests.fx('job_g2'), 'cancelled');
select tests.as_superuser();
select tests.eq((select count(*) from public.comms_followup_candidates(now() + interval '2 hours') where doc_id = tests.fx('inv_g')),
                0::bigint, 'once every billed job is cancelled it stops');

-- ============================================================ coupons: a cancelled booking gives its redemption back
select tests.as_superuser();
select ((now() at time zone 'America/Chicago')::date + 10)::text as d1, ((now() at time zone 'America/Chicago')::date + 11)::text as d2,
       ((now() at time zone 'America/Chicago')::date + 12)::text as d3 \gset
create function pg_temp.book(p_day text, p_code text, p_email text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Nina', 'last_name', 'New', 'email', p_email),
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', p_day || 'T10:00:00',
           'coupon_code', p_code)))
$$;
grant execute on function pg_temp.book(text, text, text) to anon;
create function pg_temp.redemptions(p_code text) returns integer language sql as $$
  select redemptions from public.coupons where shop_id = tests.fx('shop_a') and code = p_code
$$;
select tests.as_anon();
select pg_temp.book(:'d1', 'LIMITED', 'nina@example.com') ->> 'job_token' as t1 \gset
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 1, 'the booking takes the only redemption');
select tests.as_anon();
select public.public_cancel_booking(:'t1', 'wrong day') is not null;
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 0, 'cancelling online gives it back');
select tests.fx_set('job_c1', (select id from public.jobs where public_token = :'t1'::uuid));
select tests.eq((select coupon_id from public.jobs where id = tests.fx('job_c1')), tests.fx('cp_limited'),
                'the cancelled job still shows the coupon it was booked with');
select set_config('x.d2', :'d2', false), set_config('x.d3', :'d3', false);
select tests.as_anon();
select tests.lives($$select pg_temp.book(current_setting('x.d2'), 'LIMITED', 'other@example.com')$$,
                   'another customer can use the limited coupon');
select tests.throws_like($$select pg_temp.book(current_setting('x.d3'), 'LIMITED', 'third@example.com')$$, '22023',
                         '%fully redeemed%', 'the limit still holds for live bookings');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 1, 'one live redemption');
select tests.fx_set('job_c2', (select id from public.jobs where coupon_id = tests.fx('cp_limited') and id <> tests.fx('job_c1')));

-- staff reopening the cancelled booking honour its coupon (even past the limit)
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_status(tests.fx('job_c1'), 'scheduled');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 2, 'reopening takes the redemption again');
-- a no-show gives it back too; deleting that job does not give it back twice
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'no_show' where id = tests.fx('job_c1');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 1, 'a no-show releases it');
delete from public.jobs where id = tests.fx('job_c1');
select tests.eq(pg_temp.redemptions('LIMITED'), 1, 'deleting the no-show job releases nothing more');
-- changing the coupon of a cancelled job validates it but holds no redemption
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_status(tests.fx('job_c2'), 'cancelled');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions('LIMITED'), 0, 'staff cancel releases it');
select redemptions as ca from public.coupons where id = tests.fx('coupon_a') \gset
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_c2');
select tests.as_superuser();
select tests.eq(jsonb_build_array(pg_temp.redemptions('LIMITED'), (select redemptions from public.coupons where id = tests.fx('coupon_a'))),
                jsonb_build_array(0, :ca), 'swapping the coupon of a cancelled job moves no redemption');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_status(tests.fx('job_c2'), 'scheduled');
select tests.as_superuser();
select tests.eq((select redemptions from public.coupons where id = tests.fx('coupon_a')), :ca + 1,
                'reopening it takes a redemption of its (new) coupon');
