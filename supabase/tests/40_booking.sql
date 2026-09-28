-- 40 integration: create_online_booking — the full anonymous happy path
-- (real server clock), price tampering, every validation failure, slot
-- re-validation (double booking, capacity, grid, hours, lead time, window),
-- the per-shop advisory lock, deposits, auto-confirm, mobile service area,
-- and cross-shop isolation. Time-controlled cases run as service_role with
-- p_now; anon callers always get the server clock.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- expected error helper: runs a booking as the current role
create function pg_temp.book(p_payload jsonb, p_slug text default 'shop-a', p_now timestamptz default '2025-06-01 12:00Z')
returns jsonb language sql as $$ select public.create_online_booking(p_slug, p_payload, p_now) $$;
grant execute on function pg_temp.book(jsonb, text, timestamptz) to anon, authenticated, service_role;
-- a booking by guest n (own email and phone, so the daily limit never trips)
create function pg_temp.guest(p_n integer, p_overrides jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(pg_temp.booking(p_overrides),
           '{customer,email}', to_jsonb('guest' || p_n || '@example.com')),
           '{customer,phone}', to_jsonb('+1205555' || lpad(p_n::text, 4, '0'))),
           '{customer,first_name}', '"Guest"'), '{customer,last_name}', to_jsonb('N' || p_n))
$$;
grant execute on function pg_temp.guest(integer, jsonb) to anon, authenticated, service_role;

-- ============================================================ anonymous happy path (server clock)
-- a real future slot: three days from today (shop time), first opening
create temp table anon_slot as
  select min(s.starts_at) as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a'), tests.fx('addon_pet')], (now() at time zone 'America/Chicago')::date + 3,
                                  (now() at time zone 'America/Chicago')::date + 3,
                                  tests.fx('cat_car_a')) s;
grant select on anon_slot to anon;
select tests.ok((select starts_at is not null from anon_slot), 'a future slot exists for the anonymous booking');

select tests.as_anon();
create temp table anon_res as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'starts_at', (select to_char(starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') from anon_slot),
           'addon_ids', jsonb_build_array(tests.fx('addon_pet')),
           -- tampering attempts: all ignored
           'total_cents', 1, 'subtotal_cents', 1, 'deposit_required_cents', 0, 'status', 'completed',
           'prices', jsonb_build_object(tests.fx('svc_a')::text, 1),
           'line_items', jsonb_build_array(jsonb_build_object('name', 'Free stuff', 'unit_price_cents', 0))))) as r;
select tests.eq(pg_temp.keys((select r from anon_res)), 'deposit_required_cents,job_number,job_token,status,total_cents',
                'result keys are exactly the documented ones');
select tests.eq((select r ->> 'status' from anon_res), 'requested', 'not auto-confirmed: requested');
select tests.eq((select (r ->> 'total_cents')::bigint from anon_res), 26000::bigint,
                'total from the catalog only: 20000 + 4000 + 10% tax on 20000 (client prices ignored)');
select tests.eq((select (r ->> 'deposit_required_cents')::bigint from anon_res), 0::bigint, 'no deposit required');

select tests.as_superuser();
select tests.fx_set('anon_job', (select j.id from public.jobs j join anon_res on j.public_token = (anon_res.r ->> 'job_token')::uuid));
select tests.ok((select j.source = 'online_booking' and j.status = 'requested' and j.location_type = 'shop'
                        and j.scheduled_start = (select starts_at from anon_slot)
                        and j.scheduled_end = (select starts_at from anon_slot) + interval '150 minutes'
                        and j.notes = 'Please park in the back' and j.created_by is null and j.coupon_id is null
                        and j.discount_kind = 'none' and j.subtotal_cents = 24000 and j.tax_cents = 2000
                        and j.number = (select (r ->> 'job_number')::bigint from anon_res)
                        and j.internal_notes is null
                   from public.jobs j where j.id = tests.fx('anon_job')),
                'job: online_booking source, requested, exact slot (150 min), notes, catalog totals');
