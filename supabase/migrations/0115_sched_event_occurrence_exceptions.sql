-- ============================================================================
-- 0115 — Calendar events: change or delete one occurrence of a repeating
-- event (P-17 "edit/delete occurrence vs series").
--
-- blocked_times held one repeat rule and no exceptions, so neither app could
-- touch a single occurrence: a technician's weekly Monday time off could only
-- be deleted whole, or ended and rebuilt by hand, and until then it blocked
-- that member's online-booking capacity on the Monday they work.
--
--   * blocked_times.recurrence takes an optional 'except_dates': an array of
--     at most 500 distinct shop-local dates (YYYY-MM-DD) — the local start
--     date of each skipped occurrence (calendar_recurrence_valid, the column
--     CHECK). The original row's date may be skipped too.
--   * blocked_time_occurrences leaves them out (and so do calendar_events,
--     online-booking capacity (0053) and iCal feeds (0055), which all read
--     it). A skipped occurrence still counts towards 'count' (RFC 5545
--     EXDATE): "10 times" with one skipped shows 9.
--   * "Only this occurrence": delete = add its date; change = add its date
--     and write the changed occurrence as its own one-off event.
--   * blocked_times_45_keep_exceptions (before update): a client that
--     rewrites the rule without the key (an app that predates it, or a
--     series-wide edit) keeps the skipped dates — moved by as many days as
--     the event's local start date moved, and dropped when before it. Send
--     'except_dates': [] (or null) to restore every skipped occurrence.
-- ============================================================================

create or replace function public.calendar_recurrence_valid(p jsonb) returns boolean
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
             where k not in ('freq', 'interval', 'by_weekday', 'until_date', 'count', 'except_dates')) then
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
  -- except_dates (0115): skipped occurrences, by their shop-local start
  -- date; at most 500 distinct valid dates
  if p ? 'except_dates' and jsonb_typeof(p -> 'except_dates') <> 'null' then
    if jsonb_typeof(p -> 'except_dates') <> 'array' or jsonb_array_length(p -> 'except_dates') > 500
       or exists (select 1 from jsonb_array_elements(p -> 'except_dates') e
                  where jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
       or (select count(distinct e) <> count(*) from jsonb_array_elements(p -> 'except_dates') e) then
      return false;
    end if;
    begin
      if exists (select 1 from jsonb_array_elements_text(p -> 'except_dates') e
                  where to_char(e::date, 'YYYY-MM-DD') <> e) then
        return false;
      end if;
    exception when others then
      return false;
    end;
  end if;
  return true;
end
$$;

create or replace function public.blocked_time_occurrences(p_shop_id uuid, p_from timestamptz, p_to timestamptz)
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
           row_number() over (partition by b.id order by c.d) as n,
           c.d, r.ex
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
             end as wds,
             case when jsonb_typeof(b.recurrence -> 'except_dates') = 'array'
                  then array(select (x #>> '{}')::date from jsonb_array_elements(b.recurrence -> 'except_dates') x)
             end as ex
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
    -- skipped occurrences (0115) still count towards count, as RFC 5545
    -- EXDATE does: "10 times" with one skipped leaves 9
    and not (o.d = any (coalesce(o.ex, '{}'::date[])))
    and o.e > o.s
    and o.s < p_to
    and o.e > p_from
$$;

create function public.blocked_times_keep_exceptions() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tz    text;
  v_shift integer;
  v_start date;
  v_dates jsonb;
begin
  if new.recurrence is null or jsonb_typeof(new.recurrence) <> 'object' or new.recurrence ? 'except_dates'
     or jsonb_typeof(old.recurrence -> 'except_dates') is distinct from 'array'
     or jsonb_array_length(old.recurrence -> 'except_dates') = 0 then
    return new;
  end if;
  select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
  v_start := (new.starts_at at time zone v_tz)::date;
  v_shift := v_start - (old.starts_at at time zone v_tz)::date;
  begin
    select coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d), '[]') into v_dates
      from (select distinct (x::date + v_shift) as d
              from jsonb_array_elements_text(old.recurrence -> 'except_dates') x) y
     where d >= v_start;
  exception when others then
    return new;                              -- a malformed old value is not carried
  end;
  if jsonb_array_length(v_dates) > 0 then
    new.recurrence := new.recurrence || jsonb_build_object('except_dates', v_dates);
  end if;
  return new;
end
$$;

revoke execute on function public.blocked_times_keep_exceptions() from public, anon, authenticated;

create trigger blocked_times_45_keep_exceptions before update on public.blocked_times
  for each row execute function public.blocked_times_keep_exceptions();

comment on column public.blocked_times.recurrence is
  'Repeat rule {freq, interval, by_weekday, until_date | count, except_dates} expanded in shop-local wall time (blocked_time_occurrences). except_dates (0115): shop-local start dates of skipped occurrences; kept (shifted with the start date) when an update omits the key.';
comment on function public.calendar_recurrence_valid(jsonb) is
  'Validates blocked_times.recurrence: {freq day|week|month, interval 1..12, by_weekday [0..6] (week), until_date YYYY-MM-DD | count 1..500, except_dates [YYYY-MM-DD, ≤500 distinct] (0115)}.';
