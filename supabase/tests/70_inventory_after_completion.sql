-- 70 ops: inventory consumed by a job that is ALREADY completed (P-28) —
-- a walk-in recorded after the fact (inserted as 'completed', lines added
-- afterwards), a service line added to a completed job, a quantity raised
-- after completion (only the difference), a vehicle change to a category
-- with a bigger rule, lines removed or lowered after completion (nothing
-- restored), re-completion after a reopen with a new line (only the new
-- line), non-completed jobs untouched, the job / service profit reports
-- reading the top-ups, the low-stock alert, the ledger adding up, and
-- two-shop isolation.
\ir fixtures/two_shops.psql

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.products (shop_id, name, unit, unit_cost_cents, on_hand, reorder_at)
  values (tests.fx('shop_a'), 'Wax', 'oz', 200, 20, 5) returning tests.fx_set('wax', id);
insert into public.products (shop_id, name, unit, unit_cost_cents, on_hand)
  values (tests.fx('shop_a'), 'Soap', 'oz', 50, 100) returning tests.fx_set('soap', id);
insert into public.service_consumables (shop_id, service_id, product_id, quantity)
  values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('wax'), 2);
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Wash', 30)
  returning tests.fx_set('svc_wash', id);
insert into public.service_consumables (shop_id, service_id, product_id, quantity)
  values (tests.fx('shop_a'), tests.fx('svc_wash'), tests.fx('soap'), 3);
-- a bigger wax rule for the Car category
insert into public.service_consumables (shop_id, service_id, vehicle_category_id, product_id, quantity)
  values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_a'), tests.fx('wax'), 3);
select tests.as_superuser();
update public.vehicles set category_id = null where id = tests.fx('veh_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.vehicles (shop_id, customer_id, year, make, model, category_id)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 2022, 'Mazda', '3', tests.fx('cat_car_a')) returning tests.fx_set('veh_car', id);

-- ============================================================ control: the usual status change
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j1', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_a'), 'Detail', 20000);
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('j1')), 0::bigint,
                'a line on an open job uses nothing yet');
update public.jobs set status = 'completed' where id = tests.fx('j1');
select tests.eq((select on_hand from public.products where id = tests.fx('wax')), 18.000::numeric, 'the status change deducts 2');

-- ============================================================ a walk-in recorded as completed
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'completed', now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j2', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j2'), tests.fx('svc_a'), 'Detail', 20000);
select tests.eq((select jsonb_agg(jsonb_build_array(quantity, unit_cost_cents, allocation, note, created_by = tests.fx('u_manager_a')))
                   from public.inventory_movements where job_id = tests.fx('j2') and kind = 'consume'),
                jsonb_build_array(jsonb_build_array(-2.000, 200, jsonb_build_object(tests.fx('svc_a')::text, 2.000),
                                                    'Job #' || (select number from public.jobs where id = tests.fx('j2')) || ' completed',
                                                    true)),
                'a job recorded as completed consumes its materials when its lines are added');
select tests.eq((select on_hand from public.products where id = tests.fx('wax')), 16.000::numeric, 'stock deducted');
-- a second line on it, and a service without rules
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, quantity)
  values (tests.fx('shop_a'), tests.fx('j2'), tests.fx('svc_wash'), 'Wash', 3000, 2);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j2'), 'Custom work', 1000);
select tests.eq((select jsonb_agg(jsonb_build_array(product_id = tests.fx('soap'), quantity) order by created_at, product_id = tests.fx('soap'))
                   from public.inventory_movements where job_id = tests.fx('j2') and kind = 'consume'),
                '[[false, -2.000], [true, -6.000]]'::jsonb, 'a second line: only its own materials (soap 3 x 2)');
select tests.ok((select note like 'Job #% lines changed after completion' from public.inventory_movements
                  where job_id = tests.fx('j2') and product_id = tests.fx('soap')), 'the top-up says why');

-- ============================================================ a line added to a job already moved to completed
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('j3', id);
update public.jobs set status = 'completed' where id = tests.fx('j3');
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('j3')), 0::bigint,
                'completed with no lines: nothing used');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j3'), tests.fx('svc_a'), 'Detail', 20000)
  returning tests.fx_set('j3_line', id);
select tests.eq((select sum(quantity) from public.inventory_movements where job_id = tests.fx('j3') and kind = 'consume'), -2.000::numeric,
                'a service line added after completion consumes');
-- a raised quantity: only the difference
update public.job_line_items set quantity = 2.5 where id = tests.fx('j3_line');
select tests.eq((select array_agg(quantity order by created_at) from public.inventory_movements where job_id = tests.fx('j3')),
                array[-2.000, -3.000]::numeric[], 'quantity 1 -> 2.5 deducts the extra 3');