select tests.fx_set('nina', (select customer_id from public.jobs where id = tests.fx('anon_job')));
select tests.ok((select c.first_name = 'Nina' and c.last_name = 'New' and c.email = 'nina@example.com'
                        and c.phone = '+12055550142' and c.sms_opt_in and not c.email_opt_in
                        and c.source = 'online_booking' and c.portal_user_id is null and c.shop_id = tests.fx('shop_a')
                   from public.customers c where c.id = tests.fx('nina')),
                'new customer: normalized phone, opt-ins, source online_booking, not linked');
select tests.ok((select v.year = 2020 and v.make = 'Toyota' and v.model = 'Camry' and v.color = 'Blue'
                        and v.category_id = tests.fx('cat_car_a') and v.customer_id = tests.fx('nina')
                   from public.vehicles v join public.jobs j on j.vehicle_id = v.id where j.id = tests.fx('anon_job')),
                'new vehicle for the customer');
select tests.eq((select jsonb_agg(jsonb_build_object('name', li.name, 'service', li.service_id, 'price', li.unit_price_cents,
                                                     'taxable', li.taxable, 'minutes', li.duration_minutes, 'qty', li.quantity,
                                                     'sort', li.sort, 'veh', li.vehicle_id = j.vehicle_id)
                                  order by li.sort)
                   from public.job_line_items li join public.jobs j on j.id = li.job_id where li.job_id = tests.fx('anon_job')),
                jsonb_build_array(
                  jsonb_build_object('name', 'Full Detail', 'service', tests.fx('svc_a'), 'price', 20000, 'taxable', true,
                                     'minutes', 120, 'qty', 1, 'sort', 1, 'veh', true),
                  jsonb_build_object('name', 'Pet Hair', 'service', tests.fx('addon_pet'), 'price', 4000, 'taxable', false,
                                     'minutes', 30, 'qty', 1, 'sort', 2, 'veh', true)),
                'line items priced from the catalog, services then add-ons, on the booked vehicle');
select tests.eq((select count(*) from public.notifications
                  where job_id = tests.fx('anon_job') and kind = 'new_booking' and title = 'New booking request from Nina New'),
                3::bigint, 'owner, admin and manager are notified once each');
select tests.eq((select count(*) from public.notifications n join public.shop_members m on m.user_id = n.user_id and m.shop_id = n.shop_id
                  where n.job_id = tests.fx('anon_job') and m.role = 'technician'), 0::bigint, 'technicians are not notified');
select tests.eq((select string_agg(channel::text || ':' || to_address, ',' order by channel)
                   from public.messages where job_id = tests.fx('anon_job') and template_key = 'booking_request_received'),
                'email:nina@example.com',
                'booking_request_received is emailed; never texted to the phone an anonymous booker typed (0104)');
select tests.ok((select body like 'Hi there,%'
                        and body like '%https://app.example.test/booking/' || (select r ->> 'job_token' from anon_res) || '%'
                        and body not like '%Nina%' and body not like '%Toyota%' and body not like '%Vehicle:%'
                   from public.messages where job_id = tests.fx('anon_job') and channel = 'email'),
                'the email carries the booking link and nothing the anonymous booker typed (no name, no vehicle)');
select tests.ok((select body like '%Services: Full Detail, Pet Hair%' from public.messages
                  where job_id = tests.fx('anon_job') and channel = 'email'), 'the email lists the booked services');
select tests.eq((select count(*) from public.messages where job_id = tests.fx('anon_job') and template_key = 'booking_confirmed'),
                0::bigint, 'no confirmation for a request');

-- the anon caller's clock is ignored: a 2025 slot is in the past for the server
select tests.as_anon();
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z')$$, '23P01',
                         '%no longer available%', 'anon cannot book in the past by passing p_now');

-- ============================================================ validation (service_role, p_now = 2025-06-01 12:00Z)
select tests.as_superuser();
update public.booking_settings set enabled = false where shop_id = tests.fx('shop_b');
select tests.as_service();
select tests.throws($$select pg_temp.book(pg_temp.booking(), 'nope')$$, 'PT404', 'unknown shop');
select tests.throws($$select pg_temp.book(pg_temp.booking(), null)$$, 'PT404', 'null slug');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_b'))), 'shop-b')$$,
                         '55000', '%not enabled%', 'online booking disabled');
