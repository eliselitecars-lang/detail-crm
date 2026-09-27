-- 40 integration: public_get_booking / public_cancel_booking — curated keys
-- (nothing internal, no internal ids), totals, deposit status through
-- payments, forms with tokens, invoice link, the cancellation window
-- (allow_client_cancel_hours, status rules), staff notification, and the
-- server clock for API callers.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

insert into public.form_templates (shop_id, name, body, attach_to, requires_signature)
  values (tests.fx('shop_a'), 'Online waiver', 'I agree.', 'online_booking', false);
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 2500
 where shop_id = tests.fx('shop_a');

select tests.as_service();
create temp table bk as
  select public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z') as r;
select tests.as_superuser();
select tests.fx_set('tok', (select (r ->> 'job_token')::uuid from bk));
select tests.fx_set('job', (select id from public.jobs where public_token = tests.fx('tok')));
update public.jobs set internal_notes = 'SECRET-INTERNAL-NOTE' where id = tests.fx('job');
select tests.fx_set('form_tok', (select public_token from public.form_submissions where job_id = tests.fx('job')));
select tests.fx_set('tok_a', (select public_token from public.jobs where id = tests.fx('job_a')));
update public.customers set notes = 'SECRET-CUSTOMER-NOTE', tags = array['SECRET-TAG']
 where id = (select customer_id from public.jobs where id = tests.fx('job'));

-- ------------------------------------------------------------ public_get_booking
select tests.as_anon();
create temp table g as select public.public_get_booking(tests.fx('tok')) as d;
grant select on g to anon;
select tests.eq(pg_temp.keys((select d from g)),
                'booking,booking_message,cancellation,deposit,forms,invoice,line_items,shop,totals,vehicle',
                'top-level keys (no customer details: anyone can mint a booking token for an email)');
select tests.eq(pg_temp.keys((select d -> 'booking' from g)),
                'cancel_reason,cancelled_at,completed_at,confirmed_at,created_at,location_type,notes,number,scheduled_end,scheduled_start,service_address,status',
                'booking keys');
select tests.ok((select d::text not like '%Nina%' and d::text not like '%nina@example.com%' and d::text not like '%555-0142%' from g),
                'no customer name, email or phone');
select tests.eq(pg_temp.keys((select d -> 'totals' from g)),
                'balance_cents,coupon_code,discount_cents,paid_cents,subtotal_cents,tax_cents,tax_rate_bps,total_cents', 'totals keys');
select tests.eq(pg_temp.keys((select d -> 'deposit' from g)),
                'card_payments_enabled,due_cents,paid_cents,payment_pending,required_cents,status', 'deposit keys');
select tests.eq(pg_temp.keys((select d -> 'cancellation' from g)), 'allow_client_cancel_hours,allowed,deadline,policy', 'cancellation keys');
select tests.eq(pg_temp.keys((select d -> 'forms' -> 0 from g)), 'requires_signature,signed_at,status,title,token', 'form keys');
select tests.eq(pg_temp.keys((select d -> 'line_items' -> 0 from g)),
                'description,discount_cents,name,quantity,taxable,total_cents,unit_price_cents,vehicle_label', 'line keys');
select tests.ok((select d::text not like '%SECRET%' from g), 'no internal notes, customer notes or tags');
select tests.ok((select d::text not like '%' || tests.fx('job')::text || '%'
                    and d::text not like '%' || tests.fx('shop_a')::text || '%'
                    and d::text not like '%acct_%' from g), 'no internal ids or Stripe ids');
