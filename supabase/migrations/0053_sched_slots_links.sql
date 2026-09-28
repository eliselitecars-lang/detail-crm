-- ============================================================================
-- 0053 — Online availability v2 + private booking links (P-17).
--
-- booking_slots_core (internal) is the one slot engine: public_booking_slots,
-- get_available_slots (now a thin wrapper), create_online_booking (0054) and
-- the money range's quote self-scheduling call it. On top of the 0007 rules
-- (wall-clock grid anchored at each opening, merged business-hours
-- intervals, lead time, max days ahead, buffer around jobs, DST handling —
-- see 0007) it adds:
--   * blocked_times kinds (0052): shop-wide 'closed' occurrences (recurring
--     ones expanded) remove every slot they overlap; another shop-wide
--     event with affects_capacity is one busy unit (no buffer);
--   * capacity per location: with p_location_type, at most
--     max_concurrent_shop / max_concurrent_mobile jobs OF THAT TYPE at any
--     instant (null = no extra limit), on top of max_concurrent_jobs for
--     everything;
--   * member availability (count_member_availability): at every instant the
--     busy units must stay below the number of active, bookable team members
--     (shop_members.bookable, any role) not covered by a member event with
--     affects_capacity (time off, or a meeting that takes them);
--   * category weekdays: when any chosen service's category restricts
--     bookable_weekdays, the slot's local start weekday must be allowed by
--     every such category;
--   * multi-day wrap (allow_multi_day): a booking longer than the whole
--     opening it starts in (so it can never fit in it) continues at the next
--     openings; ends_at is where the work ends, the booking may cover at
--     most multi_day_max_days local days, and
--     closures / capacity are checked over the whole span (start to end,
--     nights included — the vehicle stays with the shop).
-- With the new settings at their defaults, results are identical to 0007.
--
-- Capacity is evaluated at the slot start and at every busy-unit start or
-- member-absence start inside the slot (the peaks), as in 0007.
--
-- Private booking links (booking_links): a link's token lets the public
-- booking page offer exactly the link's services — online-bookable or not —
-- priced from the catalog like every online booking. Owners/admins manage
-- links (managers read them to share); the token is server-issued and
-- immutable (create a new link to rotate).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- shop_members_50_bookable_guard — API roles: only owners/admins change
-- bookable (members cannot change their own). shop_members_client_guard
-- (0002) is unchanged.
-- ---------------------------------------------------------------------------
create function public.shop_members_bookable_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() and new.bookable is distinct from old.bookable
     and not public.is_shop_admin(old.shop_id) then
    raise exception 'only owners and admins can change who takes online bookings' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger shop_members_50_bookable_guard before update on public.shop_members
  for each row execute function public.shop_members_bookable_guard();

-- ---------------------------------------------------------------------------
-- booking_links_50_validate — services: 1..50 distinct active, non-archived
-- services / packages / add-ons of the shop (products are never booked
-- online). API roles: the token is server-issued and never changes.
-- ---------------------------------------------------------------------------
create function public.booking_links_validate() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    if tg_op = 'INSERT' then
      new.token := gen_random_uuid();
    elsif new.token is distinct from old.token then
      raise exception 'a booking link''s token cannot be changed; create a new link instead' using errcode = '42501';
    end if;
  end if;
  new.name := btrim(new.name);
  new.note := nullif(btrim(new.note), '');
  if tg_op = 'INSERT' or new.service_ids is distinct from old.service_ids then
    new.service_ids := array(select x.id
                               from (select u.id, min(u.o) as first_o
                                       from unnest(new.service_ids) with ordinality as u(id, o)
                                      group by u.id) x
                              order by x.first_o);
    if exists (select 1 from unnest(new.service_ids) as x
               where not exists (select 1 from public.services s
                                 where s.id = x and s.shop_id = new.shop_id and s.active and s.archived_at is null
                                   and s.kind in ('service', 'package', 'addon'))) then
      raise exception 'a booking link can only offer active services, packages and add-ons of this shop'
        using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;

create trigger booking_links_50_validate before insert or update on public.booking_links
  for each row execute function public.booking_links_validate();

