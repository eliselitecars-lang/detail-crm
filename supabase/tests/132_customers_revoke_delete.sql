-- 132 (0132): clients have no DELETE privilege on customers (like shops,
-- 0117): a direct delete by any staff role — or anon — is 42501, not a
-- silent "0 rows". A deletion request goes through the payments edge
-- erase_customer, whose RPC (service role) still deletes or anonymises, and
-- the service role can still delete a row directly.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ privileges
select tests.as_superuser();
select tests.ok(not has_table_privilege('authenticated', 'public.customers', 'DELETE'),
                'authenticated has no DELETE on customers');
select tests.ok(not has_table_privilege('anon', 'public.customers', 'DELETE'), 'nor anon');
select tests.ok(not exists (select 1 from information_schema.role_table_grants
                             where table_schema = 'public' and table_name = 'customers'
                               and privilege_type = 'DELETE' and grantee in ('PUBLIC', 'anon', 'authenticated')),
                'no DELETE grant to PUBLIC, anon or authenticated');
select tests.ok(has_table_privilege('service_role', 'public.customers', 'DELETE'), 'service_role keeps DELETE');
select tests.ok(not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customers' and cmd = 'DELETE'),
                'and there is still no DELETE policy (0125)');
select tests.ok(has_table_privilege('authenticated', 'public.customers', 'SELECT')
                and has_any_column_privilege('authenticated', 'public.customers', 'INSERT')
                and has_any_column_privilege('authenticated', 'public.customers', 'UPDATE'),
                'staff still read, create and edit customers (RLS decides which)');

-- ------------------------------------------------------------ a direct delete is 42501 for every role
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501',
                    'the owner cannot delete a customer directly (only payments erase_customer)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501', 'nor an admin');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501', 'nor a manager');
select tests.throws($$delete from public.customers where shop_id = tests.fx('shop_b')$$, '42501',
                    'nor another shop''s customers');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501', 'nor a technician');
select tests.as_anon();
select tests.throws($$delete from public.customers where id = tests.fx('cust_a3')$$, '42501', 'nor anon');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where id in (tests.fx('cust_a3'), tests.fx('cust_b'))), 2::bigint,
                'nothing was deleted');

-- other writes are unchanged: a manager still edits and archives
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.customers set notes = 'Prefers mornings' where id = tests.fx('cust_a3')$$), 1::bigint,
                'managers still edit customers');

-- ------------------------------------------------------------ erase_customer (service role) still works
select tests.as_service();
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_admin_a'), true) ->> 'mode', 'deleted',
                'dry run: a customer without jobs, invoices, payments or memberships would be deleted');
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a3'), tests.fx('u_admin_a')), '{"mode": "deleted"}'::jsonb,
                'erase_customer deletes it');
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.customers where id = tests.fx('cust_a3')), 'the row is gone');
select tests.eq((select mode || '/' || (erased_by = tests.fx('u_admin_a'))::text from public.customer_erasures
                  where customer_id = tests.fx('cust_a3')),
                'deleted/true', 'and the erasure is audited');

select tests.as_service();
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('u_owner_a'), true) ->> 'mode', 'anonymised',
                'dry run: a customer with a job would be anonymised');
select tests.eq(public.erase_customer(tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('u_owner_a')), '{"mode": "anonymised"}'::jsonb,
                'erase_customer anonymises it');
select tests.as_superuser();
select tests.ok((select erased_at is not null and first_name = 'Deleted' and phone is null and email is null
                   from public.customers where id = tests.fx('cust_a2')),
                'the record stays, without the personal details');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('job_a2') and customer_id = tests.fx('cust_a2')),
                'its job is kept');

-- ------------------------------------------------------------ the service role still deletes a row directly
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Temp') returning tests.fx_set('cust_tmp', id);
select tests.as_service();
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_tmp')$$), 1::bigint,
                'service_role deletes a customer without records');
select tests.throws($$delete from public.customers where id = tests.fx('cust_a')$$, '23503',
                    'and is still refused one that jobs reference');
