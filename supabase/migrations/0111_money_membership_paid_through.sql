-- ============================================================================
-- 0111 — A membership whose renewal is not paid stops covering the visits
-- of the unpaid period (money 0069 / 0108).
--
-- 0108 repriced a membership's included ($0) visits booked after "the paid
-- period's end" when it started ending or was cancelled, and took that end
-- from memberships.current_period_end. But Stripe moves current_period_end
-- forward when the renewal invoice is CREATED, before it is paid, and the
-- webhook stores it for every status. So when a member's renewal failed:
--   * past_due repriced nothing: every $0 visit already booked in the unpaid
--     period (and later ones) stayed free while dunning went on, and could
--     be completed and invoiced at $0;
--   * when Stripe finally cancelled the subscription, the cutoff was the
--     UNPAID period's end, so the visits inside the period that was never
--     paid kept their $0 price. On a weekly plan the member got extra free
--     visits without paying for them.
--
-- memberships.paid_through (new, server-maintained in every context by
-- memberships_40_paid_through; whatever a writer puts there is recomputed):
-- the end of the last billing period the member paid for.
--   * active: current_period_end (Stripe keeps a subscription active only
--     while its invoices are paid; a renewal that fails turns it past_due);
--   * past_due: the start of the current (unpaid) period — the period
--     containing just before current_period_end (membership_period_bounds
--     rules) — or the earlier paid_through if it is already before that
--     (several unpaid periods);
--   * cancelled: kept from before (cancelled while active = its period end;
--     while past_due = the start of the unpaid period; never paid = null);
--   * incomplete: null.
-- Existing memberships are backfilled with these rules.
--
-- memberships_zz_money_reprice (0108 trigger, redefined): also fires when a
-- membership becomes past_due (or its paid_through moves back while
-- past_due), and the cutoff of a past_due or cancelled membership is
-- paid_through (now() when it was never paid); an active ending membership
-- keeps current_period_end. Visits on or after the cutoff on open jobs lose
-- the membership and are charged the catalog price, exactly as 0108 does
-- for an ending membership (billed / unpriced ones are listed in the
-- managers' notification instead). A payment that later succeeds (past_due
-- -> active) does not give the included price back automatically (staff
-- re-add the membership on the job, as after 0108's reprice).
-- Coverage of new bookings is unchanged: only an active membership covers
-- a visit (membership_grants_at, 0108), so nothing is booked free while
-- past_due.
--
-- membership_period_bounds_of(started_at, current_period_end, created_at,
-- interval, interval_count, at): the period arithmetic of
-- membership_period_bounds (0069) on values instead of a stored row (the
-- BEFORE trigger needs the new row's values); membership_period_bounds now
-- calls it (same results).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- membership_period_bounds_of — 0069's membership_period_bounds on values
-- ---------------------------------------------------------------------------
create function public.membership_period_bounds_of(
  p_started_at          timestamptz,
  p_current_period_end  timestamptz,
  p_created_at          timestamptz,
  p_interval            public.membership_interval,
  p_interval_count      integer,
  p_at                  timestamptz
) returns tstzrange
language plpgsql immutable
set search_path = ''
as $$
declare
  v_anchor  timestamptz;
  v_months  integer;
  v_step    integer;
  v_days    numeric;
  v_k       integer;
  v_lo      timestamptz;
  v_hi      timestamptz;
  v_guard   integer := 0;
begin
  if p_at is null or p_interval is null or p_interval_count is null then
    return null;
  end if;
  v_anchor := coalesce(p_current_period_end, p_started_at, p_created_at);
  if v_anchor is null then
    return null;
  end if;
  if p_current_period_end is not null and p_started_at is not null
     and p_started_at <= p_current_period_end then
    -- is the period end a whole number of periods after started_at?
    if p_interval = 'week' then
      v_k := round(extract(epoch from (p_current_period_end - p_started_at)) / (604800 * p_interval_count))::integer;
    else
      v_step := p_interval_count * case p_interval when 'month' then 1 else 12 end;
      v_months := (extract(year from p_current_period_end at time zone 'UTC')
                   - extract(year from p_started_at at time zone 'UTC'))::integer * 12
                + (extract(month from p_current_period_end at time zone 'UTC')
                   - extract(month from p_started_at at time zone 'UTC'))::integer;
      v_k := case when v_months % v_step = 0 then v_months / v_step end;
    end if;
    if v_k is not null
       and public.membership_add_periods(p_started_at, p_interval, p_interval_count, v_k) = p_current_period_end then
      v_anchor := p_started_at;
    end if;
  end if;
  v_days := case p_interval when 'week' then 7 when 'month' then 30.436875 else 365.2425 end * p_interval_count;
  v_k := floor(extract(epoch from (p_at - v_anchor)) / (v_days * 86400))::integer;
  loop
    v_guard := v_guard + 1;
    v_lo := public.membership_add_periods(v_anchor, p_interval, p_interval_count, v_k);
    v_hi := public.membership_add_periods(v_anchor, p_interval, p_interval_count, v_k + 1);
    exit when (p_at >= v_lo and p_at < v_hi) or v_guard > 10;
    if p_at < v_lo then v_k := v_k - 1; else v_k := v_k + 1; end if;
  end loop;
  return tstzrange(v_lo, v_hi, '[)');
end
$$;

comment on function public.membership_period_bounds_of(timestamptz, timestamptz, timestamptz, public.membership_interval, integer, timestamptz) is
  'Internal (0111): the billing period containing p_at for a membership with these values (the rules of membership_period_bounds, 0069).';
revoke execute on function public.membership_period_bounds_of(timestamptz, timestamptz, timestamptz, public.membership_interval, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function public.membership_period_bounds_of(timestamptz, timestamptz, timestamptz, public.membership_interval, integer, timestamptz)
  to service_role;

create or replace function public.membership_period_bounds(p_membership_id uuid, p_at timestamptz) returns tstzrange
language plpgsql stable
set search_path = ''
as $$
declare
  v_m public.memberships;
begin
  select * into v_m from public.memberships m where m.id = p_membership_id;
  if not found or p_at is null then
    return null;
  end if;
  return public.membership_period_bounds_of(v_m.started_at, v_m.current_period_end, v_m.created_at,
                                            v_m.interval, v_m.interval_count, p_at);
end
$$;

-- ---------------------------------------------------------------------------
-- memberships.paid_through + memberships_40_paid_through
-- ---------------------------------------------------------------------------
alter table public.memberships add column paid_through timestamptz;

comment on column public.memberships.paid_through is
  'Server-maintained (0111): the end of the last billing period the member paid for — current_period_end while active; the start of the unpaid period while past_due; kept when cancelled; null when never paid. Visits from here on are repriced when the membership goes past_due or is cancelled.';

create function public.memberships_paid_through() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_prev   timestamptz := case when tg_op = 'UPDATE' then old.paid_through end;
  v_start  timestamptz;
begin
  if new.status = 'active' then
    new.paid_through := coalesce(new.current_period_end, v_prev);
  elsif new.status = 'past_due' then
    if new.current_period_end is not null then
      v_start := lower(public.membership_period_bounds_of(new.started_at, new.current_period_end, new.created_at,
                                                          new.interval, new.interval_count,
                                                          new.current_period_end - interval '1 microsecond'));
    end if;
    new.paid_through := least(v_prev, v_start);   -- least() ignores nulls
  elsif new.status = 'cancelled' then
    new.paid_through := case when tg_op = 'UPDATE' and old.status = 'active'
                             then coalesce(v_prev, old.current_period_end) else v_prev end;
  else
    new.paid_through := null;
  end if;
  return new;
end
$$;

comment on function public.memberships_paid_through() is
  'Internal (0111): maintains memberships.paid_through from the status and billing period (see the column).';
revoke execute on function public.memberships_paid_through() from public, anon, authenticated;

create trigger memberships_40_paid_through before insert or update on public.memberships
  for each row execute function public.memberships_paid_through();

-- ---------------------------------------------------------------------------
-- memberships_zz_money_reprice (0108) — + past_due; cutoff = paid_through
-- ---------------------------------------------------------------------------
create or replace function public.memberships_money_reprice_uncovered() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  -- 0111: an active (ending) membership is paid through its period end; a
  -- past_due or cancelled one only through paid_through (never paid: now)
  v_cutoff    timestamptz := case when new.status = 'active' then coalesce(new.current_period_end, now())
                                  else coalesce(new.paid_through, now()) end;
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
           when new.status = 'past_due' then 'Membership payment failed: booked visits after the paid period need paying'
           else 'Membership ending: booked visits after it need paying' end,
      v_body, null, null, p_customer_id => new.customer_id);
  exception when others then
    raise warning 'membership reprice notification failed for membership %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

comment on function public.memberships_money_reprice_uncovered() is
  'Internal (0108; 0111): when a membership starts ending, goes past_due or is cancelled, its included lines on open jobs starting on or after the paid period''s end (current_period_end while active; paid_through when past_due / cancelled) are charged the catalog price (billed or unpriced ones are listed in a manager notification instead).';

drop trigger memberships_zz_money_reprice on public.memberships;
create trigger memberships_zz_money_reprice
  after update of status, cancel_at_period_end, current_period_end, paid_through on public.memberships
  for each row
  when ((new.status = 'cancelled' and old.status is distinct from 'cancelled')
        or (new.status = 'past_due'
            and (old.status is distinct from 'past_due' or new.paid_through is distinct from old.paid_through))
        or (new.status = 'active' and new.cancel_at_period_end
            and (not old.cancel_at_period_end or old.status is distinct from 'active'
                 or new.current_period_end is distinct from old.current_period_end)))
  execute function public.memberships_money_reprice_uncovered();

-- ---------------------------------------------------------------------------
-- Backfill, with the rules above (a membership cancelled before 0111 keeps
-- its last period end when it had started). A membership already past_due
-- has its visits of the unpaid period repriced now (memberships_zz_money_
-- reprice fires on the new paid_through), as its next webhook would.
-- ---------------------------------------------------------------------------
alter table public.memberships disable trigger memberships_40_paid_through;
update public.memberships m
   set paid_through = case m.status
         when 'active' then m.current_period_end
         when 'past_due' then lower(public.membership_period_bounds_of(
                                m.started_at, m.current_period_end, m.created_at, m.interval, m.interval_count,
                                m.current_period_end - interval '1 microsecond'))
         when 'cancelled' then case when m.started_at is not null then m.current_period_end end
       end
 where m.status <> 'incomplete' and m.current_period_end is not null;
alter table public.memberships enable trigger memberships_40_paid_through;