-- other edits that change nothing the materials depend on do not deduct
update public.job_line_items set unit_price_cents = 25000, name = 'Detail (edited)' where id = tests.fx('j3_line');
update public.jobs set notes = 'Done' where id = tests.fx('j3');
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('j3')), 2::bigint,
                'a price or name change deducts nothing');
-- the job's vehicle moves to the Car category: the bigger rule tops up
update public.jobs set vehicle_id = tests.fx('veh_car') where id = tests.fx('j3');
select tests.eq((select sum(quantity) from public.inventory_movements where job_id = tests.fx('j3')), -7.500::numeric,
                'Car rule 3 x 2.5 = 7.5 in all');
-- lowering or removing lines after completion restores nothing
update public.job_line_items set quantity = 1 where id = tests.fx('j3_line');
delete from public.job_line_items where id = tests.fx('j3_line');
select tests.eq((select sum(quantity) from public.inventory_movements where job_id = tests.fx('j3')), -7.500::numeric,
                'lowered and removed after completion: the materials were used');
-- re-added: already consumed for that service, nothing new
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j3'), tests.fx('svc_a'), 'Detail', 20000);
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('j3')), 3::bigint,
                'a line re-added for a service already consumed deducts nothing more');

-- ============================================================ reopen, add a line, complete again
update public.jobs set status = 'in_progress' where id = tests.fx('j1');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j1'), tests.fx('svc_wash'), 'Wash', 3000);
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('j1')), 1::bigint,
                'a line on a reopened job waits for completion');
update public.jobs set status = 'completed' where id = tests.fx('j1');
select tests.eq((select jsonb_agg(jsonb_build_array(product_id = tests.fx('soap'), quantity) order by created_at, product_id = tests.fx('soap'))
                   from public.inventory_movements where job_id = tests.fx('j1')),
                '[[false, -2.000], [true, -3.000]]'::jsonb, 'completing again deducts only the new line');

-- ============================================================ the ledger, the alert and the reports
select tests.eq((select array[(select on_hand from public.products where id = tests.fx('wax')),
                              (select on_hand from public.products where id = tests.fx('soap'))]),
                array[8.500, 91.000]::numeric[], 'wax 20 - 2 - 2 - 7.5; soap 100 - 6 - 3');
select tests.eq((select array_agg(p.on_hand = (select sum(m.quantity) from public.inventory_movements m where m.product_id = p.id)
                                  order by p.name)
                   from public.products p where p.shop_id = tests.fx('shop_a')),
                array[true, true], 'the ledger adds up to the stock');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, quantity)
  values (tests.fx('shop_a'), tests.fx('j2'), tests.fx('svc_a'), 'Detail again', 20000, 2);
select tests.eq((select on_hand from public.products where id = tests.fx('wax')), 4.500::numeric, 'a second Detail line on j2: 4 more');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'low_stock' and title = 'Low stock: Wax'), 3::bigint,
                'a top-up that takes the stock to the reorder level alerts owners, admins and managers');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select jsonb_build_array(revenue_cents, materials_cents)
                   from public.report_job_profit(tests.fx('shop_a'), current_date - 2, current_date + 2) where job_id = tests.fx('j2')),
                (select jsonb_build_array(j.subtotal_cents - j.discount_cents, 6 * 200 + 6 * 50)
                   from public.jobs j where j.id = tests.fx('j2')),
                'job profit counts the walk-in''s materials (wax 6 x 200 + soap 6 x 50)');
select tests.eq((select materials_cents from public.report_service_profit(tests.fx('shop_a'), current_date - 2, current_date + 2)
                  where service_id = tests.fx('svc_a')),
                ((2 + 6 + 7.5) * 200)::bigint, 'service profit: every Detail consumption (j1 2, j2 2 + 4, j3 7.5)');

-- ============================================================ isolation and roles
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_b'), tests.fx('cust_b'), tests.fx('veh_b'), 'completed', now() - interval '3 hours', now() - interval '1 hour')
  returning tests.fx_set('jb', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_b'), tests.fx('jb'), tests.fx('svc_b'), 'Detail', 20000);
select tests.eq(tests.row_count($$select 1 from public.inventory_movements$$), 0::bigint, 'shop B has no rules and sees none of A''s ledger');
select tests.as_superuser();
select tests.eq((select count(*) from public.inventory_movements where job_id = tests.fx('jb')), 0::bigint,
                'shop A''s rules never apply to shop B''s service');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.inventory_movements$$), 0::bigint, 'technicians see none of the ledger');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', -1)$$, '42501',
                    'nor write it');
