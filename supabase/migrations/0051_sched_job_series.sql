-- ============================================================================
-- 0051 — Recurring jobs (P-1): job_series behaviour.
--
-- A series is a rule + defaults (0050). Its occurrences are ordinary jobs
-- (status 'scheduled', source 'staff') carrying series_id / series_seq, so
-- everything that works on jobs (calendar, reminders, invoices, payments,
-- checklists, technicians' access) works on occurrences unchanged.
--
-- Generation. Occurrences are generated ahead up to a horizon: the later of
-- shop-local today + 90 days and the 3rd occurrence of the rule, never past
-- until_date / max_occurrences. create_job_series generates the first batch;
-- generate_series_jobs (service_role, daily cron in setup/cron.sql) extends
-- every active series. Generation only moves forward (generated_through) and
-- skips an occurrence number that already has a job, so it is idempotent. A
-- job deleted outside the series RPCs (a skipped visit) is recorded by
-- jobs_zz_series_skip in job_series.skipped_seqs / skipped_dates and is
-- never re-created, not by the cron and not by a later series edit. A date
-- in held_dates (an occurrence a rule change kept off the new rule), or the
-- date of an occurrence numbered before start_date (series_seq <=
-- seq_offset), is held: the current rule generates nothing on it.
-- Only the first generation (create_job_series) may write past dates; the
-- cron and edits never generate an occurrence that starts at or before
-- their clock, so a pause in generation (archived customer, unpriceable
-- services, a failed or missed run) never back-fills past appointments.
-- Each occurrence starts at
-- (local date + local_start) in the shop's time zone — a local time inside a
-- DST spring-forward gap resolves the way Postgres reads it (one hour
-- later), an ambiguous fall-back time to Postgres' reading (standard time) —
-- and lasts duration_minutes. Line items are priced from the catalog when
-- the occurrence is generated (price_services_core with the customer's
-- memberships; the membership discount becomes the job's percent discount),
-- assignees are the series' members that are still active. Each occurrence
-- is priced on its own, at its own start: a membership's included service
-- is free only while the occurrence's billing period still has a use left
-- (uses are counted in that period, occurrences written earlier in the same
-- run included), and the free line names the membership, so the line
-- trigger (job_line_items_61_membership_use, 0069) re-checks the use; the
-- customer's active memberships are row-locked first (the order that
-- trigger uses) so a concurrent booking cannot take the same use. Visits
-- beyond the plan's limit are charged at the catalog price; a service
-- listed twice in template_lines is included at most once per visit.
-- Auto-applied fees (money 0068) are added when the occurrence is inserted
-- and are kept whenever its lines are re-priced; the sale is credited to
-- the series creator's membership (sold_by_member_id, money 0065), not to
-- whoever runs the generator or a later edit.
--
-- Edits. A job edited on its own through the API ("this job only": its
-- time, resource, vehicle, customer, location type, service address,
-- notes, internal notes, discount or coupon, its line items or its
-- assignees) becomes series_detached, so no later series edit overwrites
-- what was changed for that visit alone. A technician's internal note is
-- not such an edit: technicians cannot change the schedule, so their note
-- never exempts a visit from the manager's series edits; an in-place
-- series edit keeps a note that differs from the series' previous default
-- (the visit's own note) instead of overwriting it. update_job_series ("this and
-- following") changes the series defaults / rule from an edit point on.
-- The edit point is a DATE: the edited occurrence's rule date (its own date
-- for an occurrence the current rule does not number), or, without one,
-- the date of the earliest occurrence that has not started yet (for a
-- rule change: the current rule's first date on or after it, so the new
-- rule keeps the old cadence's phase even when that visit was moved into
-- an off-week or off-month). Only
-- occurrences on or after that date are touched; earlier ones never are,
-- whatever their numbers. From there on:
--   * an ELIGIBLE occurrence that stays on its date (no rule change, or the
--     new rule also produces its date) is updated IN PLACE — same job, id,
--     number, public link, automation log and forms — with the new defaults
--     (times on its date, resource, vehicle, location, notes, assignees;
--     line items re-priced only when the services or the vehicle change);
--     an in-place change that would move it to a time already past leaves
--     it as it was (counted as kept);
--   * an eligible occurrence the new rule no longer produces (or past a
--     lowered until_date / max_occurrences) is deleted;
--   * every other occurrence is kept as it was;
--   * a rule change re-anchors the rule at the edit point (rule defaults
--     such as month_day / by_weekday come from that date), sets seq_offset
--     to the visits before it and renumbers the occurrences kept from there
--     on in date order together with the new rule's dates: a kept
--     occurrence on a date the new rule does not produce holds its date
--     (held_dates) and its place in the numbering, so series_seq stays the
--     visit's ordinal and max_occurrences keeps counting visits, and a kept
--     occurrence on a date the new rule does produce takes that date's
--     number (no second job there);
--   * the missing occurrences are generated.
-- Eligible = status 'scheduled' (not yet confirmed), starts after now, not
-- detached, still the series' customer's, no invoice (also none through a
-- grouped invoice, even a voided one), nothing paid or in flight
-- (job_payment_summary), no payment rows but dead attempts, and no field
-- records a delete would destroy: a signed form, an inspection, a photo or
-- video, a ticked checklist item, a time entry, a job report or an uploaded
-- document. Each occurrence from the edit point on is row-locked and
-- checked on the locked, current row (a confirmation or reschedule
-- committed meanwhile keeps it), and a job whose delete is refused by a
-- foreign key is kept too. end_job_series stops a series after a date the
-- same way (it never moves the end later); delete_job_series removes the
-- series (kept occurrences stay as ordinary jobs).
--
-- Access: owner/admin/manager (is_shop_manager) else 42501; an unknown or
-- other shop's series / job / customer: P0002; bad input: 22023 (message
-- names the field). Technicians never see series rows (RLS) and get 42501
-- from every RPC.
--
-- Customer merge (P-20): job_series_50_validate skips the vehicle-owner
-- check while detailcrm.customer_merge = 'on' outside client context.
--
-- Locks: an edit RPC takes the series' advisory lock, then its jobs, then
-- the series row (job_series_for_edit) - the order a job delete takes them.
--
-- Later ranges (the range is merged and deployable on its own): money's
-- invoice_jobs and line fee_id / membership_id (0061), price_services_core's
-- p_starts_at (0069) and ops' job_reports / documents (0071) are used only
-- once they exist (to_regclass / to_regprocedure checks, the statements
-- behind them are planned only when reached). Without them occurrences are
-- priced by the 0040 price_services_core.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- jobs_50_series_guard — BEFORE INSERT OR UPDATE on jobs (invoker, so it sees
-- the real caller). API roles cannot put a job in a series or move it
-- between series; editing an occurrence's time, resource, vehicle, customer,
-- location type, service address, notes, discount or coupon through the
-- API detaches it ("this job only"), so a later series edit never
-- overwrites or deletes it (line items and assignees: see
-- jobs_series_detach_on_child_edit). Internal notes detach only when a
-- manager+ writes them: an assigned technician may write internal notes
-- (jobs_client_guard) but not the schedule, so a field note must not take
-- the visit out of later series edits (job_series_update_occurrence keeps
-- the note). A series deleted under its jobs
-- (ON DELETE SET NULL (series_id)) also clears series_seq.
-- ---------------------------------------------------------------------------
create function public.jobs_series_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    if new.series_id is null then
      new.series_seq := null;
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.series_id is not null or new.series_seq is not null then
      raise exception 'jobs join a recurring series only through create_job_series / update_job_series'
        using errcode = '42501';
    end if;
    new.series_detached := false;
    return new;
  end if;
  if new.series_id is distinct from old.series_id or new.series_seq is distinct from old.series_seq then
    raise exception 'a job''s recurring series cannot be changed directly' using errcode = '42501';
  end if;
  if old.series_detached and not new.series_detached then
    raise exception 'a detached occurrence cannot be re-attached to its series' using errcode = '42501';
  end if;
  if new.series_id is not null
     and (new.scheduled_start is distinct from old.scheduled_start
          or new.scheduled_end is distinct from old.scheduled_end
          or new.resource_id is distinct from old.resource_id
          or new.vehicle_id is distinct from old.vehicle_id
          or new.customer_id is distinct from old.customer_id
          or new.location_type is distinct from old.location_type
          or new.service_address_line1 is distinct from old.service_address_line1
          or new.service_address_line2 is distinct from old.service_address_line2
          or new.service_city is distinct from old.service_city
          or new.service_region is distinct from old.service_region
          or new.service_postal_code is distinct from old.service_postal_code
          or new.notes is distinct from old.notes
          or (new.internal_notes is distinct from old.internal_notes and public.is_shop_manager(new.shop_id))
          or new.discount_kind is distinct from old.discount_kind
          or new.discount_value is distinct from old.discount_value
          or new.coupon_id is distinct from old.coupon_id) then
    new.series_detached := true;
  end if;
  return new;
end
$$;

create trigger jobs_50_series_guard before insert or update on public.jobs
  for each row execute function public.jobs_series_guard();

-- ---------------------------------------------------------------------------
-- jobs_series_detach_on_child_edit — AFTER INSERT / UPDATE / DELETE on
-- job_line_items and job_assignments (invoker, so it sees the real caller).
-- A line added, removed or repriced, or an assignee changed, through the
-- API is a "this job only" edit of that visit: its occurrence is detached,
-- so a later series edit never re-prices it (dropping an extra the customer
-- asked for, or its price) or resets its team. Only managers+ write these
-- rows directly (RLS), and they may detach an occurrence (jobs_series_guard
-- only forbids re-attaching). The series RPCs, cascades and other trusted
-- paths run outside client context and detach nothing.
-- ---------------------------------------------------------------------------
create function public.jobs_series_detach_on_child_edit() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return null;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    update public.jobs j set series_detached = true
     where j.shop_id = old.shop_id and j.id = old.job_id and j.series_id is not null and not j.series_detached;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    update public.jobs j set series_detached = true
     where j.shop_id = new.shop_id and j.id = new.job_id and j.series_id is not null and not j.series_detached;
  end if;
  return null;
end
$$;

create trigger job_line_items_50_series_detach after insert or update or delete on public.job_line_items
  for each row execute function public.jobs_series_detach_on_child_edit();
create trigger job_assignments_50_series_detach after insert or update or delete on public.job_assignments
  for each row execute function public.jobs_series_detach_on_child_edit();