select tests.throws_like($$select pg_temp.book('[]'::jsonb)$$, '22023', '%JSON object%', 'payload must be an object');
select tests.throws_like($$select pg_temp.book(null)$$, '22023', '%JSON object%', 'null payload');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() - 'vehicle')$$, '22023', '%vehicle details%', 'vehicle required');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"customer": "x"}')$$, '22023', '%customer must be%', 'customer shape');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": 5}')$$, '22023', '%location must be%', 'location shape');

-- services
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"service_ids": []}')$$, '22023', '%at least one service%', 'no services');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() - 'service_ids')$$, '22023', '%at least one service%', 'missing services');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"service_ids": "x"}')$$, '22023', '%list of ids%', 'services must be a list');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"service_ids": ["not-a-uuid"]}')$$, '22023', '%list of ids%', 'bad id');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids',
                           (select jsonb_agg(gen_random_uuid()) from generate_series(1, 21))))$$, '22023', '%too many%', 'at most 20 services');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_b'))))$$,
                         '22023', '%not available for online booking%', 'another shop''s service');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_hidden'))))$$,
                         '22023', '%not available for online booking%', 'not online-bookable');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_inactive'))))$$,
                         '22023', '%not available for online booking%', 'inactive service');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('prod_a'))))$$,
                         '22023', '%not available for online booking%', 'products');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('addon_pet'))))$$,
                         '22023', '%not available for online booking%', 'an add-on is not a main service');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('addon_ids', jsonb_build_array(tests.fx('svc_wash'))))$$,
                         '22023', '%add-ons are not available%', 'a service is not an add-on');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_wash')),
                                                                                        'addon_ids', jsonb_build_array(tests.fx('addon_pet'))))$$,
                         '22023', '%not offered with the selected services%', 'add-on not linked to the chosen service');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_van'))))$$,
                         '22023', '%not offered for this vehicle type%', 'no catalog price for the vehicle category');

-- when
select tests.throws_like($$select pg_temp.book(pg_temp.booking() - 'starts_at')$$, '22023', '%starts_at is required%', 'start required');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "now"}')$$, '22023', '%ISO-8601%', '"now" is not a time');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-13-45T10:00:00Z"}')$$, '22023', '%ISO-8601%', 'invalid date');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": true}')$$, '22023', '%must be text%', 'wrong type');

-- vehicle
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"vehicle": {"model": "Camry"}}')$$, '22023', '%make is required%', 'make');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"vehicle": {"make": "Toyota"}}')$$, '22023', '%model is required%', 'model');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"vehicle": {"make": "Toyota", "model": "Camry", "year": 1700}}')$$,
                         '22023', '%year must be between%', 'year range');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"vehicle": {"make": "Toyota", "model": "Camry", "year": "twenty"}}')$$,
                         '22023', '%whole number%', 'year type');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"vehicle": {"make": "Toyota", "model": "Camry", "vin": "IO!"}}')$$,
                         '22023', '%VIN%', 'VIN format');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('vehicle', jsonb_build_object('make', repeat('x', 61), 'model', 'Camry')))$$,
                         '22023', '%too long%', 'make length');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('vehicle', jsonb_build_object('make', 'Toyota', 'model', 'Camry',
                                                                                        'category_id', tests.fx('cat_car_b'))))$$,
                         '22023', '%unknown vehicle category%', 'another shop''s vehicle category');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('vehicle', jsonb_build_object('id', tests.fx('veh_a'))))$$,
                         'PT404', '%vehicle not found%', 'a saved vehicle needs its signed-in owner');

-- contact
select tests.throws_like($$select pg_temp.book(pg_temp.booking() - 'customer')$$, '22023', '%contact details%', 'contact required');
select tests.throws_like($$select pg_temp.book(jsonb_set(pg_temp.booking(), '{customer,first_name}', '"  "'))$$, '22023',
                         '%first name is required%', 'blank first name');
select tests.throws_like($$select pg_temp.book(jsonb_set(pg_temp.booking(), '{customer,first_name}', to_jsonb(repeat('x', 101))))$$, '22023',
                         '%too long%', 'first name length');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() #- '{customer,email}')$$, '22023', '%email is required%', 'email required');
