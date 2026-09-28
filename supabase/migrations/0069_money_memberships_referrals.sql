-- ============================================================================
-- 0069 — Memberships v2 (P-23) and the referral program (P-29).
--
-- Memberships v2
--   * weekly billing ('week', 1..4 weeks on a plan, 1..12 on a membership;
--     sync_stripe_subscription accepts it from the webhook)
--   * usage limits: membership_plans.included_uses_per_period = how many
--     included services a member may use per billing period (null =
--     unlimited). Uses are COUNTED, not ledgered: job lines carrying the
--     membership (job_line_items.membership_id) on jobs that are not
--     cancelled / no-show, dated by the job's scheduled start (else its
--     creation) inside the billing period (membership_period_bounds). A
--     cancelled job frees its use.
--   * job_line_items_61_membership_use: a supplied membership must be an
--     active membership of the job's customer (for the line's vehicle when
--     vehicle-scoped) whose plan includes the service and has uses left;
--     a free line (unit price 0) of an included service gets the membership
--     automatically when one has uses left — online bookings, staff jobs,
--     series and quote conversions alike, without changing their code.
--   * jobs_zz_money_membership_uses: the same rules on the job side — a
--     customer / vehicle change, a reschedule into another billing period
--     or a cancelled job counting again re-validates the job's membership
--     lines (22023; a customer merge is let through).
--   * price_services_core prices an included service at 0 only while the
--     membership has uses left (several lines in one request use them up in
--     order); lines carry membership_id and uses_remaining, and a used-up
--     inclusion is priced from the catalog with a note.
--   * online join page (public_membership_plans / membership_join_prepare,
--     payments edge membership_join_checkout), portal list, cancellation and
--     billing portal access (portal_memberships / portal_membership_access);
--     managers are notified when an online join activates.
-- Plan notes (deviations recorded here):
--   * sync_stripe_subscription (0011) is redefined here (weekly terms; not
--     in the plan's list; money owns it, redefined once).
--   * billing periods: the plan's [current_period_end − interval × count,
--     end) is exact only when the billing day exists in every month.
--     membership_period_bounds counts periods FORWARD from the billing
--     anchor (started_at = Stripe's start_date when the period end is on
--     its cycle, else the period end), as Stripe does, so a subscription
--     billed on the 29th–31st keeps Stripe's periods and a renewal never
--     re-buckets visits already booked.
--   * membership_plans_client_guard (0011) is NOT redefined although the
--     plan listed it: the 0011 guard already lets managers write the new
--     plan columns (included_uses_per_period, online join) and keeps only
--     the Stripe ids server-set.
--   * price_services_core gains a trailing p_starts_at (DROP + CREATE, the
--     plan said "same signature"): uses are counted in the billing period of
--     the visit being priced. create_online_booking (sched 0054, edited in
--     place) passes the booking start and names the pricing's membership on
--     each free line, so the line trigger re-checks the use (a concurrent
--     job that took the last one fails the booking instead of leaving a
--     free line no membership covers). Job series (sched 0051, edited in
--     place) do the same per occurrence: each occurrence is priced at its
--     own start and its free line names the membership. price_services
--     (staff, 0040) still prices at now(); the line trigger attaches a
--     membership only when the job's period has a use left.
--   * job_line_items_61_membership_use lets the ON DELETE SET NULL of a
--     deleted service / vehicle through (nested write that only clears a
--     link), and does not re-validate edits of lines whose membership has
--     ended, so services and vehicles a membership visit used stay deletable.
-- Referral program
--   * a customer's referral code IS a coupon (once per customer, new
--     customers only, referrer_customer_id) with the shop's referee
--     discount; get_or_create_referral_code / portal_referrals create it.
--     Changing the settings updates every referral coupon (kind, value,
--     active = program enabled).
--   * when the referee's FIRST job carrying that coupon is completed (a
--     status change to completed, a job recorded as already completed, or
--     the coupon put on the referee's completed job), the
--     referrer receives store credit (gift_cards kind 'credit', issued_via
--     'referral') and the referral_reward message; a 'skipped' row records
--     a completion while the program was off or without a reward. Exactly
--     once per REFEREE: the credit row outlives the rewarded job (job_id
--     ON DELETE SET NULL), completions of one referee are serialized, and a
--     referee with a credit row no longer counts as a new customer for any
--     new-customers-only coupon (coupon_customer_reason, 0062), so deleting
--     the rewarded job neither re-opens the referral code nor earns a
--     second reward. Self-referral earns nothing.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- sync_stripe_subscription (0011) — weekly subscriptions (1..12 weeks).
-- ---------------------------------------------------------------------------
create or replace function public.sync_stripe_subscription(
  p_shop_id               uuid,
  p_subscription_id       text,
  p_status                public.membership_status,
  p_current_period_end    timestamptz default null,
  p_cancel_at_period_end  boolean default false,
  p_membership_id         uuid default null,
  p_now                   timestamptz default now(),
  p_price_id              text default null,
  p_price_cents           bigint default null,
  p_interval              public.membership_interval default null,
  p_interval_count        integer default null
) returns public.memberships
language plpgsql security definer
set search_path = ''
as $$
declare
  v_m       public.memberships;
  v_status  public.membership_status;
