-- ============================================================================
-- 0050 — Scheduling v2 schema (SPEC §9 range 0050-0059). Every new table,
-- column, CHECK, index, RLS policy and grant of the range lives here; the
-- behaviour files after it (0051-0057) add functions and triggers.
--
--   0050  schema (this file)
--   0051  recurring job series (P-1)
--   0052  calendar event kinds, recurrence expansion, calendar_events v2 (P-17)
--   0053  slot engine v2 (capacity per location / member availability,
--         category weekdays, multi-day wrap), private booking links,
--         public_booking_slots, get_available_slots wrapper, catalog v2 (P-17)
--   0054  create_online_booking v2 (links, booking answers, slot engine v2)
--   0055  per-member iCal feed (P-19)
--   0056  geostamped clock in / clock out (P-24)
--   0057  day route order + job coordinates (P-18)
--
-- New enum TYPES are created here (a new type may be used in the same
-- transaction; only ALTER TYPE ... ADD VALUE may not).
-- ============================================================================

create type public.calendar_event_kind as enum ('closed', 'time_off', 'meeting', 'consultation', 'reminder', 'other');

comment on type public.calendar_event_kind is
  'blocked_times.kind: closed = the shop is closed (shop-wide only); time_off = a member is away (member only); meeting / consultation / reminder / other = calendar events (consultation and reminder may name a customer).';

-- ---------------------------------------------------------------------------
-- Pure validators backing the CHECK constraints below.
-- ---------------------------------------------------------------------------

-- A set of weekdays (0 = Sunday ... 6 = Saturday, extract(dow)): no nulls, no
-- duplicates, every value 0..6. An empty array is a valid (empty) set.
create function public.is_valid_weekday_set(p smallint[]) returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select p is not null
     and array_position(p, null) is null
     and coalesce(cardinality(p), 0) <= 7
     and not exists (select 1 from unnest(p) as x where x < 0 or x > 6)
     and (select count(distinct x) from unnest(p) as x) = coalesce(cardinality(p), 0)
$$;

comment on function public.is_valid_weekday_set(smallint[]) is
  'True when the array is a set of distinct weekdays 0 (Sunday) .. 6 (Saturday).';

-- blocked_times.recurrence: {freq: 'day'|'week'|'month', interval: 1..12
-- (default 1), by_weekday: [0..6] (week only; default = the block's own
-- weekday), until_date: 'YYYY-MM-DD' | count: 1..500 (at most one of them;
-- neither = repeats indefinitely)}. No other keys. Never raises.
create function public.calendar_recurrence_valid(p jsonb) returns boolean
language plpgsql immutable parallel safe
set search_path = ''
as $$
declare
  v_freq text;
  v_days smallint[];
