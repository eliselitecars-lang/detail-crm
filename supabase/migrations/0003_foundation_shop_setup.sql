-- ============================================================================
-- 0003 — Shop setup (SPEC §4.1): vehicle_categories, business_hours,
-- blocked_times, resources, booking_settings + per-shop seeding.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- vehicle_categories — shop-defined size classes used for pricing.
-- ---------------------------------------------------------------------------
create table public.vehicle_categories (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 60),
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint vehicle_categories_shop_id_id_key unique (shop_id, id)
);
create unique index vehicle_categories_shop_name_key on public.vehicle_categories (shop_id, lower(name));

create trigger vehicle_categories_10_prevent_shop_change before update on public.vehicle_categories
  for each row execute function public.prevent_shop_change();
create trigger vehicle_categories_90_set_updated_at before update on public.vehicle_categories
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- business_hours — weekday 0 = Sunday … 6 = Saturday (extract(dow)). Several
-- non-overlapping intervals per day allowed; no row = closed. Times are wall
-- clock in the shop's time zone; closes_at may be 24:00.
-- ---------------------------------------------------------------------------
create table public.business_hours (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  opens_at    time not null,
  closes_at   time not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint business_hours_shop_id_id_key unique (shop_id, id),
  constraint business_hours_order check (closes_at > opens_at),
  constraint business_hours_no_overlap exclude using gist (
    shop_id with =,
    weekday with =,
    numrange(extract(epoch from opens_at), extract(epoch from closes_at)) with &&)
);

create trigger business_hours_10_prevent_shop_change before update on public.business_hours
  for each row execute function public.prevent_shop_change();
create trigger business_hours_90_set_updated_at before update on public.business_hours
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- blocked_times — member_id null blocks the whole shop (and online booking).
-- ---------------------------------------------------------------------------
create table public.blocked_times (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  member_id   uuid,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  reason      text check (reason is null or char_length(reason) <= 500),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint blocked_times_shop_id_id_key unique (shop_id, id),
  constraint blocked_times_order check (ends_at > starts_at),
  constraint blocked_times_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id) on delete cascade
);
create index blocked_times_shop_range_idx on public.blocked_times using gist (shop_id, tstzrange(starts_at, ends_at));
create index blocked_times_shop_member_idx on public.blocked_times (shop_id, member_id);
create index blocked_times_created_by_idx on public.blocked_times (created_by);

create trigger blocked_times_10_prevent_shop_change before update on public.blocked_times
  for each row execute function public.prevent_shop_change();
create trigger blocked_times_20_set_created_by before insert or update on public.blocked_times
  for each row execute function public.set_created_by();
create trigger blocked_times_90_set_updated_at before update on public.blocked_times
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- resources — bays / vans.
-- ---------------------------------------------------------------------------
create table public.resources (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 80),
  kind         public.resource_kind not null default 'bay',
  active       boolean not null default true,
  sort         integer not null default 0,
  archived_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint resources_shop_id_id_key unique (shop_id, id)
);

create trigger resources_10_prevent_shop_change before update on public.resources
  for each row execute function public.prevent_shop_change();
create trigger resources_90_set_updated_at before update on public.resources
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- booking_settings — one row per shop (seeded, disabled by default).
-- ---------------------------------------------------------------------------
create table public.booking_settings (
  shop_id                    uuid primary key references public.shops (id) on delete cascade,
  enabled                    boolean not null default false,
  auto_confirm               boolean not null default false,
  lead_time_minutes          integer not null default 120 check (lead_time_minutes between 0 and 43200),
  max_days_ahead             integer not null default 60 check (max_days_ahead between 1 and 365),
  slot_interval_minutes      integer not null default 30 check (slot_interval_minutes between 5 and 240),
  buffer_minutes             integer not null default 0 check (buffer_minutes between 0 and 480),
  max_concurrent_jobs        integer not null default 1 check (max_concurrent_jobs between 1 and 100),
  require_deposit            boolean not null default false,
  deposit_type               public.deposit_type not null default 'percent',
  deposit_value              bigint not null default 0 check (deposit_value >= 0),
  service_area_postal_codes  text[] not null default '{}'
                               check (array_position(service_area_postal_codes, null) is null),
  booking_message            text check (booking_message is null or char_length(booking_message) <= 5000),
  cancellation_policy        text check (cancellation_policy is null or char_length(cancellation_policy) <= 5000),
  allow_client_cancel_hours  integer not null default 24 check (allow_client_cancel_hours between 0 and 8760),
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  constraint booking_settings_deposit_percent check (deposit_type <> 'percent' or deposit_value <= 10000),
  constraint booking_settings_deposit_required check (not require_deposit or deposit_value > 0)
);

create trigger booking_settings_10_prevent_shop_change before update on public.booking_settings
  for each row execute function public.prevent_shop_change();
create trigger booking_settings_90_set_updated_at before update on public.booking_settings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Seed this range's defaults for every new shop (names only — no prices).
-- ---------------------------------------------------------------------------
create function public.shops_seed_shop_setup() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.booking_settings (shop_id, enabled) values (new.id, false)
  on conflict (shop_id) do nothing;

  insert into public.vehicle_categories (shop_id, name, sort)
  values (new.id, 'Car', 1),
         (new.id, 'Small SUV', 2),
         (new.id, 'Large SUV / Truck', 3),
         (new.id, 'Van', 4);
  return null;
end
$$;

create trigger shops_seed_shop_setup after insert on public.shops
  for each row execute function public.shops_seed_shop_setup();

-- ---------------------------------------------------------------------------
-- RLS — all members read; settings are owner/admin; blocked times are part
-- of the calendar so managers may edit them too (SPEC §3 "Jobs / calendar").
-- ---------------------------------------------------------------------------
alter table public.vehicle_categories enable row level security;
alter table public.business_hours     enable row level security;
alter table public.blocked_times      enable row level security;
alter table public.resources          enable row level security;
alter table public.booking_settings   enable row level security;

create policy vehicle_categories_select on public.vehicle_categories for select to authenticated
  using (public.is_shop_member(shop_id));
create policy vehicle_categories_insert on public.vehicle_categories for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy vehicle_categories_update on public.vehicle_categories for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy vehicle_categories_delete on public.vehicle_categories for delete to authenticated
  using (public.is_shop_admin(shop_id));

create policy business_hours_select on public.business_hours for select to authenticated
  using (public.is_shop_member(shop_id));
create policy business_hours_insert on public.business_hours for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy business_hours_update on public.business_hours for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy business_hours_delete on public.business_hours for delete to authenticated
  using (public.is_shop_admin(shop_id));

create policy blocked_times_select on public.blocked_times for select to authenticated
  using (public.is_shop_member(shop_id));
create policy blocked_times_insert on public.blocked_times for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy blocked_times_update on public.blocked_times for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy blocked_times_delete on public.blocked_times for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy resources_select on public.resources for select to authenticated
  using (public.is_shop_member(shop_id));
create policy resources_insert on public.resources for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy resources_update on public.resources for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy resources_delete on public.resources for delete to authenticated
  using (public.is_shop_admin(shop_id));

create policy booking_settings_select on public.booking_settings for select to authenticated
  using (public.is_shop_member(shop_id));
create policy booking_settings_update on public.booking_settings for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));

revoke all on public.vehicle_categories, public.business_hours, public.blocked_times,
              public.resources, public.booking_settings from anon;
revoke insert, delete, truncate on public.booking_settings from authenticated;
revoke truncate on public.vehicle_categories, public.business_hours, public.blocked_times,
                   public.resources from authenticated;

revoke execute on function public.shops_seed_shop_setup() from public, anon, authenticated;