begin
  if p_shop_id is null or p_subscription_id is null or p_status is null or p_now is null then
    raise exception 'shop, subscription id, status and now are required' using errcode = '22023';
  end if;
  if (p_price_cents is null) <> (p_interval is null) or (p_price_cents is null) <> (p_interval_count is null) then
    raise exception 'price, interval and interval count are given together' using errcode = '22023';
  end if;
  if p_price_cents is not null
     and (p_price_cents <= 0
          or not ((p_interval = 'month' and p_interval_count between 1 and 36)
                  or (p_interval = 'year' and p_interval_count between 1 and 3)
                  or (p_interval = 'week' and p_interval_count between 1 and 12))) then
    raise exception 'invalid billing terms: % every % %', p_price_cents, p_interval_count, p_interval
      using errcode = '22023';
  end if;
  if p_price_id is not null and p_price_id !~ '^price_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe price id' using errcode = '22023';
  end if;
  select * into v_m from public.memberships m
   where m.stripe_subscription_id = p_subscription_id for update;
  if found and v_m.shop_id <> p_shop_id then
    raise exception 'subscription belongs to another shop' using errcode = '22023';
  end if;
  if not found and p_membership_id is not null then
    select * into v_m from public.memberships m
     where m.id = p_membership_id and m.shop_id = p_shop_id for update;
    if found and v_m.stripe_subscription_id is not null and v_m.stripe_subscription_id <> p_subscription_id then
      raise exception 'membership is already linked to another subscription' using errcode = '22023';
    end if;
  end if;
  if v_m.id is null then
    raise exception 'membership for subscription % not found', p_subscription_id using errcode = 'P0002';
  end if;

  v_status := case
    when v_m.status = 'cancelled' then 'cancelled'
    when p_status = 'incomplete' and v_m.status <> 'incomplete' then v_m.status
    else p_status
  end;

  update public.memberships m
     set stripe_subscription_id = p_subscription_id,
         status = v_status,
         current_period_end = coalesce(p_current_period_end, m.current_period_end),
         cancel_at_period_end = case when v_status = 'cancelled' then false else coalesce(p_cancel_at_period_end, false) end,
         started_at = case when v_status in ('active', 'past_due') then coalesce(m.started_at, p_now) else m.started_at end,
         cancelled_at = case when v_status = 'cancelled' then coalesce(m.cancelled_at, p_now) else null end,
         price_cents = coalesce(p_price_cents, m.price_cents),
         interval = coalesce(p_interval, m.interval),
         interval_count = coalesce(p_interval_count, m.interval_count),
         stripe_price_id = coalesce(p_price_id, m.stripe_price_id)
   where m.id = v_m.id
  returning * into v_m;
  return v_m;
end
$$;

-- ---------------------------------------------------------------------------
-- Billing periods and uses (internal)
-- ---------------------------------------------------------------------------
create function public.membership_add_periods(
  p_anchor timestamptz, p_interval public.membership_interval, p_count integer, p_k integer
) returns timestamptz
language sql immutable
set search_path = ''
as $$
  -- calendar arithmetic in UTC (as Stripe bills), whatever the session's
  -- TimeZone: k whole periods FROM the anchor in one step, so a month-end
  -- anchor keeps its day where the month has it (Jan 31 + 3 months = Apr 30,
  -- + 2 months = Mar 31)
  select ((p_anchor at time zone 'UTC') + case p_interval
    when 'week' then make_interval(weeks => p_count * p_k)
    when 'month' then make_interval(months => p_count * p_k)
    else make_interval(years => p_count * p_k)
  end) at time zone 'UTC'
$$;

-- The billing period containing p_at. Periods are whole intervals counted
-- FORWARD from a billing anchor A — [A + k·I, A + (k+1)·I), UTC calendar
-- arithmetic from A itself — which is how Stripe computes them: a
-- subscription anchored on the 31st renews on Feb 28, Mar 31, Apr 30, so
-- the April period is [Mar 31, Apr 30), not [Mar 30, Apr 30) (subtracting
-- months from a clamped period end would move the start up to 3 days).
-- The anchor:
--   * started_at when current_period_end is one of its boundaries (Stripe's
--     default: the billing cycle is anchored on the subscription's
--     start_date, which the webhook passes as started_at), so every renewal
--     keeps the same periods and visits already booked stay in theirs;
--   * else current_period_end (the anchor moved: a trial, a plan change
--     that reset the cycle, a backdated start): [end − I, end) is the
--     current period and the others step from it (exact unless that end
--     itself fell on a shortened month end);
--   * without a period end (not billed by Stripe yet): started_at, else
--     created_at.
create function public.membership_period_bounds(p_membership_id uuid, p_at timestamptz) returns tstzrange
language plpgsql stable
set search_path = ''
as $$
declare
  v_m       public.memberships;
  v_anchor  timestamptz;
  v_months  integer;
  v_step    integer;
  v_days    numeric;
  v_k       integer;
  v_lo      timestamptz;
  v_hi      timestamptz;
  v_guard   integer := 0;
