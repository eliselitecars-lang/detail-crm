-- ============================================================================
-- 0108 — A membership covers only visits it will be paid for (money 0069).
--
-- A visit was priced against the billing period that contains its start
-- even when the membership had not been paid for that period — and was not
-- going to be: price_services_core, the line trigger and the job trigger
-- only asked for memberships.status = 'active', never whether the member
-- had already cancelled at period end, and nothing repriced the visits
-- booked ahead when the membership ended (lines of an ended membership are
-- "history", 0069). A member could pay one period, book an included
-- service in each of the next periods (online up to max_days_ahead; repeat
-- series up to 90 days), cancel from the portal, and keep every $0 visit —
-- copied as $0 onto the invoice. A weekly plan gave about eight free
-- visits for one week's fee.
--
-- Coverage — membership_grants_at(status, cancel_at_period_end,
-- current_period_end, at): an ACTIVE membership covers a visit at `at`
-- unless it is ending (cancel_at_period_end) and `at` is on or after
-- current_period_end. A renewing membership still covers visits in later
-- periods (one included use per period, as before), because it will be
-- billed for them; if it stops renewing, those visits are repriced (below).
--   * price_services_core (0069 body): memberships (included services and
--     the member discount) apply only when they cover p_starts_at (null =
--     now).
--   * job_line_items_61_membership_use (0069 body): a line naming a
--     membership that does not cover the job's start fails ('the membership
--     ends before this visit', 22023); a free line is auto-assigned only to
--     a covering membership.
--   * jobs_zz_money_membership_uses (0069 body): moving a job with a line of
--     an ending membership past its end (or reopening such a job) fails
--     (22023) — take the membership off the line or pick an earlier date.
--   * memberships_zz_money_reprice (new, every context): when a membership
--     starts ending (cancel_at_period_end set while active, or its period
--     end moves while ending) or is cancelled, every line of it on an open
--     job (requested / scheduled / confirmed) that starts on or after the
--     paid period's end (current_period_end; now() when the membership was
--     never billed) loses the membership and is charged the catalog price
--     for the job's vehicle (service_price_for), and the job total follows.
--     Visits inside the paid period keep their included price. Not
--     repriced, and listed in the notification instead: lines of a job
--     already on a live invoice (0097: the billed price is frozen; void the
--     invoice to reprice) and lines whose service has no catalog price.
--     Managers get one 'general' notification per membership naming the
--     jobs. Re-activating the membership later does not give the included
--     price back automatically (staff re-add it on the job).
-- The member discount of a job (jobs.discount_kind / discount_value, copied
-- from the pricing at booking) is not repriced.
-- ============================================================================

create function public.membership_grants_at(
  p_status                public.membership_status,
  p_cancel_at_period_end  boolean,
  p_current_period_end    timestamptz,
  p_at                    timestamptz
) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_status = 'active'
         and (not coalesce(p_cancel_at_period_end, false) or p_current_period_end is null
              or coalesce(p_at, now()) < p_current_period_end)
$$;

comment on function public.membership_grants_at(public.membership_status, boolean, timestamptz, timestamptz) is
  'Internal (0108): whether a membership in this state covers a visit at p_at — active, and not ending before it (cancel_at_period_end with p_at on or after current_period_end).';