select tests.throws_like($$select pg_temp.book(jsonb_set(pg_temp.booking(), '{customer,email}', '"not-an-email"'))$$, '22023',
                         '%valid email%', 'email format');
select tests.throws_like($$select pg_temp.book(jsonb_set(pg_temp.booking(), '{customer,phone}', '"555-01"'))$$, '22023',
                         '%valid phone%', 'phone format');
select tests.throws_like($$select pg_temp.book(jsonb_set(pg_temp.booking(), '{customer,sms_opt_in}', '"yes"'))$$, '22023',
                         '%true or false%', 'opt-in must be boolean');

-- where
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": {"type": "moon"}}')$$, '22023', '%shop or mobile%', 'location type');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": {"type": "mobile", "city": "Birmingham", "postal_code": "35203"}}')$$,
                         '22023', '%street address is required%', 'mobile needs an address');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": {"type": "mobile", "address_line1": "9 Elm", "city": "Birmingham"}}')$$,
                         '22023', '%postal code is required%', 'mobile needs a postal code');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('notes', repeat('x', 2001)))$$, '22023',
                         '%notes is too long%', 'notes length');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || jsonb_build_object('coupon_code', repeat('x', 41)))$$, '22023',
                         '%coupon code is too long%', 'coupon code length');
select tests.as_superuser();
update public.booking_settings set service_area_postal_codes = array['35203', '35205'] where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": {"type": "mobile", "address_line1": "9 Elm", "city": "Hoover", "postal_code": "35244"}}')$$,
                         '22023', '%outside our service area%', 'outside the service area');
select tests.as_superuser();
update public.shops set business_type = 'fixed' where id = tests.fx('shop_a');
select tests.as_service();
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"location": {"type": "mobile", "address_line1": "9 Elm", "city": "Birmingham", "postal_code": "35203"}}')$$,
                         '22023', '%does not offer mobile%', 'fixed-location shop');
select tests.as_superuser();
update public.shops set business_type = 'mobile' where id = tests.fx('shop_a');
select tests.as_service();
select tests.throws_like($$select pg_temp.book(pg_temp.booking())$$, '22023', '%only offers mobile%', 'mobile-only shop');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() - 'location')$$, '22023', '%street address is required%',
                         'a mobile-only shop defaults to mobile and needs the address');

-- coupons
select tests.as_superuser();
update public.shops set business_type = 'both' where id = tests.fx('shop_a');
select tests.as_service();
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"coupon_code": "NOPE"}')$$, '22023', '%not valid%', 'unknown coupon');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"coupon_code": "EXPIRED"}')$$, '22023', '%expired%', 'expired coupon');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"coupon_code": "FUTURE"}')$$, '22023', '%not active yet%', 'future coupon');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"coupon_code": "OFF"}')$$, '22023', '%no longer active%', 'inactive coupon');
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_a') and source = 'online_booking'), 1::bigint,
                'no failed attempt left a job behind');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and source = 'online_booking'), 1::bigint,
                'no failed attempt left a customer behind');

-- ============================================================ slots & double booking
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-09T15:30:00Z"}')$$, '23P01',
                         '%no longer available%', 'off the slot grid');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-09T03:00:00Z"}')$$, '23P01',
                         '%no longer available%', 'outside business hours');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-09T21:00:00Z"}')$$, '23P01',
                         '%no longer available%', 'would run past closing (16:00 + 120 min > 17:00)');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-02T15:00:00Z"}')$$, '23P01',
                         '%no longer available%', 'overlaps an existing staff job (job_a)');
select tests.throws_like($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-05-30T15:00:00Z"}')$$, '23P01',
                         '%no longer available%', 'in the past relative to p_now');
select tests.as_superuser();
update public.booking_settings set lead_time_minutes = 10080 where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.throws($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-05T15:00:00Z"}')$$, '23P01',
                    'inside the lead time (7 days)');