begin
  select * into v_m from public.memberships m where m.id = p_membership_id;
  if not found or p_at is null then
    return null;
  end if;
  v_anchor := coalesce(v_m.current_period_end, v_m.started_at, v_m.created_at);
  if v_m.current_period_end is not null and v_m.started_at is not null
     and v_m.started_at <= v_m.current_period_end then
    -- is the period end a whole number of periods after started_at?
    if v_m.interval = 'week' then
      v_k := round(extract(epoch from (v_m.current_period_end - v_m.started_at)) / (604800 * v_m.interval_count))::integer;
    else
      v_step := v_m.interval_count * case v_m.interval when 'month' then 1 else 12 end;
      v_months := (extract(year from v_m.current_period_end at time zone 'UTC')
                   - extract(year from v_m.started_at at time zone 'UTC'))::integer * 12
                + (extract(month from v_m.current_period_end at time zone 'UTC')
                   - extract(month from v_m.started_at at time zone 'UTC'))::integer;
      v_k := case when v_months % v_step = 0 then v_months / v_step end;
    end if;
    if v_k is not null
       and public.membership_add_periods(v_m.started_at, v_m.interval, v_m.interval_count, v_k)
           = v_m.current_period_end then
      v_anchor := v_m.started_at;
    end if;
  end if;
  v_days := case v_m.interval when 'week' then 7 when 'month' then 30.436875 else 365.2425 end * v_m.interval_count;
  v_k := floor(extract(epoch from (p_at - v_anchor)) / (v_days * 86400))::integer;
  loop
    v_guard := v_guard + 1;
    v_lo := public.membership_add_periods(v_anchor, v_m.interval, v_m.interval_count, v_k);
    v_hi := public.membership_add_periods(v_anchor, v_m.interval, v_m.interval_count, v_k + 1);
    exit when (p_at >= v_lo and p_at < v_hi) or v_guard > 10;
    if p_at < v_lo then v_k := v_k - 1; else v_k := v_k + 1; end if;
  end loop;
  return tstzrange(v_lo, v_hi, '[)');
end
$$;

-- Uses of a membership in the period containing p_at (see the header).
-- p_exclude_line: a line being re-validated does not count itself.
create function public.membership_uses_in_period(
  p_membership_id  uuid,
  p_at             timestamptz default now(),
  p_exclude_line   uuid default null
) returns integer
language sql stable
set search_path = ''
as $$
  select count(*)::integer
    from public.job_line_items li
    join public.jobs j on j.id = li.job_id and j.shop_id = li.shop_id
   where li.membership_id = p_membership_id
     and li.id is distinct from p_exclude_line
     and j.status not in ('cancelled', 'no_show')
     and coalesce(j.scheduled_start, j.created_at) <@ public.membership_period_bounds(p_membership_id, p_at)
$$;

-- ---------------------------------------------------------------------------
-- job_line_items_61_membership_use — see the header (every context).
-- ---------------------------------------------------------------------------
create function public.job_line_items_money_membership_use() returns trigger
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
    select m.id, m.status, m.customer_id, m.vehicle_id, p.included_service_ids, p.included_uses_per_period
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
       where m.shop_id = new.shop_id and m.customer_id = v_job.customer_id and m.status = 'active'
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

create trigger job_line_items_61_membership_use before insert or update on public.job_line_items
  for each row execute function public.job_line_items_money_membership_use();

