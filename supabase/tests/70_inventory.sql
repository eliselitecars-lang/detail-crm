-- 70 ops: inventory (P-28) — products / consumables / movements RLS
-- (manager+, technicians nothing), the opening stock, on_hand only through
-- the ledger, record_inventory_movement (receive with cost, adjust, count,
-- validation, roles), consumption on completion (category rules win,
-- packages expanded, line quantities, cost snapshot and per-service
-- allocation, once per job, archived products skipped), the low-stock
-- alert (once, re-armed), low_stock_products, composite FKs and two-shop
-- isolation.
\ir fixtures/two_shops.psql

-- ============================================================ products: access
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.products (shop_id, name, sku, unit, unit_cost_cents, on_hand, reorder_at, reorder_qty, low_stock_notified_at)
  values (tests.fx('shop_a'), '  Car soap ', 'SOAP-1', 'oz', 50, 100, 90, 128, now())
  returning tests.fx_set('soap', id);
insert into public.products (shop_id, name, unit, unit_cost_cents, on_hand)
  values (tests.fx('shop_a'), 'Wax', 'oz', 200, 20) returning tests.fx_set('wax', id);
insert into public.products (shop_id, name, unit, unit_cost_cents, archived_at)
  values (tests.fx('shop_a'), 'Old towels', 'each', 100, now()) returning tests.fx_set('towels', id);
select tests.eq((select jsonb_build_array(name, on_hand, low_stock_notified_at) from public.products where id = tests.fx('soap')),
                '["Car soap", 100.000, null]'::jsonb, 'name trimmed; the alert stamp is server-set');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, quantity, note, created_by = tests.fx('u_manager_a')))
                   from public.inventory_movements where product_id = tests.fx('soap')),
                '[["count", 100.000, "Opening stock", true]]'::jsonb, 'the opening stock is recorded in the ledger');
select tests.eq((select count(*) from public.inventory_movements where product_id = tests.fx('towels')), 0::bigint,
                'no ledger entry for an empty product');
select tests.throws($$insert into public.products (shop_id, name, sku, unit) values (tests.fx('shop_a'), 'Dup', 'soap-1', 'oz')$$,
                    '23505', 'SKUs are unique per shop, case-insensitive');
select tests.throws($$insert into public.products (shop_id, name, unit, unit_cost_cents) values (tests.fx('shop_a'), 'X', 'oz', -1)$$,
                    '23514', 'costs are not negative');
select tests.lives($$update public.products set on_hand = 5, low_stock_notified_at = now(), unit_cost_cents = 55 where id = tests.fx('soap')$$);
select tests.eq((select jsonb_build_array(on_hand, low_stock_notified_at, unit_cost_cents) from public.products where id = tests.fx('soap')),
                '[100.000, null, 55]'::jsonb, 'stock changes only through the ledger; the cost is the shop''s to edit');
update public.products set unit_cost_cents = 50 where id = tests.fx('soap');
select tests.throws($$insert into public.inventory_movements (shop_id, product_id, kind, quantity)
                      values (tests.fx('shop_a'), tests.fx('soap'), 'adjust', 1)$$, '42501', 'no direct ledger writes');
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.products (shop_id, name, sku, unit) values (tests.fx('shop_b'), 'Car soap', 'SOAP-1', 'oz')
  returning tests.fx_set('soap_b', id);
select tests.eq(tests.row_count($$select 1 from public.products$$), 1::bigint, 'shop B sees only its product (same SKU is fine)');
select tests.eq(tests.row_count($$select 1 from public.inventory_movements$$), 0::bigint, 'and none of A''s ledger');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.products$$), 0::bigint, 'technicians see no products');
select tests.eq(tests.row_count($$select 1 from public.inventory_movements$$), 0::bigint, 'nor the ledger');
select tests.eq(tests.row_count($$select 1 from public.service_consumables$$), 0::bigint, 'nor consumables');
select tests.throws($$insert into public.products (shop_id, name, unit) values (tests.fx('shop_a'), 'X', 'oz')$$, '42501',
                    'nor add any');
select tests.as_anon();
select tests.throws($$select 1 from public.products$$, '42501', 'anon has no access');

-- ============================================================ record_inventory_movement
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', 1)$$, '42501', 'technicians cannot');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', 1)$$, 'P0002', 'another shop''s product');
select tests.as_anon();
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', 1)$$, '42501', 'anon cannot');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.record_inventory_movement(tests.fx('wax'), 'consume', -1)$$, '22023', '%automatically%',
                         'consumption is automatic only');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', 0)$$, '22023', 'a receipt adds stock');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', -3)$$, '22023', 'never removes it');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', 0)$$, '22023', 'an adjustment changes something');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'count', -1)$$, '22023', 'a count is not negative');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', 1.0005)$$, '22023', 'three decimals at most');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', null)$$, '22023', 'quantity required');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', 1, 100)$$, '22023', 'a cost goes with a receipt');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'receive', 1, -1)$$, '22023', 'not a negative cost');