select tests.as_superuser();
update public.booking_settings set lead_time_minutes = 0, max_days_ahead = 5 where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.throws($$select pg_temp.book(pg_temp.booking())$$, '23P01', 'beyond max_days_ahead');
select tests.as_superuser();
update public.booking_settings set max_days_ahead = 365 where shop_id = tests.fx('shop_a');
insert into public.blocked_times (shop_id, starts_at, ends_at, reason) values
  (tests.fx('shop_a'), '2025-06-10 15:00Z', '2025-06-10 16:00Z', 'Closed');
select tests.as_service();
select tests.throws($$select pg_temp.book(pg_temp.booking() || '{"starts_at": "2025-06-10T15:00:00Z"}')$$, '23P01',
                    'a shop-wide blocked time');

-- first booking of the slot succeeds, holds the shop's advisory lock
select tests.fx_set('b1', (pg_temp.book(pg_temp.guest(1)) ->> 'job_token')::uuid);
select tests.as_superuser();
select tests.ok(exists (
                  select 1
                  from pg_locks l,
                       lateral (select hashtextextended('public.create_online_booking:' || tests.fx('shop_a')::text, 0) as k) h
                  where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.granted and l.objsubid = 1
                    and l.classid::bigint = (h.k >> 32) & 4294967295
                    and l.objid::bigint = h.k & 4294967295),
                'bookings take the per-shop transaction advisory lock (held until commit)');
select tests.eq((select count(*) from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid()), 1::bigint,
                'one lock per shop, however many bookings the transaction makes');
select tests.as_service();
-- the same slot is gone for everybody (capacity 1)
select tests.throws_like($$select pg_temp.book(pg_temp.guest(2))$$, '23P01',
                         '%no longer available%', 'double booking the same slot is refused');
select tests.throws($$select pg_temp.book(pg_temp.guest(2, '{"starts_at": "2025-06-09T16:00:00Z"}'))$$, '23P01',
                    'an overlapping start is refused too');
select tests.lives($$select pg_temp.book(pg_temp.guest(2, '{"starts_at": "2025-06-09T17:00:00Z"}'))$$, 'the next free slot books');
select tests.as_superuser();
update public.booking_settings set max_concurrent_jobs = 2 where shop_id = tests.fx('shop_a');
select tests.as_service();
select tests.lives($$select pg_temp.book(pg_temp.guest(3))$$, 'capacity 2 allows a second concurrent booking');
select tests.throws($$select pg_temp.book(pg_temp.guest(4))$$, '23P01', 'but not a third');
-- a cancelled booking frees its slot
select tests.as_superuser();
update public.jobs set status = 'cancelled' where public_token = tests.fx('b1');
select tests.as_service();
select tests.lives($$select pg_temp.book(pg_temp.guest(4))$$, 'cancelled jobs free their capacity');
select tests.as_superuser();
update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');

-- ============================================================ deposits
create function pg_temp.deposit_for(p_n integer, p_type public.deposit_type, p_value bigint, p_payload jsonb default '{}')
returns bigint language plpgsql as $$
declare
  r jsonb;
begin
  update public.booking_settings set require_deposit = true, deposit_type = p_type, deposit_value = p_value
   where shop_id = tests.fx('shop_a');
  r := public.create_online_booking('shop-a', pg_temp.guest(p_n, p_payload), '2025-06-01 12:00Z');
  update public.booking_settings set require_deposit = false, deposit_value = 0 where shop_id = tests.fx('shop_a');
  if (select deposit_required_cents from public.jobs where public_token = (r ->> 'job_token')::uuid)
     <> (r ->> 'deposit_required_cents')::bigint then
    raise exception 'returned deposit differs from the stored one';
  end if;
  return (r ->> 'deposit_required_cents')::bigint;
end
$$;
select tests.eq(pg_temp.deposit_for(11, 'percent', 2500), 5500::bigint, '25% of the 22000 total');
select tests.eq(pg_temp.deposit_for(12, 'percent', 3333), 7333::bigint, 'percent rounds half up (7332.6)');
select tests.eq(pg_temp.deposit_for(13, 'percent', 10000), 22000::bigint, '100% = the total');
select tests.eq(pg_temp.deposit_for(14, 'fixed', 5000), 5000::bigint, 'fixed deposit');
select tests.eq(pg_temp.deposit_for(15, 'fixed', 50000), 22000::bigint, 'a fixed deposit is capped at the total');
select tests.eq(pg_temp.deposit_for(16, 'percent', 5000, '{"coupon_code": "FIXED25"}'), 9625::bigint,
                'deposit on the discounted total ((20000 - 2500) * 1.1 = 19250 -> 50%)');
