-- ============================================================================
-- 0004 — CRM (SPEC §4.2): customers, vehicles.
-- Technician visibility (only customers/vehicles on their assigned jobs) is
-- added in 0006 once jobs exist.
-- ============================================================================

create table public.customers (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops (id) on delete cascade,
  first_name          text check (first_name is null or char_length(first_name) <= 100),
  last_name           text check (last_name is null or char_length(last_name) <= 100),
  company             text check (company is null or char_length(company) <= 200),
  email               extensions.citext check (email is null or public.is_valid_email(email::text)),
  phone               text check (phone is null or public.is_valid_e164(phone)),
  address_line1       text check (address_line1 is null or char_length(address_line1) <= 200),
  address_line2       text check (address_line2 is null or char_length(address_line2) <= 200),
  city                text check (city is null or char_length(city) <= 100),
  region              text check (region is null or char_length(region) <= 100),
  postal_code         text check (postal_code is null or char_length(postal_code) <= 20),
  country             text check (country is null or country ~ '^[A-Z]{2}$'),
  lat                 double precision check (lat is null or lat between -90 and 90),
  lng                 double precision check (lng is null or lng between -180 and 180),
  notes               text check (notes is null or char_length(notes) <= 20000),
  tags                text[] not null default '{}'
                        check (array_position(tags, null) is null and cardinality(tags) <= 50),
  lifecycle           public.customer_lifecycle not null default 'customer',
  source              public.customer_source not null default 'staff',
  sms_opt_in          boolean not null default false,
  email_opt_in        boolean not null default false,
  portal_user_id      uuid references auth.users (id) on delete set null,
  stripe_customer_id  text check (stripe_customer_id is null or stripe_customer_id ~ '^cus_[A-Za-z0-9]+$'),
  archived_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- server-maintained search haystack (trigram indexed)
  search_text         text generated always as (
                        lower(coalesce(first_name, '') || ' ' || coalesce(last_name, '') || ' ' ||
                              coalesce(company, '') || ' ' || coalesce(email::text, '') || ' ' ||
                              coalesce(phone, ''))) stored,
  constraint customers_shop_id_id_key unique (shop_id, id),
  constraint customers_has_name check (
    coalesce(nullif(btrim(first_name), ''), nullif(btrim(last_name), ''), nullif(btrim(company), '')) is not null),
  constraint customers_lat_lng_pair check ((lat is null) = (lng is null))
);
create index customers_shop_name_idx on public.customers (shop_id, last_name, first_name);
create index customers_shop_email_idx on public.customers (shop_id, email);
create index customers_shop_phone_idx on public.customers (shop_id, phone);
create index customers_portal_user_idx on public.customers (portal_user_id);
create unique index customers_shop_stripe_customer_key on public.customers (shop_id, stripe_customer_id)
  where stripe_customer_id is not null;
create index customers_search_trgm_idx on public.customers using gin (search_text extensions.gin_trgm_ops);
create index customers_tags_idx on public.customers using gin (tags);

-- Direct writes cannot link portal accounts or Stripe customers (those come
-- from portal_claim_customers and the payments edge function).
create function public.customers_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.portal_user_id is not null then
      raise exception 'portal_user_id is set by the client portal, not directly' using errcode = '42501';
    end if;
    if new.stripe_customer_id is not null then
      raise exception 'stripe_customer_id is managed by the payments service' using errcode = '42501';
    end if;
  else
    if new.portal_user_id is not null and new.portal_user_id is distinct from old.portal_user_id then
      raise exception 'portal_user_id can only be cleared, not set directly' using errcode = '42501';
    end if;
    if new.stripe_customer_id is distinct from old.stripe_customer_id then
      raise exception 'stripe_customer_id is managed by the payments service' using errcode = '42501';
    end if;
  end if;
  new.tags := coalesce(new.tags, '{}');
  return new;
end
$$;

create trigger customers_10_prevent_shop_change before update on public.customers
  for each row execute function public.prevent_shop_change();
create trigger customers_20_client_guard before insert or update on public.customers
  for each row execute function public.customers_client_guard();
create trigger customers_90_set_updated_at before update on public.customers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- vehicles
-- ---------------------------------------------------------------------------
create table public.vehicles (
  id             uuid primary key default gen_random_uuid(),
  shop_id        uuid not null references public.shops (id) on delete cascade,
  customer_id    uuid not null,
  year           smallint check (year is null or year between 1886 and 2100),
  make           text check (make is null or char_length(make) <= 60),
  model          text check (model is null or char_length(model) <= 60),
  trim           text check (trim is null or char_length(trim) <= 60),
  color          text check (color is null or char_length(color) <= 40),
  vin            text check (vin is null or vin ~ '^[A-Z0-9]{5,17}$'),
  license_plate  text check (license_plate is null or char_length(license_plate) <= 15),
  category_id    uuid,
  notes          text check (notes is null or char_length(notes) <= 20000),
  archived_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  search_text    text generated always as (
                   lower(coalesce(year::text, '') || ' ' || coalesce(make, '') || ' ' || coalesce(model, '') || ' ' ||
                         coalesce(trim, '') || ' ' || coalesce(color, '') || ' ' ||
                         coalesce(license_plate, '') || ' ' || coalesce(vin, ''))) stored,
  constraint vehicles_shop_id_id_key unique (shop_id, id),
  constraint vehicles_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint vehicles_category_fk foreign key (shop_id, category_id)
    references public.vehicle_categories (shop_id, id) on delete set null (category_id)
);
create index vehicles_shop_customer_idx on public.vehicles (shop_id, customer_id);
create index vehicles_shop_category_idx on public.vehicles (shop_id, category_id);
create index vehicles_shop_vin_idx on public.vehicles (shop_id, vin);
create index vehicles_shop_plate_idx on public.vehicles (shop_id, license_plate);
create index vehicles_search_trgm_idx on public.vehicles using gin (search_text extensions.gin_trgm_ops);

-- Normalize VIN / plate to upper case without spaces.
create function public.vehicles_normalize() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.vin := nullif(upper(regexp_replace(coalesce(new.vin, ''), '[[:space:]-]', '', 'g')), '');
  new.license_plate := nullif(upper(btrim(coalesce(new.license_plate, ''))), '');
  return new;
end
$$;

create trigger vehicles_10_prevent_shop_change before update on public.vehicles
  for each row execute function public.prevent_shop_change();
create trigger vehicles_20_normalize before insert or update on public.vehicles
  for each row execute function public.vehicles_normalize();
create trigger vehicles_90_set_updated_at before update on public.vehicles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS — owner/admin/manager: full access. (Technician read policies: 0006.)
-- ---------------------------------------------------------------------------
alter table public.customers enable row level security;
alter table public.vehicles  enable row level security;

create policy customers_select_staff on public.customers for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy customers_insert on public.customers for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy customers_update on public.customers for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy customers_delete on public.customers for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy vehicles_select_staff on public.vehicles for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy vehicles_insert on public.vehicles for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy vehicles_update on public.vehicles for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy vehicles_delete on public.vehicles for delete to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.customers, public.vehicles from anon;
revoke execute on function public.customers_client_guard(), public.vehicles_normalize()
  from public, anon, authenticated;