select tests.throws($$select public.record_inventory_movement(tests.fx('wax'), 'adjust', 1, null, repeat('x', 501))$$, '22023',
                    'notes are limited');
select tests.eq((select jsonb_build_array(kind, quantity, unit_cost_cents, note) from public.record_inventory_movement(tests.fx('wax'), 'receive', 12.5, 180, ' Supplier order ')),
                '["receive", 12.500, 180, "Supplier order"]'::jsonb, 'a receipt with its cost');
select tests.eq((select jsonb_build_array(on_hand, unit_cost_cents) from public.products where id = tests.fx('wax')),
                '[32.500, 180]'::jsonb, 'stock up; the purchase cost becomes the product cost');
select tests.eq((select quantity from public.record_inventory_movement(tests.fx('wax'), 'adjust', -2.5, null, 'Spilled')), -2.500::numeric,
                'an adjustment');
select tests.eq((select quantity from public.record_inventory_movement(tests.fx('wax'), 'count', 28)), -2.000::numeric,
                'a count stores the difference to the counted level');
select tests.eq((select quantity from public.record_inventory_movement(tests.fx('wax'), 'count', 28)), 0.000::numeric,
                'a count that matches changes nothing but is recorded');
select tests.eq((select on_hand from public.products where id = tests.fx('wax')), 28.000::numeric, 'the stock is the counted level');
select tests.eq((select sum(quantity) from public.inventory_movements where product_id = tests.fx('wax')), 28.000::numeric,
                'the ledger adds up to the stock');

-- ============================================================ consumables
insert into public.service_consumables (shop_id, service_id, product_id, quantity) values
  (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('soap'), 4),
  (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('wax'), 2),
  (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('towels'), 1);
insert into public.service_consumables (shop_id, service_id, vehicle_category_id, product_id, quantity)
  values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_a'), tests.fx('soap'), 6);
select tests.throws($$insert into public.service_consumables (shop_id, service_id, product_id, quantity)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('soap'), 1)$$, '23505', 'one rule per service, category and product');
select tests.throws($$insert into public.service_consumables (shop_id, service_id, product_id, quantity)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('soap_b'), 1)$$, '23503', 'another shop''s product');
select tests.throws($$insert into public.service_consumables (shop_id, service_id, vehicle_category_id, product_id, quantity)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_b'), tests.fx('wax'), 1)$$, '23503',
                    'another shop''s category');
select tests.throws($$insert into public.service_consumables (shop_id, service_id, product_id, quantity)
                      values (tests.fx('shop_a'), tests.fx('svc_b'), tests.fx('wax'), 1)$$, '23503', 'another shop''s service');
select tests.throws($$insert into public.service_consumables (shop_id, service_id, product_id, quantity)
                      values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('wax'), 0)$$, '23514', 'a positive quantity');
-- a package: its own rule plus the rules of the services it includes
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Wax job', 60) returning tests.fx_set('svc_wax', id);
insert into public.services (shop_id, name, kind, duration_minutes) values (tests.fx('shop_a'), 'Shine Package', 'package', 90)
  returning tests.fx_set('pkg', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg'), tests.fx('svc_wax'));
insert into public.service_consumables (shop_id, service_id, product_id, quantity) values
  (tests.fx('shop_a'), tests.fx('svc_wax'), tests.fx('wax'), 3),
  (tests.fx('shop_a'), tests.fx('pkg'), tests.fx('soap'), 1);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, quantity)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('pkg'), 'Shine Package', 10000, 2);

-- ============================================================ consumption on completion
select tests.as_superuser();
update public.products set unit_cost_cents = 200 where id = tests.fx('wax');
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq((select count(*) from public.inventory_movements where kind = 'consume'), 0::bigint, 'nothing is used before completion');
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq((select jsonb_agg(jsonb_build_array(p.name, m.quantity, m.unit_cost_cents, m.created_by = tests.fx('u_tech_a'))
                                  order by p.name)
                   from public.inventory_movements m join public.products p on p.id = m.product_id
                  where m.kind = 'consume' and m.job_id = tests.fx('job_a')),
                '[["Car soap", -8.000, 50, true], ["Wax", -8.000, 200, true]]'::jsonb,
                'one movement per product: Car rule 6 + package 1 x 2 soap; 2 + wax job 3 x 2 wax; archived towels skipped');
