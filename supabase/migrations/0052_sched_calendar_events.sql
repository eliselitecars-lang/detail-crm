-- ============================================================================
-- 0052 — Calendar events (P-17): blocked_times becomes a calendar of kinds
-- (closed, time_off, meeting, consultation, reminder, other) with titles,
-- colors, an optional customer (consultation / reminder), a capacity flag
-- and a repeat rule; calendar_events v2 returns them (recurring ones
-- expanded) together with jobs.
--
-- Rules (blocked_times_50_validate):
--   * closed is shop-wide (member_id null). A member's block written as
--     'closed' (every caller that predates kinds: the default kind) is
--     stored as time_off; time_off always belongs to a member.
--   * customer_id only on consultation / reminder events.
--   * affects_capacity defaults to true for closed / time_off, false for the
--     other kinds. Online capacity (0053): a shop-wide 'closed' block removes
--     every slot it overlaps; another shop-wide event with affects_capacity
--     counts as one busy unit (like a job); a member event with
--     affects_capacity makes that member unavailable (count_member_availability).
--   * recurrence (0050 CHECK) repeats the block in shop-local wall time: each
--     occurrence starts and ends at the same local times as the original
--     (a local time inside a DST gap resolves to the jump, an ambiguous one
--     to its first pass — wall_clock_instant, like business hours). The
--     original row is always occurrence 1; count includes it; until_date
--     bounds the occurrence's local start date and may not be before the
--     block's own local start date (23514, checked whenever starts_at or
--     recurrence is written; should a later time-zone change invert them,
--     the original row is still returned). Monthly repeats on the same day
--     of the month (the last day in shorter months).
-- RLS: the 0003 policies are unchanged (managers+ write; technicians read
-- shop-wide blocks and their own) and 0052 adds one RESTRICTIVE select
-- policy: below manager, a row that names a customer (a consultation or a
-- reminder) is not readable at all. Technicians therefore never read a
-- customer id, or the title / reason written about that customer, from
-- blocked_times; they see such an event only through calendar_events, which
-- never gives them a customer id, a customer name, or the title of a
-- customer-linked shop-wide event (their own event keeps its title).
-- "Names a customer" is blocked_times.names_customer (0050), set here
-- whenever customer_id is set and kept when the link is cleared: deleting
-- the customer (ON DELETE SET NULL) must not turn an event about them into
-- one every technician can read, in the app or in an iCal feed (0055).
-- ============================================================================

create function public.blocked_times_validate() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.kind = 'closed' and new.member_id is not null then
    new.kind := 'time_off';
  end if;
  if new.kind = 'time_off' and new.member_id is null then
    raise exception 'time off belongs to a team member (member_id); use kind closed for the whole shop'
      using errcode = '23514';
  end if;
  if new.customer_id is not null and new.kind not in ('consultation', 'reminder') then
    raise exception 'only consultations and reminders can name a customer' using errcode = '23514';
  end if;
  -- sticky: an UPDATE that clears customer_id (the customer's delete, or a
  -- manager unlinking it) keeps the flag; only an explicit false clears it
  if new.customer_id is not null then
    new.names_customer := true;
  end if;
  new.title := nullif(btrim(new.title), '');
  if new.affects_capacity is null then
    new.affects_capacity := new.kind in ('closed', 'time_off');
  end if;
  -- a repeat that ends before the block starts would hide the block itself
  -- (a malformed rule is left to the recurrence CHECK)
  if jsonb_typeof(new.recurrence -> 'until_date') = 'string'
     and public.calendar_recurrence_valid(new.recurrence)
     and (tg_op = 'INSERT' or new.recurrence is distinct from old.recurrence
          or new.starts_at is distinct from old.starts_at)
     and (new.recurrence ->> 'until_date')::date
         < (select (new.starts_at at time zone s.timezone)::date from public.shops s where s.id = new.shop_id) then
    raise exception 'the repeat''s until_date is before the event''s start date' using errcode = '23514';
  end if;
  return new;
end
$$;

create trigger blocked_times_50_validate before insert or update on public.blocked_times
  for each row execute function public.blocked_times_validate();

-- Technicians (below manager) cannot read a customer-linked row at all; the
-- permissive 0003 policies still decide everything else. See the header.
create policy blocked_times_select_customer_redaction on public.blocked_times
  as restrictive for select to authenticated
  using (not names_customer or public.is_shop_manager(shop_id));