-- ---------------------------------------------------------------------------
-- job_series_50_validate — BEFORE INSERT OR UPDATE on job_series (invoker:
-- writes come from definer RPCs, so it reads every row). References are
-- checked when they are written, so later catalog / team changes never block
-- unrelated updates (generation skips what is no longer available).
-- ---------------------------------------------------------------------------
create function public.job_series_validate() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bad text;
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id
          or new.customer_id is distinct from old.customer_id)
     and not (coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on'
              and not public.is_client_context())
     and not exists (select 1 from public.vehicles v
                     where v.id = new.vehicle_id and v.shop_id = new.shop_id and v.customer_id = new.customer_id) then
    raise exception 'the vehicle does not belong to this series'' customer' using errcode = '22023';
  end if;

  if new.resource_id is not null and (tg_op = 'INSERT' or new.resource_id is distinct from old.resource_id)
     and not exists (select 1 from public.resources r where r.id = new.resource_id and r.shop_id = new.shop_id) then
    raise exception 'unknown resource' using errcode = '22023';
  end if;

  if tg_op = 'INSERT' or new.template_lines is distinct from old.template_lines then
    if jsonb_typeof(new.template_lines) <> 'array'
       or jsonb_array_length(new.template_lines) not between 1 and 30 then
      raise exception 'template_lines must list 1 to 30 services' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(new.template_lines) e
               where jsonb_typeof(e) <> 'object'
                  or (select array_agg(k order by k) from jsonb_object_keys(e) k) <> array['quantity', 'service_id']
                  or jsonb_typeof(e -> 'service_id') <> 'string'
                  or (e ->> 'service_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  or jsonb_typeof(e -> 'quantity') <> 'number'
                  or (e ->> 'quantity')::numeric <= 0 or (e ->> 'quantity')::numeric > 1000
                  or (e ->> 'quantity')::numeric <> round((e ->> 'quantity')::numeric, 2)) then
      raise exception 'each template line needs a service_id and a quantity (0 < quantity <= 1000, 2 decimals)'
        using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(new.template_lines) e
               where not exists (select 1 from public.services s
                                 where s.id = (e ->> 'service_id')::uuid and s.shop_id = new.shop_id
                                   and s.active and s.archived_at is null)) then
      raise exception 'one or more services are not available' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'INSERT' or new.assignee_member_ids is distinct from old.assignee_member_ids then
    select string_agg(a::text, ', ') into v_bad
      from unnest(new.assignee_member_ids) as a
     where not exists (select 1 from public.shop_members m where m.id = a and m.shop_id = new.shop_id and m.active);
    if v_bad is not null then
      raise exception 'only active team members of this shop can be assigned' using errcode = '22023';
    end if;
    if cardinality(new.assignee_member_ids)
       <> (select count(distinct a) from unnest(new.assignee_member_ids) as a) then
      raise exception 'assignee_member_ids lists a member twice' using errcode = '22023';
    end if;
  end if;
  return new;
end
$$;

create trigger job_series_50_validate before insert or update on public.job_series
  for each row execute function public.job_series_validate();

-- ---------------------------------------------------------------------------
-- series_occurrence_dates — the series' numbered dates (seq, local date)
-- with p_from <= d <= p_to, in date order, at most p_limit (null = all):
-- the rule's dates plus held_dates (one entry each; on a date that is both,
-- the rule's date is numbered first). seq counts from start_date
-- (seq_offset + 1, + 2, ...) whatever p_from is, and is prefix-stable (a
-- later p_to or until_date never renumbers an earlier date). until_date and
-- max_occurrences are applied. Internal (service_role).
-- ---------------------------------------------------------------------------
create function public.series_occurrence_dates(
  p_series  public.job_series,
  p_from    date,
  p_to      date,
  p_limit   integer
) returns table (seq integer, d date)
language sql stable
set search_path = ''
as $$
  with b as (
    select p_series.start_date as s,
           case when p_series.until_date is null then p_to else least(p_to, p_series.until_date) end as e
  ),
  cand as (
    -- weekly: days of by_weekday in every "interval"-th week (weeks start on
    -- the Sunday on or before start_date)
    select g::date as d, 0 as k
    from b
    cross join lateral generate_series(b.s::timestamp, b.e::timestamp, interval '1 day') as g
    where p_series.freq = 'week'
      and extract(dow from g)::smallint = any (p_series.by_weekday)
      and ((g::date - (b.s - extract(dow from b.s)::integer)) / 7) % p_series."interval" = 0
    union all
    -- monthly: one date in every "interval"-th month
    select x.d, 0 as k
    from b
    cross join lateral generate_series(date_trunc('month', b.s::timestamp), b.e::timestamp,
                                       make_interval(months => p_series."interval")) as m
    cross join lateral (select m::date as ms, (m + interval '1 month')::date - 1 as me) mm
    cross join lateral (
      select case
               when p_series.month_mode = 'day_of_month' then
                 mm.ms + (least(p_series.month_day::integer, mm.me - mm.ms + 1) - 1)
               when p_series.month_nth = -1 then
                 mm.me - ((extract(dow from mm.me)::integer - p_series.month_weekday + 7) % 7)
               else
                 mm.ms + ((p_series.month_weekday - extract(dow from mm.ms)::integer + 7) % 7)
                       + 7 * (p_series.month_nth - 1)
             end as d
    ) x
    where p_series.freq = 'month'
      and x.d <= mm.me            -- no 5th such weekday this month: skipped
    union all
    -- dates of occurrences a rule change kept off the rule
    select h.d, 1 as k
    from unnest(coalesce(p_series.held_dates, '{}'::date[])) as h(d)
  ),
  numbered as (
    select (p_series.seq_offset + row_number() over (order by c.d, c.k))::integer as seq, c.d
    from cand c
    cross join b
    where c.d between b.s and b.e
  )
  select n.seq, n.d
  from numbered n
  where (p_series.max_occurrences is null or n.seq <= p_series.max_occurrences)
    and (p_from is null or n.d >= p_from)
  order by n.d
  limit p_limit
$$;

comment on function public.series_occurrence_dates(public.job_series, date, date, integer) is
  'Occurrences (seq, local date) of a series rule between p_from and p_to (internal).';

-- A date by which the rule has produced its first p_k occurrences (unless
-- until / max stop it first): every on-week of a weekly rule has at least
-- one occurrence; monthly rules are scanned month by month (cheap), up to
-- 100 years (a 5th weekday in one calendar month can be years apart).
create function public.job_series_scan_end(p_series public.job_series, p_k integer) returns date
language sql immutable
set search_path = ''
as $$
  select p_series.start_date
         + case when p_series.freq = 'week' then 7 * p_series."interval" * (greatest(p_k, 1) + 1)
                else 36600 end
$$;

-- ---------------------------------------------------------------------------
-- job_series_apply — reads the series JSON (create / preview: every field;
-- patch: the editable ones) onto p_base. A present key with JSON null clears
-- a nullable field. Unknown keys: 22023. Returns the merged row (not yet
-- normalized: see job_series_normalize).
-- ---------------------------------------------------------------------------
create function public.job_series_apply(p_base public.job_series, p_in jsonb, p_mode text)
returns public.job_series
language plpgsql stable
set search_path = ''
as $$
declare
  c_patch constant text[] := array[
    'vehicle_id', 'location_type', 'service_address_line1', 'service_address_line2', 'service_city',
    'service_region', 'service_postal_code', 'service_lat', 'service_lng', 'resource_id', 'local_start',
    'duration_minutes', 'template_lines', 'assignee_member_ids', 'notes', 'internal_notes', 'freq', 'interval',
    'by_weekday', 'month_mode', 'month_day', 'month_nth', 'month_weekday', 'until_date', 'max_occurrences'];
  c_create constant text[] := c_patch || array['customer_id', 'start_date', 'send_confirmation'];
  v       public.job_series := p_base;
  v_key   text;
  v_txt   text;
  v_num   jsonb;
  v_lines jsonb;
