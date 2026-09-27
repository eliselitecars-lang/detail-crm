-- 10 money: deleting catalog / CRM rows that money documents point at.
--   * a vehicle covered by a membership cannot be deleted (a null vehicle
--     would silently widen the membership to every vehicle)
--   * services and vehicles that appear on paid / void invoices can be
--     deleted: the lines keep their name/price snapshot (ON DELETE SET NULL)
--   * deleting a service included in a membership plan removes it from the
--     plan, and the plan stays editable
-- price_services checks run only when 0040 is applied (--ranges).
\ir fixtures/two_shops.psql

select to_regprocedure('public.price_services(uuid, uuid, uuid, uuid[], uuid)') is not null as has_pricing \gset

-- ============================================================ memberships keep their vehicle
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, year, make, model, category_id)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 2020, 'Toyota', 'Camry', tests.fx('cat_car_a')) returning tests.fx_set('veh_other', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
  values (tests.fx('shop_a'), 'Civic Club', 5000, array[tests.fx('svc_a')]) returning tests.fx_set('plan', id);
select tests.fx_set('mem', (public.create_membership(tests.fx('plan'), tests.fx('cust_a'), tests.fx('veh_a'))).id);
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_abc123', 'active', '2025-07-01', false, tests.fx('mem'), '2025-06-01');

\if :has_pricing
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cat_car_a'), array[tests.fx('svc_a')],
                                       tests.fx('veh_other')) -> 'lines' -> 0 ->> 'unit_price_cents')::bigint,
                20000::bigint, 'before: the other vehicle pays full price');
\endif

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.vehicles where id = tests.fx('veh_a')$$, '23503',
                    'the vehicle a membership covers cannot be deleted');
select tests.as_superuser();
select tests.eq((select vehicle_id from public.memberships where id = tests.fx('mem')), tests.fx('veh_a'),
                'the membership still covers only that vehicle');
\if :has_pricing
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cat_car_a'), array[tests.fx('svc_a')],
                                       tests.fx('veh_other')) -> 'lines' -> 0 ->> 'unit_price_cents')::bigint,
                20000::bigint, 'after the attempt the membership still does not cover other vehicles');
\endif
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.vehicles set archived_at = now() where id = tests.fx('veh_a')$$,
                   'a sold vehicle is archived instead');
-- a membership that is moved away no longer holds the vehicle
select tests.lives($$update public.memberships set vehicle_id = tests.fx('veh_other') where id = tests.fx('mem')$$,
                   'staff move the membership to another vehicle');
select tests.lives($$delete from public.vehicles where id = tests.fx('veh_a')$$, 'then the old vehicle can be deleted');
-- history: a cancelled membership keeps its vehicle too
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_abc123', 'cancelled', null, false, null, '2025-08-01');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.vehicles where id = tests.fx('veh_other')$$, '23503',
                    'cancelled memberships keep their vehicle as history');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from public.vehicles where id = tests.fx('veh_other')$$), 0::bigint,
                'shop B cannot delete A''s vehicles');

-- ============================================================ invoiced services / vehicles can be deleted
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, year, make, model) values (tests.fx('shop_a'), tests.fx('cust_a2'), 2022, 'Kia', 'EV6')
  returning tests.fx_set('veh_inv', id);
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Headlight restore', 30)
  returning tests.fx_set('svc_inv', id);
insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_inv'), tests.fx('veh_inv'), 'Headlight restore', 8000);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_paid', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
select public.mark_invoice_sent(tests.fx('inv_paid'));
select public.record_manual_payment(tests.fx('inv_paid'), (select balance_cents from public.invoices where id = tests.fx('inv_paid')), 'cash');
-- an ad-hoc void invoice with the same service and vehicle
select tests.fx_set('inv_void', (public.create_invoice(tests.fx('cust_a2'),
          jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_inv'), 'vehicle_id', tests.fx('veh_inv'),
                                               'unit_price_cents', 8000)))).id);
