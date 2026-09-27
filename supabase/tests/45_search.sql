-- 45 reports: search_shop — customers / vehicles / jobs / quotes / invoices,
-- LIKE-wildcard escaping, trigram typo matching, phone digits, number
-- prefixes, per-kind limits, technician visibility and cross-shop isolation.
-- Data: fixtures/45_reports_seed.psql (shop B also has an "Alice Anders"
-- with a Honda Civic plate ABC123).
\ir fixtures/45_reports_seed.psql

-- ============================================================ helpers
select tests.eq(public.like_escape('50%_off\x'), '50\%\_off\\x', 'like_escape escapes %, _ and the escape char');
select tests.eq(public.like_escape('plain'), 'plain', 'like_escape leaves plain text alone');
-- the escaping tests below are meaningful: unescaped, these patterns WOULD match seeded data
select tests.ok(exists (select 1 from public.customers where shop_id = tests.fx('rshop_a') and search_text like '%1_3%'),
                'unescaped "1_3" would match a phone number');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('rshop_a') and search_text like '%%%'),
                6::bigint, 'unescaped "%" would match every customer');

-- ============================================================ owner of shop A
select tests.authenticate_as(tests.fx('ru_owner_a'));

select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), 'alice')),
                jsonb_build_array(jsonb_build_array('customer', tests.fx('rc_alice'))),
                'name search finds only shop A''s Alice');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), '  ALICE ')),
                jsonb_build_array(jsonb_build_array('customer', tests.fx('rc_alice'))), 'case and whitespace insensitive');
select tests.eq((select jsonb_build_object('title', title, 'subtitle', subtitle, 'customer_id', customer_id, 'status', status,
                                           'archived', archived, 'number', number)
                   from public.search_shop(tests.fx('rshop_a'), 'alice@example')),
                jsonb_build_object('title', 'Alice Anders', 'subtitle', 'alice@example.com · +12055550101',
                                   'customer_id', tests.fx('rc_alice'), 'status', 'customer', 'archived', false, 'number', null),
                'email search and customer row shape');

-- ------------------------------------------------------------ wildcard escaping
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), '%')),
                jsonb_build_array(jsonb_build_array('customer', tests.fx('rc_pct'))),
                '"%" matches only a literal percent sign');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), '_')),
                jsonb_build_array(jsonb_build_array('customer', tests.fx('rc_ann'))),
                '"_" matches only a literal underscore');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '1_3')), 0::bigint,
                '"_" is not a single-character wildcard');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '\')), 0::bigint,
                'a lone backslash is literal');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '100%')), 1::bigint,
                '"100%" finds the company with a literal percent');

-- ------------------------------------------------------------ fuzzy / phone / vehicles
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'anderz')),
                jsonb_build_array(tests.fx('rc_alice')), 'typo matched by trigram similarity');
select tests.ok((select score from public.search_shop(tests.fx('rshop_a'), 'anderz')) < 1,
                'fuzzy-only matches score below exact substring matches');
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), '(205) 555-0102')),
                jsonb_build_array(tests.fx('rc_bob')), 'formatted phone number finds the customer');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id, title, subtitle, customer_id))
                   from public.search_shop(tests.fx('rshop_a'), 'civic')),
                jsonb_build_array(jsonb_build_array('vehicle', tests.fx('rv_civic'), '2021 Honda Civic',
                                                    'ABC123 · 1HGCM82633A004352 · Alice Anders', tests.fx('rc_alice'))),
                'vehicle by model');
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'abc123')),
                jsonb_build_array(tests.fx('rv_civic')), 'vehicle by plate (shop B''s ABC123 excluded)');
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), '1HGCM826')),
                jsonb_build_array(tests.fx('rv_civic')), 'vehicle by partial VIN');

-- ------------------------------------------------------------ document numbers
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id, number, score)) from public.search_shop(tests.fx('rshop_a'), '1002')),
                jsonb_build_array(jsonb_build_array('job', tests.fx('rj_1002'), 1002, 2),
                                  jsonb_build_array('quote', tests.fx('rq_1002'), 1002, 2),
                                  jsonb_build_array('invoice', tests.fx('ri_1002'), 1002, 2)),
                'exact number across jobs, quotes and invoices');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, title, subtitle, status, customer_id, job_id))
                   from public.search_shop(tests.fx('rshop_a'), '#1004')),
                jsonb_build_array(
                  jsonb_build_array('job', 'Job #1004', 'Ann_Marie Smith', 'confirmed', tests.fx('rc_ann'), tests.fx('rj_1004')),
                  jsonb_build_array('quote', 'Quote #1004', 'Bob Brown', 'draft', tests.fx('rc_bob'), null),
                  jsonb_build_array('invoice', 'Invoice #1004', 'Ann_Marie Smith', 'partially_paid', tests.fx('rc_ann'), null)),
                '"#" prefix accepted; document row shape');