revoke execute on function public.membership_grants_at(public.membership_status, boolean, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.membership_grants_at(public.membership_status, boolean, timestamptz, timestamptz)
  to service_role;

create or replace function public.price_services_core(
  p_shop_id              uuid,
  p_customer_id          uuid,
  p_vehicle_category_id  uuid,
  p_service_ids          uuid[],
  p_vehicle_id           uuid default null,
  p_apply_membership     boolean default true,
  p_starts_at            timestamptz default null
) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_ids       uuid[];
  v_found     integer;
  v_members   jsonb := '[]'::jsonb;
  v_disc      integer := 0;
  v_lines     jsonb := '[]'::jsonb;
  v_priced    boolean := true;
  v_duration  integer := 0;
  v_tax       integer;
  v_totals    public.document_totals;
  v_apply     boolean := coalesce(p_apply_membership, false) and p_customer_id is not null;
  v_left      jsonb := '{}'::jsonb;
  r           record;
  m           record;
  v_mid       uuid;
  v_plan      text;
  v_rem       integer;
  v_used_up   boolean;
begin
  v_ids := array(select x.id
                   from (select u.id, min(u.o) as first_o
                           from unnest(p_service_ids) with ordinality as u(id, o)
                          where u.id is not null
                          group by u.id) x
                  order by x.first_o);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 100 then
    raise exception 'too many services (max 100)' using errcode = '22023';
  end if;
  select count(*) into v_found
    from public.services s
   where s.id = any (v_ids) and s.shop_id = p_shop_id and s.active and s.archived_at is null;
  if v_found <> cardinality(v_ids) then
    raise exception 'one or more services are not available' using errcode = '22023';
  end if;
  select s.tax_rate_bps into v_tax from public.shops s where s.id = p_shop_id;

  if v_apply then
    select coalesce(jsonb_agg(jsonb_build_object(
                      'membership_id', mm.id,
                      'plan_id', p.id,
                      'plan_name', p.name,
                      'discount_bps', p.discount_bps,
                      'vehicle_id', mm.vehicle_id) order by p.name, mm.id), '[]'::jsonb),
           coalesce(max(p.discount_bps), 0)
      into v_members, v_disc
      from public.memberships mm
      join public.membership_plans p on p.id = mm.plan_id and p.shop_id = mm.shop_id
     where mm.shop_id = p_shop_id and mm.customer_id = p_customer_id
       and public.membership_grants_at(mm.status, mm.cancel_at_period_end, mm.current_period_end,
                                       coalesce(p_starts_at, now()))
       and (mm.vehicle_id is null or mm.vehicle_id = p_vehicle_id);
  end if;

  for r in
    select u.o, s.id, s.name, s.kind, s.taxable, pr.price_cents, pr.duration_minutes
      from unnest(v_ids) with ordinality as u(id, o)
      join public.services s on s.id = u.id and s.shop_id = p_shop_id
      cross join lateral public.service_price_for(s.id, p_vehicle_category_id) pr
     order by u.o
  loop
    v_mid := null; v_plan := null; v_rem := null; v_used_up := false;
    if v_apply then
      for m in
        select mm.id, p.name, p.included_uses_per_period as lim
          from public.memberships mm
          join public.membership_plans p on p.id = mm.plan_id and p.shop_id = mm.shop_id
         where mm.shop_id = p_shop_id and mm.customer_id = p_customer_id
       and public.membership_grants_at(mm.status, mm.cancel_at_period_end, mm.current_period_end,
                                       coalesce(p_starts_at, now()))
           and (mm.vehicle_id is null or mm.vehicle_id = p_vehicle_id)
           and r.id = any (p.included_service_ids)
         order by p.name, p.id, mm.id
      loop
        if m.lim is null then
          v_mid := m.id; v_plan := m.name; v_rem := null;
          exit;
        end if;
        if not (v_left ? m.id::text) then
          v_left := v_left || jsonb_build_object(m.id::text,
                                                 greatest(m.lim - public.membership_uses_in_period(m.id, coalesce(p_starts_at, now())), 0));
        end if;
        if (v_left ->> m.id::text)::integer > 0 then
          v_mid := m.id; v_plan := m.name;
          v_rem := (v_left ->> m.id::text)::integer - 1;
          v_left := jsonb_set(v_left, array[m.id::text], to_jsonb(v_rem));
          exit;
        end if;
        v_used_up := true;
      end loop;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'service_id', r.id,
      'name', r.name,
      'kind', r.kind,
      'taxable', r.taxable,
      'duration_minutes', r.duration_minutes,
      'catalog_price_cents', r.price_cents,
      'unit_price_cents', case when v_mid is not null then 0 else r.price_cents end,
      'membership_included', v_mid is not null,
      'membership_id', v_mid,
      'uses_remaining', case when v_mid is not null then v_rem when v_used_up then 0 end,
      'note', case when v_mid is not null then 'Included with your ' || v_plan || ' membership'
                   when v_used_up then 'Membership visits used for this period' end));
    v_priced := v_priced and (r.price_cents is not null or v_mid is not null);
    v_duration := v_duration + coalesce(r.duration_minutes, 0);
  end loop;

  if v_priced then
    v_totals := public.compute_document_totals(
                  (select jsonb_agg(jsonb_build_object('quantity', 1,
                                                       'unit_price_cents', (e ->> 'unit_price_cents')::bigint,
                                                       'taxable', (e ->> 'taxable')::boolean))
                     from jsonb_array_elements(v_lines) e),
                  case when v_disc > 0 then 'percent' else 'none' end::public.discount_kind,
                  v_disc, v_tax);
  end if;

  return jsonb_build_object(
    'vehicle_category_id', p_vehicle_category_id,
    'tax_rate_bps', v_tax,
    'duration_minutes', v_duration,
    'priced', v_priced,
    'lines', v_lines,
    'memberships', v_members,
    'suggested_discount_kind', case when v_disc > 0 then 'percent' else 'none' end,
    'suggested_discount_value', v_disc,
    'totals', case when v_priced then jsonb_build_object(
                'subtotal_cents', v_totals.subtotal_cents,
                'discount_cents', v_totals.discount_cents,
                'tax_cents', v_totals.tax_cents,
                'total_cents', v_totals.total_cents) end);