-- ---------------------------------------------------------------------------
-- jobs_zz_money_membership_uses — the job side of the same rules. A
-- membership line is checked when it is written (above), but uses are
-- counted by the JOB (its customer, vehicle, status and scheduled start),
-- so a job update that changes any of those re-validates the job's
-- membership lines (every context; 22023, the whole update fails — prices
-- never change behind the staff's back):
--   * customer change: a line naming a membership of another customer
--     fails (take the membership off the line first — then the line is an
--     ordinary priced line). A customer merge (merge GUC, trusted context)
--     moves the memberships with the jobs and is let through.
--   * vehicle change: a line without its own vehicle on a vehicle-scoped
--     active membership must still be on that vehicle.
--   * reschedule into another billing period, or a cancelled / no-show job
--     that counts again (e.g. back to scheduled): the period of the job's
--     (new) start may not hold more uses than the plan includes. A
--     reschedule inside the same period and every other status change
--     (cancelling frees the use) are not re-checked, so existing jobs are
--     never blocked by an unrelated edit.
-- Lines of a membership that has ended are history (as in the line trigger):
-- only the customer rule applies to them. The membership row is locked
-- (FOR NO KEY UPDATE, like the line trigger) before counting, so two
-- concurrent moves cannot both take the last use.
-- ---------------------------------------------------------------------------
create function public.jobs_money_membership_uses() returns trigger
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

create trigger jobs_zz_money_membership_uses
  after update of scheduled_start, status, customer_id, vehicle_id on public.jobs
  for each row execute function public.jobs_money_membership_uses();

-- ---------------------------------------------------------------------------
-- price_services_core — INTERNAL (0040) plus a trailing p_starts_at:
-- memberships apply only while they have uses left (see the header) in the
-- billing period that contains p_starts_at — the visit being priced (null =
-- now: a job without a start is dated by its creation, as
-- membership_uses_in_period counts it). The job line trigger
-- (job_line_items_61_membership_use) counts uses in the period of the job's
-- scheduled start, so pricing and the trigger agree for a booking in a later
-- period: a visit beyond the limit is charged, and a visit in a period that
-- still has uses is free even when the current one is used up. Result as
-- 0040; each line also has membership_id and uses_remaining (null =
-- unlimited or no membership). Positional callers with 6 arguments keep
-- working (create_online_booking passes the booking start, 0054).
-- ---------------------------------------------------------------------------
drop function public.price_services_core(uuid, uuid, uuid, uuid[], uuid, boolean);

create function public.price_services_core(
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
     where mm.shop_id = p_shop_id and mm.customer_id = p_customer_id and mm.status = 'active'
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
         where mm.shop_id = p_shop_id and mm.customer_id = p_customer_id and mm.status = 'active'
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

-- ---------------------------------------------------------------------------
-- create_membership_core — INTERNAL (no caller checks): an incomplete
-- membership on an active plan for a customer (and optionally one of their
-- vehicles); 23505 when one is already open. create_membership (manager+)
-- delegates; membership_join_prepare (online join) uses it too.
-- ---------------------------------------------------------------------------
create function public.create_membership_core(
  p_plan_id      uuid,
  p_customer_id  uuid,
  p_vehicle_id   uuid default null
) returns public.memberships
language plpgsql volatile
set search_path = ''
as $$
declare
  v_plan  public.membership_plans;
  v_m     public.memberships;
begin
  select * into v_plan from public.membership_plans p where p.id = p_plan_id;
  if not found then
    raise exception 'membership plan not found' using errcode = 'P0002';
  end if;
  if not v_plan.active or v_plan.archived_at is not null then
    raise exception 'this membership plan is not available' using errcode = '22023';
  end if;
  if not exists (select 1 from public.customers c
                 where c.id = p_customer_id and c.shop_id = v_plan.shop_id and c.archived_at is null) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if p_vehicle_id is not null and not exists (
       select 1 from public.vehicles v
       where v.id = p_vehicle_id and v.shop_id = v_plan.shop_id and v.customer_id = p_customer_id
         and v.archived_at is null) then
    raise exception 'the vehicle does not belong to this customer' using errcode = '22023';
  end if;
  if exists (select 1 from public.memberships m
             where m.shop_id = v_plan.shop_id and m.plan_id = v_plan.id and m.customer_id = p_customer_id
               and m.vehicle_id is not distinct from p_vehicle_id and m.status <> 'cancelled') then
    raise exception 'this customer already has an open membership on this plan%',
      case when p_vehicle_id is null then '' else ' for this vehicle' end using errcode = '23505';
  end if;

  insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status)
  values (v_plan.shop_id, v_plan.id, p_customer_id, p_vehicle_id, 'incomplete')
  returning * into v_m;
  return v_m;
end
$$;

create or replace function public.create_membership(
  p_plan_id      uuid,
  p_customer_id  uuid,
  p_vehicle_id   uuid default null
) returns public.memberships
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select p.shop_id into v_shop from public.membership_plans p where p.id = p_plan_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'membership plan not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can create memberships' using errcode = '42501';
  end if;
  return public.create_membership_core(p_plan_id, p_customer_id, p_vehicle_id);
end
$$;

-- ---------------------------------------------------------------------------
-- membership_usage(membership, at) — owner/admin/manager:
-- {uses_per_period, uses_this_period, period_start, period_end}.
-- ---------------------------------------------------------------------------
create function public.membership_usage(p_membership_id uuid, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_m     public.memberships;
  v_lim   integer;
  v_range tstzrange;
  v_at    timestamptz := coalesce(p_at, now());
begin
  select * into v_m from public.memberships m where m.id = p_membership_id;
  if not found or not public.is_shop_member(v_m.shop_id) then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_m.shop_id) then
    raise exception 'only owners, admins and managers can see membership usage' using errcode = '42501';
  end if;
  select p.included_uses_per_period into v_lim from public.membership_plans p
   where p.id = v_m.plan_id and p.shop_id = v_m.shop_id;
  v_range := public.membership_period_bounds(v_m.id, v_at);
  return jsonb_build_object(
    'uses_per_period', v_lim,
    'uses_this_period', public.membership_uses_in_period(v_m.id, v_at),
    'period_start', lower(v_range),
    'period_end', upper(v_range));
end
$$;

-- ---------------------------------------------------------------------------
-- public_membership_plans(slug) — anon: the plans the shop offers online.
-- ---------------------------------------------------------------------------
create function public.public_membership_plans(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'logo_path', v_shop.logo_path, 'brand_color', v_shop.brand_color),
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'name', p.name,
               'description', p.description,
               'price_cents', p.price_cents,
               'interval', p.interval,
               'interval_count', p.interval_count,
               'included_services', coalesce((select jsonb_agg(s.name order by s.sort, s.name)
                                                from public.services s
                                               where s.shop_id = p.shop_id and s.id = any (p.included_service_ids)
                                                 and s.archived_at is null), '[]'::jsonb),
               'discount_bps', p.discount_bps,
               'uses_per_period', p.included_uses_per_period,
               'vehicle_scoped', false,
               'terms', p.terms)
             order by p.sort, p.name, p.id)
      from public.membership_plans p
      where p.shop_id = v_shop.id and p.active and p.archived_at is null and p.online_joinable), '[]'::jsonb),
    'currency', v_shop.currency);
end
$$;

