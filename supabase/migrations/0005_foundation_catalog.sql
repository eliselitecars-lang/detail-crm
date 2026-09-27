-- ============================================================================
-- 0005 — Catalog (SPEC §4.3): service_categories, services, service_prices,
-- package_items, service_addons, coupons, service_price_for().
-- ============================================================================

create table public.service_categories (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint service_categories_shop_id_id_key unique (shop_id, id)
);
create unique index service_categories_shop_name_key on public.service_categories (shop_id, lower(name));

create trigger service_categories_10_prevent_shop_change before update on public.service_categories
  for each row execute function public.prevent_shop_change();
create trigger service_categories_90_set_updated_at before update on public.service_categories
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
create table public.services (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  category_id       uuid,
  name              text not null check (char_length(btrim(name)) between 1 and 120),
  description       text check (description is null or char_length(description) <= 10000),
  kind              public.service_kind not null default 'service',
  duration_minutes  integer not null default 60 check (duration_minutes between 0 and 1440),
  taxable           boolean not null default true,
  online_bookable   boolean not null default false,
  active            boolean not null default true,
  sort              integer not null default 0,
  image_path        text,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint services_shop_id_id_key unique (shop_id, id),
  constraint services_category_fk foreign key (shop_id, category_id)
    references public.service_categories (shop_id, id) on delete set null (category_id),
  -- the image is an object of THIS shop's shop-assets folder (0001)
  constraint services_image_path_check check (image_path is null or public.is_shop_asset_path(shop_id, image_path))
);
create index services_shop_category_idx on public.services (shop_id, category_id);
create index services_shop_sort_idx on public.services (shop_id, sort, name);

create trigger services_10_prevent_shop_change before update on public.services
  for each row execute function public.prevent_shop_change();
create trigger services_90_set_updated_at before update on public.services
  for each row execute function public.set_updated_at();
-- upload the image first, then save its path
create trigger services_image_object_exists after insert or update of image_path on public.services
  for each row execute function public.require_shop_asset_object('image_path');

-- ---------------------------------------------------------------------------
-- service_prices — vehicle_category_id null = base price. One row per
-- (service, category) with NULLS NOT DISTINCT so there is one base price.
-- ---------------------------------------------------------------------------
create table public.service_prices (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  service_id           uuid not null,
  vehicle_category_id  uuid,
  price_cents          bigint not null check (price_cents >= 0),
  duration_minutes     integer check (duration_minutes is null or duration_minutes between 0 and 1440),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint service_prices_shop_id_id_key unique (shop_id, id),
  constraint service_prices_service_category_key unique nulls not distinct (service_id, vehicle_category_id),
  constraint service_prices_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete cascade,
  constraint service_prices_category_fk foreign key (shop_id, vehicle_category_id)
    references public.vehicle_categories (shop_id, id) on delete cascade
);
create index service_prices_shop_service_idx on public.service_prices (shop_id, service_id);
create index service_prices_shop_category_idx on public.service_prices (shop_id, vehicle_category_id);

create trigger service_prices_10_prevent_shop_change before update on public.service_prices
  for each row execute function public.prevent_shop_change();
create trigger service_prices_90_set_updated_at before update on public.service_prices
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- package_items — what a package includes (packages are not nested).
-- ---------------------------------------------------------------------------
create table public.package_items (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  package_id  uuid not null,
  service_id  uuid not null,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  constraint package_items_shop_id_id_key unique (shop_id, id),
  constraint package_items_package_service_key unique (package_id, service_id),
  constraint package_items_not_self check (package_id <> service_id),
  constraint package_items_package_fk foreign key (shop_id, package_id)
    references public.services (shop_id, id) on delete cascade,
  constraint package_items_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete cascade
);
create index package_items_shop_package_idx on public.package_items (shop_id, package_id);
create index package_items_shop_service_idx on public.package_items (shop_id, service_id);

-- ---------------------------------------------------------------------------
-- service_addons — add-ons offered with a service (none listed = all add-ons).
-- ---------------------------------------------------------------------------
create table public.service_addons (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  service_id  uuid not null,
  addon_id    uuid not null,
  created_at  timestamptz not null default now(),
  constraint service_addons_shop_id_id_key unique (shop_id, id),
  constraint service_addons_service_addon_key unique (service_id, addon_id),
  constraint service_addons_not_self check (service_id <> addon_id),
  constraint service_addons_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete cascade,
  constraint service_addons_addon_fk foreign key (shop_id, addon_id)
    references public.services (shop_id, id) on delete cascade
);
create index service_addons_shop_service_idx on public.service_addons (shop_id, service_id);
create index service_addons_shop_addon_idx on public.service_addons (shop_id, addon_id);

-- Kind rules for package_items / service_addons. AFTER triggers so RLS,
-- constraints and composite FKs reject bad rows first.
create function public.catalog_links_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_parent_kind public.service_kind;
  v_child_kind  public.service_kind;
begin
  if tg_table_name = 'package_items' then
    select kind into v_parent_kind from public.services where id = new.package_id and shop_id = new.shop_id;
    select kind into v_child_kind from public.services where id = new.service_id and shop_id = new.shop_id;
    if v_parent_kind is distinct from 'package' then
      raise exception 'package_items.package_id must reference a service of kind package' using errcode = '23514';
    end if;
    if v_child_kind = 'package' then
      raise exception 'packages cannot contain other packages' using errcode = '23514';
    end if;
  else
    select kind into v_parent_kind from public.services where id = new.service_id and shop_id = new.shop_id;
    select kind into v_child_kind from public.services where id = new.addon_id and shop_id = new.shop_id;
    if v_child_kind is distinct from 'addon' then
      raise exception 'service_addons.addon_id must reference a service of kind addon' using errcode = '23514';
    end if;
    if v_parent_kind = 'addon' then
      raise exception 'add-ons cannot have their own add-ons' using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