-- ---------------------------------------------------------------------------
-- blocked_time_occurrences(shop, from, to) — every block occurrence
-- overlapping [p_from, p_to), recurring blocks expanded (see the header).
-- title = the block's title, else its reason. Internal (service_role and
-- definer code; reads every block of the shop).
-- ---------------------------------------------------------------------------
create function public.blocked_time_occurrences(p_shop_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  block_id          uuid,
  member_id         uuid,
  kind              public.calendar_event_kind,
  affects_capacity  boolean,
  title             text,
  customer_id       uuid,
  color             text,
  starts_at         timestamptz,
  ends_at           timestamptz,
  names_customer    boolean
)
language sql stable
set search_path = ''
as $$
  select b.id, b.member_id, b.kind, b.affects_capacity, coalesce(b.title, b.reason), b.customer_id, b.color,
         b.starts_at, b.ends_at, b.names_customer
  from public.blocked_times b
  where b.shop_id = p_shop_id
    and b.recurrence is null
    and b.starts_at < p_to
    and b.ends_at > p_from
  union all
  select o.block_id, o.member_id, o.kind, o.affects_capacity, o.title, o.customer_id, o.color, o.s, o.e,
         o.names_customer
  from (
    select b.id as block_id, b.member_id, b.kind, b.affects_capacity, coalesce(b.title, b.reason) as title,
           b.customer_id, b.color, b.names_customer, r.cnt,
           case when c.d = r.bd then b.starts_at
                else public.wall_clock_instant(c.d + (r.ls - r.bd::timestamp), sh.timezone) end as s,
           case when c.d = r.bd then b.ends_at
                else public.wall_clock_instant(c.d + (r.le - r.bd::timestamp), sh.timezone) end as e,
           row_number() over (partition by b.id order by c.d) as n
    from public.blocked_times b
    join public.shops sh on sh.id = b.shop_id
    cross join lateral (
      select b.starts_at at time zone sh.timezone as ls,
             b.ends_at at time zone sh.timezone as le,
             (b.starts_at at time zone sh.timezone)::date as bd,
             b.recurrence ->> 'freq' as freq,
             coalesce((b.recurrence ->> 'interval')::integer, 1) as iv,
             (b.recurrence ->> 'until_date')::date as until_d,
             (b.recurrence ->> 'count')::integer as cnt,
             case when jsonb_typeof(b.recurrence -> 'by_weekday') = 'array'
                  then array(select (x #>> '{}')::integer from jsonb_array_elements(b.recurrence -> 'by_weekday') x)
             end as wds
    ) r
    cross join lateral (
      -- candidate local dates: from the original (needed to number the
      -- occurrences for count) or, without a count, from shortly before the
      -- window (an occurrence starting that early may still overlap it)
      select g::date as d
      from generate_series(
             greatest(r.bd,
                      case when r.cnt is null
                           then (p_from at time zone sh.timezone)::date - (r.le::date - r.ls::date) - 1
                           else r.bd end)::timestamp,
             -- (never below the original's date: it is always occurrence 1)
             greatest(r.bd,
                      least(coalesce(r.until_d, (p_to at time zone sh.timezone)::date),
                            (p_to at time zone sh.timezone)::date))::timestamp,
             interval '1 day') as g
    ) c
    where b.shop_id = p_shop_id
      and b.recurrence is not null
      and b.starts_at < p_to
      and (c.d = r.bd
           or (r.freq = 'day' and (c.d - r.bd) % r.iv = 0)
           or (r.freq = 'week'
               and extract(dow from c.d)::integer = any (coalesce(r.wds, array[extract(dow from r.bd)::integer]))
               and ((c.d - (r.bd - extract(dow from r.bd)::integer)) / 7) % r.iv = 0)
           or (r.freq = 'month'
               and ((extract(year from c.d) * 12 + extract(month from c.d))
                    - (extract(year from r.bd) * 12 + extract(month from r.bd)))::integer % r.iv = 0
               and extract(day from c.d)::integer
                   = least(extract(day from r.bd)::integer,
                           extract(day from (date_trunc('month', c.d::timestamp) + interval '1 month - 1 day'))::integer)))
  ) o
  where (o.cnt is null or o.n <= o.cnt)
    and o.e > o.s
    and o.s < p_to
    and o.e > p_from
$$;

comment on function public.blocked_time_occurrences(uuid, timestamptz, timestamptz) is
  '@nullable: member_id, title, customer_id, color';

-- ---------------------------------------------------------------------------
-- calendar_events v2 — same arguments; the v1 columns first, then
-- event_kind ('job' or the calendar_event_kind), series_id, color and the
-- job's service coordinates (full view only). Recurring blocks appear once
-- per occurrence (id = the block's id). Managers+ and assigned technicians
-- get full job details; technicians receive other jobs as anonymous busy
-- blocks, and blocked-time titles only for shop-wide events that name no
-- customer (blocked_times.names_customer: also once that customer is
-- deleted) and for their own events. customer_id / customer_name of a
-- customer-linked event: managers+ only.
-- ---------------------------------------------------------------------------
drop function public.calendar_events(uuid, timestamptz, timestamptz, boolean);

create function public.calendar_events(
  p_shop_id            uuid,
  p_from               timestamptz,
  p_to                 timestamptz,
  p_include_cancelled  boolean default false
) returns table (
  event_type           text,
  id                   uuid,
  job_number           bigint,
  status               public.job_status,
  starts_at            timestamptz,
  ends_at              timestamptz,
  is_busy_block        boolean,
  customer_id          uuid,
  customer_name        text,
  vehicle_id           uuid,
  vehicle_label        text,
  location_type        public.location_type,
  service_address      text,
  resource_id          uuid,
  assigned_member_ids  uuid[],
  member_id            uuid,
  title                text,
  event_kind           text,
  series_id            uuid,
  color                text,
  service_lat          double precision,
  service_lng          double precision
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role    public.shop_role := public.shop_role_of(p_shop_id);
  v_is_tech boolean;
  v_self    uuid;
begin
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if p_to - p_from > interval '93 days' then
    raise exception 'calendar range cannot exceed 93 days' using errcode = '22023';
  end if;
  v_is_tech := v_role = 'technician';
  select m.id into v_self from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid();

  return query
  with job_rows as (
    select j.*,
           coalesce(array_agg(ja.member_id order by ja.created_at) filter (where ja.member_id is not null),
                    '{}'::uuid[]) as members,
           coalesce(bool_or(ja.member_id = v_self), false) as mine
    from public.jobs j
    left join public.job_assignments ja on ja.job_id = j.id and ja.shop_id = j.shop_id
    where j.shop_id = p_shop_id
      and j.scheduled_start is not null
      and j.scheduled_start < p_to
      and j.scheduled_end > p_from
      and (p_include_cancelled or j.status <> 'cancelled')
    group by j.id
  )
  select 'job'::text,
         jr.id,
         case when full_view then jr.number end,
         jr.status,
         jr.scheduled_start,
         jr.scheduled_end,
         not full_view,
         case when full_view then jr.customer_id end,
         case when full_view then nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), '') end,
         case when full_view then jr.vehicle_id end,
         case when full_view then nullif(btrim(concat_ws(' ', v.year::text, v.make, v.model)), '') end,
         case when full_view then jr.location_type end,
         case when full_view then nullif(concat_ws(', ', jr.service_address_line1, jr.service_city), '') end,
         jr.resource_id,
         jr.members,
         null::uuid,
         case when full_view then
           coalesce(nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), c.company)
           || coalesce(' — ' || (select string_agg(li.name, ', ' order by li.sort, li.created_at)
                                 from public.job_line_items li where li.job_id = jr.id), '')
         end,
         'job'::text,
         case when full_view then jr.series_id end,
         null::text,
         case when full_view then jr.service_lat end,
         case when full_view then jr.service_lng end
  from job_rows jr
  join public.customers c on c.id = jr.customer_id
  left join public.vehicles v on v.id = jr.vehicle_id
  cross join lateral (select (not v_is_tech or jr.mine) as full_view) fv
  union all
  select 'blocked_time'::text,
         o.block_id,
         null::bigint,
         null::public.job_status,
         o.starts_at,
         o.ends_at,
         true,
         case when not v_is_tech then o.customer_id end,
         case when not v_is_tech and o.customer_id is not null then
           coalesce(nullif(btrim(concat_ws(' ', bc.first_name, bc.last_name)), ''), bc.company) end,
         null::uuid, null::text, null::public.location_type, null::text,
         null::uuid,
         '{}'::uuid[],
         o.member_id,
         case when not v_is_tech
                   or (o.member_id is null and not o.names_customer)
                   or o.member_id = v_self
              then o.title end,
         o.kind::text,
         null::uuid,
         o.color,
         null::double precision,
         null::double precision
  from public.blocked_time_occurrences(p_shop_id, p_from, p_to) o
  left join public.customers bc on bc.id = o.customer_id and bc.shop_id = p_shop_id
  order by 5, 1, 2;
end
$$;
-- (contract tag for scripts/gen_types.py: busy blocks and blocked times
-- leave these columns null)
comment on function public.calendar_events(uuid, timestamptz, timestamptz, boolean) is
  '@nullable: job_number, status, customer_id, customer_name, vehicle_id, vehicle_label, location_type, service_address, resource_id, member_id, title, series_id, color, service_lat, service_lng';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.blocked_times_validate() from public, anon, authenticated;

revoke execute on function public.blocked_time_occurrences(uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.blocked_time_occurrences(uuid, timestamptz, timestamptz) to service_role;

revoke execute on function public.calendar_events(uuid, timestamptz, timestamptz, boolean) from public, anon;
grant execute on function public.calendar_events(uuid, timestamptz, timestamptz, boolean)
  to authenticated, service_role;