-- prefix "100": customer "100% Detail Co" + jobs 1001-1009 + quotes 1001-1005 + invoices 1001-1009
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '100')), 24::bigint, 'number prefix search');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, coalesce(number::text, title)))
                   from public.search_shop(tests.fx('rshop_a'), '100', 2)),
                '[["customer","100% Detail Co"],["job","1001"],["job","1002"],["quote","1001"],["quote","1002"],
                  ["invoice","1001"],["invoice","1002"]]'::jsonb,
                'p_limit applies per kind; kinds in a fixed order');

-- ------------------------------------------------------------ archived records stay findable, flagged
select tests.as_superuser();
update public.customers set archived_at = '2025-03-01 00:00+00' where id = tests.fx('rc_annie');
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(id, archived)) from public.search_shop(tests.fx('rshop_a'), 'hall')),
                jsonb_build_array(jsonb_build_array(tests.fx('rc_annie'), true)), 'archived customers are flagged');

-- ------------------------------------------------------------ input validation
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '   ')), 0::bigint, 'blank query returns nothing');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), null)), 0::bigint, 'null query returns nothing');
select tests.throws(format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), repeat('a', 201)),
                    '22023', 'queries over 200 characters rejected');
select tests.throws(format('select * from public.search_shop(%L::uuid, %L, 0)', tests.fx('rshop_a'), 'alice'),
                    '22023', 'limit must be at least 1');
select tests.throws(format('select * from public.search_shop(%L::uuid, %L, 101)', tests.fx('rshop_a'), 'alice'),
                    '22023', 'limit capped at 100');

-- ============================================================ manager: full shop
select tests.authenticate_as(tests.fx('ru_manager_a'));
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '1004')), 3::bigint, 'manager sees job, quote and invoice');

-- ============================================================ technicians
-- tech1 is assigned 1001 1002 1003 1005 1007 (customers Alice, Bob; vehicles Civic, F-150)
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'alice')),
                jsonb_build_array(tests.fx('rc_alice')), 'technician finds a customer of an assigned job');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), 'ann')), 0::bigint,
                'technician does not find customers outside their jobs');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), 'tesla')), 0::bigint,
                'technician does not find vehicles outside their jobs');
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'f-150')),
                jsonb_build_array(tests.fx('rv_f150')), 'technician finds a vehicle of an assigned job');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '1004')), 0::bigint,
                'technician: unassigned job, quote and invoice hidden');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), '1003')),
                jsonb_build_array(jsonb_build_array('job', tests.fx('rj_1003'))),
                'technician: assigned job only (no quotes, no invoices while collecting is off)');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '100') where kind in ('quote', 'invoice')),
                0::bigint, 'technician: no quotes or invoices at all');

select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('rshop_a');
select tests.authenticate_as(tests.fx('ru_tech1_a'));
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_a'), '1003')),
                jsonb_build_array(jsonb_build_array('job', tests.fx('rj_1003')), jsonb_build_array('invoice', tests.fx('ri_1003'))),
                'collecting technician finds the invoice of an assigned job');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, number)) from public.search_shop(tests.fx('rshop_a'), '100')
                  where kind in ('quote', 'invoice')),
                '[["invoice", 1001], ["invoice", 1002], ["invoice", 1003]]'::jsonb,
                'collecting technician: only invoices of assigned jobs, never quotes');
select tests.eq((select count(*) from public.search_shop(tests.fx('rshop_a'), '1004')), 0::bigint,
                'collecting technician: other invoices still hidden');

select tests.authenticate_as(tests.fx('ru_tech2_a'));
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'ann')),
                jsonb_build_array(tests.fx('rc_ann')), 'tech2 finds Ann (job 1004) but not Annie');
select tests.eq((select jsonb_agg(id) from public.search_shop(tests.fx('rshop_a'), 'tesla')),
                jsonb_build_array(tests.fx('rv_tesla')), 'tech2 finds the Tesla');

-- ============================================================ shop B and isolation
select tests.authenticate_as(tests.fx('ru_owner_b'));
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_b'), 'abc123')),
                jsonb_build_array(jsonb_build_array('vehicle', tests.fx('rv_b'))), 'shop B finds its own vehicle');
select tests.eq((select jsonb_agg(jsonb_build_array(kind, id)) from public.search_shop(tests.fx('rshop_b'), '1001')),
                jsonb_build_array(jsonb_build_array('job', tests.fx('rj_b1'))), 'shop B numbers are its own');
select tests.throws(format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), 'alice'),
                    '42501', 'owner of B cannot search shop A');
select tests.authenticate_as(tests.fx('ru_tech_b'));
select tests.throws(format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), 'alice'),
                    '42501', 'technician of B cannot search shop A');
select tests.authenticate_as(tests.fx('ru_outsider'));
select tests.throws(format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), 'alice'),
                    '42501', 'non-member cannot search');
select tests.as_anon();
select tests.throws(format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), 'alice'),
                    '42501', 'anon cannot execute search_shop');
select tests.as_superuser();