select tests.eq((select (pg_temp.book(pg_temp.guest(17)) ->> 'deposit_required_cents')::bigint),
                0::bigint, 'no deposit when not required');

-- ============================================================ auto-confirm
update public.booking_settings set auto_confirm = true where shop_id = tests.fx('shop_a');
select tests.as_service();
create temp table ac as
  select pg_temp.book(pg_temp.guest(20)) as r;
select tests.eq((select r ->> 'status' from ac), 'scheduled', 'auto-confirm books straight to scheduled');
select tests.as_superuser();
select tests.fx_set('ac_job', (select id from public.jobs where public_token = (select (r ->> 'job_token')::uuid from ac)));
select tests.eq((select string_agg(template_key::text || ':' || channel::text, ',' order by channel)
                   from public.messages where job_id = tests.fx('ac_job')),
                'booking_confirmed:email',
                'booking_confirmed (not request_received) is queued: emailed, not texted to the guest''s unverified phone');
select tests.eq((select count(*) from public.notifications where job_id = tests.fx('ac_job') and title = 'New booking from Guest N20'),
                3::bigint, 'staff notified of the confirmed booking');
select tests.eq((select string_agg(event, ',' order by event) from public.integration_events where job_id = tests.fx('ac_job')),
                'booking_confirmed,booking_created', 'both events are claimed');
-- a later scheduled -> confirmed by staff does not re-send
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'confirmed' where id = tests.fx('ac_job');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where job_id = tests.fx('ac_job')), 1::bigint, 'no second confirmation');
update public.booking_settings set auto_confirm = false where shop_id = tests.fx('shop_a');

-- ============================================================ mobile bookings
select tests.as_service();
create temp table mob as
  select pg_temp.book(pg_temp.guest(21, '{"location": {"type": "mobile", "address_line1": " 9 Elm St ", "address_line2": "Apt 2",
                                                     "city": "Birmingham", "region": "AL", "postal_code": "35205-1234"}}')) as r;
select tests.as_superuser();
select tests.ok((select location_type = 'mobile' and service_address_line1 = '9 Elm St' and service_address_line2 = 'Apt 2'
                        and service_city = 'Birmingham' and service_region = 'AL' and service_postal_code = '35205-1234'
                   from public.jobs where public_token = (select (r ->> 'job_token')::uuid from mob)),
                'mobile job stores the (trimmed) service address; ZIP+4 inside the area');
select tests.ok((select c.address_line1 = '9 Elm St' and c.postal_code = '35205-1234'
                   from public.customers c join public.jobs j on j.customer_id = c.id
                  where j.public_token = (select (r ->> 'job_token')::uuid from mob)),
                'the new customer''s empty address is filled from the booking');

-- ============================================================ shop B isolation
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_b');
select tests.as_anon();
select tests.throws_like($$select public.create_online_booking('shop-b', pg_temp.booking())$$, '22023',
                         '%not available for online booking%', 'shop A services cannot be booked through shop B');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b')), 1::bigint, 'shop B untouched');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_b')), 0::bigint, 'no shop B notifications');

-- ============================================================ access
select tests.ok(has_function_privilege('anon', 'public.create_online_booking(text, jsonb, timestamptz)', 'execute'), 'anon may book');
select tests.ok(has_function_privilege('authenticated', 'public.create_online_booking(text, jsonb, timestamptz)', 'execute'),
                'signed-in users may book');
select tests.ok(not has_function_privilege('anon', 'public.integration_online_booking_created(uuid)', 'execute'),
                'the side-effect helper is internal');
select tests.ok(not has_function_privilege('authenticated', 'public.booking_public_json(uuid, timestamptz)', 'execute'),
                'the booking JSON builder is internal');
