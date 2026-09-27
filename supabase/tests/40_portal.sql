-- 40 integration: portal_claim_customers / portal_overview — linking only
-- for a CONFIRMED email (across shops, case-insensitive; archived customers
-- and customers linked to someone else are left alone), the curated overview
-- (exact key sets, nothing internal, only the caller's own records), and
-- role access.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
select tests.fx_set('u_alice_unconfirmed', tests.create_user('alice2@example.com', false));
select tests.fx_set('u_mallory', tests.create_user('mallory@example.com'));

-- Alice also shops at B (email in another case), has an archived duplicate in A,
-- and a record in A that someone else already claimed
insert into public.customers (shop_id, first_name, email, phone, notes, tags, stripe_customer_id)
  values (tests.fx('shop_b'), 'Alice', 'ALICE@example.com', '+12055550101', 'SECRET-NOTE-B', array['SECRET-TAG'], 'cus_SECRET1')
  returning tests.fx_set('cust_alice_b', id);
insert into public.customers (shop_id, first_name, email, archived_at)
  values (tests.fx('shop_a'), 'Alice (old)', 'alice@example.com', now()) returning tests.fx_set('cust_alice_arch', id);
insert into public.customers (shop_id, first_name, email, portal_user_id)
  values (tests.fx('shop_a'), 'Alice (claimed)', 'alice@example.com', tests.fx('u_mallory')) returning tests.fx_set('cust_alice_taken', id);
update public.customers set notes = 'SECRET-NOTE-A', stripe_customer_id = 'cus_SECRET2' where id = tests.fx('cust_a');
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'Alicia', 'alice2@example.com')
  returning tests.fx_set('cust_alicia', id);

-- ------------------------------------------------------------ portal_claim_customers
select tests.as_anon();
select tests.throws($$select public.portal_claim_customers()$$, '42501', 'anon cannot claim');
select tests.throws($$select public.portal_overview()$$, '42501', 'anon has no portal');
select tests.authenticate_as(tests.fx('u_alice_unconfirmed'));
select tests.throws_like($$select public.portal_claim_customers()$$, '42501', '%confirm your email%', 'unconfirmed email: refused');
select tests.as_superuser();
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_alicia')), 'nothing linked');

select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(public.portal_claim_customers(), 2, 'links Alice in shop A and shop B');
select tests.eq(public.portal_claim_customers(), 0, 'idempotent');
select tests.as_superuser();
select tests.eq((select array_agg(id order by first_name, shop_id) from public.customers where portal_user_id = tests.fx('u_alice')),
                (select array_agg(id order by first_name, shop_id) from public.customers where id in (tests.fx('cust_a'), tests.fx('cust_alice_b'))),
                'exactly the two live records');
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_alice_arch')), 'archived record not linked');
select tests.eq((select portal_user_id from public.customers where id = tests.fx('cust_alice_taken')), tests.fx('u_mallory'),
                'a record claimed by someone else is never taken over');

-- a confirmed user whose email matches nothing links nothing
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.portal_claim_customers(), 0, 'no matches');
-- an anonymous (guest) auth user is never trusted
select tests.as_superuser();
update auth.users set is_anonymous = true, email = 'alice2@example.com', email_confirmed_at = now()
 where id = tests.fx('u_alice_unconfirmed');
select tests.authenticate_as(tests.fx('u_alice_unconfirmed'));
select tests.throws($$select public.portal_claim_customers()$$, '42501', 'anonymous accounts cannot claim');