end
$$;

create or replace function public.job_line_items_money_membership_use() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_at   timestamptz;
  v_veh  uuid;
  r      record;
begin
  select * into v_job from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
  if not found then
    return new;   -- the composite FK rejects the line
  end if;
  v_at := coalesce(v_job.scheduled_start, v_job.created_at, now());
  v_veh := coalesce(new.vehicle_id, v_job.vehicle_id);

  if new.membership_id is not null then
    if tg_op = 'UPDATE' and new.membership_id is not distinct from old.membership_id
       and new.service_id is not distinct from old.service_id and new.vehicle_id is not distinct from old.vehicle_id then
      return new;
    end if;
    -- Deleting a service or a vehicle clears the line's link (ON DELETE SET
    -- NULL, issued by the FK's own trigger, so pg_trigger_depth() > 1): the
    -- line keeps its name / price snapshot and the membership use it
    -- recorded. Only a nested write that clears links (never a client's own
    -- UPDATE, which runs at depth 1) skips the checks.
    if tg_op = 'UPDATE' and new.membership_id is not distinct from old.membership_id
       and pg_catalog.pg_trigger_depth() > 1
       and (new.service_id is null or new.service_id is not distinct from old.service_id)
       and (new.vehicle_id is null or new.vehicle_id is not distinct from old.vehicle_id) then
      return new;
    end if;
    select m.id, m.status, m.customer_id, m.vehicle_id, p.included_service_ids, p.included_uses_per_period,
           m.cancel_at_period_end, m.current_period_end
      into r
      from public.memberships m
      join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
     where m.id = new.membership_id and m.shop_id = new.shop_id
       for no key update of m;
    if not found then
      return new;   -- another shop's membership: the composite FK rejects it
    end if;
    -- A line of a membership that has ended is history: editing its service
    -- or vehicle does not re-validate a membership that no longer grants
    -- anything (attaching one that is not active still fails below).
    if tg_op = 'UPDATE' and new.membership_id is not distinct from old.membership_id and r.status <> 'active' then
      return new;
    end if;
    if r.status <> 'active' then
      raise exception 'the membership is not active' using errcode = '22023';
    end if;
    -- 0108: a membership ending at the end of its period covers no visit after it
    if not public.membership_grants_at(r.status, r.cancel_at_period_end, r.current_period_end, v_at) then
      raise exception 'the membership ends before this visit' using errcode = '22023';
    end if;
    if r.customer_id <> v_job.customer_id then
      raise exception 'the membership belongs to another customer' using errcode = '22023';
    end if;
    if r.vehicle_id is not null and r.vehicle_id is distinct from v_veh then
      raise exception 'the membership covers another vehicle' using errcode = '22023';
    end if;
    if new.service_id is null or not (new.service_id = any (r.included_service_ids)) then
      raise exception 'the membership does not include this service' using errcode = '22023';
    end if;
    if r.included_uses_per_period is not null
       and public.membership_uses_in_period(r.id, v_at, new.id) >= r.included_uses_per_period then
      raise exception 'no membership visits left in this billing period' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.unit_price_cents = 0 and new.service_id is not null
     and (tg_op = 'INSERT' or new.service_id is distinct from old.service_id
          or new.unit_price_cents is distinct from old.unit_price_cents) then
    for r in
      select m.id, p.included_uses_per_period as lim
        from public.memberships m
        join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
       where m.shop_id = new.shop_id and m.customer_id = v_job.customer_id
         and public.membership_grants_at(m.status, m.cancel_at_period_end, m.current_period_end, v_at)
         and (m.vehicle_id is null or m.vehicle_id = v_veh)
         and new.service_id = any (p.included_service_ids)
       order by p.name, p.id, m.id
    loop
      perform 1 from public.memberships m where m.id = r.id for no key update;
      if r.lim is null or public.membership_uses_in_period(r.id, v_at, new.id) < r.lim then
        new.membership_id := r.id;
        exit;
      end if;
    end loop;
  end if;
  return new;
