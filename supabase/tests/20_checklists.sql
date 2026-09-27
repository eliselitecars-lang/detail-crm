-- 20 field ops: checklist_templates, job_checklist_items, auto-attach from
-- job line items (incl. packages), apply_checklist_template — role matrix,
-- technician tick-only rule, server stamps, dedupe, cross-shop isolation.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ templates: role matrix + validation
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'Tech', '[{"id":"a","label":"A"}]')$$, '42501',
                    'technicians cannot create checklist templates');
select tests.eq(tests.row_count($$select 1 from public.checklist_templates$$), 0::bigint, 'no templates yet');

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.checklist_templates (shop_id, name, items, service_id)
  values (tests.fx('shop_a'), '  Full detail  ',
          '[{"id":"vac","label":"  Vacuum interior "},{"label":"Clean glass"},{"id":"tires","label":"Dress tires"}]',
          tests.fx('svc_a'))
  returning tests.fx_set('tpl_a', id);
select tests.eq((select name from public.checklist_templates where id = tests.fx('tpl_a')), 'Full detail', 'name trimmed');
select tests.eq((select jsonb_array_length(items) from public.checklist_templates where id = tests.fx('tpl_a')), 3,
                'three items stored');
select tests.eq((select items -> 0 from public.checklist_templates where id = tests.fx('tpl_a')),
                '{"id":"vac","label":"Vacuum interior"}'::jsonb, 'labels trimmed, ids kept');
select tests.ok((select (items -> 1 ->> 'id') ~ '^[0-9a-f-]{36}$' from public.checklist_templates where id = tests.fx('tpl_a')),
                'missing item id is generated');
select tests.ok(public.checklist_items_valid((select items from public.checklist_templates where id = tests.fx('tpl_a'))),
                'stored items satisfy the validator');

select tests.throws($$insert into public.checklist_templates (shop_id, name, items) values (tests.fx('shop_a'), 'X', '{"id":"a"}')$$,
                    '23514', 'items must be an array');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items) values (tests.fx('shop_a'), 'X', '["just text"]')$$,
                    '23514', 'items must be objects');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":"a","label":"A","extra":1}]')$$, '23514', 'no extra keys');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":"a","label":"   "}]')$$, '23514', 'labels cannot be blank');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":"a","label":5}]')$$, '23514', 'labels must be strings');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":"a","label":"A"},{"id":"a","label":"B"}]')$$, '23514',
                    'item ids are unique within a template');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":"a b","label":"A"}]')$$, '23514', 'item ids are url-safe');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', '[{"id":7,"label":"A"}]')$$, '23514', 'item ids are strings');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items)
                      values (tests.fx('shop_a'), 'X', (select jsonb_agg(jsonb_build_object('id', 'i' || g, 'label', 'L')) from generate_series(1, 201) g))$$,
                    '23514', 'at most 200 items');
select tests.throws($$insert into public.checklist_templates (shop_id, name, items) values (tests.fx('shop_a'), '  ', '[]')$$,
                    '23514', 'name required');
select tests.lives($$insert into public.checklist_templates (shop_id, name) values (tests.fx('shop_a'), 'Empty draft')$$,
                   'an empty template is allowed while drafting');
-- cross-shop
select tests.throws($$insert into public.checklist_templates (shop_id, name) values (tests.fx('shop_b'), 'Nope')$$, '42501',
                    'manager of A cannot create templates in shop B');
select tests.throws($$insert into public.checklist_templates (shop_id, name, service_id)
                      values (tests.fx('shop_a'), 'Nope', tests.fx('svc_b'))$$, '23503',
                    'a template cannot point at another shop''s service');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.checklist_templates$$), 2::bigint, 'technicians read their shop''s templates');
