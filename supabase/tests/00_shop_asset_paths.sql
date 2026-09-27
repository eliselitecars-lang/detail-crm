-- 00 foundation: shops.logo_path and services.image_path (SPEC §4.6) name an
-- object of the row's OWN shop in the shop-assets bucket — never another
-- tenant's folder, an unsafe name or a file that was not uploaded. Runs with
-- only the foundation range applied: the objects are written as the
-- superuser (the storage policies of 0025 are tested in 20_storage.sql).
\ir fixtures/two_shops.psql

select tests.as_superuser();
-- the buckets are created by 0025; make sure they exist when only 0001-0009 are applied
insert into storage.buckets (id, name, public) values ('shop-assets', 'shop-assets', true), ('job-photos', 'job-photos', false)
on conflict (id) do nothing;
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('shop-assets', tests.fx('shop_a') || '/logo.png',         tests.fx('u_admin_a'), tests.fx('u_admin_a')::text),
  ('shop-assets', tests.fx('shop_a') || '/logo-v2.webp',     tests.fx('u_admin_a'), tests.fx('u_admin_a')::text),
  ('shop-assets', tests.fx('shop_a') || '/services/wash.png', tests.fx('u_admin_a'), tests.fx('u_admin_a')::text),
  ('shop-assets', tests.fx('shop_b') || '/logo.png',         tests.fx('u_owner_b'), tests.fx('u_owner_b')::text),
  ('shop-assets', tests.fx('shop_b') || '/secret-promo.png', tests.fx('u_owner_b'), tests.fx('u_owner_b')::text),
  -- same name in a private bucket: only shop-assets objects count
  ('job-photos',  tests.fx('shop_a') || '/not-an-asset.png', tests.fx('u_admin_a'), tests.fx('u_admin_a')::text)
on conflict do nothing;

-- =================================================================== is_shop_asset_path (pure)
select tests.ok(public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/logo.png'), 'own folder file');
select tests.ok(public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/services/a b.png'), 'nested file');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_b') || '/logo.png'), 'other shop''s folder');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), 'shop-a/logo.png'), 'slug is not the shop folder');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), 'logo.png'), 'bare file name');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a')::text), 'folder only');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/'), 'trailing slash');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), '/' || tests.fx('shop_a') || '/logo.png'), 'leading slash');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '//logo.png'), 'empty segment');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/../' || tests.fx('shop_b') || '/logo.png'),
                'dot-dot traversal into another shop');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/./logo.png'), 'dot segment');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), upper(tests.fx('shop_a')::text) || '/logo.png'),
                'upper-case folder (the purge queue matches canonical lower-case uuids)');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/a\b.png'), 'backslash');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || E'/a\nb.png'), 'control character');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), tests.fx('shop_a') || '/' || repeat('x', 1024)), 'longer than 1024');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), 'https://evil.example/logo.png'), 'a URL');
select tests.ok(not public.is_shop_asset_path(null, tests.fx('shop_a') || '/logo.png'), 'null shop');
select tests.ok(not public.is_shop_asset_path(tests.fx('shop_a'), null), 'null path');

-- Same safety rules as the field-ops validator (0020) when that range is applied.
do $$
declare
  v_mismatch integer;
begin
  if to_regprocedure('public.is_safe_storage_path(text)') is null then
    perform tests.ok(true, 'is_safe_storage_path not applied in this range');
    return;
  end if;
  execute $q$
    select count(*)::integer
    from unnest(array['logo.png', 'a/b.png', '/x.png', 'x/', 'x//y.png', 'x/../y.png', 'x/./y.png', '..', 'x/.hidden.png',
                      E'x/a\tb.png', 'x/a\b.png', 'x/' || repeat('y', 1000), 'x/' || repeat('y', 1030)]) as t(suffix)
    where public.is_shop_asset_path($1, $1::text || '/' || t.suffix)
          is distinct from public.is_safe_storage_path($1::text || '/' || t.suffix)
  $q$ into v_mismatch using tests.fx('shop_a');
  perform tests.eq(v_mismatch, 0, 'is_shop_asset_path applies is_safe_storage_path''s rules');
end $$;

