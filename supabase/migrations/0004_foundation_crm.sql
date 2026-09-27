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

-- A vehicle's owner is part of every document that references it: jobs,
-- job/quote/invoice lines, quotes, memberships and inspections all require
-- their vehicle to belong to the document's customer. Moving a referenced
-- vehicle to another customer would silently hand the old customer's history
-- (and vehicle-scoped memberships) to the new one and break later steps such
-- as converting an approved quote. So a vehicle may change customer only
-- while nothing references it; a sold car becomes a new vehicle record for
-- the new owner. Referencing tables are discovered from the catalog, so
-- tables added by later migrations are covered without changes here. AFTER,
-- so RLS and the composite customer FK (another shop's customer -> 23503)
-- are checked first; runs in every context.
create function public.vehicles_keep_owner_history() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  r        record;
  v_found  boolean;
begin
  for r in
    select format('%I.%I', n.nspname, cl.relname) as tbl,
           cl.relname::text as label,
           string_agg(format('t.%I = ($1).%I', a.attname, fa.attname), ' and ' order by k.ord) as cond
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class cl on cl.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = cl.relnamespace
    cross join lateral unnest(c.conkey, c.confkey) with ordinality as k(att, fatt, ord)
    join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.att
    join pg_catalog.pg_attribute fa on fa.attrelid = c.confrelid and fa.attnum = k.fatt
    where c.contype = 'f' and c.confrelid = 'public.vehicles'::regclass
    group by c.oid, n.nspname, cl.relname
    order by n.nspname, cl.relname, c.oid
  loop
    execute format('select exists (select 1 from %s t where %s)', r.tbl, r.cond) into v_found using old;
    if v_found then
      raise exception 'this vehicle is referenced by % of its current customer and cannot be moved to another customer; add it as a new vehicle for the new owner',
                      replace(r.label, '_', ' ')
        using errcode = '23514';
    end if;
  end loop;
  return null;
end
$$;

create trigger vehicles_keep_owner_history after update of customer_id on public.vehicles
  for each row when (new.customer_id is distinct from old.customer_id)
  execute function public.vehicles_keep_owner_history();

-- Race guard for the rule above. A document that starts referencing the
-- vehicle takes only FOR KEY SHARE on it (its composite FK check), and a
-- plain customer_id change takes FOR NO KEY UPDATE (customer_id is in no
-- unique index); those do not conflict, so an owner change and an
-- uncommitted job/quote/line/membership/inspection for the old owner could
-- both commit, leaving the document with another customer's vehicle.
-- Upgrading the row lock to FOR UPDATE before the row is changed conflicts
-- with FOR KEY SHARE in both orders:
--   * the reference came first: the move waits until it commits, then the
--     AFTER check above (fresh snapshot) sees it and refuses the move;
--   * the move came first: the other transaction's FK check waits until the
--     move commits, then its AFTER validator (every vehicle-ownership
--     validator is an AFTER trigger, and AFTER row triggers fire by name, so
--     after the "RI_ConstraintTrigger_*" FK check) reads the new owner and
--     refuses the document.
create function public.vehicles_lock_owner_change() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform 1 from public.vehicles v where v.shop_id = old.shop_id and v.id = old.id for update;
  return new;
end
$$;

create trigger vehicles_15_lock_owner_change before update of customer_id on public.vehicles
  for each row when (new.customer_id is distinct from old.customer_id)
  execute function public.vehicles_lock_owner_change();

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
revoke execute on function public.customers_client_guard(), public.vehicles_normalize(),
  public.vehicles_keep_owner_history(), public.vehicles_lock_owner_change()
  from public, anon, authenticated;