-- ---------------------------------------------------------------------------
-- membership_join_prepare(slug, plan, payload, now) — service_role (payments
-- edge membership_join_checkout). payload: {customer {first_name*,
-- last_name, email*, phone, sms_opt_in, email_opt_in}, vehicle? {year,
-- make*, model*}}. Customer matching / trust as online booking (0042): an
-- existing customer (same email, else same phone without email) is never
-- modified — a public form proves nothing; a new one is created (source
-- online_booking, lifecycle customer, the form's opt-ins). The vehicle (a
-- vehicle-scoped membership) is the customer's vehicle with the same year /
-- make / model, else a new one from the submitted fields.
-- An open but never-billed membership on the same plan / customer /
-- vehicle is reused (a checkout retried). PT429 after 3 joins per email per
-- shop in 24 hours; 55000 plan not offered online; PT404 unknown shop.
-- Returns {membership_id, customer_id, shop_id, email}.
-- ---------------------------------------------------------------------------
create function public.membership_join_prepare(
  p_slug     text,
  p_plan_id  uuid,
  p_payload  jsonb,
  p_now      timestamptz default now()
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop       public.shops;
  v_plan       public.membership_plans;
  v_cust_in    jsonb;
  v_veh_in     jsonb;
  v_first      text;
  v_last       text;
  v_email      text;
  v_phone_raw  text;
  v_phone      text;
  v_sms        boolean;
  v_email_opt  boolean;
  v_customer   uuid;
  v_vehicle    uuid;
  v_year       integer;
  v_make       text;
  v_model      text;
  v_m          public.memberships;
begin
  -- (p_now is accepted for symmetry with the other entry points; the abuse
  -- limit always uses the wall clock)
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_plan from public.membership_plans p
   where p.id = p_plan_id and p.shop_id = v_shop.id and p.active and p.archived_at is null and p.online_joinable;
  if not found then
    raise exception 'this membership plan is not available online' using errcode = '55000';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'join details must be a JSON object' using errcode = '22023';
  end if;
  v_cust_in := p_payload -> 'customer';
  v_veh_in := p_payload -> 'vehicle';
  if coalesce(jsonb_typeof(v_cust_in), 'null') <> 'object' then
    raise exception 'contact details are required' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(v_veh_in), 'null') not in ('object', 'null') then
    raise exception 'vehicle must be an object' using errcode = '22023';
  end if;
  v_first := public.payload_text(v_cust_in, 'first_name', 100, 'first name', true);
  v_last := public.payload_text(v_cust_in, 'last_name', 100, 'last name');
  v_email := lower(public.payload_text(v_cust_in, 'email', 254, 'email', true));
  if not public.is_valid_email(v_email) then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  v_phone_raw := public.payload_text(v_cust_in, 'phone', 32, 'phone');
  if v_phone_raw is not null then
    v_phone := public.normalize_phone_e164(v_phone_raw, v_shop.country);
    if v_phone is null then
      raise exception 'enter a valid phone number' using errcode = '22023';
    end if;
  end if;
  v_sms := public.payload_bool(v_cust_in, 'sms_opt_in', 'sms_opt_in');
  v_email_opt := public.payload_bool(v_cust_in, 'email_opt_in', 'email_opt_in');
  if jsonb_typeof(v_veh_in) = 'object' then
    v_year := public.payload_int(v_veh_in, 'year', 'vehicle year', 1886, 2100);
    v_make := public.payload_text(v_veh_in, 'make', 60, 'vehicle make', true);
    v_model := public.payload_text(v_veh_in, 'model', 60, 'vehicle model', true);
  end if;

  -- abuse limit (wall clock): online joins (created_by null) per email
  if (select count(*) from public.memberships m
        join public.customers c on c.id = m.customer_id and c.shop_id = m.shop_id
       where m.shop_id = v_shop.id and m.created_by is null and c.email is not null
         and lower(c.email::text) = v_email and m.created_at > now() - interval '24 hours') >= 3 then
    raise exception 'too many membership sign-ups for this email today; please contact the shop' using errcode = 'PT429';
  end if;

  select c.id into v_customer from public.customers c
   where c.shop_id = v_shop.id and c.archived_at is null and c.email is not null and lower(c.email::text) = v_email
     and (not c.phone_unverified or c.phone is null or c.phone = v_phone)
   order by coalesce(c.phone = v_phone, false) desc, c.created_at desc, c.id
   limit 1;
  if v_customer is null and v_phone is not null then
    select c.id into v_customer from public.customers c
     where c.shop_id = v_shop.id and c.archived_at is null and c.email is null and c.phone = v_phone
     order by c.created_at desc, c.id limit 1;
  end if;
  if v_customer is null then
    insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, source,
                                  lifecycle, phone_unverified)
    values (v_shop.id, v_first, v_last, v_email::extensions.citext, v_phone, v_sms and v_phone is not null, v_email_opt,
            'online_booking', 'customer', v_phone is not null)
    returning id into v_customer;
  end if;
  if v_make is not null then
    -- a retried join finds the vehicle it created (nothing about the
    -- customer's vehicles is returned to the caller)
    select v.id into v_vehicle from public.vehicles v
     where v.shop_id = v_shop.id and v.customer_id = v_customer and v.archived_at is null
       and lower(btrim(v.make)) = lower(v_make) and lower(btrim(v.model)) = lower(v_model)
       and v.year is not distinct from v_year
     order by v.created_at desc, v.id limit 1;
    if v_vehicle is null then
      insert into public.vehicles (shop_id, customer_id, year, make, model)
      values (v_shop.id, v_customer, v_year, v_make, v_model)
      returning id into v_vehicle;
    end if;
  end if;

  select * into v_m from public.memberships m
   where m.shop_id = v_shop.id and m.plan_id = v_plan.id and m.customer_id = v_customer
     and m.vehicle_id is not distinct from v_vehicle and m.status <> 'cancelled';
  if found then
    if v_m.status <> 'incomplete' or v_m.stripe_subscription_id is not null then
      raise exception 'this customer already has this membership' using errcode = '22023';
    end if;
  else
    v_m := public.create_membership_core(v_plan.id, v_customer, v_vehicle);
  end if;
  return jsonb_build_object('membership_id', v_m.id, 'customer_id', v_customer, 'shop_id', v_shop.id,
                            'email', v_email);
end
$$;

-- ---------------------------------------------------------------------------
-- portal_memberships() — signed-in client: memberships of the customers
-- linked to them (portal_user_id), never-billed checkouts left out.
-- [{id, shop_name, shop_slug, plan_name, status, price_cents, interval,
--   interval_count, current_period_end, cancel_at_period_end,
--   uses_per_period, uses_this_period, can_cancel}]
-- ---------------------------------------------------------------------------
create function public.portal_memberships() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', m.id,
             'shop_name', s.name,
             'shop_slug', s.slug,
             'plan_name', p.name,
             'status', m.status,
             'price_cents', m.price_cents,
             'interval', m.interval,
             'interval_count', m.interval_count,
             'current_period_end', m.current_period_end,
             'cancel_at_period_end', m.cancel_at_period_end,
             'uses_per_period', p.included_uses_per_period,
             'uses_this_period', case when m.status in ('active', 'past_due')
                                      then public.membership_uses_in_period(m.id, now()) end,
             'can_cancel', m.status in ('active', 'past_due') and not m.cancel_at_period_end
                           and m.stripe_subscription_id is not null)
           order by s.name, m.created_at, m.id)
      from public.customers c
      join public.memberships m on m.customer_id = c.id and m.shop_id = c.shop_id
      join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
      join public.shops s on s.id = c.shop_id
     where c.portal_user_id = v_uid and c.archived_at is null
       and not (m.status = 'incomplete' and m.stripe_subscription_id is null)), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------