-- =================================================================== shops.logo_path
select tests.authenticate_as(tests.fx('u_admin_a'));
-- regression (finding #1): shop A cannot point its logo at shop B's object
select tests.throws(format($$update public.shops set logo_path = '%s/logo.png' where id = '%s'$$, tests.fx('shop_b'), tests.fx('shop_a')),
                    '23514', 'shop A cannot point its logo at shop B''s object');
select tests.throws(format($$update public.shops set logo_path = '%s/../%s/logo.png' where id = '%s'$$,
                           tests.fx('shop_a'), tests.fx('shop_b'), tests.fx('shop_a')),
                    '23514', 'no traversal out of the own folder');
select tests.throws(format($$update public.shops set logo_path = 'https://evil.example/logo.png' where id = '%s'$$, tests.fx('shop_a')),
                    '23514', 'an arbitrary string is not a logo path');
select tests.throws(format($$update public.shops set logo_path = '%s/missing.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('shop_a')),
                    '23514', 'the logo must be uploaded before its path is saved');
select tests.throws(format($$update public.shops set logo_path = '%s/not-an-asset.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('shop_a')),
                    '23514', 'an object in another bucket is not a shop asset');
select tests.lives(format($$update public.shops set logo_path = '%s/logo.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('shop_a')),
                   'admin sets the uploaded logo of the own shop');
select tests.eq((select logo_path from public.shops where id = tests.fx('shop_a')), tests.fx('shop_a') || '/logo.png', 'logo saved');
select tests.lives(format($$update public.shops set logo_path = '%s/logo-v2.webp' where id = '%s'$$, tests.fx('shop_a'), tests.fx('shop_a')),
                   'replace with another uploaded logo');
-- cross-shop: shop A's admin cannot touch shop B's row at all
select tests.eq(tests.row_count(format($$update public.shops set logo_path = null where id = '%s'$$, tests.fx('shop_b'))), 0::bigint,
                'admin A cannot change shop B''s logo');

-- the stored file may disappear later (deleted through the Storage API);
-- unrelated edits keep working, only a new path is checked
select tests.as_superuser();
delete from storage.objects where bucket_id = 'shop-assets' and name = tests.fx('shop_a') || '/logo-v2.webp';
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives(format($$update public.shops set name = 'Shop A Detailing' where id = '%s'$$, tests.fx('shop_a')),
                   'unrelated update with a since-deleted logo object');
select tests.lives(format($$update public.shops set logo_path = logo_path where id = '%s'$$, tests.fx('shop_a')),
                   're-saving the unchanged path is not re-checked');
select tests.lives(format($$update public.shops set logo_path = null where id = '%s'$$, tests.fx('shop_a')), 'clear the logo');

-- a technician (not admin) cannot set the logo at all
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count(format($$update public.shops set logo_path = '%s/logo.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('shop_a'))),
                0::bigint, 'technician cannot set the logo');

-- the rule is a constraint, not a policy: service_role and direct inserts obey it too
select tests.as_service();
select tests.throws(format($$update public.shops set logo_path = '%s/logo.png' where id = '%s'$$, tests.fx('shop_b'), tests.fx('shop_a')),
                    '23514', 'service_role cannot cross-link logos either');
select tests.as_superuser();
select tests.throws(format($$insert into public.shops (id, name, slug, timezone, logo_path)
                            values ('%s', 'Shop C', 'shop-c', 'America/Chicago', '%s/logo.png')$$,
                           gen_random_uuid(), tests.fx('shop_b')),
                    '23514', 'a new shop cannot start with another shop''s logo');
select tests.lives(format($$update public.shops set logo_path = '%s/logo.png' where id = '%s'$$, tests.fx('shop_b'), tests.fx('shop_b')),
                   'shop B keeps its own logo');

-- =================================================================== services.image_path
select tests.authenticate_as(tests.fx('u_manager_a'));
-- regression (finding #1): a service image cannot point into another shop's folder
select tests.throws(format($$update public.services set image_path = '%s/secret-promo.png' where id = '%s'$$, tests.fx('shop_b'), tests.fx('svc_a')),
                    '23514', 'a service image cannot point into another shop''s folder');
select tests.throws(format($$update public.services set image_path = 'secret-promo.png' where id = '%s'$$, tests.fx('svc_a')),
                    '23514', 'a bare file name is not an image path');
select tests.throws(format($$update public.services set image_path = '%s/services/missing.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('svc_a')),
                    '23514', 'the image must be uploaded before its path is saved');
select tests.throws(format($$insert into public.services (shop_id, name, image_path) values ('%s', 'Promo', '%s/secret-promo.png')$$,
                           tests.fx('shop_a'), tests.fx('shop_b')),
                    '23514', 'a new service cannot use another shop''s image');
select tests.lives(format($$update public.services set image_path = '%s/services/wash.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('svc_a')),
                   'manager sets an uploaded image of the own shop');
select tests.eq((select image_path from public.services where id = tests.fx('svc_a')), tests.fx('shop_a') || '/services/wash.png', 'image saved');
select tests.lives(format($$insert into public.services (shop_id, name, image_path) values ('%s', 'Wash Plus', '%s/services/wash.png')$$,
                          tests.fx('shop_a'), tests.fx('shop_a')),
                   'a new service with an uploaded image of the own shop');
select tests.lives(format($$update public.services set image_path = null where id = '%s'$$, tests.fx('svc_a')), 'clear the image');
-- cross-shop: shop A's manager cannot touch shop B's services
select tests.eq(tests.row_count(format($$update public.services set image_path = null where id = '%s'$$, tests.fx('svc_b'))), 0::bigint,
                'manager A cannot change shop B''s service image');
-- a technician cannot edit services
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count(format($$update public.services set image_path = '%s/services/wash.png' where id = '%s'$$, tests.fx('shop_a'), tests.fx('svc_a'))),
                0::bigint, 'technician cannot set a service image');
select tests.as_service();
select tests.throws(format($$update public.services set image_path = '%s/secret-promo.png' where id = '%s'$$, tests.fx('shop_b'), tests.fx('svc_a')),
                    '23514', 'service_role cannot cross-link service images either');

-- the trigger function is internal
select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.require_shop_asset_object()', 'execute')
                and not has_function_privilege('anon', 'public.require_shop_asset_object()', 'execute'),
                'require_shop_asset_object is not executable by API roles');