select tests.eq((select d #>> '{booking,status}' from g), 'requested', 'status');
select tests.eq((select d #>> '{booking,scheduled_start}' from g)::timestamptz, '2025-06-09 15:00Z'::timestamptz, 'start');
select tests.ok((select d -> 'booking' -> 'service_address' = 'null'::jsonb from g), 'in-shop: no service address');
select tests.eq((select d -> 'totals' from g),
                '{"subtotal_cents": 20000, "discount_cents": 0, "coupon_code": null, "tax_rate_bps": 1000, "tax_cents": 2000,
                  "total_cents": 22000, "paid_cents": 0, "balance_cents": 22000}'::jsonb, 'totals');
select tests.eq((select d -> 'deposit' from g),
                '{"required_cents": 5500, "paid_cents": 0, "due_cents": 5500, "status": "due", "payment_pending": false,
                  "card_payments_enabled": true}'::jsonb, 'deposit due');
select tests.eq((select d #>> '{vehicle,model}' from g), 'Camry', 'vehicle');
select tests.eq((select d #>> '{shop,name}' from g), 'Shop A', 'shop');
select tests.eq((select d ->> 'booking_message' from g), 'See you soon', 'booking message');
select tests.eq((select d #>> '{forms,0,title}' from g), 'Online waiver', 'online-booking forms are attached');
select tests.eq((select d #>> '{forms,0,status}' from g), 'pending', 'unsigned');
select tests.eq((select (d #>> '{forms,0,token}')::uuid from g), tests.fx('form_tok'), 'form token for /f/:token');
select tests.ok((select d -> 'invoice' = 'null'::jsonb from g), 'no invoice yet');
select tests.ok((select (d #>> '{cancellation,allowed}')::boolean = false from g),
                'anon uses the server clock: a 2025 appointment is past its cancellation deadline');
drop table g;

select tests.as_anon();
select tests.throws($$select public.public_get_booking(gen_random_uuid())$$, 'P0002', 'unknown token');
select tests.throws($$select public.public_get_booking(null)$$, 'P0002', 'null token');
select tests.eq(public.public_get_booking(tests.fx('tok_a')) #>> '{booking,notes}',
                'Gate code 1234', 'staff-created jobs have booking pages too (customer-visible notes)');
select tests.ok(public.public_get_booking(tests.fx('tok_a'))::text not like '%Customer is picky%', 'but never internal notes');

-- trusted clock: inside the window
select tests.as_service();
select tests.eq(public.public_get_booking(tests.fx('tok'), '2025-06-01 12:00Z') -> 'cancellation',
                '{"allowed": true, "deadline": "2025-06-08T15:00:00+00:00", "allow_client_cancel_hours": 24,
                  "policy": "Cancel 24 hours ahead"}'::jsonb, 'cancellable until 24 h before the start');
select tests.eq(public.public_get_booking(tests.fx('tok'), '2025-06-08 15:00:01Z') #>> '{cancellation,allowed}', 'false',
                'not after the deadline');

-- deposit through payments
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'pending', 5500, 0, 'deposit', 'card',
                                    null, tests.fx('job'));
select tests.eq(public.public_get_booking(tests.fx('tok')) #>> '{deposit,payment_pending}', 'true', 'a pending checkout shows');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5500, 0, 'deposit', 'card',
                                    null, tests.fx('job'), null, null, 'ch_1', null, 'visa', '4242', '2025-06-02 12:00Z');
select tests.eq(public.public_get_booking(tests.fx('tok')) -> 'deposit',
                '{"required_cents": 5500, "paid_cents": 5500, "due_cents": 0, "status": "paid", "payment_pending": false,
                  "card_payments_enabled": true}'::jsonb, 'deposit paid');
select tests.eq(public.public_get_booking(tests.fx('tok')) #>> '{totals,balance_cents}', '16500', 'balance after the deposit');

-- invoice link once issued
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.create_invoice_from_job(tests.fx('job'));
select tests.as_anon();
select tests.eq(pg_temp.keys(public.public_get_booking(tests.fx('tok')) -> 'invoice'), 'balance_cents,due_at,number,status,token,total_cents',
                'invoice keys');
select tests.eq(public.public_get_booking(tests.fx('tok')) #>> '{invoice,balance_cents}', '16500', 'the invoice carries the deposit');
select tests.as_superuser();
select tests.fx_set('inv_tok', (select public_token from public.invoices where job_id = tests.fx('job')));
select tests.as_anon();
select tests.eq((public.public_get_booking(tests.fx('tok')) #>> '{invoice,token}')::uuid, tests.fx('inv_tok'), 'invoice token for /i/:token');

-- ------------------------------------------------------------ public_cancel_booking (trusted clock)
select tests.as_service();
select tests.throws_like($$select public.public_cancel_booking(tests.fx('tok'), 'plans changed', '2025-06-08 16:00Z')$$, '22023',
                         '%closed 24 hours before%', 'inside the 24-hour window: refused');
select tests.throws($$select public.public_cancel_booking(gen_random_uuid())$$, 'P0002', 'unknown token');
select tests.throws_like($$select public.public_cancel_booking(tests.fx('tok'), repeat('x', 1001), '2025-06-01 12:00Z')$$, '22023',
                         '%too long%', 'reason length');
create temp table c as select public.public_cancel_booking(tests.fx('tok'), '  plans changed  ', '2025-06-08 14:00Z') as d;
select tests.eq((select d #>> '{booking,status}' from c), 'cancelled', 'cancelled');
select tests.eq((select d #>> '{booking,cancel_reason}' from c), 'plans changed', 'reason trimmed');
select tests.eq((select d #>> '{cancellation,allowed}' from c), 'false', 'cannot be cancelled again');
select tests.eq((select d #>> '{forms,0,status}' from c), 'void', 'unsigned forms of a cancelled booking are void');
select tests.as_superuser();
select tests.ok((select status = 'cancelled' and cancelled_at is not null from public.jobs where id = tests.fx('job')), 'job row cancelled');
select tests.eq((select count(*) from public.notifications
                  where job_id = tests.fx('job') and kind = 'booking_cancelled' and title = 'Booking cancelled by Nina New'
                    and body = 'Job #' || (select number from public.jobs where id = tests.fx('job')) || ' · Monday, June 9 at 10:00 AM · plans changed'),
                3::bigint, 'owner/admin/manager notified once each');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_b')), 0::bigint, 'nothing in shop B');
select tests.as_service();
select tests.throws_like($$select public.public_cancel_booking(tests.fx('tok'), null, '2025-06-01 12:00Z')$$, '22023',
                         '%can no longer be cancelled online (it is cancelled)%', 'a cancelled booking cannot be cancelled again');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'booking_cancelled'), 3::bigint, 'still one set of notifications');
select tests.ok(exists (select 1 from public.get_available_slots('shop-a', array[tests.fx('svc_a')], null, '2025-06-09', '2025-06-09',
                                                                 '2025-06-01 12:00Z') s where s.starts_at = '2025-06-09 15:00Z'),
                'the cancelled slot is free again');

-- status rules and the 0-hour setting
select tests.as_service();
select tests.fx_set('tok2', (public.create_online_booking('shop-a', pg_temp.booking(
                      jsonb_build_object('starts_at', '2025-06-10T15:00:00Z',
                                         'customer', jsonb_build_object('first_name', 'Oscar', 'email', 'oscar@example.com'))),
                      '2025-06-01 12:00Z') ->> 'job_token')::uuid);
select tests.as_superuser();
update public.booking_settings set allow_client_cancel_hours = 0 where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.throws($$select public.public_cancel_booking(tests.fx('tok2'), null, '2025-06-10 15:00:01Z')$$, '22023',
                    '0 hours: not after the start');
select tests.as_superuser();
update public.jobs set status = 'scheduled' where public_token = tests.fx('tok2');
update public.jobs set status = 'in_progress' where public_token = tests.fx('tok2');
select tests.as_service();
select tests.throws_like($$select public.public_cancel_booking(tests.fx('tok2'), null, '2025-06-01 12:00Z')$$, '22023',
                         '%(it is in progress)%', 'work has started: refused');
select tests.as_superuser();
update public.jobs set status = 'scheduled' where public_token = tests.fx('tok2');
select tests.as_service();
select tests.eq(public.public_cancel_booking(tests.fx('tok2'), '', '2025-06-10 14:59Z') #>> '{booking,cancel_reason}',
                'Cancelled by the customer online', '0 hours: allowed up to the start; blank reason gets a default');

-- unscheduled requests (staff-created) can always be cancelled
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('tok3', public_token);
select tests.as_anon();
select tests.eq(public.public_cancel_booking(tests.fx('tok3')) #>> '{booking,status}', 'cancelled', 'no start time: no deadline');

-- ------------------------------------------------------------ API callers use the server clock
select tests.as_superuser();
update public.booking_settings set allow_client_cancel_hours = 24 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '1 hour', now() + interval '2 hours')
  returning tests.fx_set('tok_soon', public_token);
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'confirmed', now() + interval '3 days', now() + interval '3 days 1 hour')
  returning tests.fx_set('tok_later', public_token);
select tests.as_anon();
select tests.throws_like($$select public.public_cancel_booking(tests.fx('tok_soon'), 'x', now() - interval '2 days')$$, '22023',
                         '%closed%', 'anon cannot rewind the clock to get back inside the window');
select tests.eq(public.public_get_booking(tests.fx('tok_soon'), now() - interval '2 days') #>> '{cancellation,allowed}', 'false',
                'nor to show the cancel button');
select tests.eq(public.public_cancel_booking(tests.fx('tok_later'), 'x', now() + interval '10 days') #>> '{booking,status}', 'cancelled',
                'anon cancels a booking 3 days out (a future p_now is ignored too)');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.public_cancel_booking(tests.fx('tok_soon'))$$, '22023', 'signed-in callers too');
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_cancel_booking(uuid, text, timestamptz)', 'execute'), 'anon may cancel by token');
select tests.ok(has_function_privilege('anon', 'public.public_get_booking(uuid, timestamptz)', 'execute'), 'anon may view by token');