-- ---------------------------------------------------------------------------
-- booking_link_service_ids(shop, token) — the services a live link offers
-- (in the link's order; services archived / deactivated since are left
-- out), or null when the token is not a live link of that shop (unknown,
-- another shop's, inactive, expired). Internal: service_role and definer
-- code (money's public_validate_coupon uses it).
-- ---------------------------------------------------------------------------
create function public.booking_link_service_ids(p_shop_id uuid, p_token uuid) returns uuid[]
language sql stable
set search_path = ''
as $$
  select array(select x.id
                 from unnest(l.service_ids) with ordinality as x(id, o)
                 join public.services s on s.id = x.id and s.shop_id = l.shop_id
                where s.active and s.archived_at is null and s.kind in ('service', 'package', 'addon')
                order by x.o)
  from public.booking_links l
  where l.token = p_token
    and l.shop_id = p_shop_id
    and l.active
    and (l.expires_at is null or l.expires_at > now())
$$;

comment on function public.booking_link_service_ids(uuid, uuid) is
  'Services offered by a live booking link of the shop (null when the token is unknown, inactive, expired or another shop''s).';

-- ---------------------------------------------------------------------------
-- booking_slots_core — see the header. Internal (service_role and definer
-- code). p_now is used as given (callers pass effective_now). Raises 22023
-- for a bad range / duration, P0002 for an unknown shop; returns nothing
-- when the shop has no booking settings.
-- ---------------------------------------------------------------------------
create function public.booking_slots_core(
  p_shop_id           uuid,
  p_duration_minutes  integer,
  p_from              date,
  p_to                date,
  p_now               timestamptz,
  p_location_type     public.location_type default null,
  p_category_ids      uuid[] default null
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable
set search_path = ''
-- (see 0007: the generate_series estimates would make JIT cost ~100x)
set jit = off
as $$
#variable_conflict use_column
declare
  c_max_range_days constant integer := 62;
  v_shop       public.shops;
  v_bs         public.booking_settings;
  v_now        timestamptz := coalesce(p_now, now());
  v_dur        interval;
  v_buf        interval;
  v_today      date;
  v_from       date;
  v_to         date;
  v_tz         text;
  v_scan_start timestamptz;
  v_loc_cap    integer;
  v_days       smallint[];
  v_members    uuid[];
begin
  if p_shop_id is null or p_from is null or p_to is null then
    raise exception 'shop and date range are required' using errcode = '22023';
  end if;
  if p_duration_minutes is null or p_duration_minutes <= 0 then
    raise exception 'the selected services have no duration' using errcode = '22023';
  end if;
  if p_duration_minutes > 44640 then
    raise exception 'the selected services take longer than 31 days' using errcode = '22023';
  end if;
  if p_to < p_from then
    raise exception 'p_to must be on or after p_from' using errcode = '22023';
  end if;
  if p_to - p_from + 1 > c_max_range_days then
    raise exception 'date range cannot exceed % days', c_max_range_days using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.id = p_shop_id;
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = p_shop_id;
  if not found then
    return;
  end if;

  v_tz := v_shop.timezone;
  v_dur := make_interval(mins => p_duration_minutes);
  v_buf := make_interval(mins => v_bs.buffer_minutes);
  v_today := (v_now at time zone v_tz)::date;
  v_from := greatest(p_from, v_today);
  v_to := least(p_to, v_today + v_bs.max_days_ahead);
  if v_from > v_to then
    return;
  end if;
  v_loc_cap := case p_location_type when 'shop' then v_bs.max_concurrent_shop
                                    when 'mobile' then v_bs.max_concurrent_mobile end;
  if exists (select 1 from public.service_categories sc
             where sc.shop_id = p_shop_id and sc.id = any (p_category_ids) and sc.bookable_weekdays is not null) then
    v_days := array(select d::smallint from generate_series(0, 6) as d
                     where not exists (select 1 from public.service_categories sc
                                        where sc.shop_id = p_shop_id and sc.id = any (p_category_ids)
                                          and sc.bookable_weekdays is not null
                                          and not (d::smallint = any (sc.bookable_weekdays))));
  end if;
  if v_bs.count_member_availability then
    v_members := array(select m.id from public.shop_members m
                        where m.shop_id = p_shop_id and m.active and m.bookable);
  end if;

  -- 8 days either side find the true opening / closing of every stretch
  -- that can hold a slot starting in [v_from, v_to] (0007); the later days
  -- also hold the openings a multi-day booking wraps into (<= 7 days).
  v_scan_start := public.wall_clock_instant((v_from - 8)::timestamp, v_tz);

  return query
  with days as (
    select (v_from - 8 + i) as d
    from generate_series(0, v_to - v_from + 16) as i
  ),
  raw_intervals as (
    select public.wall_clock_instant(dd.d + bh.opens_at, v_tz)  as o,
           public.wall_clock_instant(dd.d + bh.closes_at, v_tz) as c
    from days dd
    join public.business_hours bh
      on bh.shop_id = p_shop_id and bh.weekday = extract(dow from dd.d)::smallint
  ),
  marked as (
    select ri.o, ri.c,
           case when ri.o <= max(ri.c) over (order by ri.o, ri.c
                                              rows between unbounded preceding and 1 preceding)
                then 0 else 1 end as is_new
    from raw_intervals ri
    where ri.c > ri.o
  ),
  grouped as (
    select mk.o, mk.c, sum(mk.is_new) over (order by mk.o, mk.c) as grp
    from marked mk
  ),
  islands as (
    select min(g.o) as o, max(g.c) as c from grouped g group by g.grp
  ),
  isl as materialized (
    -- cum = open time from the scan start through the end of this stretch
    select i.o, i.c, i.o <= v_scan_start as around_the_clock,
           sum(i.c - i.o) over (order by i.o) as cum
    from islands i
  ),
  relevant as (
    select r.o, r.c, r.around_the_clock, r.cum
    from isl r
    where r.c > public.wall_clock_instant(v_from::timestamp, v_tz)
      and r.o < public.wall_clock_instant((v_to + 1)::timestamp, v_tz)
  ),
  local_starts as (
    -- a stretch with an opening time: grid anchored at that opening
    select lt, r.c as island_close, r.cum as island_cum, r.c - r.o as island_len
    from relevant r
    cross join lateral generate_series(r.o at time zone v_tz, r.c at time zone v_tz,
                                       make_interval(mins => v_bs.slot_interval_minutes)) as lt
    where not r.around_the_clock
    union all
    -- open around the clock: grid anchored at each local midnight
    select lt, 'infinity'::timestamptz, null::interval, null::interval
    from relevant r
    cross join generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') as dd(d)
    cross join lateral generate_series(dd.d, dd.d + interval '1 day',
                                       make_interval(mins => v_bs.slot_interval_minutes)) as lt
    where r.around_the_clock and lt < dd.d + interval '1 day'
  ),
  candidates as (
    select distinct public.wall_clock_instant(ls.lt, v_tz) as s, ls.island_close, ls.island_cum, ls.island_len
    from local_starts ls
    where ((ls.lt at time zone v_tz) at time zone v_tz) = ls.lt       -- skip nonexistent local times
  ),
  slots as (
    select cd.s,
           case
             when cd.s + v_dur <= cd.island_close then cd.s + v_dur
             -- only a booking longer than the whole opening wraps (a short
             -- one never starts late and finishes the next morning)
             when v_bs.allow_multi_day and cd.s < cd.island_close and v_dur > cd.island_len then (
               -- wrap: the work left at closing continues at the next
               -- openings; it ends inside the first later stretch whose
               -- cumulative open time covers it
               select n.c - ((n.cum - cd.island_cum) - (v_dur - (cd.island_close - cd.s)))
               from isl n
               where n.o >= cd.island_close
                 and n.cum - cd.island_cum >= v_dur - (cd.island_close - cd.s)
               order by n.o
               limit 1)
           end as e,
           cd.s + v_dur > cd.island_close as wrapped
    from candidates cd
    where (cd.s at time zone v_tz)::date between v_from and v_to
      and cd.s >= v_now + make_interval(mins => v_bs.lead_time_minutes)
      and (v_days is null or extract(dow from (cd.s at time zone v_tz))::smallint = any (v_days))
  ),
  fitting as materialized (
    select sl.s, sl.e
    from slots sl
    where sl.e is not null
      and (not sl.wrapped
           or ((sl.e - interval '1 microsecond') at time zone v_tz)::date - (sl.s at time zone v_tz)::date
              < v_bs.multi_day_max_days)
  ),
  win as (
    select min(f.s) as ws, max(f.e) as we from fitting f
  ),
  ev as materialized (
    select o.member_id, o.kind, o.affects_capacity, o.starts_at, o.ends_at
    from win
    cross join lateral public.blocked_time_occurrences(p_shop_id, win.ws, win.we) o
    where win.ws is not null
  ),
  units as materialized (
    -- jobs (widened by the buffer) and shop-wide events that take capacity
    select j.scheduled_start - v_buf as bs, j.scheduled_end + v_buf as be, j.location_type as loc
    from public.jobs j
    cross join win
    where j.shop_id = p_shop_id
      and j.scheduled_start is not null
      and j.status not in ('cancelled', 'no_show')
      and j.scheduled_start < win.we + v_buf
      and j.scheduled_end > win.ws - v_buf
    union all
    select e.starts_at, e.ends_at, null::public.location_type
    from ev e
    where e.member_id is null and e.kind <> 'closed' and e.affects_capacity
  ),
  closures as materialized (
    select e.starts_at, e.ends_at from ev e where e.member_id is null and e.kind = 'closed'
  ),
  away as materialized (
    select e.member_id, e.starts_at, e.ends_at
    from ev e
    where v_members is not null and e.member_id = any (v_members) and e.affects_capacity
  )
  select f.s, f.e
  from fitting f
  where not exists (select 1 from closures cl where cl.starts_at < f.e and cl.ends_at > f.s)
    and not exists (
          -- capacity peaks at the slot start or at a busy-unit / absence start inside it
          select 1
          from (select f.s as p
                union
                select u.bs from units u where u.bs > f.s and u.bs < f.e
                union
                select a.starts_at from away a where a.starts_at > f.s and a.starts_at < f.e) pts
          where (select count(*) from units u2 where u2.bs <= pts.p and u2.be > pts.p) >= v_bs.max_concurrent_jobs
             or (v_loc_cap is not null
                 and (select count(*) from units u3
                       where u3.loc = p_location_type and u3.bs <= pts.p and u3.be > pts.p) >= v_loc_cap)
             or (v_members is not null
                 and (select count(*) from units u4 where u4.bs <= pts.p and u4.be > pts.p)
                     >= cardinality(v_members)
                        - (select count(distinct a2.member_id) from away a2
                            where a2.starts_at <= pts.p and a2.ends_at > pts.p)))
  order by f.s;
end
$$;

comment on function public.booking_slots_core(uuid, integer, date, date, timestamptz, public.location_type, uuid[]) is
  'Internal slot engine (0053): business hours, closures, lead time, horizon, buffer, capacity (total / per location / members), category weekdays, multi-day wrap.';

-- ---------------------------------------------------------------------------
-- booking_catalog_json(shop, only) — the public catalog document: with
-- p_only null the shop's online-bookable services, else exactly the
-- services in p_only (a booking link's), online-bookable or not. Items need
-- at least one price. Internal builder of public_booking_catalog and
-- public_booking_link.
-- ---------------------------------------------------------------------------
create function public.booking_catalog_json(p_shop_id uuid, p_only uuid[]) returns jsonb
language sql stable
set search_path = ''
as $$
  with bookable as (
    select s.*
    from public.services s
    where s.shop_id = p_shop_id and s.active and s.archived_at is null
      and s.kind in ('service', 'package', 'addon')
      and (case when p_only is null then s.online_bookable else s.id = any (p_only) end)
      and exists (select 1 from public.service_prices sp where sp.service_id = s.id and sp.shop_id = s.shop_id)
  ),
  item as (
    select b.id, b.kind, b.sort, b.name,
           jsonb_build_object(
             'id', b.id,
             'category_id', b.category_id,
             'name', b.name,
             'description', b.description,
             'kind', b.kind,
             'image_path', b.image_path,
             'duration_minutes', b.duration_minutes,
             'base_price_cents', (select pr.price_cents from public.service_price_for(b.id, null) pr),
             'prices', coalesce((
               select jsonb_agg(jsonb_build_object('vehicle_category_id', vc.id,
                                                   'price_cents', pr.price_cents,
                                                   'duration_minutes', pr.duration_minutes)
                                order by vc.sort, vc.name, vc.id)
               from public.vehicle_categories vc
               cross join lateral public.service_price_for(b.id, vc.id) pr
               where vc.shop_id = p_shop_id and pr.price_cents is not null), '[]'::jsonb)) as base,
           case when b.kind = 'package' then coalesce((
             select jsonb_agg(inc.name order by pi.sort, inc.name, inc.id)
             from public.package_items pi
             join public.services inc on inc.id = pi.service_id and inc.shop_id = pi.shop_id
             where pi.package_id = b.id and pi.shop_id = b.shop_id), '[]'::jsonb)
           else '[]'::jsonb end as includes,
           case when exists (select 1 from public.service_addons sa where sa.service_id = b.id and sa.shop_id = b.shop_id)
             then coalesce((select jsonb_agg(a.id order by a.sort, a.name, a.id)
                              from public.service_addons sa
                              join bookable a on a.id = sa.addon_id and a.kind = 'addon'
                             where sa.service_id = b.id and sa.shop_id = b.shop_id), '[]'::jsonb)
             else coalesce((select jsonb_agg(a.id order by a.sort, a.name, a.id) from bookable a where a.kind = 'addon'),
                           '[]'::jsonb)
           end as addon_ids
    from bookable b
  )
  select jsonb_build_object(
    'vehicle_categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', vc.id, 'name', vc.name) order by vc.sort, vc.name, vc.id)
      from public.vehicle_categories vc where vc.shop_id = p_shop_id), '[]'::jsonb),
    'service_categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', sc.id, 'name', sc.name,
                                          'bookable_weekdays', to_jsonb(sc.bookable_weekdays))
                       order by sc.sort, sc.name, sc.id)
      from public.service_categories sc
      where sc.shop_id = p_shop_id and exists (select 1 from bookable b where b.category_id = sc.id)), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg(i.base || jsonb_build_object('includes', i.includes, 'addon_ids', i.addon_ids)
                       order by i.sort, i.name, i.id)
      from item i where i.kind in ('service', 'package')), '[]'::jsonb),
    'addons', coalesce((
      select jsonb_agg(i.base order by i.sort, i.name, i.id)
      from item i where i.kind = 'addon'), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- public_booking_catalog(slug) — v2: service_categories[] gain
-- bookable_weekdays (null = every day). Otherwise unchanged (0042).
-- ---------------------------------------------------------------------------
create or replace function public.public_booking_catalog(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop    public.shops;
  v_enabled boolean;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  return public.booking_catalog_json(v_shop.id, null);
end
$$;

-- ---------------------------------------------------------------------------
-- public_booking_link(token) — the private booking page: {slug, name, note,
-- expires_at, catalog} where catalog has the public_booking_catalog shape
-- restricted to the link's services (online-bookable or not). Unknown,
-- inactive or expired link: PT404. Online booking off: 55000.
-- ---------------------------------------------------------------------------
create function public.public_booking_link(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_link    public.booking_links;
  v_shop    public.shops;
  v_enabled boolean;
begin
  select * into v_link from public.booking_links l where l.token = p_token;
  if not found or not v_link.active or (v_link.expires_at is not null and v_link.expires_at <= now()) then
    raise exception 'booking link not found' using errcode = 'PT404';
  end if;
  select * into v_shop from public.shops s where s.id = v_link.shop_id;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  return jsonb_build_object(
    'slug', v_shop.slug,
    'name', v_link.name,
    'note', v_link.note,
    'expires_at', v_link.expires_at,
    'catalog', public.booking_catalog_json(v_shop.id, public.booking_link_service_ids(v_shop.id, p_token)));
end
$$;

-- ---------------------------------------------------------------------------
-- public_booking_slots — public availability v2 (anon + authenticated).
-- Same validation as get_available_slots (0007) plus: p_location_type
-- ('shop' | 'mobile'; must be offered by the shop) applies the per-location
-- capacity. Without one, the slots are those of the location a booking
-- without one gets from create_online_booking (0054): 'mobile' for a
-- mobile-only shop, otherwise 'shop' (a 'fixed' shop, and a 'both' shop
-- too), so every slot offered can be booked the way get_available_slots
-- callers book (no location); a 'both' shop's booking page passes the type
-- the customer picked to see that location's slots; p_link_token (a live
-- booking link of the shop, else PT404)
-- validates the services against the link instead of online_bookable.
-- Duration = the services' catalog durations for the vehicle category.
-- p_now is honoured only for trusted callers (effective_now).
-- ---------------------------------------------------------------------------
create function public.public_booking_slots(
  p_slug                 text,
  p_service_ids          uuid[],
  p_from                 date,
  p_to                   date,
  p_vehicle_category_id  uuid default null,
  p_location_type        public.location_type default null,
  p_link_token           uuid default null,
  p_now                  timestamptz default now()
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
set jit = off
as $$
#variable_conflict use_column
declare
  c_max_range_days constant integer := 62;
  v_shop      public.shops;
  v_bs        public.booking_settings;
  v_ids       uuid[];
  v_link_ids  uuid[];
  v_found     integer;
  v_duration  integer;
  v_cats      uuid[];
  v_loc       public.location_type;
begin
  if p_slug is null or p_from is null or p_to is null then
    raise exception 'shop slug and date range are required' using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  if not found or not v_bs.enabled then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if p_to < p_from then
    raise exception 'p_to must be on or after p_from' using errcode = '22023';
  end if;
  if p_to - p_from + 1 > c_max_range_days then
    raise exception 'date range cannot exceed % days', c_max_range_days using errcode = '22023';
  end if;

  v_ids := array(select distinct x from unnest(p_service_ids) as x where x is not null);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 50 then
    raise exception 'too many services' using errcode = '22023';
  end if;
  if p_vehicle_category_id is not null and not exists (
       select 1 from public.vehicle_categories vc
       where vc.id = p_vehicle_category_id and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  if p_link_token is not null then
    v_link_ids := public.booking_link_service_ids(v_shop.id, p_link_token);
    if v_link_ids is null then
      raise exception 'booking link not found' using errcode = 'PT404';
    end if;
  end if;
  if p_location_type = 'mobile' and v_shop.business_type = 'fixed' then
    raise exception 'this shop does not offer mobile service' using errcode = '22023';
  end if;
  if p_location_type = 'shop' and v_shop.business_type = 'mobile' then
    raise exception 'this shop only offers mobile service' using errcode = '22023';
  end if;
  -- the location a booking without one gets (create_online_booking, 0054)
  v_loc := coalesce(p_location_type,
                    case when v_shop.business_type = 'mobile' then 'mobile'::public.location_type
                         else 'shop'::public.location_type end);

  select count(*), sum(sp.duration_minutes)
    into v_found, v_duration
    from public.services s
    cross join lateral public.service_price_for(s.id, p_vehicle_category_id) sp
   where s.id = any (v_ids)
     and s.shop_id = v_shop.id
     and s.active
     and s.archived_at is null
     and case when v_link_ids is null then s.online_bookable else s.id = any (v_link_ids) end;
  if v_found <> cardinality(v_ids) then
    raise exception 'one or more services are not available for online booking' using errcode = '22023';
  end if;
  if coalesce(v_duration, 0) <= 0 then
    raise exception 'the selected services have no duration' using errcode = '22023';
  end if;
  v_cats := array(select distinct s.category_id from public.services s
                   where s.id = any (v_ids) and s.shop_id = v_shop.id and s.category_id is not null);

  return query
    select c.starts_at, c.ends_at
      from public.booking_slots_core(v_shop.id, v_duration, p_from, p_to, public.effective_now(p_now),
                                     v_loc, v_cats) c;
end
$$;

comment on function public.public_booking_slots(text, uuid[], date, date, uuid, public.location_type, uuid, timestamptz) is
  'Public (anon) availability v2: per-location capacity (p_location_type) and private links (p_link_token). Range capped at 62 days; p_now honoured only for trusted callers.';

-- ---------------------------------------------------------------------------
-- get_available_slots — same signature and results as 0007 (no location
-- type, no link): a thin wrapper over public_booking_slots. The per-location
-- capacity of the location a booking without one gets applies ('shop'
-- unless the shop is mobile-only), as for the booking itself.
-- ---------------------------------------------------------------------------
create or replace function public.get_available_slots(
  p_shop_slug            text,
  p_service_ids          uuid[],
  p_from                 date,
  p_to                   date,
  p_vehicle_category_id  uuid default null,
  p_now                  timestamptz default now()
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
set jit = off
as $$
#variable_conflict use_column
begin
  return query
    select s.starts_at, s.ends_at
      from public.public_booking_slots(p_shop_slug, p_service_ids, p_from, p_to, p_vehicle_category_id,
                                       null, null, p_now) s;
end
$$;

comment on function public.get_available_slots(text, uuid[], date, date, uuid, timestamptz) is
  'Public (anon) availability for online booking (wrapper over public_booking_slots without location type or link). Range capped at 62 days. p_now is honoured only for trusted callers (effective_now).';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.shop_members_bookable_guard(), public.booking_links_validate()
  from public, anon, authenticated;

revoke execute on function
  public.booking_link_service_ids(uuid, uuid),
  public.booking_slots_core(uuid, integer, date, date, timestamptz, public.location_type, uuid[]),
  public.booking_catalog_json(uuid, uuid[])
from public, anon, authenticated;
grant execute on function
  public.booking_link_service_ids(uuid, uuid),
  public.booking_slots_core(uuid, integer, date, date, timestamptz, public.location_type, uuid[]),
  public.booking_catalog_json(uuid, uuid[])
to service_role;

revoke execute on function
  public.public_booking_link(uuid),
  public.public_booking_slots(text, uuid[], date, date, uuid, public.location_type, uuid, timestamptz)
from public;
grant execute on function
  public.public_booking_link(uuid),
  public.public_booking_slots(text, uuid[], date, date, uuid, public.location_type, uuid, timestamptz)
to anon, authenticated, service_role;