end
$$;

create or replace function public.jobs_money_membership_uses() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_merge   boolean := coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on'
                       and not public.is_client_context();
  v_at      timestamptz := coalesce(new.scheduled_start, new.created_at);
  v_old_at  timestamptz := coalesce(old.scheduled_start, old.created_at);
  v_tz      text;
  r         record;
begin
  if not exists (select 1 from public.job_line_items li
                 where li.job_id = new.id and li.shop_id = new.shop_id and li.membership_id is not null) then
    return null;
  end if;

  if not v_merge
     and (new.customer_id is distinct from old.customer_id or new.vehicle_id is distinct from old.vehicle_id) then
    for r in
      select li.name, li.vehicle_id as line_vehicle, m.customer_id, m.vehicle_id as membership_vehicle, m.status
        from public.job_line_items li
        join public.memberships m on m.id = li.membership_id and m.shop_id = li.shop_id
       where li.job_id = new.id and li.shop_id = new.shop_id
       order by li.sort, li.created_at, li.id
    loop
      if r.customer_id is distinct from new.customer_id then
        raise exception '"%" is included with the previous customer''s membership; take the membership off that line before moving the job to another customer',
          r.name using errcode = '22023';
      end if;
      if r.status = 'active' and r.membership_vehicle is not null
         and r.membership_vehicle is distinct from coalesce(r.line_vehicle, new.vehicle_id) then
        raise exception '"%" is included with a membership that covers another vehicle; take the membership off that line before changing the job''s vehicle',
          r.name using errcode = '22023';
      end if;
    end loop;
  end if;

  if new.status not in ('cancelled', 'no_show')
     and (old.status in ('cancelled', 'no_show') or v_at is distinct from v_old_at) then
    -- 0108: never onto a date after the end of a membership that is ending
    for r in
      select distinct m.id, p.name, m.current_period_end
        from public.job_line_items li
        join public.memberships m on m.id = li.membership_id and m.shop_id = li.shop_id
        join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
       where li.job_id = new.id and li.shop_id = new.shop_id and m.status = 'active'
         and not public.membership_grants_at(m.status, m.cancel_at_period_end, m.current_period_end, v_at)
       order by m.id
    loop
      select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
      raise exception 'the % membership ends on %, before this visit; take the membership off the job''s line or choose an earlier date',
        r.name, to_char(r.current_period_end at time zone coalesce(v_tz, 'UTC'), 'YYYY-MM-DD') using errcode = '22023';
    end loop;
    for r in
      select distinct m.id, p.name, p.included_uses_per_period as lim
        from public.job_line_items li
        join public.memberships m on m.id = li.membership_id and m.shop_id = li.shop_id
        join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
       where li.job_id = new.id and li.shop_id = new.shop_id
         and m.status = 'active' and p.included_uses_per_period is not null
       order by m.id
    loop
      if old.status not in ('cancelled', 'no_show')
         and public.membership_period_bounds(r.id, v_at) = public.membership_period_bounds(r.id, v_old_at) then
        continue;   -- same billing period: the count does not change
      end if;
      perform 1 from public.memberships m where m.id = r.id for no key update;
      if public.membership_uses_in_period(r.id, v_at) > r.lim then
        select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
        raise exception 'no membership visits left in the billing period of % (% includes % per period); take the membership off the job''s line or choose another date',
          to_char(v_at at time zone coalesce(v_tz, 'UTC'), 'YYYY-MM-DD'), r.name, r.lim using errcode = '22023';
      end if;
    end loop;
  end if;
  return null;