select public.mark_invoice_sent(tests.fx('inv_void'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.void_invoice(tests.fx('inv_void'));
select tests.as_superuser();
select tests.eq((select string_agg(status::text, ',' order by status) from public.invoices where id in (tests.fx('inv_paid'), tests.fx('inv_void'))),
                'paid,void', 'one paid and one void invoice reference the service and vehicle');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.invoice_line_items set service_id = null where invoice_id = tests.fx('inv_paid')$$,
                         '23514', '%payments have been received%', 'staff still cannot edit lines of a paid invoice');
select tests.throws_like($$update public.invoice_line_items set vehicle_id = null where invoice_id = tests.fx('inv_void')$$,
                         '23514', '%void%', 'nor of a void invoice');
select tests.lives($$delete from public.services where id = tests.fx('svc_inv')$$,
                   'FK is ON DELETE SET NULL: deleting an invoiced service succeeds');
select tests.lives($$delete from public.vehicles where id = tests.fx('veh_inv')$$,
                   'FK is ON DELETE SET NULL: deleting an invoiced vehicle succeeds');
select tests.as_superuser();
select tests.eq((select string_agg(concat_ws('/', name, unit_price_cents, service_id is null, vehicle_id is null), ',' order by invoice_id = tests.fx('inv_void'))
                   from public.invoice_line_items where invoice_id in (tests.fx('inv_paid'), tests.fx('inv_void'))
                     and name = 'Headlight restore'),
                'Headlight restore/8000/t/t,Headlight restore/8000/t/t', 'lines keep their snapshot, links cleared');
select tests.eq((select concat_ws('/', status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = tests.fx('inv_paid')),
                'paid/8000/8000/0', 'the paid invoice is unchanged');
select tests.eq((select concat_ws('/', status, total_cents) from public.invoices where id = tests.fx('inv_void')),
                'void/8000', 'the void invoice is unchanged');
-- the fixture's invoiced service (line_a on job_a) the same way
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_a', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select public.mark_invoice_sent(tests.fx('inv_a'));
select public.record_manual_payment(tests.fx('inv_a'), (select balance_cents from public.invoices where id = tests.fx('inv_a')), 'cash');
select tests.lives($$delete from public.services where id = tests.fx('svc_a')$$, 'the fixture service on a paid invoice can be deleted');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$delete from public.services where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B cannot delete A''s services');

-- ============================================================ plans survive deleted services
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Tire Shine', 15) returning tests.fx_set('svc_tire', id);
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Wash', 30) returning tests.fx_set('svc_wash', id);
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
  values (tests.fx('shop_a'), 'Wash Club', 3000, array[tests.fx('svc_wash'), tests.fx('svc_tire')]) returning tests.fx_set('plan_w', id);
delete from public.services where id = tests.fx('svc_tire');
select tests.eq((select included_service_ids from public.membership_plans where id = tests.fx('plan_w')), array[tests.fx('svc_wash')],
                'the deleted service leaves the plan');
select tests.lives($$update public.membership_plans set name = 'Wash Club Plus' where id = tests.fx('plan_w')$$,
                   'plan still editable after an included service is deleted');
select tests.as_service();
select tests.lives($$update public.membership_plans set stripe_product_id = 'prod_ABC', stripe_price_id = 'price_ABC' where id = tests.fx('plan_w')$$,
                   'payments function can still attach Stripe ids');
-- a dangling id that got onto a plan anyway (written before this rule) is dropped, not fatal
select tests.as_superuser();
alter table public.membership_plans disable trigger membership_plans_20_before_write;
update public.membership_plans set included_service_ids = array[tests.fx('svc_wash'), tests.fx('svc_tire')] where id = tests.fx('plan_w');
alter table public.membership_plans enable trigger membership_plans_20_before_write;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.membership_plans set active = false where id = tests.fx('plan_w')$$,
                   'a plan with a dangling id can still be deactivated');
select tests.eq((select included_service_ids from public.membership_plans where id = tests.fx('plan_w')), array[tests.fx('svc_wash')],
                'and the dangling id is dropped');
-- adding ids is still validated
select tests.throws_like($$update public.membership_plans set included_service_ids = included_service_ids || tests.fx('svc_tire')
                           where id = tests.fx('plan_w')$$, '23503', '%belong to this shop%', 'a deleted service cannot be added');
select tests.throws_like($$update public.membership_plans set included_service_ids = included_service_ids || tests.fx('svc_b')
                           where id = tests.fx('plan_w')$$, '23503', '%belong to this shop%', 'another shop''s service cannot be added');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$update public.membership_plans set name = 'x' where id = tests.fx('plan_w')$$), 0::bigint,
                'shop B cannot edit A''s plans');
-- B deleting its own service touches only B's plans
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
  values (tests.fx('shop_b'), 'B Club', 3000, array[tests.fx('svc_b')]) returning tests.fx_set('plan_b', id);
delete from public.services where id = tests.fx('svc_b');
select tests.as_superuser();
select tests.eq((select concat_ws('/', cardinality(included_service_ids), name) from public.membership_plans where id = tests.fx('plan_b')),
                '0/B Club', 'B''s plan lost B''s deleted service');
select tests.eq((select included_service_ids from public.membership_plans where id = tests.fx('plan_w')), array[tests.fx('svc_wash')],
                'A''s plan untouched');