-- portal_membership_access(membership, user) — service_role (payments edge
-- portal_membership_cancel / portal_billing_portal): the Stripe handles of a
-- membership, or null unless p_user_id is the portal user linked to its
-- customer. {shop_id, stripe_subscription_id, stripe_customer_id, status}.
-- ---------------------------------------------------------------------------
create function public.portal_membership_access(p_membership_id uuid, p_user_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('shop_id', m.shop_id, 'stripe_subscription_id', m.stripe_subscription_id,
                            'stripe_customer_id', c.stripe_customer_id, 'status', m.status)
    from public.memberships m
    join public.customers c on c.id = m.customer_id and c.shop_id = m.shop_id
   where m.id = p_membership_id and p_user_id is not null
     and c.portal_user_id = p_user_id and c.archived_at is null
$$;

-- ---------------------------------------------------------------------------
-- A membership joined online (created_by null) that activates notifies
-- owners / admins / managers (membership_joined).
-- ---------------------------------------------------------------------------
create function public.memberships_money_joined() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_plan     text;
  v_currency text;
begin
  begin
    select p.name into v_plan from public.membership_plans p where p.id = new.plan_id and p.shop_id = new.shop_id;
    select s.currency into v_currency from public.shops s where s.id = new.shop_id;
    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'membership_joined',
      'New member: ' || public.integration_customer_label(new.shop_id, new.customer_id) || ' joined ' || coalesce(v_plan, 'a plan'),
      public.format_money(new.price_cents, v_currency) || ' every '
        || case when new.interval_count = 1 then new.interval::text
                else new.interval_count::text || ' ' || new.interval::text || 's' end,
      null, null, p_customer_id => new.customer_id);
  exception when others then
    raise warning 'membership join notification failed for membership %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger memberships_zz_money_joined after update of status on public.memberships
  for each row when (old.status = 'incomplete' and new.status = 'active' and new.created_by is null)
  execute function public.memberships_money_joined();

-- ===========================================================================
-- Referral program
-- ===========================================================================

-- referral_code is server-set (client writes ignored).
create function public.customers_money_referral_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    if tg_op = 'INSERT' then
      new.referral_code := null;
    else
      new.referral_code := old.referral_code;
    end if;
  end if;
  return new;
end
$$;

create trigger customers_60_referral_guard before insert or update on public.customers
  for each row execute function public.customers_money_referral_guard();

-- Settings changes apply to every referral coupon of the shop.
create function public.referral_settings_money_sync() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.coupons c
     set kind = case when new.referee_discount_value > 0 then new.referee_discount_kind else c.kind end,
         value = case when new.referee_discount_value > 0 then new.referee_discount_value else c.value end,
         active = new.enabled
   where c.shop_id = new.shop_id and c.referrer_customer_id is not null
     and (c.active is distinct from new.enabled
          or (new.referee_discount_value > 0
              and (c.kind, c.value) is distinct from (new.referee_discount_kind, new.referee_discount_value)));
  return null;
end
$$;

create trigger referral_settings_zz_money_sync
  after update of enabled, referee_discount_kind, referee_discount_value on public.referral_settings
  for each row execute function public.referral_settings_money_sync();