begin
  if p_in is null or jsonb_typeof(p_in) <> 'object' then
    raise exception 'series details must be a JSON object' using errcode = '22023';
  end if;
  select k into v_key from jsonb_object_keys(p_in) k
   where k <> all (case when p_mode = 'patch' then c_patch else c_create end)
   order by k limit 1;
  if v_key is not null then
    raise exception 'unknown or read-only series field: %', v_key using errcode = '22023';
  end if;

  if p_in ? 'customer_id' then
    v.customer_id := public.payload_uuid(p_in, 'customer_id', 'customer_id');
  end if;
  if p_in ? 'vehicle_id' then
    v.vehicle_id := public.payload_uuid(p_in, 'vehicle_id', 'vehicle_id');
  end if;
  if p_in ? 'resource_id' then
    v.resource_id := public.payload_uuid(p_in, 'resource_id', 'resource_id');
  end if;
  if p_in ? 'location_type' then
    v_txt := lower(public.payload_text(p_in, 'location_type', 10, 'location_type', true));
    if v_txt not in ('shop', 'mobile') then
      raise exception 'location_type must be shop or mobile' using errcode = '22023';
    end if;
    v.location_type := v_txt::public.location_type;
  end if;
  if p_in ? 'service_address_line1' then
    v.service_address_line1 := public.payload_text(p_in, 'service_address_line1', 200, 'service_address_line1');
  end if;
  if p_in ? 'service_address_line2' then
    v.service_address_line2 := public.payload_text(p_in, 'service_address_line2', 200, 'service_address_line2');
  end if;
  if p_in ? 'service_city' then
    v.service_city := public.payload_text(p_in, 'service_city', 100, 'service_city');
  end if;
  if p_in ? 'service_region' then
    v.service_region := public.payload_text(p_in, 'service_region', 100, 'service_region');
  end if;
  if p_in ? 'service_postal_code' then
    v.service_postal_code := public.payload_text(p_in, 'service_postal_code', 20, 'service_postal_code');
  end if;
  foreach v_key in array array['service_lat', 'service_lng'] loop
    if p_in ? v_key then
      v_num := p_in -> v_key;
      if jsonb_typeof(v_num) = 'null' then
        if v_key = 'service_lat' then v.service_lat := null; else v.service_lng := null; end if;
      elsif jsonb_typeof(v_num) <> 'number' then
        raise exception '% must be a number', v_key using errcode = '22023';
      elsif v_key = 'service_lat' then
        v.service_lat := (v_num #>> '{}')::double precision;
      else
        v.service_lng := (v_num #>> '{}')::double precision;
      end if;
    end if;
  end loop;
  -- coordinates belong to an address: a patch that moves the location
  -- (type or any address field) without sending new coordinates clears
  -- them, so occurrences are geocoded again (as jobs_56_route_geo_reset
  -- does for a single job, 0057)
  if p_mode = 'patch' and not (p_in ? 'service_lat' or p_in ? 'service_lng')
     and (v.location_type, v.service_address_line1, v.service_address_line2, v.service_city, v.service_region,
          v.service_postal_code)
         is distinct from
         (p_base.location_type, p_base.service_address_line1, p_base.service_address_line2, p_base.service_city,
          p_base.service_region, p_base.service_postal_code) then
    v.service_lat := null;
    v.service_lng := null;
  end if;
  if (v.service_lat is null) <> (v.service_lng is null) then
    raise exception 'service_lat and service_lng go together' using errcode = '22023';
  end if;
  if v.service_lat not between -90 and 90 or v.service_lng not between -180 and 180 then
    raise exception 'service coordinates are out of range' using errcode = '22023';
  end if;

  if p_in ? 'freq' then
    v_txt := lower(public.payload_text(p_in, 'freq', 10, 'freq', true));
    if v_txt not in ('week', 'month') then
      raise exception 'freq must be week or month' using errcode = '22023';
    end if;
    v.freq := v_txt;
  end if;
  if p_in ? 'interval' then
    v."interval" := coalesce(public.payload_int(p_in, 'interval', 'interval', 1, 12), 1);
  end if;
  if p_in ? 'by_weekday' then
    v_num := p_in -> 'by_weekday';
    if jsonb_typeof(v_num) = 'null' then
      v.by_weekday := '{}';
    elsif jsonb_typeof(v_num) <> 'array'
          or exists (select 1 from jsonb_array_elements(v_num) e
                     where jsonb_typeof(e) <> 'number' or (e #>> '{}') !~ '^[0-6]$') then
      raise exception 'by_weekday must be a list of weekdays 0 (Sunday) to 6 (Saturday)' using errcode = '22023';
    else
      v.by_weekday := array(select distinct (e #>> '{}')::smallint from jsonb_array_elements(v_num) e order by 1);
    end if;
  end if;
  if p_in ? 'month_mode' then
    v_txt := lower(public.payload_text(p_in, 'month_mode', 20, 'month_mode'));
    if v_txt is not null and v_txt not in ('day_of_month', 'nth_weekday') then
      raise exception 'month_mode must be day_of_month or nth_weekday' using errcode = '22023';
    end if;
    v.month_mode := v_txt;
  end if;
  if p_in ? 'month_day' then
    v.month_day := public.payload_int(p_in, 'month_day', 'month_day', 1, 31);
  end if;
  if p_in ? 'month_nth' then
    v.month_nth := public.payload_int(p_in, 'month_nth', 'month_nth', -1, 5);
    if v.month_nth = 0 then
      raise exception 'month_nth must be 1-5 or -1 (last)' using errcode = '22023';
    end if;
  end if;
  if p_in ? 'month_weekday' then
    v.month_weekday := public.payload_int(p_in, 'month_weekday', 'month_weekday', 0, 6);
  end if;

  if p_in ? 'start_date' then
    v_txt := public.payload_text(p_in, 'start_date', 10, 'start_date', true);
    begin
      if v_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or to_char(v_txt::date, 'YYYY-MM-DD') <> v_txt then
        raise exception using errcode = '22007';
      end if;
      v.start_date := v_txt::date;
    exception when others then
      raise exception 'start_date must be a date (YYYY-MM-DD)' using errcode = '22023';
    end;
  end if;
  if p_in ? 'until_date' then
    v_txt := public.payload_text(p_in, 'until_date', 10, 'until_date');
    if v_txt is null then
      v.until_date := null;
    else
      begin
        if v_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or to_char(v_txt::date, 'YYYY-MM-DD') <> v_txt then
          raise exception using errcode = '22007';
        end if;
        v.until_date := v_txt::date;
      exception when others then
        raise exception 'until_date must be a date (YYYY-MM-DD)' using errcode = '22023';
      end;
    end if;
  end if;
  if p_in ? 'local_start' then
    v_txt := public.payload_text(p_in, 'local_start', 8, 'local_start', true);
    if v_txt !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
      raise exception 'local_start must be a time of day (HH:MM)' using errcode = '22023';
    end if;
    v.local_start := v_txt::time;
  end if;
  if p_in ? 'duration_minutes' then
    v.duration_minutes := public.payload_int(p_in, 'duration_minutes', 'duration_minutes', 15, 44640);
  end if;
  if p_in ? 'max_occurrences' then
    v.max_occurrences := public.payload_int(p_in, 'max_occurrences', 'max_occurrences', 1, 500);
  end if;

  if p_in ? 'template_lines' then
    v_lines := p_in -> 'template_lines';
    if jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) not between 1 and 30 then
      raise exception 'template_lines must list 1 to 30 services' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(v_lines) e
               where jsonb_typeof(e) <> 'object'
                  or exists (select 1 from jsonb_object_keys(e) k where k not in ('service_id', 'quantity'))
                  or jsonb_typeof(e -> 'service_id') is distinct from 'string'
                  or (e ->> 'service_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  or coalesce(jsonb_typeof(e -> 'quantity'), 'null') not in ('number', 'null')) then
      raise exception 'each template line needs a service_id and an optional quantity' using errcode = '22023';
    end if;
    v.template_lines := (
      select jsonb_agg(jsonb_build_object('service_id', lower(e ->> 'service_id'),
                                          'quantity', coalesce((e ->> 'quantity')::numeric, 1)) order by o)
      from jsonb_array_elements(v_lines) with ordinality as t(e, o));
    if exists (select 1 from jsonb_array_elements(v.template_lines) e
               where (e ->> 'quantity')::numeric <= 0 or (e ->> 'quantity')::numeric > 1000
                  or (e ->> 'quantity')::numeric <> round((e ->> 'quantity')::numeric, 2)) then
      raise exception 'quantity must be more than 0 and at most 1000 (2 decimals)' using errcode = '22023';
    end if;
  end if;
  if p_in ? 'assignee_member_ids' then
    v.assignee_member_ids := public.payload_uuid_array(p_in, 'assignee_member_ids', 'assignee_member_ids', 10);
  end if;
  if p_in ? 'notes' then
    v.notes := public.payload_text(p_in, 'notes', 20000, 'notes');
  end if;
  if p_in ? 'internal_notes' then
    v.internal_notes := public.payload_text(p_in, 'internal_notes', 20000, 'internal_notes');
  end if;
  if p_in ? 'send_confirmation' then
    perform public.payload_bool(p_in, 'send_confirmation', 'send_confirmation');
  end if;
  return v;
end
$$;

-- Fills rule defaults from start_date (week: its weekday; month: its day of
-- the month) and clears the fields of the other frequency; 22023 when the
-- rule is incomplete.
create function public.job_series_normalize(p public.job_series) returns public.job_series
language plpgsql immutable
set search_path = ''
as $$
declare
  v public.job_series := p;
begin
  if v.freq is null then
    raise exception 'freq is required (week or month)' using errcode = '22023';
  end if;
  if v.start_date is null then
    raise exception 'start_date is required' using errcode = '22023';
  end if;
  if v.local_start is null then
    raise exception 'local_start is required' using errcode = '22023';
  end if;
  v."interval" := coalesce(v."interval", 1);
  if v.freq = 'week' then
    v.month_mode := null; v.month_day := null; v.month_nth := null; v.month_weekday := null;
    if coalesce(cardinality(v.by_weekday), 0) = 0 then
      v.by_weekday := array[extract(dow from v.start_date)::smallint];
    end if;
  else
    v.by_weekday := '{}';
    if v.month_mode is null then
      if v.month_nth is not null or v.month_weekday is not null then
        v.month_mode := 'nth_weekday';
      else
        v.month_mode := 'day_of_month';
      end if;
    end if;
    if v.month_mode = 'day_of_month' then
      v.month_nth := null; v.month_weekday := null;
      v.month_day := coalesce(v.month_day, extract(day from v.start_date)::smallint);
    else
      v.month_day := null;
      if v.month_nth is null or v.month_weekday is null then
        raise exception 'an nth-weekday rule needs month_nth and month_weekday' using errcode = '22023';
      end if;
    end if;
  end if;
  if v.until_date is not null and v.until_date < v.start_date then
    raise exception 'until_date must be on or after the start date' using errcode = '22023';
  end if;
  return v;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_price_lines — the occurrence's line items priced from the
-- catalog now: {lines: [{service_id, name, description, quantity,
-- unit_price_cents, taxable, duration_minutes, membership_id}],
-- discount_value (membership percent in bps), duration_minutes (sum of
-- duration x quantity)}.
-- p_starts_at: the start of the occurrence being priced — membership uses
-- are counted in ITS billing period (null = now, for validation and
-- durations only; occurrences are always written with their own start).
-- An included service is free (unit price 0, membership_id set) only while
-- that period has a use left; the next template line of the same service
-- is charged at the catalog price.
-- p_strict: every template service must be available and priced (22023);
-- otherwise unavailable / unpriced services are left out and null is
-- returned when nothing is left.
-- ---------------------------------------------------------------------------
create function public.job_series_price_lines(
  p_series     public.job_series,
  p_strict     boolean,
  p_starts_at  timestamptz default null
) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_ids      uuid[];
  v_all      integer;
  v_cat      uuid;
  v_pricing  jsonb;
  v_lines    jsonb := '[]'::jsonb;
  v_dur      numeric := 0;
  v_seen     uuid[] := '{}';
  v_sid      uuid;
  v_unit     bigint;
  v_mid      uuid;
  r          record;
  v_price    jsonb;
begin
  select count(distinct e ->> 'service_id') into v_all from jsonb_array_elements(p_series.template_lines) e;
  v_ids := array(
    select distinct s.id
      from jsonb_array_elements(p_series.template_lines) e
      join public.services s on s.id = (e ->> 'service_id')::uuid and s.shop_id = p_series.shop_id
     where s.active and s.archived_at is null);
  if coalesce(cardinality(v_ids), 0) < v_all and p_strict then
    raise exception 'one or more services are not available' using errcode = '22023';
  end if;
  if coalesce(cardinality(v_ids), 0) = 0 then
    return null;
  end if;
  if p_series.vehicle_id is not null then
    select v.category_id into v_cat from public.vehicles v
     where v.id = p_series.vehicle_id and v.shop_id = p_series.shop_id;
  end if;
  if to_regprocedure('public.price_services_core(uuid,uuid,uuid,uuid[],uuid,boolean,timestamptz)') is not null then
    -- (named: p_starts_at is price_services_core's trailing argument, money 0069)
    v_pricing := public.price_services_core(p_series.shop_id, p_series.customer_id, v_cat, v_ids,
                                            p_series.vehicle_id, true, p_starts_at => p_starts_at);
  else
    -- without money 0069 (see the header): the 0040 pricing, no billing periods
    v_pricing := public.price_services_core(p_series.shop_id, p_series.customer_id, v_cat, v_ids,
                                            p_series.vehicle_id, true);
  end if;
  for r in
    select e, o from jsonb_array_elements(p_series.template_lines) with ordinality as t(e, o) order by o
  loop
    select l into v_price from jsonb_array_elements(v_pricing -> 'lines') l
     where l ->> 'service_id' = r.e ->> 'service_id';
    if v_price is null then
      continue;                            -- not available any more (non-strict)
    end if;
    v_sid := (v_price ->> 'service_id')::uuid;
    v_mid := nullif(v_price ->> 'membership_id', '')::uuid;
    v_unit := (v_price ->> 'unit_price_cents')::bigint;
    if v_mid is not null and v_sid = any (v_seen) then
      -- the same service again in this visit: the membership covered the
      -- first line only (one use per line)
      v_mid := null;
      v_unit := (v_price ->> 'catalog_price_cents')::bigint;
    end if;
    v_seen := v_seen || v_sid;
    if v_unit is null then
      if p_strict then
        raise exception '"%" has no price for this vehicle%', v_price ->> 'name',
          case when v_price ->> 'membership_id' is not null or (v_price ->> 'uses_remaining') = '0'
               then ' (needed once the membership''s visits for the period are used)' else '' end
          using errcode = '22023';
      end if;
      continue;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'service_id', v_sid,
      'name', v_price ->> 'name',
      'description', case when v_mid is null and v_price ->> 'membership_id' is not null then null
                          else v_price ->> 'note' end,
      'quantity', (r.e ->> 'quantity')::numeric,
      'unit_price_cents', v_unit,
      'taxable', (v_price ->> 'taxable')::boolean,
      'duration_minutes', coalesce((v_price ->> 'duration_minutes')::integer, 0),
      'membership_id', v_mid));
    v_dur := v_dur + coalesce((v_price ->> 'duration_minutes')::integer, 0) * (r.e ->> 'quantity')::numeric;
  end loop;
  if jsonb_array_length(v_lines) = 0 then
    return null;
  end if;
  return jsonb_build_object(
    'lines', v_lines,
    'discount_value', coalesce((v_pricing ->> 'suggested_discount_value')::bigint, 0),
    'duration_minutes', round(v_dur)::integer);
end
$$;

-- Row-locks the series customer's active memberships (the order
-- job_line_items_61_membership_use locks them in) before occurrences are
-- priced, so a concurrent booking cannot take a use this run counts as free.
create function public.job_series_lock_memberships(p_series public.job_series) returns void
language plpgsql volatile
set search_path = ''
as $$
begin
  perform 1
     from public.memberships m
     join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
    where m.shop_id = p_series.shop_id and m.customer_id = p_series.customer_id and m.status = 'active'
    order by p.name, p.id, m.id
      for no key update of m;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_write_lines — (re)writes an occurrence's line items and its
-- membership percent discount from p_pr (job_series_price_lines for THIS
-- occurrence's start; a free line carries its membership). Existing
-- service lines are deleted first (their membership uses are released
-- before the new lines take them again). Fee lines (fee_id: added by
-- jobs_zz_money_auto_fees when the occurrence is inserted or its location
-- type changes, or by hand through add_fee_line, money 0068) are kept, so
-- a recurring visit carries the same fees as a one-off job. Without money
-- 0061 (see the header) lines have neither fee_id nor membership_id.
-- job_series_write_assignees — makes the occurrence's assignees exactly the
-- series' members that are still active.
-- ---------------------------------------------------------------------------
create function public.job_series_write_lines(p_s public.job_series, p_job_id uuid, p_pr jsonb) returns void
language plpgsql volatile
set search_path = ''
as $$
declare
  v_disc bigint := coalesce((p_pr ->> 'discount_value')::bigint, 0);
begin
  if to_regclass('public.invoice_jobs') is not null then       -- money 0061 applied
    delete from public.job_line_items li
     where li.shop_id = p_s.shop_id and li.job_id = p_job_id and li.fee_id is null;
    insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                       unit_price_cents, taxable, duration_minutes, sort, membership_id)
    select p_s.shop_id, p_job_id, (l.e ->> 'service_id')::uuid, p_s.vehicle_id, l.e ->> 'name', l.e ->> 'description',
           (l.e ->> 'quantity')::numeric, (l.e ->> 'unit_price_cents')::bigint, (l.e ->> 'taxable')::boolean,
           (l.e ->> 'duration_minutes')::integer, l.o::integer, nullif(l.e ->> 'membership_id', '')::uuid
      from jsonb_array_elements(p_pr -> 'lines') with ordinality as l(e, o);
  else
    delete from public.job_line_items li
     where li.shop_id = p_s.shop_id and li.job_id = p_job_id;
    insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                       unit_price_cents, taxable, duration_minutes, sort)
    select p_s.shop_id, p_job_id, (l.e ->> 'service_id')::uuid, p_s.vehicle_id, l.e ->> 'name', l.e ->> 'description',
           (l.e ->> 'quantity')::numeric, (l.e ->> 'unit_price_cents')::bigint, (l.e ->> 'taxable')::boolean,
           (l.e ->> 'duration_minutes')::integer, l.o::integer
      from jsonb_array_elements(p_pr -> 'lines') with ordinality as l(e, o);
  end if;
  update public.jobs j
     set discount_kind = case when v_disc > 0 then 'percent' else 'none' end::public.discount_kind,
         discount_value = v_disc
   where j.shop_id = p_s.shop_id and j.id = p_job_id
     and (j.discount_kind, j.discount_value)
         is distinct from (case when v_disc > 0 then 'percent' else 'none' end::public.discount_kind, v_disc);
end
$$;

create function public.job_series_write_assignees(p_s public.job_series, p_job_id uuid) returns void
language plpgsql volatile
set search_path = ''
as $$
begin
  delete from public.job_assignments ja
   where ja.shop_id = p_s.shop_id and ja.job_id = p_job_id
     and not exists (select 1 from unnest(p_s.assignee_member_ids) as a(id)
                      join public.shop_members m on m.id = a.id and m.shop_id = p_s.shop_id and m.active
                     where a.id = ja.member_id);
  insert into public.job_assignments (shop_id, job_id, member_id)
  select p_s.shop_id, p_job_id, a.id
    from unnest(p_s.assignee_member_ids) with ordinality as a(id, o)
    join public.shop_members m on m.id = a.id and m.shop_id = p_s.shop_id and m.active
   where not exists (select 1 from public.job_assignments x
                      where x.shop_id = p_s.shop_id and x.job_id = p_job_id and x.member_id = a.id)
   order by a.o;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_insert_occurrence — writes occurrence p_seq on local date p_d:
-- the job (series defaults, status scheduled), its priced lines (p_pr from
-- job_series_price_lines for THIS occurrence's start) and the series'
-- still-active assignees.
-- ---------------------------------------------------------------------------
create function public.job_series_insert_occurrence(
  p_s    public.job_series,
  p_seq  integer,
  p_d    date,
  p_pr   jsonb,
  p_tz   text
) returns uuid
language plpgsql volatile
set search_path = ''
as $$
declare
  v_start  timestamptz := (p_d + p_s.local_start) at time zone p_tz;
  v_disc   bigint := coalesce((p_pr ->> 'discount_value')::bigint, 0);
  v_job_id uuid;
begin
  insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end, location_type,
                           service_address_line1, service_address_line2, service_city, service_region,
                           service_postal_code, service_lat, service_lng, resource_id, notes, internal_notes,
                           source, discount_kind, discount_value, series_id, series_seq)
  values (p_s.shop_id, p_s.customer_id, p_s.vehicle_id, 'scheduled', v_start,
          v_start + make_interval(mins => p_s.duration_minutes), p_s.location_type,
          p_s.service_address_line1, p_s.service_address_line2, p_s.service_city, p_s.service_region,
          p_s.service_postal_code, p_s.service_lat, p_s.service_lng, p_s.resource_id, p_s.notes, p_s.internal_notes,
          'staff', case when v_disc > 0 then 'percent' else 'none' end::public.discount_kind, v_disc,
          p_s.id, p_seq)
  returning id into v_job_id;
  perform public.job_series_write_lines(p_s, v_job_id, p_pr);
  perform public.job_series_write_assignees(p_s, v_job_id);
  return v_job_id;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_update_occurrence — brings an eligible occurrence (locked by
-- the caller) up to the series defaults IN PLACE on its own local date p_d:
-- same job, id, number, public link, automation log and forms. Lines are
-- re-priced (at the occurrence's start) only when p_reprice (the services
-- or the vehicle changed); assignees are rewritten only when p_reassign.
-- Internal notes take the new default only while the job's note is still
-- the series' previous default (p_old_internal_notes): a note written on
-- the visit itself (a technician's field note) is kept. Coordinates: the series' point when it has one; otherwise the job's own
-- point while its address stays the same (null once it moves). Returns
-- false (nothing written) when the new start would already have passed.
-- ---------------------------------------------------------------------------
create function public.job_series_update_occurrence(
  p_s         public.job_series,
  p_job_id    uuid,
  p_d         date,
  p_tz        text,
  p_now       timestamptz,
  p_reprice   boolean,
  p_reassign  boolean,
  p_old_internal_notes text
) returns boolean
language plpgsql volatile
set search_path = ''
as $$
declare
  v_start timestamptz := (p_d + p_s.local_start) at time zone p_tz;
  v_job   public.jobs;
  v_same  boolean;
  v_inote text;
begin
  select * into v_job from public.jobs j where j.shop_id = p_s.shop_id and j.id = p_job_id;
  if not found then
    return false;
  end if;
  v_inote := case when v_job.internal_notes is not distinct from p_old_internal_notes then p_s.internal_notes
                  else v_job.internal_notes end;
  if v_start <> v_job.scheduled_start and v_start <= p_now then
    return false;
  end if;
  v_same := (p_s.location_type, p_s.service_address_line1, p_s.service_address_line2, p_s.service_city,
             p_s.service_region, p_s.service_postal_code)
            is not distinct from
            (v_job.location_type, v_job.service_address_line1, v_job.service_address_line2, v_job.service_city,
             v_job.service_region, v_job.service_postal_code);
  update public.jobs j
     set vehicle_id = p_s.vehicle_id, location_type = p_s.location_type,
         service_address_line1 = p_s.service_address_line1, service_address_line2 = p_s.service_address_line2,
         service_city = p_s.service_city, service_region = p_s.service_region,
         service_postal_code = p_s.service_postal_code,
         service_lat = case when p_s.service_lat is not null then p_s.service_lat
                            when v_same then j.service_lat end,
         service_lng = case when p_s.service_lat is not null then p_s.service_lng
                            when v_same then j.service_lng end,
         resource_id = p_s.resource_id, notes = p_s.notes, internal_notes = v_inote,
         scheduled_start = v_start, scheduled_end = v_start + make_interval(mins => p_s.duration_minutes)
   where j.shop_id = p_s.shop_id and j.id = p_job_id
     and (j.vehicle_id, j.location_type, j.service_address_line1, j.service_address_line2, j.service_city,
          j.service_region, j.service_postal_code, j.resource_id, j.notes, j.internal_notes,
          j.scheduled_start, j.scheduled_end,
          j.service_lat, j.service_lng)
         is distinct from
         (p_s.vehicle_id, p_s.location_type, p_s.service_address_line1, p_s.service_address_line2, p_s.service_city,
          p_s.service_region, p_s.service_postal_code, p_s.resource_id, p_s.notes, v_inote,
          v_start, v_start + make_interval(mins => p_s.duration_minutes),
          case when p_s.service_lat is not null then p_s.service_lat when v_same then j.service_lat end,
          case when p_s.service_lat is not null then p_s.service_lng when v_same then j.service_lng end);
  if p_reprice then
    perform public.job_series_write_lines(p_s, p_job_id, public.job_series_price_lines(p_s, true, v_start));
  end if;
  if p_reassign then
    perform public.job_series_write_assignees(p_s, p_job_id);
  end if;
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_generate — extends one series to its horizon (see the header).
-- Returns the number of jobs created. Serialized per series by an advisory
-- lock (the same key the edit RPCs take). Each occurrence is priced at its
-- own start (job_series_price_lines). When an occurrence cannot be priced
-- (non-strict: the cron) generation stops before it and resumes from its
-- date on a later run.
-- ---------------------------------------------------------------------------
create function public.job_series_generate(p_series_id uuid, p_now timestamptz, p_strict boolean)
returns integer
language plpgsql volatile
set search_path = ''
as $$
declare
  v_s        public.job_series;
  v_tz       text;
  v_today    date;
  v_third    date;
  v_horizon  date;
  v_to       date;
  v_from     date;
  v_pr       jsonb;
  v_occ      record;
  v_count    integer := 0;
  v_now      timestamptz := coalesce(p_now, now());
  v_extend   boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('job_series:' || p_series_id::text, 0));
  select * into v_s from public.job_series js where js.id = p_series_id for update;
  if not found or not v_s.active then
    return 0;
  end if;
  -- only the first generation (create_job_series) may write past dates
  v_extend := v_s.generated_through is not null;
  if exists (select 1 from public.customers c where c.id = v_s.customer_id and c.shop_id = v_s.shop_id
                                                 and c.archived_at is not null) then
    if p_strict then
      raise exception 'this customer is archived' using errcode = '22023';
    end if;
    return 0;
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_s.shop_id;
  v_today := (v_now at time zone v_tz)::date;
  select o.d into v_third
    from public.series_occurrence_dates(v_s, v_s.start_date, public.job_series_scan_end(v_s, 3), 3) o
   order by o.d offset 2 limit 1;
  v_horizon := greatest(v_today + 90, coalesce(v_third, v_today + 90));
  v_to := case when v_s.until_date is null then v_horizon else least(v_horizon, v_s.until_date) end;
  v_from := greatest(coalesce(v_s.generated_through + 1, v_s.start_date), v_s.start_date);
  if v_extend then
    v_from := greatest(v_from, v_today);
  end if;
  if v_from > v_to then
    return 0;
  end if;

  perform public.job_series_lock_memberships(v_s);
  for v_occ in
    select o.seq, o.d
      from public.series_occurrence_dates(v_s, v_from, v_to, null) o
     where not exists (select 1 from public.jobs j where j.series_id = v_s.id and j.series_seq = o.seq)
       -- skipped visits (deleted outside the series RPCs)
       and o.seq <> all (v_s.skipped_seqs)
       and o.d <> all (v_s.skipped_dates)
       -- a date held by an occurrence a rule change kept (its number is
       -- that job's, or a skipped visit's once the job is deleted)
       and o.d <> all (v_s.held_dates)
       -- a kept occurrence numbered before start_date holds its date
       and not exists (select 1 from public.jobs j
                        where j.shop_id = v_s.shop_id and j.series_id = v_s.id
                          and j.series_seq <= v_s.seq_offset
                          and j.scheduled_start is not null
                          and (j.scheduled_start at time zone v_tz)::date = o.d)
       -- the cron and edits never write an occurrence that already started
       and (not v_extend or ((o.d + v_s.local_start) at time zone v_tz) > v_now)
     order by o.d
  loop
    -- priced at this occurrence's start, after the occurrences written
    -- before it (their membership uses count)
    v_pr := public.job_series_price_lines(v_s, p_strict, (v_occ.d + v_s.local_start) at time zone v_tz);
    if v_pr is null then
      if p_strict then
        raise exception 'none of the series'' services can be priced' using errcode = '22023';
      end if;
      raise warning 'job series %: no available priced services from %; generation stopped', v_s.id, v_occ.d;
      v_to := v_occ.d - 1;
      exit;
    end if;
    perform public.job_series_insert_occurrence(v_s, v_occ.seq, v_occ.d, v_pr, v_tz);
    v_count := v_count + 1;
  end loop;

  update public.job_series js
     set generated_through = greatest(coalesce(js.generated_through, v_to), v_to)
   where js.id = v_s.id;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_occurrence_eligible — may a "this and following" edit (or the
-- end of the series) replace this occurrence? See the header. Needs the
-- caller's job access (job_payment_summary checks it). Records of later
-- ranges (invoice_jobs: money 0061; job_reports, documents: ops 0071) are
-- looked up only once their tables exist (see the header).
-- ---------------------------------------------------------------------------
create function public.job_series_occurrence_eligible(p_job public.jobs, p_now timestamptz) returns boolean
language plpgsql stable
set search_path = ''
as $$
begin
  if not (p_job.status = 'scheduled' and p_job.scheduled_start > p_now and not p_job.series_detached) then
    return false;
  end if;
  -- given to another customer (by a trusted path that does not detach it):
  -- that customer's appointment, not the series'
  if not exists (select 1 from public.job_series js
                  where js.id = p_job.series_id and js.shop_id = p_job.shop_id
                    and js.customer_id = p_job.customer_id) then
    return false;
  end if;
  -- money
  if exists (select 1 from public.invoices i where i.shop_id = p_job.shop_id and i.job_id = p_job.id)
     or exists (select 1 from public.payments p
                 where p.shop_id = p_job.shop_id and p.job_id = p_job.id
                   and not (p.status in ('failed', 'cancelled') and p.refunded_cents = 0 and p.paid_at is null))
     or not exists (select 1 from public.job_payment_summary(p_job.id) s
                     where s.invoice_id is null and s.paid_cents = 0 and s.pending_cents = 0) then
    return false;
  end if;
  -- billed through a grouped invoice (money 0061), even a voided one: the
  -- line is a financial record of this visit (invoice_jobs RESTRICTs its delete)
  if to_regclass('public.invoice_jobs') is not null then
    if exists (select 1 from public.invoice_jobs x where x.shop_id = p_job.shop_id and x.job_id = p_job.id) then
      return false;
    end if;
  end if;
  -- field records a delete would cascade away (a signed waiver is a legal
  -- record; photos, inspections, ticked checklist items, time, reports and
  -- documents are work already done or recorded on this visit)
  if exists (select 1 from public.form_submissions f
              where f.shop_id = p_job.shop_id and f.job_id = p_job.id and f.signed_at is not null)
     or exists (select 1 from public.inspections x where x.shop_id = p_job.shop_id and x.job_id = p_job.id)
     or exists (select 1 from public.job_photos x where x.shop_id = p_job.shop_id and x.job_id = p_job.id)
     or exists (select 1 from public.job_checklist_items x
                 where x.shop_id = p_job.shop_id and x.job_id = p_job.id and x.done_at is not null)
     or exists (select 1 from public.time_entries x where x.shop_id = p_job.shop_id and x.job_id = p_job.id) then
    return false;
  end if;
  if to_regclass('public.job_reports') is not null then        -- ops 0071 applied
    if exists (select 1 from public.job_reports x where x.shop_id = p_job.shop_id and x.job_id = p_job.id)
       or exists (select 1 from public.documents x where x.shop_id = p_job.shop_id and x.job_id = p_job.id) then
      return false;
    end if;
  end if;
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_lock_occurrence — locks the job row (waiting for a concurrent
-- confirmation / reschedule / payment to commit) and says, on the locked,
-- current row, whether it is still an eligible occurrence of p_series_id.
-- o_status: 'eligible' | 'kept' | 'gone' (deleted or moved out of the
-- series meanwhile); o_seq / o_start describe the row as it is.
-- job_series_remove_occurrence — the one place the series RPCs delete an
-- occurrence: locks and re-checks it (above), then deletes it in a
-- subtransaction: a delete refused by a foreign key keeps the job
-- (o_status 'kept'). The delete runs with detailcrm.series_rebuild = the
-- series id, so jobs_zz_series_skip does not record it as a skipped visit.
-- ---------------------------------------------------------------------------
create function public.job_series_lock_occurrence(
  p_job_id     uuid,
  p_series_id  uuid,
  p_now        timestamptz,
  out o_status text,
  out o_seq    integer,
  out o_start  timestamptz
)
language plpgsql volatile
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs j where j.id = p_job_id for update;
  if not found or v_job.series_id is distinct from p_series_id then
    o_status := 'gone';
    return;
  end if;
  o_seq := v_job.series_seq;
  o_start := v_job.scheduled_start;
  o_status := case when public.job_series_occurrence_eligible(v_job, p_now) then 'eligible' else 'kept' end;
end
$$;

create function public.job_series_remove_occurrence(
  p_job_id     uuid,
  p_series_id  uuid,
  p_now        timestamptz,
  out o_status text,
  out o_seq    integer,
  out o_start  timestamptz
)
language plpgsql volatile
set search_path = ''
as $$
begin
  select l.o_status, l.o_seq, l.o_start into o_status, o_seq, o_start
    from public.job_series_lock_occurrence(p_job_id, p_series_id, p_now) l;
  if o_status <> 'eligible' then
    return;
  end if;
  begin
    perform pg_catalog.set_config('detailcrm.series_rebuild', p_series_id::text, true);
    delete from public.jobs j where j.id = p_job_id and j.series_id = p_series_id;
    perform pg_catalog.set_config('detailcrm.series_rebuild', '', true);
    o_status := 'deleted';
  exception when foreign_key_violation or restrict_violation then
    -- (the subtransaction rollback also restores the setting)
    o_status := 'kept';
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- jobs_zz_series_skip — AFTER DELETE on jobs (definer: job_series is
-- RPC-only). An occurrence deleted outside the series RPCs is a skipped
-- visit: its number and its RULE date are recorded on the series so no
-- later generation or edit re-creates it. The rule date is the date the
-- current numbering gives its series_seq — also for a detached visit (one
-- edited on its own, often still on that date, or moved elsewhere), whose
-- number alone would be lost when a rule change renumbers the series
-- (skipped_seqs is reset then; skipped_dates survives). An occurrence the
-- rule does not number (series_seq <= seq_offset, before start_date)
-- records its own date unless it was detached.
-- ---------------------------------------------------------------------------
create function public.jobs_series_record_skip() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_s public.job_series;
  v_d date;
begin
  if coalesce(current_setting('detailcrm.series_rebuild', true), '') = old.series_id::text then
    return null;
  end if;
  select * into v_s from public.job_series js where js.id = old.series_id and js.shop_id = old.shop_id;
  if not found then
    return null;
  end if;
  if old.series_seq is not null and old.series_seq > v_s.seq_offset then
    -- (numbering is prefix-stable: until_date / max_occurrences are not
    -- applied, so a visit kept past them still finds its date)
    v_s.until_date := null;
    v_s.max_occurrences := null;
    select o.d into v_d
      from public.series_occurrence_dates(v_s, v_s.start_date,
                                          public.job_series_scan_end(v_s, old.series_seq - v_s.seq_offset), null) o
     where o.seq = old.series_seq;
  end if;
  if v_d is null and not old.series_detached and old.scheduled_start is not null then
    select (old.scheduled_start at time zone s.timezone)::date into v_d
      from public.shops s where s.id = old.shop_id;
  end if;
  update public.job_series js
     set skipped_seqs = case when old.series_seq is null or old.series_seq = any (js.skipped_seqs) then js.skipped_seqs
                             else js.skipped_seqs || old.series_seq end,
         skipped_dates = case when v_d is null or v_d = any (js.skipped_dates) then js.skipped_dates
                              else js.skipped_dates || v_d end
   where js.id = old.series_id and js.shop_id = old.shop_id;
  return null;
end
$$;

create trigger jobs_zz_series_skip after delete on public.jobs
  for each row when (old.series_id is not null) execute function public.jobs_series_record_skip();

-- Loads a series for an edit RPC: P0002 unless the caller is an active
-- member of its shop, 42501 below manager. Advisory-locked, then every job
-- of the series is row-locked (id order) and only then the series row: the
-- order a job delete takes them (the job row, then jobs_zz_series_skip
-- updates the series row), so deleting one visit while an edit, the end or
-- the removal of its series runs waits instead of deadlocking (40P01). A
-- visit deleted while this waited is gone and its skip is on the row read
-- here; a delete that comes later waits for this transaction.
create function public.job_series_for_edit(p_series_id uuid) returns public.job_series
language plpgsql volatile
set search_path = ''
as $$
declare
  v public.job_series;
begin
  select * into v from public.job_series js where js.id = p_series_id;
  if not found or not public.is_shop_member(v.shop_id) then
    raise exception 'series not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v.shop_id) then
    raise exception 'only owners, admins and managers can change recurring jobs' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('job_series:' || p_series_id::text, 0));
  perform 1 from public.jobs j
   where j.shop_id = v.shop_id and j.series_id = p_series_id
   order by j.id
     for update;
  select * into v from public.job_series js where js.id = p_series_id for update;
  if not found then
    -- removed (delete_job_series) while this call waited
    raise exception 'series not found' using errcode = 'P0002';
  end if;
  return v;
end
$$;

-- ---------------------------------------------------------------------------
-- create_job_series(shop, series, p_now) — see the header. p_series keys:
-- customer_id*, vehicle_id, location_type, service_address_line1/line2,
-- service_city, service_region, service_postal_code, service_lat/lng,
-- resource_id, freq* ('week'|'month'), interval (1..12, default 1),
-- by_weekday [0..6] (default: start_date's weekday), month_mode
-- ('day_of_month' default | 'nth_weekday'), month_day (default: start_date's
-- day), month_nth (1..5, -1 = last), month_weekday (0..6), start_date*
-- ('YYYY-MM-DD'), local_start* ('HH:MM'), duration_minutes (default: the
-- services' durations x quantity), until_date, max_occurrences (1..500),
-- template_lines* [{service_id, quantity}], assignee_member_ids, notes,
-- internal_notes, send_confirmation (booking_confirmed to the customer for
-- the first occurrence).
-- Returns {series_id, jobs_created, first_job_id, generated_through}.
-- ---------------------------------------------------------------------------
create function public.create_job_series(p_shop_id uuid, p_series jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v          public.job_series;
  v_pr       jsonb;
  v_created  integer;
  v_first    uuid;
  v_send     boolean;
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can create recurring jobs' using errcode = '42501';
  end if;
  v.shop_id := p_shop_id;
  v.location_type := 'shop';
  v."interval" := 1;
  v.by_weekday := '{}';
  v.assignee_member_ids := '{}';
  v.template_lines := null;
  v := public.job_series_apply(v, p_series, 'create');
  v := public.job_series_normalize(v);
  v_send := public.payload_bool(p_series, 'send_confirmation', 'send_confirmation');

  if v.customer_id is null then
    raise exception 'customer_id is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.customers c where c.id = v.customer_id and c.shop_id = p_shop_id) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.customers c where c.id = v.customer_id and c.archived_at is not null) then
    raise exception 'this customer is archived' using errcode = '22023';
  end if;
  if v.vehicle_id is not null and not exists (
       select 1 from public.vehicles vh
        where vh.id = v.vehicle_id and vh.shop_id = p_shop_id and vh.customer_id = v.customer_id
          and vh.archived_at is null) then
    raise exception 'the vehicle does not belong to this customer' using errcode = '22023';
  end if;
  if v.template_lines is null then
    raise exception 'template_lines is required' using errcode = '22023';
  end if;
  -- validates the services (trigger rules) before pricing them
  if exists (select 1 from jsonb_array_elements(v.template_lines) e
             where not exists (select 1 from public.services s
                               where s.id = (e ->> 'service_id')::uuid and s.shop_id = p_shop_id
                                 and s.active and s.archived_at is null)) then
    raise exception 'one or more services are not available' using errcode = '22023';
  end if;
  v_pr := public.job_series_price_lines(v, true);
  if v.duration_minutes is null then
    v.duration_minutes := (v_pr ->> 'duration_minutes')::integer;
    if coalesce(v.duration_minutes, 0) < 15 then
      raise exception 'duration_minutes is required (the services add up to less than 15 minutes)'
        using errcode = '22023';
    end if;
    if v.duration_minutes > 44640 then
      raise exception 'the services add up to more than 31 days; set duration_minutes' using errcode = '22023';
    end if;
  end if;

  insert into public.job_series (shop_id, customer_id, vehicle_id, location_type, service_address_line1,
                                 service_address_line2, service_city, service_region, service_postal_code,
                                 service_lat, service_lng, resource_id, freq, "interval", by_weekday, month_mode,
                                 month_day, month_nth, month_weekday, start_date, local_start, duration_minutes,
                                 until_date, max_occurrences, template_lines, assignee_member_ids, notes,
                                 internal_notes, created_by)
  values (p_shop_id, v.customer_id, v.vehicle_id, v.location_type, v.service_address_line1,
          v.service_address_line2, v.service_city, v.service_region, v.service_postal_code,
          v.service_lat, v.service_lng, v.resource_id, v.freq, v."interval", v.by_weekday, v.month_mode,
          v.month_day, v.month_nth, v.month_weekday, v.start_date, v.local_start, v.duration_minutes,
          v.until_date, v.max_occurrences, v.template_lines, v.assignee_member_ids, v.notes,
          v.internal_notes, auth.uid())
  returning * into v;

  v_created := public.job_series_generate(v.id, v_now, true);
  select j.id into v_first from public.jobs j
   where j.shop_id = p_shop_id and j.series_id = v.id order by j.series_seq limit 1;
  select * into v from public.job_series js where js.id = v.id;

  if v_send and v_first is not null then
    begin
      if public.integration_claim_event(p_shop_id, 'booking_confirmed', p_job_id => v_first) then
        perform public.integration_send_customer_template(p_shop_id, v.customer_id, 'booking_confirmed', v_first);
      end if;
    exception when others then
      raise warning 'series confirmation failed for job %: % (%)', v_first, sqlerrm, sqlstate;
    end;
  end if;

  return jsonb_build_object(
    'series_id', v.id,
    'jobs_created', v_created,
    'first_job_id', v_first,
    'generated_through', v.generated_through);
end
$$;

-- ---------------------------------------------------------------------------
-- job_series_preview(shop, series, count) — the first p_count (1..100)
-- occurrences the series would get, exactly as create_job_series generates
-- them (same rule, time-zone conversion and until / max limits); no writes.
-- duration_minutes defaults as in create_job_series (template_lines needed
-- then); customer_id is optional.
-- ---------------------------------------------------------------------------
create function public.job_series_preview(p_shop_id uuid, p_series jsonb, p_count integer default 10)
returns table (seq integer, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v      public.job_series;
  v_tz   text;
  v_pr   jsonb;
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can plan recurring jobs' using errcode = '42501';
  end if;
  if p_count is null or p_count not between 1 and 100 then
    raise exception 'p_count must be between 1 and 100' using errcode = '22023';
  end if;
  v.shop_id := p_shop_id;
  v.location_type := 'shop';
  v."interval" := 1;
  v.by_weekday := '{}';
  v.assignee_member_ids := '{}';
  v.seq_offset := 0;
  v.template_lines := null;
  v := public.job_series_apply(v, p_series, 'create');
  v := public.job_series_normalize(v);
  if v.customer_id is not null
     and not exists (select 1 from public.customers c where c.id = v.customer_id and c.shop_id = p_shop_id) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if v.duration_minutes is null then
    if v.template_lines is null then
      raise exception 'duration_minutes or template_lines is required' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(v.template_lines) e
               where not exists (select 1 from public.services s
                                 where s.id = (e ->> 'service_id')::uuid and s.shop_id = p_shop_id
                                   and s.active and s.archived_at is null)) then
      raise exception 'one or more services are not available' using errcode = '22023';
    end if;
    -- (durations do not depend on the customer: without one no membership applies)
    v_pr := public.job_series_price_lines(v, true);
    v.duration_minutes := (v_pr ->> 'duration_minutes')::integer;
    if coalesce(v.duration_minutes, 0) < 15 then
      raise exception 'duration_minutes is required (the services add up to less than 15 minutes)'
        using errcode = '22023';
    end if;
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  return query
    select o.seq,
           (o.d + v.local_start) at time zone v_tz,
           ((o.d + v.local_start) at time zone v_tz) + make_interval(mins => v.duration_minutes)
      from public.series_occurrence_dates(v, v.start_date,
                                          coalesce(v.until_date, public.job_series_scan_end(v, p_count)), p_count) o
     order by o.d;
end
$$;

comment on function public.job_series_preview(uuid, jsonb, integer) is
  'First occurrences of a planned series (no writes): same rule and time-zone handling as create_job_series.';

-- ---------------------------------------------------------------------------
-- update_job_series(series, patch, from_job, p_now) — "this and following".
-- p_patch keys: vehicle_id, location_type, service address fields,
-- service_lat/lng, resource_id, local_start, duration_minutes,
-- template_lines, assignee_member_ids, notes, internal_notes, freq,
-- interval, by_weekday, month_mode, month_day, month_nth, month_weekday,
-- until_date, max_occurrences. p_from_job_id: an occurrence of this series
-- (null = from the earliest occurrence that has not started yet).
-- The edit point is a date (see the header): the occurrence's date in the
-- current numbering (its original rule date, also when it was moved), or
-- its own date when the current rule does not number it; without
-- p_from_job_id the earliest of the first upcoming occurrence's own and
-- rule dates — for a rule change, the current rule's first date on or
-- after that (or an attached upcoming occurrence's held date, if earlier),
-- so an every-N-weeks / months cadence keeps its phase when that visit was
-- moved into an off-period. Occurrences before that date are never touched.
--   * Without a rule change every eligible occurrence from the edit point
--     on is updated IN PLACE on its own date with the new defaults (new
--     local_start, duration, services, assignees ...); occurrences past a
--     lowered until_date / max_occurrences are removed; a later until_date
--     / higher max_occurrences generates the missing ones.
--   * With a rule change (freq, interval, weekdays, month fields) the rule
--     is re-anchored at the edit point — fields the patch leaves to their
--     default (by_weekday, month_day) take it from that date. An eligible
--     occurrence on a date the new rule produces stays (in place, with the
--     new defaults), the other eligible ones are removed, and the kept and
--     staying occurrences are renumbered with the new rule's dates in date
--     order after the visits before the edit point (held_dates keeps the
--     place of a kept occurrence the new rule does not produce), so a kept
--     occurrence never shares its date with a new one, series_seq stays the
--     visit's ordinal and max_occurrences counts every visit.
-- Skipped visits (jobs deleted outside these RPCs) are not re-created.
-- template_lines without duration_minutes recomputes the duration from the
-- services; line items are re-priced only when the services or the vehicle
-- change. Returns {updated: true, deleted, created, changed, kept}:
-- eligible occurrences removed, occurrences generated, occurrences updated
-- in place, and occurrences from the edit point on left as they were.
-- ---------------------------------------------------------------------------
create function public.update_job_series(
  p_series_id    uuid,
  p_patch        jsonb,
  p_from_job_id  uuid default null,
  p_now          timestamptz default now()
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now        timestamptz := public.effective_now(p_now);
  v_old        public.job_series;
  v_raw        public.job_series;
  v            public.job_series;
  v_num        public.job_series;
  v_tz         text;
  v_today      date;
  v_job        public.jobs;
  v_job_date   date;
  v_rule_date  date;
  v_from_date  date;
  v_rule_chg   boolean;
  v_reprice    boolean;
  v_reassign   boolean;
  v_pr         jsonb;
  v_occ        record;
  v_lk         record;
  v_region     uuid[] := '{}';
  v_elig       uuid[] := '{}';
  v_stay       uuid[] := '{}';
  v_stay_days  date[] := '{}';
  v_kept_days  date[] := '{}';
  v_rule_days  date[];
  v_ren_ids    uuid[];
  v_ren_days   date[];
  v_ren_rk     integer[];
  v_ren_seqs   integer[];
  v_status     text;
  v_last       date;
  v_bump       integer;
  v_deleted    integer := 0;
  v_kept       integer := 0;
  v_changed    integer := 0;
  v_created    integer := 0;
begin
  v_old := public.job_series_for_edit(p_series_id);
  if not v_old.active then
    raise exception 'this series has ended' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_old.shop_id;
  v_today := (v_now at time zone v_tz)::date;

  -- the edit point (a date)
  if p_from_job_id is not null then
    select * into v_job from public.jobs j where j.id = p_from_job_id and j.shop_id = v_old.shop_id;
    if not found or v_job.series_id is distinct from v_old.id then
      raise exception 'that job is not an occurrence of this series' using errcode = '22023';
    end if;
  else
    select * into v_job from public.jobs j
     where j.shop_id = v_old.shop_id and j.series_id = v_old.id and j.scheduled_start > v_now
     order by j.scheduled_start, j.series_seq limit 1;
  end if;
  if v_job.id is not null then
    v_job_date := (v_job.scheduled_start at time zone v_tz)::date;
    if v_job.series_seq > v_old.seq_offset then
      select o.d into v_rule_date
        from public.series_occurrence_dates(v_old, v_old.start_date,
                                            public.job_series_scan_end(v_old, v_job.series_seq - v_old.seq_offset),
                                            null) o
       where o.seq = v_job.series_seq;
    end if;
    v_from_date := case when p_from_job_id is null then least(v_rule_date, v_job_date)
                        else coalesce(v_rule_date, v_job_date) end;
  end if;

  v_raw := public.job_series_apply(v_old, p_patch, 'patch');
  v := public.job_series_normalize(v_raw);
  v_rule_chg := (v.freq, v."interval", v.by_weekday, v.month_mode, v.month_day, v.month_nth, v.month_weekday)
                is distinct from
                (v_old.freq, v_old."interval", v_old.by_weekday, v_old.month_mode, v_old.month_day, v_old.month_nth,
                 v_old.month_weekday);
  if v_rule_chg and p_from_job_id is null and v_from_date is not null then
    -- "all future visits": the rule is re-anchored at the current rule's
    -- first date on or after that point, not at a visit moved into an
    -- off-week (off-month) of an every-N cadence, which would shift the new
    -- rule by a period. Held dates are not rule dates, but an attached
    -- upcoming occurrence on one (kept by an earlier rule change, eligible
    -- again) keeps the point there, so no eligible occurrence is left out:
    -- the attached ones are on rule or held dates. With neither before
    -- until_date the point stays.
    v_num := v_old;
    v_num.held_dates := '{}';
    v_num.seq_offset := 0;
    v_num.max_occurrences := null;
    v_from_date := coalesce(
      least(
        (select o.d from public.series_occurrence_dates(
                           v_num, v_from_date,
                           v_from_date + case when v_old.freq = 'week' then 7 * (v_old."interval" + 1) else 36600 end,
                           1) o),
        (select min((j.scheduled_start at time zone v_tz)::date) from public.jobs j
          where j.shop_id = v_old.shop_id and j.series_id = v_old.id and j.scheduled_start > v_now
            and not j.series_detached and (j.scheduled_start at time zone v_tz)::date >= v_from_date)),
      v_from_date);
  end if;
  v_from_date := coalesce(v_from_date, greatest(v_old.start_date, v_today + 1));
  if v_rule_chg then
    -- re-anchor the rule at the edit point and fill the rule's defaults
    -- (weekday / day of the month) from that date, not the original start
    v := v_raw;
    v.start_date := v_from_date;
    if v.until_date is not null and v.until_date < v.start_date then
      raise exception 'until_date is before the edited occurrence; end the series instead' using errcode = '22023';
    end if;
    v := public.job_series_normalize(v);
  end if;
  if v.vehicle_id is not null and v.vehicle_id is distinct from v_old.vehicle_id and not exists (
       select 1 from public.vehicles vh
        where vh.id = v.vehicle_id and vh.shop_id = v.shop_id and vh.customer_id = v.customer_id
          and vh.archived_at is null) then
    raise exception 'the vehicle does not belong to this customer' using errcode = '22023';
  end if;
  if v.template_lines is distinct from v_old.template_lines
     and exists (select 1 from jsonb_array_elements(v.template_lines) e
                 where not exists (select 1 from public.services s
                                   where s.id = (e ->> 'service_id')::uuid and s.shop_id = v.shop_id
                                     and s.active and s.archived_at is null)) then
    raise exception 'one or more services are not available' using errcode = '22023';
  end if;
  v_pr := public.job_series_price_lines(v, true);
  if p_patch ? 'template_lines' and not (p_patch ? 'duration_minutes') then
    v.duration_minutes := (v_pr ->> 'duration_minutes')::integer;
    if coalesce(v.duration_minutes, 0) < 15 or v.duration_minutes > 44640 then
      raise exception 'duration_minutes is required (the services'' durations do not give a valid length)'
        using errcode = '22023';
    end if;
  end if;
  if v.duration_minutes is null then
    raise exception 'duration_minutes is required' using errcode = '22023';
  end if;
  v_reprice := v.template_lines is distinct from v_old.template_lines or v.vehicle_id is distinct from v_old.vehicle_id;
  v_reassign := v.assignee_member_ids is distinct from v_old.assignee_member_ids;

  -- every occurrence from the edit point's date on, locked and checked on
  -- the current row (job_series_lock_occurrence), in date order
  for v_occ in
    select j.id from public.jobs j
     where j.shop_id = v_old.shop_id and j.series_id = v_old.id and j.scheduled_start is not null
       and (j.scheduled_start at time zone v_tz)::date >= v_from_date
     order by j.scheduled_start, j.series_seq
  loop
    select * into v_lk from public.job_series_lock_occurrence(v_occ.id, v_old.id, v_now);
    if v_lk.o_status = 'gone' then
      continue;
    end if;
    v_region := v_region || v_occ.id;
    if v_lk.o_status = 'eligible' then
      v_elig := v_elig || v_occ.id;
    else
      v_kept := v_kept + 1;
      v_kept_days := v_kept_days || (v_lk.o_start at time zone v_tz)::date;
    end if;
  end loop;
  select max((j.scheduled_start at time zone v_tz)::date) into v_last from public.jobs j where j.id = any (v_region);
  if v_rule_chg and v_last is not null then
    -- the new rule's own dates (within until_date) up to the last one touched
    v_num := v;
    v_num.held_dates := '{}';
    v_num.seq_offset := 0;
    v_num.max_occurrences := null;
    v_rule_days := array(select o.d from public.series_occurrence_dates(v_num, v_from_date, v_last, null) o);
  end if;

  -- eligible occurrences: stay on their date (in place) or go
  for v_occ in
    select j.id, j.series_seq as seq, (j.scheduled_start at time zone v_tz)::date as d
      from public.jobs j join unnest(v_elig) as e(id) on e.id = j.id
     order by j.scheduled_start, j.series_seq
  loop
    if (not v_rule_chg
        and (v.until_date is null or v_occ.d <= v.until_date)
        and (v.max_occurrences is null or v_occ.seq <= v.max_occurrences))
       or (v_rule_chg
           and v_occ.d = any (v_rule_days)
           and v_occ.d <> all (v_kept_days)       -- a kept occurrence holds that date
           and v_occ.d <> all (v_stay_days)) then  -- one occurrence per rule date
      v_stay := v_stay || v_occ.id;
      v_stay_days := v_stay_days || v_occ.d;
    else
      select r.o_status into v_status from public.job_series_remove_occurrence(v_occ.id, v_old.id, v_now) r;
      if v_status = 'deleted' then
        v_deleted := v_deleted + 1;
      elsif v_status = 'kept' then
        v_kept := v_kept + 1;
      end if;
    end if;
  end loop;

  if v_rule_chg then
    -- renumber from the edit point: the visits before it keep their numbers
    -- (seq_offset = the last number used before it, by the old numbering or
    -- by a job); every occurrence left from there on is numbered in date
    -- order together with the new rule's dates, a kept one off the new rule
    -- holding its date (held_dates)
    select greatest(
             case when v_from_date >= v_old.start_date then v_old.seq_offset else 0 end,
             coalesce((select max(o.seq) from public.series_occurrence_dates(v_old, v_old.start_date, v_from_date - 1, null) o), 0),
             coalesce((select max(j.series_seq) from public.jobs j
                        where j.shop_id = v_old.shop_id and j.series_id = v_old.id
                          and not (j.id = any (v_region) and j.scheduled_start is not null
                                   and (j.scheduled_start at time zone v_tz)::date >= v_from_date)), 0))
      into v.seq_offset;
    v.skipped_seqs := '{}';
    v.skipped_dates := array(select x from unnest(v_old.skipped_dates) as x where x >= v.start_date order by x);
    -- the occurrences renumbered: every one left from the edit point on,
    -- ranked within its date
    select coalesce(array_agg(x.id order by x.d, x.rk), '{}'), coalesce(array_agg(x.d order by x.d, x.rk), '{}'),
           coalesce(array_agg(x.rk order by x.d, x.rk), '{}')
      into v_ren_ids, v_ren_days, v_ren_rk
      from (select j.id, (j.scheduled_start at time zone v_tz)::date as d,
                   row_number() over (partition by (j.scheduled_start at time zone v_tz)::date
                                      order by j.scheduled_start, j.series_seq)::integer as rk
              from public.jobs j
             where j.id = any (v_region) and j.series_id = v_old.id and j.scheduled_start is not null
               and (j.scheduled_start at time zone v_tz)::date >= v_from_date) x;
    v.held_dates := array(
      select x.d from (
        select t.d, count(*) - case when t.d = any (coalesce(v_rule_days, '{}')) then 1 else 0 end as n
          from unnest(v_ren_days) as t(d)
         group by t.d) x
      cross join lateral generate_series(1, x.n::integer)
     order by x.d);
    if cardinality(v_ren_ids) > 0 then
      -- (numbers are assigned without until_date / max_occurrences:
      -- numbering is prefix-stable, so an occurrence kept past them keeps a
      -- number no later generation gives to another date)
      v_num := v;
      v_num.until_date := null;
      v_num.max_occurrences := null;
      select array_agg(s.seq order by t.o) into v_ren_seqs
        from unnest(v_ren_ids, v_ren_days, v_ren_rk) with ordinality as t(id, d, rk, o)
        left join (select o.seq, o.d, row_number() over (partition by o.d order by o.seq)::integer as rk
                     from public.series_occurrence_dates(v_num, v_from_date, v_last, null) o) s
               on s.d = t.d and s.rk = t.rk;
      if array_position(v_ren_seqs, null) is not null then
        raise exception 'job series %: renumbering failed', v_old.id using errcode = 'XX000';
      end if;
      -- two steps: the new numbers are unique, but one may still be held by
      -- another occurrence being renumbered
      select greatest(coalesce(max(j.series_seq), 0), (select max(x) from unnest(v_ren_seqs) as x)) + 1
        into v_bump
        from public.jobs j where j.series_id = v_old.id;
      update public.jobs j set series_seq = j.series_seq + v_bump
        from unnest(v_ren_ids, v_ren_seqs) as t(id, seq) where j.id = t.id and j.series_seq <> t.seq;
      update public.jobs j set series_seq = t.seq
        from unnest(v_ren_ids, v_ren_seqs) as t(id, seq) where j.id = t.id and j.series_seq <> t.seq;
      -- an occurrence staying on a date past max_occurrences goes
      for v_occ in
        select t.id from unnest(v_ren_ids, v_ren_seqs) as t(id, seq)
         where t.id = any (v_stay) and v.max_occurrences is not null and t.seq > v.max_occurrences
         order by t.seq
      loop
        v_stay := array_remove(v_stay, v_occ.id);
        select r.o_status into v_status from public.job_series_remove_occurrence(v_occ.id, v_old.id, v_now) r;
        if v_status = 'deleted' then
          v_deleted := v_deleted + 1;
        elsif v_status = 'kept' then
          v_kept := v_kept + 1;
        end if;
      end loop;
    end if;
  end if;

  update public.job_series js
     set vehicle_id = v.vehicle_id, location_type = v.location_type,
         service_address_line1 = v.service_address_line1, service_address_line2 = v.service_address_line2,
         service_city = v.service_city, service_region = v.service_region,
         service_postal_code = v.service_postal_code, service_lat = v.service_lat, service_lng = v.service_lng,
         resource_id = v.resource_id, freq = v.freq, "interval" = v."interval", by_weekday = v.by_weekday,
         month_mode = v.month_mode, month_day = v.month_day, month_nth = v.month_nth,
         month_weekday = v.month_weekday, start_date = v.start_date, seq_offset = v.seq_offset,
         local_start = v.local_start, duration_minutes = v.duration_minutes, until_date = v.until_date,
         max_occurrences = v.max_occurrences, template_lines = v.template_lines,
         assignee_member_ids = v.assignee_member_ids, notes = v.notes, internal_notes = v.internal_notes,
         skipped_seqs = v.skipped_seqs, skipped_dates = v.skipped_dates, held_dates = v.held_dates,
         -- generation resumes at the edit point (existing numbers are skipped)
         generated_through = least(coalesce(js.generated_through, v_from_date - 1), v_from_date - 1)
   where js.id = v.id
  returning * into v;

  -- the staying occurrences take the new defaults in place, in date order
  -- (each re-priced at its own start: membership uses per period). Staff
  -- pushes (job rescheduled / assigned, comms 0082) announce only the first
  -- occurrence changed, as for occurrences generated in bulk.
  perform public.job_series_lock_memberships(v);
  for v_occ in
    select j.id, (j.scheduled_start at time zone v_tz)::date as d
      from public.jobs j join unnest(v_stay) as e(id) on e.id = j.id
     order by j.scheduled_start, j.series_seq
  loop
    perform pg_catalog.set_config('detailcrm.series_bulk_edit', case when v_changed = 0 then '' else v.id::text end, true);
    if public.job_series_update_occurrence(v, v_occ.id, v_occ.d, v_tz, v_now, v_reprice, v_reassign,
                                              v_old.internal_notes) then
      v_changed := v_changed + 1;
    else
      v_kept := v_kept + 1;
    end if;
  end loop;
  perform pg_catalog.set_config('detailcrm.series_bulk_edit', '', true);
  v_created := public.job_series_generate(v.id, v_now, true);
  return jsonb_build_object('updated', true, 'deleted', v_deleted, 'created', v_created, 'changed', v_changed,
                            'kept', v_kept);
end
$$;

-- ---------------------------------------------------------------------------
-- end_job_series(series, after_date, p_now) — no occurrences after
-- p_after_date (shop-local date). It only ever shortens a series: the end
-- becomes the earlier of p_after_date and the current until_date (a later
-- date never moves until_date out, which would generate more visits —
-- update_job_series with until_date extends a series). Eligible
-- occurrences after the end are deleted, the others kept (and counted).
-- The series stops (active false) when that end is today or earlier.
-- Returns {deleted, kept}.
-- ---------------------------------------------------------------------------
create function public.end_job_series(p_series_id uuid, p_after_date date, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v          public.job_series;
  v_tz       text;
  v_today    date;
  v_end      date;
  v_cand     uuid;
  v_status   text;
  v_deleted  integer := 0;
  v_kept     integer := 0;
  v_stop     boolean;
begin
  v := public.job_series_for_edit(p_series_id);
  if p_after_date is null then
    raise exception 'p_after_date is required' using errcode = '22023';
  end if;
  if not v.active then
    raise exception 'this series has ended' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v.shop_id;
  v_today := (v_now at time zone v_tz)::date;
  v_end := least(coalesce(v.until_date, p_after_date), p_after_date);
  v_stop := v_end <= v_today;

  update public.job_series js
     set until_date = v_end,
         active = not v_stop,
         ended_at = case when v_stop then now() else js.ended_at end
   where js.id = v.id;

  for v_cand in
    select j.id from public.jobs j
     where j.shop_id = v.shop_id and j.series_id = v.id
       and (j.scheduled_start at time zone v_tz)::date > v_end
     order by j.scheduled_start, j.series_seq
  loop
    select r.o_status into v_status from public.job_series_remove_occurrence(v_cand, v.id, v_now) r;
    if v_status = 'deleted' then
      v_deleted := v_deleted + 1;
    elsif v_status = 'kept' then
      v_kept := v_kept + 1;
    end if;
  end loop;
  return jsonb_build_object('deleted', v_deleted, 'kept', v_kept);
end
$$;

-- ---------------------------------------------------------------------------
-- delete_job_series(series, p_now) — removes the series: eligible
-- occurrences are deleted, the others stay as ordinary jobs (series_id
-- cleared). Frees the customer for deletion. Returns {deleted, kept}.
-- ---------------------------------------------------------------------------
create function public.delete_job_series(p_series_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v          public.job_series;
  v_cand     uuid;
  v_status   text;
  v_deleted  integer := 0;
  v_kept     integer := 0;
begin
  v := public.job_series_for_edit(p_series_id);
  for v_cand in
    select j.id from public.jobs j where j.shop_id = v.shop_id and j.series_id = v.id order by j.series_seq
  loop
    select r.o_status into v_status from public.job_series_remove_occurrence(v_cand, v.id, v_now) r;
    if v_status = 'deleted' then
      v_deleted := v_deleted + 1;
    elsif v_status = 'kept' then
      v_kept := v_kept + 1;
    end if;
  end loop;
  delete from public.job_series js where js.id = v.id;
  return jsonb_build_object('deleted', v_deleted, 'kept', v_kept);
end
$$;

-- ---------------------------------------------------------------------------
-- generate_series_jobs(p_now) — service_role (daily cron): extends every
-- active series to its horizon. A series that cannot be generated (e.g. its
-- vehicle moved to another customer) is skipped with a WARNING and never
-- blocks the others. Returns the number of jobs created.
-- ---------------------------------------------------------------------------
create function public.generate_series_jobs(p_now timestamptz default now())
returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := public.effective_now(p_now);
  v_id     uuid;
  v_total  integer := 0;
begin
  for v_id in select js.id from public.job_series js where js.active order by js.created_at, js.id loop
    begin
      v_total := v_total + public.job_series_generate(v_id, v_now, false);
    exception when others then
      raise warning 'job series %: generation failed: % (%)', v_id, sqlerrm, sqlstate;
    end;
  end loop;
  return v_total;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.jobs_series_guard(), public.job_series_validate(),
  public.jobs_series_record_skip(), public.jobs_series_detach_on_child_edit()
  from public, anon, authenticated;

revoke execute on function
  public.series_occurrence_dates(public.job_series, date, date, integer),
  public.job_series_apply(public.job_series, jsonb, text),
  public.job_series_normalize(public.job_series),
  public.job_series_scan_end(public.job_series, integer),
  public.job_series_price_lines(public.job_series, boolean, timestamptz),
  public.job_series_lock_memberships(public.job_series),
  public.job_series_generate(uuid, timestamptz, boolean),
  public.job_series_insert_occurrence(public.job_series, integer, date, jsonb, text),
  public.job_series_write_lines(public.job_series, uuid, jsonb),
  public.job_series_write_assignees(public.job_series, uuid),
  public.job_series_update_occurrence(public.job_series, uuid, date, text, timestamptz, boolean, boolean, text),
  public.job_series_occurrence_eligible(public.jobs, timestamptz),
  public.job_series_lock_occurrence(uuid, uuid, timestamptz),
  public.job_series_remove_occurrence(uuid, uuid, timestamptz),
  public.job_series_for_edit(uuid)
from public, anon, authenticated;
grant execute on function
  public.series_occurrence_dates(public.job_series, date, date, integer),
  public.job_series_apply(public.job_series, jsonb, text),
  public.job_series_normalize(public.job_series),
  public.job_series_scan_end(public.job_series, integer),
  public.job_series_price_lines(public.job_series, boolean, timestamptz),
  public.job_series_lock_memberships(public.job_series),
  public.job_series_generate(uuid, timestamptz, boolean),
  public.job_series_insert_occurrence(public.job_series, integer, date, jsonb, text),
  public.job_series_write_lines(public.job_series, uuid, jsonb),
  public.job_series_write_assignees(public.job_series, uuid),
  public.job_series_update_occurrence(public.job_series, uuid, date, text, timestamptz, boolean, boolean, text),
  public.job_series_occurrence_eligible(public.jobs, timestamptz),
  public.job_series_lock_occurrence(uuid, uuid, timestamptz),
  public.job_series_remove_occurrence(uuid, uuid, timestamptz),
  public.job_series_for_edit(uuid)
to service_role;

revoke execute on function
  public.create_job_series(uuid, jsonb, timestamptz),
  public.job_series_preview(uuid, jsonb, integer),
  public.update_job_series(uuid, jsonb, uuid, timestamptz),
  public.end_job_series(uuid, date, timestamptz),
  public.delete_job_series(uuid, timestamptz)
from public, anon;
grant execute on function
  public.create_job_series(uuid, jsonb, timestamptz),
  public.job_series_preview(uuid, jsonb, integer),
  public.update_job_series(uuid, jsonb, uuid, timestamptz),
  public.end_job_series(uuid, date, timestamptz),
  public.delete_job_series(uuid, timestamptz)
to authenticated, service_role;

revoke execute on function public.generate_series_jobs(timestamptz) from public, anon, authenticated;
grant execute on function public.generate_series_jobs(timestamptz) to service_role;
