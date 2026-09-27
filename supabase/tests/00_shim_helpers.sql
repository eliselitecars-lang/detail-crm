-- 00 foundation: the local Supabase shim and the tests.* helpers behave like
-- the platform (auth.uid()/role()/email()/jwt(), role switching, storage
-- helpers) and assertion helpers really fail when they should.
-- superuser-only assertions are skipped on a non-superuser connection
select rolsuper as is_superuser from pg_roles where rolname = current_user \gset

-- auth.* read request.jwt.claims (current PostgREST) ...
select tests.lives($$select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000abcd","role":"authenticated","email":"x@y.z"}', true)$$);
select tests.eq(auth.uid(), '00000000-0000-0000-0000-00000000abcd'::uuid, 'auth.uid() from request.jwt.claims');
select tests.eq(auth.role(), 'authenticated', 'auth.role() from request.jwt.claims');
select tests.eq(auth.email(), 'x@y.z', 'auth.email() from request.jwt.claims');
select tests.eq(auth.jwt() ->> 'role', 'authenticated', 'auth.jwt() returns the claims');
-- ... and the legacy per-claim settings take precedence, like Supabase.
select tests.lives($$select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000beef', true)$$);
select tests.eq(auth.uid(), '00000000-0000-0000-0000-00000000beef'::uuid, 'legacy request.jwt.claim.sub wins');
select tests.as_superuser();
select tests.ok(auth.uid() is null, 'as_superuser clears claims');

-- role switching
select tests.fx_set('u1', tests.create_user('shim-user@test.local', true, '{"full_name":"Shim User"}'));
select tests.fx_set('u2', tests.create_user('shim-unconfirmed@test.local', false));
select tests.eq((select email_confirmed_at is null from auth.users where id = tests.fx('u2')), true,
                'create_user(confirmed => false) leaves email unconfirmed');
select tests.eq((select concat_ws('/', instance_id, aud, role, raw_app_meta_data ->> 'provider', created_at is not null)
                 from auth.users where id = tests.fx('u1')),
                '00000000-0000-0000-0000-000000000000/authenticated/authenticated/email/t',
                'create_user sets every column GoTrue''s admin API sets (real auth.users.id has no default)');
select tests.as_service();
select tests.throws($$delete from auth.users where id = tests.fx('u2')$$, '42501',
                    'service_role cannot delete auth.users directly (only GoTrue / the owner can), like Supabase');
select tests.as_superuser();
select tests.authenticate_as(tests.fx('u1'));
select tests.eq(current_user::text, 'authenticated', 'authenticate_as switches to role authenticated');
select tests.eq(auth.uid(), tests.fx('u1'), 'authenticate_as sets sub');
select tests.eq(auth.email(), 'shim-user@test.local', 'authenticate_as sets email');
select tests.throws('select count(*) from auth.users', '42501', 'authenticated cannot read auth.users');
select tests.as_anon();
select tests.eq(current_user::text, 'anon', 'as_anon switches to anon');
select tests.ok(auth.uid() is null, 'anon has no uid');
select tests.eq(auth.role(), 'anon', 'anon role claim');
select tests.as_service();
select tests.eq(current_user::text, 'service_role', 'as_service switches to service_role');
select tests.ok((select rolbypassrls from pg_roles where rolname = 'service_role'), 'service_role bypasses RLS');
select tests.as_superuser();
\if :is_superuser
select tests.ok((select rolsuper from pg_roles where rolname = current_user), 'as_superuser returns to superuser');
\else
\echo SKIP (needs superuser): as_superuser returns to the connecting role, which is not a superuser here
\endif

-- roles look like Supabase's
select tests.ok(not (select rolcanlogin from pg_roles where rolname = 'anon'), 'anon is NOLOGIN');
select tests.ok(not (select rolcanlogin from pg_roles where rolname = 'authenticated'), 'authenticated is NOLOGIN');
select tests.ok((select rolcanlogin and not rolinherit from pg_roles where rolname = 'authenticator'),
                'authenticator is LOGIN NOINHERIT');
select tests.ok(pg_has_role('authenticator', 'authenticated', 'member'), 'authenticator can become authenticated');

-- extensions live in schema extensions
select tests.eq((select count(*) from pg_extension e join pg_namespace n on n.oid = e.extnamespace
                  where n.nspname = 'extensions' and e.extname in ('citext', 'pg_trgm', 'btree_gist', 'pgcrypto')),
                4::bigint, 'citext, pg_trgm, btree_gist, pgcrypto are in schema extensions');
select tests.ok(exists (select 1 from pg_publication where pubname = 'supabase_realtime'),
                'supabase_realtime publication exists');

-- storage helpers
select tests.eq(storage.foldername('shop-1/jobs/abc/photo.jpg'), array['shop-1', 'jobs', 'abc'], 'storage.foldername');
select tests.eq(storage.filename('shop-1/jobs/abc/photo.jpg'), 'photo.jpg', 'storage.filename');
select tests.eq(storage.extension('shop-1/jobs/abc/photo.tar.gz'), 'gz', 'storage.extension');
select tests.ok((select relrowsecurity from pg_class where oid = 'storage.objects'::regclass), 'storage.objects has RLS');
select tests.ok((select relrowsecurity from pg_class where oid = 'storage.buckets'::regclass), 'storage.buckets has RLS');
select tests.lives($$insert into storage.buckets (id, name) values ('shim-bucket', 'shim-bucket')$$);
select tests.lives($$insert into storage.objects (bucket_id, name) values ('shim-bucket', 'a/b/c.png')$$);
select tests.eq((select path_tokens from storage.objects where name = 'a/b/c.png'), array['a', 'b', 'c.png'],
                'storage.objects.path_tokens is generated');

-- the assertion helpers fail when they should
select tests.throws($$select tests.ok(false, 'expected failure')$$, 'P0001', 'ok(false) raises');
select tests.throws($$select tests.ok(null, 'expected failure')$$, 'P0001', 'ok(null) raises');
select tests.throws($$select tests.eq(1, 2, 'expected failure')$$, 'P0001', 'eq(1, 2) raises');
select tests.throws($$select tests.eq(1, null::int, 'expected failure')$$, 'P0001', 'eq(1, null) raises');
select tests.throws($$select tests.throws('select 1')$$, 'P0001', 'throws() on a succeeding statement raises');
select tests.throws($$select tests.throws('select 1/0', '42501')$$, 'P0001', 'throws() with the wrong SQLSTATE raises');
select tests.throws($$select tests.throws_like('select 1/0', '22012', '%nope%')$$, 'P0001',
                    'throws_like() with a non-matching message raises');
select tests.throws_like('select 1/0', '22012', '%division by zero%', 'throws_like matches message');
select tests.throws($$select tests.lives('select 1/0')$$, 'P0001', 'lives() on a failing statement raises');
select tests.eq(tests.row_count('select generate_series(1, 3)'), 3::bigint, 'row_count counts SELECT rows');
select tests.eq(tests.row_count($$update storage.objects set metadata = '{}' where bucket_id = 'shim-bucket'$$),
                1::bigint, 'row_count counts affected rows');
select tests.throws($$select tests.fx('missing-fixture')$$, 'P0001', 'fx() on a missing key raises');