-- A new referral code: 8 characters, no look-alikes, unique among the
-- shop's referral codes and coupon codes.
create function public.referral_new_code(p_shop_id uuid) returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_bytes bytea;
begin
  for attempt in 1..20 loop
    v_bytes := extensions.gen_random_bytes(8);
    v_code := '';
    for i in 0..7 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) % 31) + 1, 1);
    end loop;
    if not exists (select 1 from public.customers c where c.shop_id = p_shop_id and c.referral_code = v_code::extensions.citext)
       and not exists (select 1 from public.coupons k where k.shop_id = p_shop_id and k.code = v_code::extensions.citext) then
      return v_code;
    end if;
  end loop;
  raise exception 'could not create a unique referral code; try again' using errcode = '40001';
end
$$;

-- INTERNAL: the customer's referral code and coupon, created on first use.
-- 55000 while the program is off. {code, share_url}.
create function public.referral_code_core(p_customer_id uuid) returns jsonb
language plpgsql volatile
set search_path = ''
as $$
declare
  v_c     public.customers;
  v_rs    public.referral_settings;
  v_slug  text;
  v_code  text;
begin
  select * into v_c from public.customers c where c.id = p_customer_id for no key update;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if v_c.archived_at is not null then
    raise exception 'archived customers cannot refer others' using errcode = '22023';
  end if;
  select * into v_rs from public.referral_settings r where r.shop_id = v_c.shop_id;
  if not coalesce(v_rs.enabled, false) then
    raise exception 'the referral program is not enabled' using errcode = '55000';
  end if;
  select s.slug into v_slug from public.shops s where s.id = v_c.shop_id;
  v_code := v_c.referral_code::text;
  if v_code is not null and exists (select 1 from public.coupons k
                                    where k.shop_id = v_c.shop_id and k.referrer_customer_id = v_c.id
                                      and k.code = v_code::extensions.citext) then
    return jsonb_build_object('code', v_code, 'share_url', public.app_url('/book/' || v_slug || '?coupon=' || v_code));
  end if;
  if v_code is null
     or exists (select 1 from public.coupons k where k.shop_id = v_c.shop_id and k.code = v_code::extensions.citext) then
    v_code := public.referral_new_code(v_c.shop_id);
    update public.customers c set referral_code = v_code::extensions.citext where c.id = v_c.id;
  end if;
  insert into public.coupons (shop_id, code, description, kind, value, once_per_customer, new_customers_only,
                              referrer_customer_id, active)
  values (v_c.shop_id, v_code::extensions.citext,
          left('Referral from ' || coalesce(nullif(btrim(v_c.first_name), ''), nullif(btrim(v_c.company), ''), 'a customer'), 500),
          v_rs.referee_discount_kind, v_rs.referee_discount_value, true, true, v_c.id, true);
  return jsonb_build_object('code', v_code, 'share_url', public.app_url('/book/' || v_slug || '?coupon=' || v_code));
end
$$;

-- get_or_create_referral_code(customer) — owner/admin/manager.
create function public.get_or_create_referral_code(p_customer_id uuid) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select c.shop_id into v_shop from public.customers c where c.id = p_customer_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can create referral codes' using errcode = '42501';
  end if;
  return public.referral_code_core(p_customer_id);
end
$$;

-- ---------------------------------------------------------------------------
-- jobs_zz_money_referral_reward — the referee's first completed job with a
-- referral coupon (see the header).
-- ---------------------------------------------------------------------------
create function public.jobs_money_referral_reward() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_coupon   public.coupons;
  v_rs       public.referral_settings;
  v_credit   uuid;
  v_card     jsonb;
  v_first    text;
  v_currency text;