select tests.eq((select allocation from public.inventory_movements where kind = 'consume' and product_id = tests.fx('soap')),
                jsonb_build_object(tests.fx('svc_a')::text, 6.000, tests.fx('pkg')::text, 2.000),
                'the allocation records what each line service used');
select tests.eq((select array[(select on_hand from public.products where id = tests.fx('soap')),
                              (select on_hand from public.products where id = tests.fx('wax'))]),
                array[92.000, 20.000]::numeric[], 'stock is deducted');
select tests.eq((select count(*) from public.notifications where kind = 'low_stock'), 0::bigint, 'above the reorder level: no alert');

-- a job without a vehicle category uses the every-category rule; quantities multiply
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, quantity)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 'Full Detail', 20000, 1.5);
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'completed' where id = tests.fx('job_a2');
select tests.as_superuser();
select tests.eq((select jsonb_agg(jsonb_build_array(product_id = tests.fx('soap'), quantity) order by product_id = tests.fx('soap'))
                   from public.inventory_movements where kind = 'consume' and job_id = tests.fx('job_a2')),
                '[[false, -3.000], [true, -6.000]]'::jsonb, 'generic rules x 1.5');
select tests.eq((select on_hand from public.products where id = tests.fx('soap')), 86.000::numeric, 'soap at 86, reorder at 90');
select tests.eq((select array_agg(u.email::text || ' ' || n.title order by u.email)
                   from public.notifications n join auth.users u on u.id = n.user_id where n.kind = 'low_stock'),
                array['admin-a@test.local Low stock: Car soap', 'manager-a@test.local Low stock: Car soap',
                      'owner-a@test.local Low stock: Car soap'],
                'owners, admins and managers are told once');
select tests.eq((select body from public.notifications where kind = 'low_stock' limit 1), '86 oz left (reorder at 90; usual order 128).',
                'with the level');
select tests.ok((select low_stock_notified_at is not null from public.products where id = tests.fx('soap')), 'the alert is stamped');

-- completing again never deducts twice
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a2');
update public.jobs set status = 'completed' where id = tests.fx('job_a2');
select tests.as_superuser();
select tests.eq((select count(*) from public.inventory_movements where kind = 'consume' and job_id = tests.fx('job_a2')), 2::bigint,
                'no second consumption');
select tests.eq((select on_hand from public.products where id = tests.fx('soap')), 86.000::numeric, 'and moving back restores nothing');

-- the alert fires once, then re-arms when stock rises above the level
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.record_inventory_movement(tests.fx('soap'), 'adjust', -1);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'low_stock'), 3::bigint, 'still low: no new alert');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select array_agg(name) from public.low_stock_products(tests.fx('shop_a'))), array['Car soap'], 'the low-stock list');
select public.record_inventory_movement(tests.fx('soap'), 'receive', 20);
select tests.eq((select jsonb_build_array(on_hand, low_stock_notified_at) from public.products where id = tests.fx('soap')),
                '[105.000, null]'::jsonb, 'restocked: the alert re-arms');
select tests.eq((select count(*) from public.low_stock_products(tests.fx('shop_a'))), 0::bigint, 'nothing is low');
select public.record_inventory_movement(tests.fx('soap'), 'count', 90);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'low_stock'), 6::bigint, 'a count down to the level alerts again');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.low_stock_products(tests.fx('shop_a'))$$, '42501', 'technicians get no list');
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'low_stock'$$), 0::bigint, 'nor the alerts');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select * from public.low_stock_products(tests.fx('shop_a'))$$, '42501', 'nor another shop');

-- deleting a completed job keeps its ledger rows (job link cleared)
select tests.as_superuser();
delete from public.job_assignments where job_id = tests.fx('job_a2');
delete from public.jobs where id = tests.fx('job_a2');
select tests.eq((select count(*) from public.inventory_movements where kind = 'consume' and job_id is null), 2::bigint,
                'the consumption stays in the ledger without its job');
select tests.as_service();
select tests.throws($$insert into public.inventory_movements (shop_id, product_id, kind, quantity, job_id)
                      values (tests.fx('shop_a'), tests.fx('wax'), 'adjust', 1, tests.fx('job_a'))$$, '23514',
                    'only consumption links a job');
select tests.throws($$insert into public.inventory_movements (shop_id, product_id, kind, quantity, job_id)
                      values (tests.fx('shop_a'), tests.fx('wax'), 'consume', -1, tests.fx('job_b'))$$, '23503',
                    'composite FK: another shop''s job');
select tests.throws($$insert into public.inventory_movements (shop_id, product_id, kind, quantity)
                      values (tests.fx('shop_a'), tests.fx('soap_b'), 'receive', 1)$$, '23503', 'composite FK: another shop''s product');