create trigger package_items_10_prevent_shop_change before update on public.package_items
  for each row execute function public.prevent_shop_change();
create trigger package_items_validate after insert or update on public.package_items
  for each row execute function public.catalog_links_validate();
create trigger service_addons_10_prevent_shop_change before update on public.service_addons
  for each row execute function public.prevent_shop_change();
create trigger service_addons_validate after insert or update on public.service_addons
  for each row execute function public.catalog_links_validate();

-- A service referenced as a package / add-on keeps the kind it is used as.
create function public.services_kind_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.kind is distinct from old.kind then
    if old.kind = 'package' and exists (select 1 from public.package_items where package_id = new.id) then
      raise exception 'remove the package items before changing this package''s kind' using errcode = '23514';
    end if;
    if old.kind = 'addon' and exists (select 1 from public.service_addons where addon_id = new.id) then
      raise exception 'remove this add-on from services before changing its kind' using errcode = '23514';
    end if;
    if new.kind = 'package' and exists (select 1 from public.package_items where service_id = new.id) then
      raise exception 'a service included in a package cannot become a package' using errcode = '23514';
    end if;
    if new.kind = 'addon' and exists (select 1 from public.service_addons where service_id = new.id) then
      raise exception 'a service with add-ons cannot become an add-on' using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;

create trigger services_20_kind_guard before update of kind on public.services
  for each row execute function public.services_kind_guard();

-- ---------------------------------------------------------------------------
-- coupons — code unique per shop, case-insensitive (citext).
-- ---------------------------------------------------------------------------
create table public.coupons (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops (id) on delete cascade,
  code             extensions.citext not null check (code::text ~ '^[A-Za-z0-9_-]{3,40}$'),
  description      text check (description is null or char_length(description) <= 500),
  kind             public.coupon_kind not null,
  value            bigint not null check (value > 0),
  starts_at        timestamptz,
  ends_at          timestamptz,
  max_redemptions  integer check (max_redemptions is null or max_redemptions > 0),
  redemptions      integer not null default 0 check (redemptions >= 0),
  online_only      boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint coupons_shop_id_id_key unique (shop_id, id),
  constraint coupons_shop_code_key unique (shop_id, code),
  constraint coupons_percent_range check (kind <> 'percent' or value <= 10000),
  constraint coupons_window check (starts_at is null or ends_at is null or ends_at > starts_at)
);

-- redemptions is server-maintained (booking / invoicing RPCs).
create function public.coupons_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    if tg_op = 'INSERT' then
      new.redemptions := 0;
    else
      new.redemptions := old.redemptions;
    end if;
  end if;
  return new;
end
$$;

create trigger coupons_10_prevent_shop_change before update on public.coupons
  for each row execute function public.prevent_shop_change();
create trigger coupons_20_client_guard before insert or update on public.coupons
  for each row execute function public.coupons_client_guard();
create trigger coupons_90_set_updated_at before update on public.coupons
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- service_price_for — category price if defined, else base price; duration
-- from the chosen price row, else the service's own duration. price_cents is
-- null when the service has no applicable price. SECURITY INVOKER: staff see
-- only their shop's services through RLS; definer RPCs call it freely.
-- ---------------------------------------------------------------------------
create function public.service_price_for(p_service_id uuid, p_vehicle_category_id uuid)
returns table (price_cents bigint, duration_minutes integer)
language sql stable
set search_path = ''
as $$
  select p.price_cents,
         coalesce(p.duration_minutes, s.duration_minutes)
  from public.services s
  left join lateral (
    select sp.price_cents, sp.duration_minutes
    from public.service_prices sp
    where sp.service_id = s.id
      and sp.shop_id = s.shop_id
      and (sp.vehicle_category_id = p_vehicle_category_id or sp.vehicle_category_id is null)
    order by (sp.vehicle_category_id is null)   -- category-specific row first
    limit 1
  ) p on true
  where s.id = p_service_id
$$;

-- ---------------------------------------------------------------------------
-- RLS — members read the catalog; managers+ edit it; coupons are a setting
-- (managers+ read, owner/admin edit).
-- ---------------------------------------------------------------------------
alter table public.service_categories enable row level security;
alter table public.services           enable row level security;
alter table public.service_prices     enable row level security;
alter table public.package_items      enable row level security;
alter table public.service_addons     enable row level security;
alter table public.coupons            enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['service_categories', 'services', 'service_prices', 'package_items', 'service_addons'] loop
    execute format('create policy %I on public.%I for select to authenticated using (public.is_shop_member(shop_id))',
                   t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_shop_manager(shop_id))',
                   t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id))',
                   t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_shop_manager(shop_id))',
                   t || '_delete', t);
  end loop;
end
$$;

-- Coupon codes (incl. private, limited and inactive ones) are a shop setting
-- (SPEC §3, §6): managers+ read them to attach to jobs; technicians have no
-- operational need and must not be able to list or leak non-public codes.
create policy coupons_select on public.coupons for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy coupons_insert on public.coupons for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy coupons_update on public.coupons for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy coupons_delete on public.coupons for delete to authenticated
  using (public.is_shop_admin(shop_id));

revoke all on public.service_categories, public.services, public.service_prices,
              public.package_items, public.service_addons, public.coupons from anon;

revoke execute on function public.catalog_links_validate(), public.services_kind_guard(),
                           public.coupons_client_guard()
  from public, anon, authenticated;
-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.service_price_for(uuid, uuid) is '@nullable: price_cents';
revoke execute on function public.service_price_for(uuid, uuid) from public, anon;
grant execute on function public.service_price_for(uuid, uuid) to authenticated, service_role;