select tests.eq(tests.row_count($$update public.checklist_templates set name = 'Hacked'$$), 0::bigint, 'technicians cannot edit templates');
select tests.eq(tests.row_count($$delete from public.checklist_templates$$), 0::bigint, 'technicians cannot delete templates');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.checklist_templates$$), 0::bigint, 'shop B sees none of shop A''s templates');
select tests.eq(tests.row_count($$update public.checklist_templates set name = 'Hacked'$$), 0::bigint, 'shop B cannot edit A''s templates');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.checklist_templates set name = 'Empty draft 2' where name = 'Empty draft'$$), 1::bigint,
                'admins edit templates');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$delete from public.checklist_templates where name = 'Empty draft 2'$$), 1::bigint,
                'owners delete templates');
select tests.throws($$update public.checklist_templates set shop_id = tests.fx('shop_b') where id = tests.fx('tpl_a')$$, '42501',
                    'templates never move between shops');

-- ------------------------------------------------------------ auto-attach on line items
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_a2')$$), 0::bigint,
                'job_a2 has no checklist yet');
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 20000);
select tests.eq((select array_agg(label order by sort) from public.job_checklist_items where job_id = tests.fx('job_a2')),
                array['Vacuum interior', 'Clean glass', 'Dress tires'], 'template items attached in order');
select tests.eq((select array_agg(sort order by sort) from public.job_checklist_items where job_id = tests.fx('job_a2')),
                array[1, 2, 3], 'sorted after existing items');
select tests.ok((select bool_and(template_id = tests.fx('tpl_a') and template_item_id is not null and done_at is null)
                   from public.job_checklist_items where job_id = tests.fx('job_a2')), 'items link back to the template, not done');
-- the same service again: no duplicates
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 20000);
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_a2')$$), 3::bigint,
                'adding the same service twice does not duplicate the checklist');

-- a second template for the same service attaches too, after existing items
insert into public.checklist_templates (shop_id, name, items, service_id)
  values (tests.fx('shop_a'), 'Quality check', '[{"id":"qc","label":"Walk-around with customer"}]', tests.fx('svc_a'))
  returning tests.fx_set('tpl_qc', id);
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 20000);
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_a2')$$), 4::bigint,
                'new template for the service attaches on the next line item, existing ones are not duplicated');
select tests.eq((select sort from public.job_checklist_items where template_id = tests.fx('tpl_qc') and job_id = tests.fx('job_a2')), 4,
                'new items append after the existing checklist');

-- packages attach the templates of the services they contain
insert into public.services (shop_id, name, kind) values (tests.fx('shop_a'), 'Signature package', 'package')
  returning tests.fx_set('pkg_a', id);
insert into public.package_items (shop_id, package_id, service_id) values (tests.fx('shop_a'), tests.fx('pkg_a'), tests.fx('svc_a'));
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_pkg', id);
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_pkg'), tests.fx('pkg_a'), 50000);
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_pkg')$$), 4::bigint,
                'a package line attaches the templates of its included services');

-- changing a custom line to a service attaches as well
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_custom', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_custom'), 'Custom work', 1000) returning tests.fx_set('line_custom', id);
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_custom')$$), 0::bigint,
                'custom lines attach nothing');
update public.job_line_items set service_id = tests.fx('svc_a') where id = tests.fx('line_custom');
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_custom')$$), 4::bigint,
                'setting a service on a line attaches its checklists');
update public.job_line_items set unit_price_cents = 2000 where id = tests.fx('line_custom');
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_custom')$$), 4::bigint,
                'other line edits attach nothing new');
-- deleting the line keeps the checklist (work may already be ticked)
delete from public.job_line_items where id = tests.fx('line_custom');
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_custom')$$), 4::bigint,
                'removing the line keeps the checklist');

-- shop B services never attach shop A templates
select tests.as_superuser();
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents)
  values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('svc_b'), 5000);
select tests.eq((select count(*) from public.job_checklist_items where shop_id = tests.fx('shop_b')), 0::bigint,
                'no cross-shop attachment');

-- ------------------------------------------------------------ apply_checklist_template
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_a')$$), 0::bigint,
                'job_a predates the templates');