begin
  if p is null then
    return true;
  end if;
  if jsonb_typeof(p) <> 'object' then
    return false;
  end if;
  if exists (select 1 from jsonb_object_keys(p) k
             where k not in ('freq', 'interval', 'by_weekday', 'until_date', 'count')) then
    return false;
  end if;
  if jsonb_typeof(p -> 'freq') is distinct from 'string' then
    return false;
  end if;
  v_freq := p ->> 'freq';
  if v_freq not in ('day', 'week', 'month') then
    return false;
  end if;
  if p ? 'interval' and jsonb_typeof(p -> 'interval') <> 'null' then
    if jsonb_typeof(p -> 'interval') <> 'number' or (p ->> 'interval') !~ '^[0-9]{1,2}$'
       or (p ->> 'interval')::integer not between 1 and 12 then
      return false;
    end if;
  end if;
  if p ? 'by_weekday' and jsonb_typeof(p -> 'by_weekday') <> 'null' then
    if v_freq <> 'week' or jsonb_typeof(p -> 'by_weekday') <> 'array'
       or jsonb_array_length(p -> 'by_weekday') = 0
       or exists (select 1 from jsonb_array_elements(p -> 'by_weekday') e
                  where jsonb_typeof(e) <> 'number' or (e #>> '{}') !~ '^[0-6]$') then
      return false;
    end if;
    v_days := array(select (e #>> '{}')::smallint from jsonb_array_elements(p -> 'by_weekday') e);
    if not public.is_valid_weekday_set(v_days) then
      return false;
    end if;
  end if;
  if p ? 'count' and jsonb_typeof(p -> 'count') <> 'null' then
    if jsonb_typeof(p -> 'count') <> 'number' or (p ->> 'count') !~ '^[0-9]{1,3}$'
       or (p ->> 'count')::integer not between 1 and 500 then
      return false;
    end if;
  end if;
  if p ? 'until_date' and jsonb_typeof(p -> 'until_date') <> 'null' then
    if jsonb_typeof(p -> 'until_date') <> 'string' or (p ->> 'until_date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return false;
    end if;
    begin
      if to_char((p ->> 'until_date')::date, 'YYYY-MM-DD') <> (p ->> 'until_date') then
        return false;
      end if;
    exception when others then
      return false;
    end;
    if p ? 'count' and jsonb_typeof(p -> 'count') <> 'null' then
      return false;
    end if;
  end if;
  return true;
end
$$;

comment on function public.calendar_recurrence_valid(jsonb) is
  'Validates blocked_times.recurrence: {freq day|week|month, interval 1..12, by_weekday [0..6] (week), until_date YYYY-MM-DD | count 1..500}.';

-- ---------------------------------------------------------------------------
-- job_series (P-1) — a repeating appointment. Occurrences are ordinary jobs
-- (jobs.series_id / series_seq); the series row keeps the defaults and the
-- rule. Written only by the 0051 RPCs; managers+ read it. Technicians see
-- the occurrences they are assigned to as jobs, never the series row.
--
-- Rule: freq 'week' (every "interval" weeks on by_weekday, weeks anchored at
-- the Sunday on or before start_date) or 'month' (every "interval" months on
-- month_day — clamped to the month's last day — or on the month_nth
-- (1..5, -1 = last) month_weekday; a month without a 5th such weekday is
-- skipped). Occurrence k (k = 1, 2, ... from start_date, in date order) has
-- series_seq seq_offset + k; the dates numbered are the rule's dates plus
-- held_dates (the dates of occurrences a rule change kept off the new
-- rule), so series_seq is the visit's ordinal. A rule change ("this and
-- following") re-anchors start_date at the edit point, sets seq_offset to
-- the visits before it and renumbers the occurrences it keeps from there
-- on. The series ends at until_date (local date) and / or after
-- max_occurrences (the highest series_seq, i.e. the number of visits).
-- ---------------------------------------------------------------------------
create table public.job_series (
  id                     uuid primary key default gen_random_uuid(),
  shop_id                uuid not null references public.shops (id) on delete cascade,
  customer_id            uuid not null,
  vehicle_id             uuid,
  location_type          public.location_type not null default 'shop',
  service_address_line1  text check (service_address_line1 is null or char_length(service_address_line1) <= 200),
  service_address_line2  text check (service_address_line2 is null or char_length(service_address_line2) <= 200),
  service_city           text check (service_city is null or char_length(service_city) <= 100),
  service_region         text check (service_region is null or char_length(service_region) <= 100),
  service_postal_code    text check (service_postal_code is null or char_length(service_postal_code) <= 20),
  service_lat            double precision check (service_lat is null or service_lat between -90 and 90),
  service_lng            double precision check (service_lng is null or service_lng between -180 and 180),
  resource_id            uuid,
  freq                   text not null check (freq in ('week', 'month')),
  "interval"             smallint not null default 1 check ("interval" between 1 and 12),
  by_weekday             smallint[] not null default '{}' check (public.is_valid_weekday_set(by_weekday)),
  month_mode             text check (month_mode is null or month_mode in ('day_of_month', 'nth_weekday')),
  month_day              smallint check (month_day is null or month_day between 1 and 31),
  month_nth              smallint check (month_nth is null or month_nth in (1, 2, 3, 4, 5, -1)),
  month_weekday          smallint check (month_weekday is null or month_weekday between 0 and 6),
  start_date             date not null,
  seq_offset             integer not null default 0 check (seq_offset between 0 and 100000),
  local_start            time not null,
  duration_minutes       integer not null check (duration_minutes between 15 and 44640),
  until_date             date,
  max_occurrences        integer check (max_occurrences is null or max_occurrences between 1 and 500),
  template_lines         jsonb not null default '[]'::jsonb,
  assignee_member_ids    uuid[] not null default '{}',
  notes                  text check (notes is null or char_length(notes) <= 20000),
  internal_notes         text check (internal_notes is null or char_length(internal_notes) <= 20000),
  active                 boolean not null default true,
  generated_through      date,
  skipped_seqs           integer[] not null default '{}',
  skipped_dates          date[] not null default '{}',
  held_dates             date[] not null default '{}',
  ended_at               timestamptz,
  created_by             uuid references auth.users (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint job_series_shop_id_id_key unique (shop_id, id),
  constraint job_series_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete restrict,
  constraint job_series_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id),
  constraint job_series_resource_fk foreign key (shop_id, resource_id)
    references public.resources (shop_id, id) on delete set null (resource_id),
  constraint job_series_lat_lng_pair check ((service_lat is null) = (service_lng is null)),
  constraint job_series_week_rule check (
    freq <> 'week'
    or (cardinality(by_weekday) >= 1
        and month_mode is null and month_day is null and month_nth is null and month_weekday is null)),
  constraint job_series_month_rule check (
    freq <> 'month'
    or (cardinality(by_weekday) = 0
        and month_mode is not null
        and (month_mode <> 'day_of_month' or (month_day is not null and month_nth is null and month_weekday is null))
        and (month_mode <> 'nth_weekday' or (month_nth is not null and month_weekday is not null and month_day is null)))),
  -- (no until_date >= start_date CHECK: end_job_series may end a series
  -- before its re-anchored start_date while earlier occurrences exist; the
  -- create / update RPCs validate until_date against the rule)
  constraint job_series_template_shape check (jsonb_typeof(template_lines) = 'array'),
  constraint job_series_assignees check (array_position(assignee_member_ids, null) is null
                                         and cardinality(assignee_member_ids) <= 10),
  constraint job_series_ended check (active or ended_at is not null),
  constraint job_series_skipped check (array_position(skipped_seqs, null) is null
                                       and array_position(skipped_dates, null) is null),
  constraint job_series_held check (array_position(held_dates, null) is null and cardinality(held_dates) <= 1000)
);
create index job_series_shop_customer_idx on public.job_series (shop_id, customer_id);
create index job_series_shop_vehicle_idx on public.job_series (shop_id, vehicle_id);
create index job_series_shop_resource_idx on public.job_series (shop_id, resource_id);
create index job_series_active_idx on public.job_series (shop_id) where active;
create index job_series_created_by_idx on public.job_series (created_by);

comment on table public.job_series is
  'Recurring appointment (0051): rule + defaults; occurrences are jobs with series_id/series_seq. RPC-only writes (create_job_series, update_job_series, end_job_series, delete_job_series); managers+ read.';
comment on column public.job_series.seq_offset is
  'Occurrence numbers used before start_date (0 for a new series): a rule change re-anchors start_date at the edit point and sets this to the last number before it, so series_seq stays the visit''s ordinal.';
comment on column public.job_series.held_dates is
  'Shop-local dates (one entry per occurrence) of occurrences a rule change kept although the new rule does not produce their date: they are numbered with the rule''s dates (series_seq stays the ordinal, max_occurrences counts them) and never generated.';
comment on column public.job_series.template_lines is
  'Services of every occurrence: [{service_id, quantity}] (1..30), priced from the catalog when each occurrence is generated.';
comment on column public.job_series.generated_through is
  'Local date through which occurrences have been generated (generate_series_jobs extends it to the horizon).';
comment on column public.job_series.skipped_seqs is
  'Occurrence numbers whose job was deleted outside the series RPCs (a skipped visit): never generated again. Cleared when a rule change renumbers the occurrences.';
comment on column public.job_series.skipped_dates is
  'Shop-local dates of skipped (deleted, not detached) occurrences: no occurrence is generated on them, also after a rule change.';

create trigger job_series_05_prevent_shop_change before update on public.job_series
  for each row execute function public.prevent_shop_change();
create trigger job_series_90_set_updated_at before update on public.job_series
  for each row execute function public.set_updated_at();

alter table public.job_series enable row level security;
create policy job_series_select on public.job_series for select to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.job_series from anon;
revoke insert, update, delete, truncate, references, trigger on public.job_series from authenticated;

-- ---------------------------------------------------------------------------
-- jobs: series membership (P-1), booking answers (P-9, validated by comms),
-- manual route order (P-18). Every new jobs column is SELECT-granted to
-- authenticated (0042 column privileges; 40_booking_token_privacy).
-- ---------------------------------------------------------------------------
alter table public.jobs
  add column series_id       uuid,
  add column series_seq      integer check (series_seq is null or series_seq >= 1),
  add column series_detached boolean not null default false,
  add column custom_data     jsonb not null default '{}'::jsonb,
  add column route_position  integer check (route_position is null or route_position between 0 and 999),
  add constraint jobs_series_fk foreign key (shop_id, series_id)
    references public.job_series (shop_id, id) on delete set null (series_id),
  add constraint jobs_series_pair check ((series_id is null) = (series_seq is null)),
  add constraint jobs_custom_data_object check (jsonb_typeof(custom_data) = 'object');
create index jobs_shop_series_idx on public.jobs (shop_id, series_id);
create unique index jobs_series_seq_key on public.jobs (series_id, series_seq) where series_id is not null;

comment on column public.jobs.series_id is 'Recurring series this job is an occurrence of (0051); set only by the series RPCs.';
comment on column public.jobs.series_seq is 'Occurrence number within the series (unique per series).';
comment on column public.jobs.series_detached is
  'True once the occurrence was edited on its own through the API (time, resource, vehicle, customer, location, address, notes, discount / coupon, line items or assignees): "this and following" series edits leave it alone.';
comment on column public.jobs.custom_data is
  'Answers to the shop''s job fields / booking questions {key: value} (online bookings store their answers here; validated by the comms range).';
comment on column public.jobs.route_position is 'Manual stop order of the job within its local day (0 = first; set_route_order).';

grant select (series_id, series_seq, series_detached, custom_data, route_position) on public.jobs to authenticated;

-- ---------------------------------------------------------------------------
-- booking_settings: capacity v2 + multi-day wrap (P-17).
-- ---------------------------------------------------------------------------
alter table public.booking_settings
  add column max_concurrent_shop       integer check (max_concurrent_shop is null or max_concurrent_shop between 1 and 100),
  add column max_concurrent_mobile     integer check (max_concurrent_mobile is null or max_concurrent_mobile between 1 and 100),
  add column count_member_availability boolean not null default false,
  add column allow_multi_day           boolean not null default false,
  add column multi_day_max_days        smallint not null default 2 check (multi_day_max_days between 2 and 7);

comment on column public.booking_settings.max_concurrent_shop is
  'At most this many in-shop jobs at once (null = only max_concurrent_jobs applies).';
comment on column public.booking_settings.max_concurrent_mobile is
  'At most this many mobile jobs at once (null = only max_concurrent_jobs applies).';
comment on column public.booking_settings.count_member_availability is
  'Online capacity is also limited by the active, bookable team members not away (time off / events that affect capacity).';
comment on column public.booking_settings.allow_multi_day is
  'A booking longer than the opening it starts in continues at the next openings (up to multi_day_max_days local days).';

-- ---------------------------------------------------------------------------
-- service_categories: weekdays on which the category can be booked online.
-- ---------------------------------------------------------------------------
alter table public.service_categories
  add column bookable_weekdays smallint[]
    check (bookable_weekdays is null or public.is_valid_weekday_set(bookable_weekdays));

comment on column public.service_categories.bookable_weekdays is
  'Local weekdays (0 = Sunday .. 6) on which services of this category can start online; null = every day.';

-- ---------------------------------------------------------------------------
-- shop_members: may take online bookings (capacity v2).
-- ---------------------------------------------------------------------------
alter table public.shop_members
  add column bookable boolean not null default true;

comment on column public.shop_members.bookable is
  'Counts toward online-booking capacity when booking_settings.count_member_availability is on. Only owners/admins change it.';

-- ---------------------------------------------------------------------------
-- blocked_times: calendar event kinds, titles, customer link, capacity flag,
-- color, recurrence (P-17).
-- ---------------------------------------------------------------------------
alter table public.blocked_times
  add column kind             public.calendar_event_kind not null default 'closed',
  add column title            text check (title is null or char_length(title) <= 120),
  add column customer_id      uuid,
  add column names_customer   boolean not null default false,
  add column affects_capacity boolean,
  add column color            text check (color is null or public.is_valid_hex_color(color)),
  add column recurrence       jsonb check (public.calendar_recurrence_valid(recurrence)),
  add constraint blocked_times_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete set null (customer_id),
  add constraint blocked_times_names_customer_set check (customer_id is null or names_customer);

-- existing rows: a member's block is time off; every existing block keeps
-- blocking (closures block slots; time off counts against availability)
update public.blocked_times set kind = 'time_off' where member_id is not null and kind = 'closed';
update public.blocked_times set affects_capacity = true where affects_capacity is null;

alter table public.blocked_times
  add constraint blocked_times_affects_capacity_set check (affects_capacity is not null);

create index blocked_times_shop_customer_idx on public.blocked_times (shop_id, customer_id);
create index blocked_times_shop_recurring_idx on public.blocked_times (shop_id, starts_at) where recurrence is not null;

comment on column public.blocked_times.kind is
  'closed (shop-wide, blocks online booking) | time_off (a member) | meeting | consultation | reminder | other.';
comment on column public.blocked_times.names_customer is
  'True once the event has named a customer (blocked_times_50_validate sets it whenever customer_id is set). It stays true when the link is cleared - deleting the customer sets customer_id null - so the title and reason written about that customer stay manager-only (RLS, calendar_events, iCal feeds). A manager may clear it while customer_id is null.';
comment on column public.blocked_times.affects_capacity is
  'Whether the event takes capacity: a shop-wide event counts as one busy unit, a member event makes that member unavailable. Defaults to true for closed / time_off.';
comment on column public.blocked_times.recurrence is
  'Repeat rule {freq, interval, by_weekday, until_date | count} expanded in shop-local wall time (blocked_time_occurrences).';

-- ---------------------------------------------------------------------------
-- time_entries: geostamps (P-24). Written only by clock_in / clock_out.
-- ---------------------------------------------------------------------------
alter table public.time_entries
  add column clock_in_lat          double precision check (clock_in_lat is null or clock_in_lat between -90 and 90),
  add column clock_in_lng          double precision check (clock_in_lng is null or clock_in_lng between -180 and 180),
  add column clock_in_accuracy_m   real check (clock_in_accuracy_m is null or clock_in_accuracy_m between 0 and 10000),
  add column clock_out_lat         double precision check (clock_out_lat is null or clock_out_lat between -90 and 90),
  add column clock_out_lng         double precision check (clock_out_lng is null or clock_out_lng between -180 and 180),
  add column clock_out_accuracy_m  real check (clock_out_accuracy_m is null or clock_out_accuracy_m between 0 and 10000),
  add constraint time_entries_clock_in_geo check ((clock_in_lat is null) = (clock_in_lng is null)
                                                  and (clock_in_accuracy_m is null or clock_in_lat is not null)),
  add constraint time_entries_clock_out_geo check ((clock_out_lat is null) = (clock_out_lng is null)
                                                   and (clock_out_accuracy_m is null or clock_out_lat is not null));

comment on column public.time_entries.clock_in_lat is 'Where the member clocked in (device location; evidence, not editable by API roles).';
comment on column public.time_entries.clock_out_lat is 'Where the member clocked out (device location; evidence, not editable by API roles).';

-- ---------------------------------------------------------------------------
-- booking_links (P-17) — private booking links: a link lets the public
-- booking page offer exactly its services (online-bookable or not). Prices
-- always come from the catalog. Admin-managed like booking settings;
-- managers read them to share the link.
-- ---------------------------------------------------------------------------
create table public.booking_links (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  token        uuid not null default gen_random_uuid() unique,
  name         text not null check (char_length(btrim(name)) between 1 and 120),
  service_ids  uuid[] not null check (array_position(service_ids, null) is null
                                      and cardinality(service_ids) between 1 and 50),
  note         text check (note is null or char_length(note) <= 1000),
  active       boolean not null default true,
  expires_at   timestamptz,
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint booking_links_shop_id_id_key unique (shop_id, id)
);
create index booking_links_shop_idx on public.booking_links (shop_id, created_at);
create index booking_links_created_by_idx on public.booking_links (created_by);

comment on table public.booking_links is
  'Private booking links (?link=<token>): the booking page offers only these services (non-online-bookable ones included). Prices come from the catalog.';
comment on column public.booking_links.token is 'Unguessable public credential of the link (server-issued).';
comment on column public.booking_links.service_ids is 'Services / packages / add-ons offered through the link (1..50, active services of the shop).';

create trigger booking_links_05_prevent_shop_change before update on public.booking_links
  for each row execute function public.prevent_shop_change();
create trigger booking_links_20_set_created_by before insert or update on public.booking_links
  for each row execute function public.set_created_by();
create trigger booking_links_90_set_updated_at before update on public.booking_links
  for each row execute function public.set_updated_at();

alter table public.booking_links enable row level security;
create policy booking_links_select on public.booking_links for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy booking_links_insert on public.booking_links for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy booking_links_update on public.booking_links for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy booking_links_delete on public.booking_links for delete to authenticated
  using (public.is_shop_admin(shop_id));

revoke all on public.booking_links from anon;
revoke truncate, references, trigger on public.booking_links from authenticated;

-- ---------------------------------------------------------------------------
-- calendar_feed_tokens (P-19) — one live iCal feed token per member. The
-- member reads their own row; writes go through the 0055 RPCs.
-- ---------------------------------------------------------------------------
create table public.calendar_feed_tokens (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  member_id         uuid not null,
  token             uuid not null default gen_random_uuid() unique,
  include_all       boolean not null default false,
  created_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  last_accessed_at  timestamptz,
  constraint calendar_feed_tokens_shop_id_id_key unique (shop_id, id),
  constraint calendar_feed_tokens_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id) on delete cascade
);
create unique index calendar_feed_tokens_live_key on public.calendar_feed_tokens (member_id) where revoked_at is null;
create index calendar_feed_tokens_shop_member_idx on public.calendar_feed_tokens (shop_id, member_id);

comment on table public.calendar_feed_tokens is
  'Per-member iCal feed credentials (0055). At most one live (unrevoked) token per member; include_all (managers+) lists every job of the shop.';

create trigger calendar_feed_tokens_05_prevent_shop_change before update on public.calendar_feed_tokens
  for each row execute function public.prevent_shop_change();

alter table public.calendar_feed_tokens enable row level security;
create policy calendar_feed_tokens_select on public.calendar_feed_tokens for select to authenticated
  using (public.is_own_member(member_id) and public.is_shop_member(shop_id));

revoke all on public.calendar_feed_tokens from anon;
revoke insert, update, delete, truncate, references, trigger on public.calendar_feed_tokens from authenticated;

-- ---------------------------------------------------------------------------
-- Grants for the validators (used by CHECK constraints; harmless to call).
-- ---------------------------------------------------------------------------
revoke execute on function public.is_valid_weekday_set(smallint[]), public.calendar_recurrence_valid(jsonb)
  from public, anon;
grant execute on function public.is_valid_weekday_set(smallint[]), public.calendar_recurrence_valid(jsonb)
  to authenticated, service_role;