end
$$;
-- ---------------------------------------------------------------------------
-- memberships_zz_money_reprice — see the header.
-- ---------------------------------------------------------------------------
create function public.memberships_money_reprice_uncovered() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cutoff    timestamptz := coalesce(new.current_period_end, now());
  v_repriced  bigint[] := '{}';
  v_billed    bigint[] := '{}';
  v_unpriced  bigint[] := '{}';
  v_plan      text;
  v_tz        text;
  v_body      text;
  r           record;
begin
  for r in
    select li.id as line_id, j.number, pr.price_cents,
           public.job_live_invoice_number(j.shop_id, j.id) as invoice_number
      from public.job_line_items li
      join public.jobs j on j.id = li.job_id and j.shop_id = li.shop_id
      left join public.vehicles v on v.id = coalesce(li.vehicle_id, j.vehicle_id) and v.shop_id = li.shop_id
      left join lateral public.service_price_for(li.service_id, v.category_id) pr on li.service_id is not null
     where li.shop_id = new.shop_id and li.membership_id = new.id
       and j.status in ('requested', 'scheduled', 'confirmed')
       and coalesce(j.scheduled_start, j.created_at) >= v_cutoff
     order by j.scheduled_start nulls last, j.number, li.sort, li.id
       for update of li
  loop
    if r.invoice_number is not null then
      v_billed := v_billed || r.number;
    elsif r.price_cents is null then
      v_unpriced := v_unpriced || r.number;
    else
      update public.job_line_items li
         set membership_id = null,
             unit_price_cents = r.price_cents
       where li.id = r.line_id;
      v_repriced := v_repriced || r.number;
    end if;
  end loop;

  if cardinality(v_repriced) + cardinality(v_billed) + cardinality(v_unpriced) = 0 then
    return null;
  end if;
  begin
    select p.name into v_plan from public.membership_plans p where p.id = new.plan_id and p.shop_id = new.shop_id;
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    v_body := concat_ws(' ',
      format('%s · %s membership, paid through %s.',
             public.integration_customer_label(new.shop_id, new.customer_id), coalesce(v_plan, 'the'),
             to_char(v_cutoff at time zone coalesce(v_tz, 'UTC'), 'FMMonth FMDD, YYYY')),
      case when cardinality(v_repriced) > 0 then
        format('Now charged at the catalog price: %s.',
               (select string_agg('Job #' || x::text, ', ' order by x) from (select distinct unnest(v_repriced) as x) d)) end,
      case when cardinality(v_unpriced) > 0 then
        format('Still included — no catalog price, set one: %s.',
               (select string_agg('Job #' || x::text, ', ' order by x) from (select distinct unnest(v_unpriced) as x) d)) end,
      case when cardinality(v_billed) > 0 then
        format('Still included — already invoiced (void the invoice to reprice): %s.',
               (select string_agg('Job #' || x::text, ', ' order by x) from (select distinct unnest(v_billed) as x) d)) end);
    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'general',
      case when new.status = 'cancelled' then 'Membership ended: booked visits after it need paying'
           else 'Membership ending: booked visits after it need paying' end,
      v_body, null, null, p_customer_id => new.customer_id);
  exception when others then
    raise warning 'membership reprice notification failed for membership %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

comment on function public.memberships_money_reprice_uncovered() is
  'Internal (0108): when a membership starts ending or is cancelled, its included lines on open jobs starting on or after current_period_end are charged the catalog price (billed or unpriced ones are listed in a manager notification instead).';
revoke execute on function public.memberships_money_reprice_uncovered() from public, anon, authenticated;

create trigger memberships_zz_money_reprice
  after update of status, cancel_at_period_end, current_period_end on public.memberships
  for each row
  when ((new.status = 'cancelled' and old.status is distinct from 'cancelled')
        or (new.status = 'active' and new.cancel_at_period_end
            and (not old.cancel_at_period_end or old.status is distinct from 'active'
                 or new.current_period_end is distinct from old.current_period_end)))
  execute function public.memberships_money_reprice_uncovered();