select tests.eq((select count(*) from public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_a'))), 3::bigint,
                'apply returns the added items');
select tests.eq((select count(*) from public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_a'))), 0::bigint,
                'applying again adds nothing');
update public.checklist_templates
   set items = items || '[{"id":"wax","label":"Spray wax"}]'::jsonb where id = tests.fx('tpl_a');
select tests.eq((select array_agg(label) from public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_a'))),
                array['Spray wax'], 're-applying an edited template adds only the new items');
select tests.eq((select max(sort) from public.job_checklist_items where job_id = tests.fx('job_a')), 7,
                'appended item sort continues after the last one');
select tests.throws($$select public.apply_checklist_template(tests.fx('job_a'), gen_random_uuid())$$, 'P0002', 'unknown template');
select tests.throws($$select public.apply_checklist_template(gen_random_uuid(), tests.fx('tpl_a'))$$, 'P0002', 'unknown job');
select tests.throws($$select public.apply_checklist_template(tests.fx('job_b'), tests.fx('tpl_a'))$$, 'P0002',
                    'jobs of another shop are not found');
select tests.as_superuser();
insert into public.checklist_templates (shop_id, name, items) values (tests.fx('shop_b'), 'B list', '[{"id":"b","label":"B"}]')
  returning tests.fx_set('tpl_b', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_b'))$$, 'P0002',
                    'another shop''s template cannot be applied');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_qc'))$$, '42501',
                    'technicians cannot apply templates');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_qc'))$$, 'P0002',
                    'outsiders learn nothing about the job');
select tests.as_anon();
select tests.throws($$select public.apply_checklist_template(tests.fx('job_a'), tests.fx('tpl_qc'))$$, '42501',
                    'anon cannot call apply_checklist_template');

-- ------------------------------------------------------------ job_checklist_items: technicians tick only
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items$$), 4::bigint,
                'technician sees only the checklist of assigned jobs');
select tests.eq(tests.row_count($$update public.job_checklist_items set done_at = '2000-01-01Z'
                                   where job_id = tests.fx('job_a') and template_item_id = 'vac'$$), 1::bigint,
                'assigned technician ticks an item');
select tests.eq((select done_at from public.job_checklist_items where job_id = tests.fx('job_a') and template_item_id = 'vac'),
                now(), 'done_at is server time, not the client value');
select tests.eq((select done_by from public.job_checklist_items where job_id = tests.fx('job_a') and template_item_id = 'vac'),
                tests.fx('u_tech_a'), 'done_by is the acting user');
select tests.lives($$update public.job_checklist_items set done_by = tests.fx('u_owner_a')
                      where job_id = tests.fx('job_a') and template_item_id = 'vac'$$);
select tests.eq((select done_by from public.job_checklist_items where job_id = tests.fx('job_a') and template_item_id = 'vac'),
                tests.fx('u_tech_a'), 'done_by cannot be forged');
select tests.throws($$update public.job_checklist_items set label = 'Skip it' where job_id = tests.fx('job_a') and template_item_id = 'vac'$$,
                    '42501', 'technicians cannot rename items');
select tests.throws($$update public.job_checklist_items set sort = 99 where job_id = tests.fx('job_a') and template_item_id = 'vac'$$,
                    '42501', 'technicians cannot reorder items');
select tests.throws($$insert into public.job_checklist_items (shop_id, job_id, label) values (tests.fx('shop_a'), tests.fx('job_a'), 'Mine')$$,
                    '42501', 'technicians cannot add items');
select tests.eq(tests.row_count($$delete from public.job_checklist_items where job_id = tests.fx('job_a')$$), 0::bigint,
                'technicians cannot delete items');
select tests.lives($$update public.job_checklist_items set done_at = null where job_id = tests.fx('job_a') and template_item_id = 'vac'$$,
                   'technician unticks');
select tests.ok((select done_at is null and done_by is null from public.job_checklist_items
                  where job_id = tests.fx('job_a') and template_item_id = 'vac'), 'untick clears done_by');

select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items where job_id = tests.fx('job_a')$$), 0::bigint,
                'unassigned technician cannot see the job''s checklist');
select tests.eq(tests.row_count($$update public.job_checklist_items set done_at = now() where job_id = tests.fx('job_a')$$), 0::bigint,
                'unassigned technician cannot tick');