begin
  if new.coupon_id is null then
    return null;
  end if;
  select * into v_coupon from public.coupons c where c.id = new.coupon_id and c.shop_id = new.shop_id;
  if not found or v_coupon.referrer_customer_id is null or v_coupon.referrer_customer_id = new.customer_id then
    return null;
  end if;
  -- one reward per referee, whatever happened to the rewarded job (its
  -- credit row survives the job's deletion with job_id null): completions of
  -- the same referee's jobs are serialized so two of them cannot both see
  -- "no credit yet" (each check below runs after the lock, on a fresh
  -- snapshot in READ COMMITTED)
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.jobs_money_referral_reward:' || new.customer_id::text, 0));
  if exists (select 1 from public.jobs j
             where j.shop_id = new.shop_id and j.customer_id = new.customer_id and j.status = 'completed'
               and j.id <> new.id)
     or exists (select 1 from public.referral_credits rc
                where rc.shop_id = new.shop_id and rc.referee_customer_id = new.customer_id) then
    return null;   -- not the referee's first completed job, or already rewarded
  end if;
  select * into v_rs from public.referral_settings r where r.shop_id = new.shop_id;
  if not coalesce(v_rs.enabled, false) or coalesce(v_rs.referrer_reward_cents, 0) <= 0 then
    insert into public.referral_credits (shop_id, referrer_customer_id, referee_customer_id, coupon_id, job_id,
                                         amount_cents, status)
    values (new.shop_id, v_coupon.referrer_customer_id, new.customer_id, v_coupon.id, new.id, 0, 'skipped')
    on conflict (job_id) do nothing;
    return null;
  end if;

  insert into public.referral_credits (shop_id, referrer_customer_id, referee_customer_id, coupon_id, job_id,
                                       amount_cents, status)
  values (new.shop_id, v_coupon.referrer_customer_id, new.customer_id, v_coupon.id, new.id,
          v_rs.referrer_reward_cents, 'issued')
  on conflict (job_id) do nothing
  returning id into v_credit;
  if v_credit is null then
    return null;   -- already rewarded
  end if;
  v_card := public.gift_card_issue_core(new.shop_id, 'credit', v_rs.referrer_reward_cents, null, 'referral', null,
                                        v_coupon.referrer_customer_id, null, null, null, null, null,
                                        'Referral reward for job #' || new.number::text);
  update public.referral_credits rc set gift_card_id = (v_card ->> 'gift_card_id')::uuid where rc.id = v_credit;

  begin
    select nullif(btrim(c.first_name), '') into v_first from public.customers c
     where c.id = new.customer_id and c.shop_id = new.shop_id;
    select s.currency into v_currency from public.shops s where s.id = new.shop_id;
    perform public.integration_send_customer_template(
      new.shop_id, v_coupon.referrer_customer_id, 'referral_reward', null,
      jsonb_build_object('credit_amount', public.format_money(v_rs.referrer_reward_cents, v_currency),
                         'gift_card_code', v_card ->> 'code',
                         'referee_first_name', v_first),
      false);
  exception when others then
    raise warning 'referral reward message failed for job %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

-- A completion is a status change to completed, a job inserted already
-- completed (a walk-in logged after the fact: jobs_status_machine allows it)
-- or the referral coupon put on a completed job; without the last two a
-- referee whose first completed job skipped the update would never reward
-- the referrer (every later job fails the first-completed-job test).
create trigger jobs_zz_money_referral_reward after update of status, coupon_id on public.jobs
  for each row when (new.status = 'completed' and new.coupon_id is not null
                     and (old.status is distinct from 'completed' or old.coupon_id is distinct from new.coupon_id))
  execute function public.jobs_money_referral_reward();
create trigger jobs_zz_money_referral_reward_insert after insert on public.jobs
  for each row when (new.status = 'completed' and new.coupon_id is not null)
  execute function public.jobs_money_referral_reward();

-- ---------------------------------------------------------------------------
-- portal_referrals() — signed-in client: for each linked customer in a shop
-- whose program is on, their code (created on first call), share link,
-- credit earned and store credit left.
-- [{shop_name, code, share_url, credits_earned_cents, credit_balance_cents}]
-- ---------------------------------------------------------------------------
create function public.portal_referrals() returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_out  jsonb := '[]'::jsonb;
  r      record;
  v_code jsonb;
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  for r in
    select c.id, c.shop_id, s.name as shop_name
      from public.customers c
      join public.shops s on s.id = c.shop_id
      join public.referral_settings rs on rs.shop_id = c.shop_id and rs.enabled
     where c.portal_user_id = v_uid and c.archived_at is null
     order by s.name, c.created_at, c.id
  loop
    v_code := public.referral_code_core(r.id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'shop_name', r.shop_name,
      'code', v_code ->> 'code',
      'share_url', v_code ->> 'share_url',
      'credits_earned_cents', (select coalesce(sum(rc.amount_cents), 0) from public.referral_credits rc
                                where rc.shop_id = r.shop_id and rc.referrer_customer_id = r.id and rc.status = 'issued'),
      'credit_balance_cents', (select coalesce(sum(g.balance_cents), 0) from public.gift_cards g
                                where g.shop_id = r.shop_id and g.owner_customer_id = r.id and g.kind = 'credit'
                                  and g.status = 'active' and (g.expires_at is null or g.expires_at > now()))));
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.job_line_items_money_membership_use(),
  public.jobs_money_membership_uses(),
  public.memberships_money_joined(),
  public.customers_money_referral_guard(),
  public.referral_settings_money_sync(),
  public.jobs_money_referral_reward()
from public, anon, authenticated;

revoke execute on function
  public.membership_add_periods(timestamptz, public.membership_interval, integer, integer),
  public.membership_period_bounds(uuid, timestamptz),
  public.membership_uses_in_period(uuid, timestamptz, uuid),
  public.create_membership_core(uuid, uuid, uuid),
  public.membership_join_prepare(text, uuid, jsonb, timestamptz),
  public.portal_membership_access(uuid, uuid),
  public.referral_new_code(uuid),
  public.referral_code_core(uuid),
  public.price_services_core(uuid, uuid, uuid, uuid[], uuid, boolean, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.membership_add_periods(timestamptz, public.membership_interval, integer, integer),
  public.membership_period_bounds(uuid, timestamptz),
  public.membership_uses_in_period(uuid, timestamptz, uuid),
  public.create_membership_core(uuid, uuid, uuid),
  public.membership_join_prepare(text, uuid, jsonb, timestamptz),
  public.portal_membership_access(uuid, uuid),
  public.referral_new_code(uuid),
  public.referral_code_core(uuid),
  public.price_services_core(uuid, uuid, uuid, uuid[], uuid, boolean, timestamptz)
to service_role;

revoke execute on function
  public.membership_usage(uuid, timestamptz),
  public.get_or_create_referral_code(uuid),
  public.portal_memberships(),
  public.portal_referrals()
from public, anon;
grant execute on function
  public.membership_usage(uuid, timestamptz),
  public.get_or_create_referral_code(uuid),
  public.portal_memberships(),
  public.portal_referrals()
to authenticated, service_role;

revoke execute on function public.public_membership_plans(text) from public;
grant execute on function public.public_membership_plans(text) to anon, authenticated, service_role;
