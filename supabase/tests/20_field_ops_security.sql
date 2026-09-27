-- 20 field ops: schema-level guarantees for this range's tables and
-- functions (grants, FK indexes, owner-only helpers, RPC privileges).
select tests.as_superuser();

create temporary table fo_tables (name text primary key);
insert into fo_tables values ('checklist_templates'), ('job_checklist_items'), ('inspections'), ('inspection_marks'),
                             ('job_photos'), ('form_templates'), ('form_submissions'), ('time_entries');

select tests.eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname in (select name from fo_tables) and c.relrowsecurity),
                8::bigint, 'every field-ops table exists with RLS enabled');

select tests.eq((
  select coalesce(string_agg(table_name || ':' || grantee || ':' || privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public' and table_name in (select name from fo_tables)
    and (grantee = 'anon' or (grantee = 'authenticated' and privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES')))),
  '', 'anon holds nothing and authenticated has no TRUNCATE/TRIGGER/REFERENCES on field-ops tables');

select tests.ok(not has_table_privilege('authenticated', 'public.form_submissions', 'update'),
                'form submissions are only changed through the signing RPCs');

-- every FK on a field-ops table is backed by an index whose leading columns are the FK columns
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_namespace n on n.oid = child.relnamespace and n.nspname = 'public'
  where con.contype = 'f'
    and child.relname in (select name from fo_tables)
    and not exists (
      select 1 from pg_index i
      where i.indrelid = con.conrelid
        and (select array_agg(x order by x) from unnest((i.indkey::int2[])[0:cardinality(con.conkey) - 1]) x)
            = (select array_agg(x order by x) from unnest(con.conkey) x))),
  '', 'every field-ops FK is backed by an index');

-- every FK between field-ops tables and other tenant tables is composite on shop_id
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_class parent on parent.oid = con.confrelid
  join pg_namespace pn on pn.oid = parent.relnamespace
  where con.contype = 'f'
    and child.relname in (select name from fo_tables)
    and pn.nspname = 'public' and parent.relname <> 'shops'
    and not exists (select 1 from unnest(con.conkey) k
                    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k
                    where a.attname = 'shop_id')),
  '', 'field-ops FKs to tenant tables include shop_id');

-- trigger functions and internal helpers are not callable by API roles
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('checklist_templates_normalize', 'job_checklist_items_client_guard', 'job_line_items_attach_checklists',
                      'checklist_attach_template', 'inspections_client_guard', 'inspections_validate',
                      'inspection_marks_client_guard', 'inspection_marks_validate', 'job_photos_client_guard',
                      'job_photos_validate', 'form_templates_normalize', 'form_submissions_before_insert',
                      'form_submissions_client_guard', 'jobs_attach_forms', 'jobs_sync_form_customer',
                      'form_submission_public_json', 'form_submission_sign', 'time_entries_client_guard',
                      'storage_object_exists', 'form_signer_ip')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'internal field-ops functions are not executable by anon/authenticated');

-- staff RPCs: authenticated only; public RPCs: anon too
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('apply_checklist_template', 'sign_form_submission', 'clock_in', 'clock_out', 'can_work_job')
    and (has_function_privilege('anon', p.oid, 'execute') or not has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'staff RPCs are executable by authenticated and not by anon');
select tests.eq((
  select count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('public_get_form', 'public_sign_form', 'public_form_signature_upload_allowed')
    and has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute')),
  3::bigint, 'public form RPCs are executable by anon and authenticated');

-- every SECURITY DEFINER function of this range pins search_path = ''
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.proname in ('can_work_job', 'storage_object_exists', 'checklist_attach_template', 'job_line_items_attach_checklists',
                      'apply_checklist_template', 'inspections_validate', 'inspection_marks_validate', 'job_photos_validate',
                      'jobs_attach_forms', 'jobs_sync_form_customer', 'form_submission_public_json', 'form_submission_sign',
                      'public_get_form', 'public_sign_form', 'public_form_signature_upload_allowed',
                      'sign_form_submission', 'clock_in', 'clock_out', 'is_signed_evidence', 'can_read_signature_object')
    and not coalesce('search_path=""' = any (p.proconfig), false)),
  '', 'field-ops SECURITY DEFINER functions pin an empty search_path');

-- guard triggers must be SECURITY INVOKER (client context is detected from current_user)
select tests.eq((
  select coalesce(string_agg(p.proname, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.proname in ('job_checklist_items_client_guard', 'inspections_client_guard', 'inspection_marks_client_guard',
                      'job_photos_client_guard', 'form_submissions_before_insert', 'form_submissions_client_guard',
                      'time_entries_client_guard')),
  '', 'client guard triggers are SECURITY INVOKER');

-- storage policy helpers: authenticated (policies run as the caller), never anon
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('is_signed_evidence', 'can_read_signature_object')
    and (has_function_privilege('anon', p.oid, 'execute') or not has_function_privilege('authenticated', p.oid, 'execute')
         or not p.prosecdef)),
  '', 'storage policy helpers are SECURITY DEFINER, executable by authenticated and not by anon');
select tests.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname in ('is_signed_evidence', 'can_read_signature_object')),
                2::bigint, 'both storage policy helpers exist');

-- signed evidence is locked in every UPDATE/DELETE policy of the evidence buckets
select tests.eq((select coalesce(string_agg(policyname, ', ' order by 1), '') from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and policyname in ('field_ops_job_photos_update', 'field_ops_job_photos_delete',
                                       'field_ops_signatures_update', 'field_ops_signatures_delete')
                    and qual not like '%is_signed_evidence%'),
                '', 'evidence-bucket overwrite/delete policies refuse signed evidence');

-- the storage policies of this range exist
select tests.eq((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname like 'field\_ops\_%'), 13::bigint, 'thirteen storage.objects policies installed');
select tests.eq((select coalesce(string_agg(policyname, ', ' order by 1), '') from pg_policies
                  where schemaname = 'storage' and tablename = 'objects' and policyname like 'field\_ops\_%'
                    and 'anon' = any (roles)
                    and policyname not in ('field_ops_shop_assets_select', 'field_ops_signatures_insert_public_form')),
                '', 'anon only reads shop assets and uploads public form signatures');

-- the time-entry overlap guard is a real exclusion constraint
select tests.ok(exists (select 1 from pg_constraint where conname = 'time_entries_no_overlap' and contype = 'x'),
                'time_entries has the no-overlap exclusion constraint');