-- deactivated technicians lose access
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items$$), 0::bigint, 'inactive members see nothing');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');

-- ------------------------------------------------------------ job_checklist_items: managers full edit
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_checklist_items (shop_id, job_id, label, sort, template_id, template_item_id, done_at, done_by)
  values (tests.fx('shop_a'), tests.fx('job_a'), '  Photograph odometer ', 10, tests.fx('tpl_a'), 'fake', '2000-01-01Z', tests.fx('u_owner_b'))
  returning tests.fx_set('item_manual', id);
select tests.ok((select label = 'Photograph odometer' and template_id is null and template_item_id is null
                   and done_at = now() and done_by = tests.fx('u_manager_a')
                   from public.job_checklist_items where id = tests.fx('item_manual')),
                'manual items: label trimmed, template link and done stamps are server-controlled');
select tests.lives($$update public.job_checklist_items set label = 'Photo of odometer', sort = 0 where id = tests.fx('item_manual')$$,
                   'managers edit labels and order');
select tests.throws($$update public.job_checklist_items set template_id = tests.fx('tpl_qc'), template_item_id = 'qc'
                      where id = tests.fx('item_manual')$$, '42501', 'template links cannot be edited');
select tests.throws($$update public.job_checklist_items set job_id = tests.fx('job_a2') where id = tests.fx('item_manual')$$,
                    '42501', 'items do not move between jobs');
select tests.throws($$update public.job_checklist_items set shop_id = tests.fx('shop_b') where id = tests.fx('item_manual')$$,
                    '42501', 'items do not move between shops');
select tests.throws($$insert into public.job_checklist_items (shop_id, job_id, label) values (tests.fx('shop_a'), tests.fx('job_b'), 'X')$$,
                    '23503', 'composite FK blocks another shop''s job');
select tests.throws($$insert into public.job_checklist_items (shop_id, job_id, label) values (tests.fx('shop_b'), tests.fx('job_b'), 'X')$$,
                    '42501', 'managers cannot write into another shop');
select tests.throws($$insert into public.job_checklist_items (shop_id, job_id, label) values (tests.fx('shop_a'), tests.fx('job_a'), ' ')$$,
                    '23514', 'labels cannot be blank');
select tests.eq(tests.row_count($$delete from public.job_checklist_items where id = tests.fx('item_manual')$$), 1::bigint,
                'managers delete items');

select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.job_checklist_items$$), 0::bigint, 'shop B sees none of A''s items');
select tests.eq(tests.row_count($$update public.job_checklist_items set done_at = now()$$), 0::bigint, 'shop B ticks nothing of A');
select tests.eq(tests.row_count($$delete from public.job_checklist_items$$), 0::bigint, 'shop B deletes nothing of A');

-- ------------------------------------------------------------ deletes: template / service / job
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.checklist_templates where id = tests.fx('tpl_qc');
select tests.eq((select count(*) from public.job_checklist_items where template_item_id = 'qc'), 3::bigint,
                'deleting a template keeps attached items');
select tests.ok((select bool_and(template_id is null) from public.job_checklist_items where template_item_id = 'qc'),
                'their template link is cleared');
delete from public.services where id = tests.fx('pkg_a');
select tests.as_superuser();
delete from public.services where id = tests.fx('svc_a');
select tests.eq((select service_id from public.checklist_templates where id = tests.fx('tpl_a')), null::uuid,
                'deleting the service unlinks the template');
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = tests.fx('job_custom');
select tests.eq((select count(*) from public.job_checklist_items where job_id = tests.fx('job_custom')), 0::bigint,
                'deleting the job deletes its checklist');

-- ------------------------------------------------------------ privileges
select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.checklist_attach_template(uuid, uuid, uuid)', 'execute'),
                'the internal attach helper is not callable by clients');
select tests.ok(not has_table_privilege('anon', 'public.checklist_templates', 'select'), 'anon has no template access');
select tests.ok(not has_table_privilege('anon', 'public.job_checklist_items', 'select'), 'anon has no checklist access');