-- ------------------------------------------------------------ data for the overview
select tests.as_superuser();
update public.shops set logo_path = 'a/logo.png' where id = tests.fx('shop_a');
-- jobs: job_a scheduled (upcoming, fixture); a completed and a cancelled job in the past; job_a2 is Aaron's
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end, completed_at, internal_notes)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'completed', '2025-05-01 15:00Z', '2025-05-01 16:00Z',
          '2025-05-01 16:00Z', 'SECRET-JOB')
  returning tests.fx_set('job_done', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_done'), tests.fx('svc_wash'), 'Exterior Wash', 5000);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end, cancelled_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'cancelled', '2025-04-01 15:00Z', '2025-04-01 16:00Z', '2025-03-30 12:00Z')
  returning tests.fx_set('job_cancelled', id);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_b'), tests.fx('cust_alice_b'), 'confirmed', '2025-07-01 15:00Z', '2025-07-01 16:00Z')
  returning tests.fx_set('job_b_alice', id);
insert into public.vehicles (shop_id, customer_id, make, model, archived_at)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'Old', 'Car', now());
-- quotes: sent (listed), draft (not), declined (not)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id, internal_notes) values (tests.fx('shop_a'), tests.fx('cust_a'), 'SECRET-QUOTE')
  returning tests.fx_set('q_sent', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_sent'), 'Coating', 90000);
select public.mark_quote_sent(tests.fx('q_sent'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_draft', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q_declined', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_declined'), 'Tint', 30000);
select public.mark_quote_sent(tests.fx('q_declined'));
update public.quotes set status = 'declined' where id = tests.fx('q_declined');
-- invoices: open (listed) for job_done; a draft (not)
select tests.fx_set('inv_open', (public.create_invoice_from_job(tests.fx('job_done'))).id);
select tests.fx_set('inv_draft', (public.create_invoice(tests.fx('cust_a'), '[{"name": "Wax", "unit_price_cents": 1000}]')).id);
-- memberships: active (listed), incomplete (not)
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids, discount_bps, description)
  values (tests.fx('shop_a'), 'Gold', 9900, array[tests.fx('svc_wash')], 1500, 'Monthly wash') returning tests.fx_set('plan_gold', id);
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Silver', 4900)
  returning tests.fx_set('plan_silver', id);
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, stripe_subscription_id, current_period_end)
  values (tests.fx('shop_a'), tests.fx('plan_gold'), tests.fx('cust_a'), tests.fx('veh_a'), 'active', 'sub_SECRET3', '2025-07-01Z');
insert into public.memberships (shop_id, plan_id, customer_id, status)
  values (tests.fx('shop_a'), tests.fx('plan_silver'), tests.fx('cust_a'), 'incomplete');

select tests.fx_set('tok_job_a', (select public_token from public.jobs where id = tests.fx('job_a')));
select tests.fx_set('tok_done', (select public_token from public.jobs where id = tests.fx('job_done')));
select tests.fx_set('tok_q', (select public_token from public.quotes where id = tests.fx('q_sent')));
select tests.fx_set('tok_inv', (select public_token from public.invoices where id = tests.fx('inv_open')));
select tests.fx_set('tok_b_alice', (select public_token from public.jobs where id = tests.fx('job_b_alice')));

-- ------------------------------------------------------------ portal_overview
select tests.authenticate_as(tests.fx('u_alice'));
create temp table o as select public.portal_overview() as d;
select tests.eq(pg_temp.keys((select d from o)), 'customers,invoices,memberships,past_jobs,quotes,shops,upcoming_jobs,vehicles',
                'top-level keys');
select tests.eq((select jsonb_agg(e ->> 'slug') from o, jsonb_array_elements(d -> 'shops') e), '["shop-a", "shop-b"]'::jsonb,
                'both shops');
select tests.eq((select pg_temp.keys(d -> 'shops' -> 0) from o),
                'booking_enabled,brand_color,city,currency,email,logo_path,name,phone,region,slug,timezone,website', 'shop keys');
select tests.eq((select pg_temp.keys(d -> 'customers' -> 0) from o),
                'company,email,email_opt_in,first_name,last_name,phone,shop_slug,sms_opt_in', 'customer keys');
select tests.eq((select jsonb_array_length(d -> 'customers') from o), 2, 'one customer record per shop');
select tests.eq((select jsonb_agg(e ->> 'model' order by e ->> 'model') from o, jsonb_array_elements(d -> 'vehicles') e),
                '["Civic"]'::jsonb, 'live vehicles only (archived hidden)');
select tests.eq((select pg_temp.keys(d -> 'vehicles' -> 0) from o),
                'category_id,category_name,color,id,license_plate,make,model,shop_slug,trim,year', 'vehicle keys');
select tests.eq((select (d #>> '{vehicles,0,id}')::uuid from o), tests.fx('veh_a'), 'vehicle id (to book it again)');
select tests.eq((select d #>> '{vehicles,0,category_name}' from o), 'Car', 'vehicle category');
select tests.eq((select jsonb_agg(e ->> 'token' order by e ->> 'scheduled_start') from o, jsonb_array_elements(d -> 'upcoming_jobs') e),
                jsonb_build_array(tests.fx('tok_job_a'), tests.fx('tok_b_alice')), 'upcoming jobs across shops, by start');
select tests.eq((select pg_temp.keys(d -> 'upcoming_jobs' -> 0) from o),
                'deposit_required_cents,location_type,number,scheduled_end,scheduled_start,services,shop_slug,status,token,total_cents,vehicle',
                'upcoming job keys');
select tests.eq((select d -> 'upcoming_jobs' -> 0 ->> 'services' from o), 'Full Detail', 'services by name');
select tests.eq((select d -> 'upcoming_jobs' -> 0 ->> 'vehicle' from o), '2021 Honda Civic', 'vehicle label');
select tests.eq((select jsonb_agg(e ->> 'status') from o, jsonb_array_elements(d -> 'past_jobs') e), '["completed", "cancelled"]'::jsonb,
                'past jobs, most recent first');
select tests.eq((select d -> 'past_jobs' -> 0 ->> 'completed_at' from o)::timestamptz, '2025-05-01 16:00Z'::timestamptz, 'completion time');
select tests.eq((select (d -> 'past_jobs' -> 0 ->> 'token')::uuid from o), tests.fx('tok_done'), 'past job token');
select tests.eq((select pg_temp.keys(d -> 'past_jobs' -> 0) from o),
                'completed_at,location_type,number,scheduled_end,scheduled_start,services,shop_slug,status,token,total_cents,vehicle',
                'past job keys');
select tests.eq((select jsonb_agg(e ->> 'token') from o, jsonb_array_elements(d -> 'quotes') e), jsonb_build_array(tests.fx('tok_q')),
                'only sent/viewed/approved quotes');
select tests.eq((select pg_temp.keys(d -> 'quotes' -> 0) from o), 'number,sent_at,shop_slug,status,token,total_cents,valid_until,vehicle',
                'quote keys');
select tests.eq((select jsonb_agg(e ->> 'token') from o, jsonb_array_elements(d -> 'invoices') e), jsonb_build_array(tests.fx('tok_inv')),
                'only issued invoices');
select tests.eq((select pg_temp.keys(d -> 'invoices' -> 0) from o),
                'amount_paid_cents,balance_cents,due_at,issued_at,number,shop_slug,status,token,total_cents', 'invoice keys');
select tests.eq((select d -> 'memberships' from o),
                jsonb_build_array(jsonb_build_object(
                  'shop_slug', 'shop-a', 'plan_name', 'Gold', 'plan_description', 'Monthly wash', 'status', 'active',
                  'price_cents', 9900, 'interval', 'month', 'interval_count', 1, 'discount_bps', 1500,
                  'included_services', jsonb_build_array('Exterior Wash'), 'vehicle', '2021 Honda Civic',
                  'current_period_end', '2025-07-01T00:00:00+00:00', 'cancel_at_period_end', false,
                  'started_at', now())),
                'active memberships only, with plan details (started when activated)');
select tests.ok((select d::text not like '%SECRET%' from o), 'no internal notes, customer notes, tags or Stripe ids');
select tests.ok((select d::text not like '%Aaron%' and d::text not like '%Gate code%' and d::text not like '%Mallory%'
                    and d::text not like '%claimed%' from o), 'no other customers'' data (or job notes)');
select tests.ok((select d::text not like '%' || tests.fx('cust_a')::text || '%' from o), 'no customer ids');
drop table o;

-- other users see only their own (or nothing)
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.portal_overview(),
                '{"shops": [], "customers": [], "vehicles": [], "upcoming_jobs": [], "past_jobs": [], "quotes": [],
                  "invoices": [], "memberships": []}'::jsonb, 'nothing linked: empty lists');
select tests.authenticate_as(tests.fx('u_mallory'));
select tests.eq((select jsonb_agg(e ->> 'first_name') from jsonb_array_elements(public.portal_overview() -> 'customers') e),
                '["Alice (claimed)"]'::jsonb, 'Mallory sees only the record linked to her');
-- staff membership gives no portal visibility of shop customers
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(jsonb_array_length(public.portal_overview() -> 'shops'), 0, 'the portal is for clients, not a staff back door');
-- archiving a customer hides it from the portal
select tests.as_superuser();
update public.customers set archived_at = now() where id = tests.fx('cust_alice_b');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq((select jsonb_agg(e ->> 'slug') from jsonb_array_elements(public.portal_overview() -> 'shops') e), '["shop-a"]'::jsonb,
                'archived customer records disappear');
select tests.as_superuser();
select tests.ok(not has_function_privilege('anon', 'public.portal_overview()', 'execute'), 'anon cannot execute portal_overview');
select tests.ok(has_function_privilege('authenticated', 'public.portal_claim_customers()', 'execute'), 'clients can claim');
