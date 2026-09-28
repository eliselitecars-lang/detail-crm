-- ============================================================================
-- 0065 — Tips per technician, service and sales commissions, sold-by, and
-- the per-job earnings drill-down (P-12). Report-derived (no ledger): the
-- numbers are computed from completed jobs, their lines and payments.
--
-- Per job completed in the range (completed_at, shop time zone):
--   line net           line total minus the job's document discount allocated
--                      over its discount-eligible lines in line order
--                      (cumulative rounding: share_i = round(D·cum_i/E) −
--                      round(D·cum_{i−1}/E), shares add up to exactly D)
--   commission base    Σ net of lines whose service has no service commission
--                      (member commission_bps applies to this, not to lines
--                      paid by a service commission)
--   service commission percent: round(net × bps / 10000) per line;
--                      flat: round(value × quantity) per line
--   tips               Σ net tips (payment_net_tip) of received payments of
--                      the job; tips on a grouped invoice's own payments are
--                      split across its jobs in proportion to the job totals
--                      (largest remainder)
--   revenue / pre-tax revenue / commission base / service commission / tips
--   are split evenly among the job's assignees; remainders go one cent each
--   to the earliest assignments (created_at, id), as before.
--   sales base         the job's pre-tax revenue, credited to
--                      jobs.sold_by_member_id (not split)
-- Per member: commission = round(Σ commission base × commission_bps / 10000),
-- sales commission = round(Σ sales base × sales_commission_bps / 10000),
-- total earnings = labor cost + commission + service commission + sales
-- commission + tips. report_member_earnings allocates the two rounded
-- totals over the jobs cumulatively, so its rows add up to report_team's.
-- Service commission rates are read at report time (not snapshotted).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- jobs.sold_by_member_id defaults to the member creating the job (staff
-- jobs; quote conversion sets the quote creator explicitly); online
-- bookings have none. A recurring-series occurrence is credited to the
-- series creator's membership (job_series.created_by) whoever inserts it —
-- the manager creating the series, the nightly generator (no auth.uid()) or
-- another manager's "this and following" edit — so every visit of a series
-- earns its seller the same sales commission (a deactivated seller keeps
-- the credit, as a converted quote's creator does; none once the creator's
-- account is deleted: created_by ON DELETE SET NULL). Managers+ may
-- change it (jobs_client_guard keeps technicians off every column but
-- status / internal notes). Only the series RPCs can insert a job with
-- series_id (jobs_50_series_guard).
-- ---------------------------------------------------------------------------
create function public.jobs_money_sold_by_default() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.sold_by_member_id is not null then
    return new;
  end if;
  if new.series_id is not null then
    select m.id into new.sold_by_member_id
      from public.job_series js
      join public.shop_members m on m.shop_id = js.shop_id and m.user_id = js.created_by
     where js.id = new.series_id and js.shop_id = new.shop_id;
  elsif new.source <> 'online_booking' and auth.uid() is not null then
    select m.id into new.sold_by_member_id
      from public.shop_members m
     where m.shop_id = new.shop_id and m.user_id = auth.uid() and m.active;
  end if;
  return new;
end
$$;

create trigger jobs_60_sold_by_default before insert on public.jobs
  for each row execute function public.jobs_money_sold_by_default();

-- Service commission rates are pay settings: owners / admins only (services
-- themselves are managed by managers+).
create function public.services_money_commission_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() and not public.is_shop_admin(new.shop_id)
     and ((tg_op = 'INSERT' and (new.commission_kind <> 'none' or new.commission_value <> 0))
          or (tg_op = 'UPDATE' and (new.commission_kind, new.commission_value)
                                   is distinct from (old.commission_kind, old.commission_value))) then
    raise exception 'only owners and admins can set service commissions' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger services_60_money_commission_guard before insert or update on public.services
  for each row execute function public.services_money_commission_guard();

-- ---------------------------------------------------------------------------
-- report_team_job_rows — INTERNAL (definer report RPCs only): one row per
-- (member, completed job in [p_start, p_end)) with the member's shares (see
-- the header). is_assignee = the member is assigned; sales_base > 0 only for
-- the job's seller.
-- ---------------------------------------------------------------------------
create function public.report_team_job_rows(p_shop_id uuid, p_start timestamptz, p_end timestamptz)
returns table (
  member_id              uuid,
  job_id                 uuid,
  is_assignee            boolean,
  revenue_share          bigint,
  pre_tax_share          bigint,
  commission_base_share  bigint,
  service_commission     bigint,
  tips                   bigint,
  sales_base             bigint
)
language sql stable
set search_path = ''
as $$
  with done as (
    select j.id, j.total_cents, (j.subtotal_cents - j.discount_cents) as pre_tax, j.discount_cents as d,
           j.sold_by_member_id
    from public.jobs j
    where j.shop_id = p_shop_id
      and j.status = 'completed'
      and j.completed_at >= p_start
      and j.completed_at < p_end
  ), lines as (
    select li.job_id, li.quantity, li.total_cents as t, li.discount_eligible as elig,
           coalesce(s.commission_kind, 'none') as ck, coalesce(s.commission_value, 0) as cv, d.d,
           sum(li.total_cents) filter (where li.discount_eligible) over (partition by li.job_id) as e,
           sum(li.total_cents) filter (where li.discount_eligible)
             over (partition by li.job_id order by li.sort, li.created_at, li.id
                   rows between unbounded preceding and current row) as cum
    from done d
    join public.job_line_items li on li.shop_id = p_shop_id and li.job_id = d.id
    left join public.services s on s.shop_id = p_shop_id and s.id = li.service_id
  ), nets as (
    select l.job_id, l.quantity, l.ck, l.cv,
           l.t - case when l.elig and l.e > 0 and l.d > 0
                      then round(l.d::numeric * l.cum / l.e)::bigint
                         - round(l.d::numeric * (l.cum - l.t) / l.e)::bigint
                      else 0 end as net
    from lines l
  ), job_comm as (
    select n.job_id,
           coalesce(sum(n.net) filter (where n.ck = 'none'), 0)::bigint as cbase,
           coalesce(sum(case n.ck
                          when 'percent' then round(n.net::numeric * n.cv / 10000)
                          when 'flat' then round(n.cv * n.quantity)
                          else 0 end), 0)::bigint as svc
    from nets n
    group by n.job_id
  ), received as (
    select p.job_id, p.invoice_id,
           public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as tip
    from public.payments p
    where p.shop_id = p_shop_id
      and p.status in ('succeeded', 'partially_refunded', 'refunded')
      and p.tip_cents > 0
  ), direct_tips as (
    select r.job_id, sum(r.tip)::bigint as tip
    from received r join done d on d.id = r.job_id
    group by r.job_id
  ), grouped_pool as (
    -- tips paid on a grouped invoice itself (no job on the payment)
    select r.invoice_id, sum(r.tip)::bigint as tip
    from received r
    join public.invoices i on i.id = r.invoice_id and i.shop_id = p_shop_id and i.job_id is null
    where r.job_id is null
    group by r.invoice_id
  ), grouped_jobs as (
    select gp.invoice_id, gp.tip, ij.job_id, j.total_cents as w, j.number,
           sum(j.total_cents) over (partition by gp.invoice_id) as wsum,
           count(*) over (partition by gp.invoice_id) as cnt
    from grouped_pool gp
    join public.invoice_jobs ij on ij.invoice_id = gp.invoice_id and ij.shop_id = p_shop_id
    join public.jobs j on j.id = ij.job_id and j.shop_id = p_shop_id
  ), grouped_floor as (
    select g.*,
           case when g.wsum > 0 then (g.tip * g.w) / g.wsum::bigint else g.tip / g.cnt end as base,
           case when g.wsum > 0 then (g.tip * g.w) % g.wsum::bigint else g.tip % g.cnt end as rem
    from grouped_jobs g
  ), grouped_tips as (
    select x.job_id,
           sum(x.base + case when x.rn <= x.leftover then 1 else 0 end)::bigint as tip
    from (select f.*,
                 f.tip - sum(f.base) over (partition by f.invoice_id) as leftover,
                 row_number() over (partition by f.invoice_id order by f.rem desc, f.number) as rn
            from grouped_floor f) x
    group by x.job_id
  ), job_totals as (
    select d.id, d.total_cents, d.pre_tax, d.sold_by_member_id,
           coalesce(c.cbase, 0) as cbase, coalesce(c.svc, 0) as svc,
           coalesce(dt.tip, 0) + coalesce(gt.tip, 0) as tip
    from done d
    left join job_comm c on c.job_id = d.id
    left join direct_tips dt on dt.job_id = d.id
    left join grouped_tips gt on gt.job_id = d.id
  ), split as (
    select ja.member_id as mid, jt.*,
           count(*) over (partition by jt.id) as n,
           row_number() over (partition by jt.id order by ja.created_at, ja.id) as rn
    from job_totals jt
    join public.job_assignments ja on ja.shop_id = p_shop_id and ja.job_id = jt.id
  ), parts as (
    select sp.mid, sp.id as jid, true as assignee,
           sp.total_cents / sp.n + case when sp.rn <= sp.total_cents % sp.n then 1 else 0 end as rev,
           sp.pre_tax / sp.n + case when sp.rn <= sp.pre_tax % sp.n then 1 else 0 end as pre,
           sp.cbase / sp.n + case when sp.rn <= sp.cbase % sp.n then 1 else 0 end as cbase,
           sp.svc / sp.n + case when sp.rn <= sp.svc % sp.n then 1 else 0 end as svc,
           sp.tip / sp.n + case when sp.rn <= sp.tip % sp.n then 1 else 0 end as tip,
           0::bigint as sales
    from split sp
    union all
    select jt.sold_by_member_id, jt.id, false, 0, 0, 0, 0, 0, jt.pre_tax
    from job_totals jt
    where jt.sold_by_member_id is not null
  )
  select p.mid, p.jid, bool_or(p.assignee),
         sum(p.rev)::bigint, sum(p.pre)::bigint, sum(p.cbase)::bigint, sum(p.svc)::bigint, sum(p.tip)::bigint,
         sum(p.sales)::bigint
  from parts p
  group by p.mid, p.jid
$$;

-- ---------------------------------------------------------------------------
-- report_team — same arguments and visibility as 0048; new columns:
--   tips_cents, service_commission_cents, sales_commission_cents,
--   total_earnings_cents (pay columns: null for managers, technicians see
--   only their own row). commission_cents now excludes lines paid by a
--   service commission.
-- ---------------------------------------------------------------------------
drop function public.report_team(uuid, date, date, timestamptz);

create function public.report_team(
  p_shop_id  uuid,
  p_from     date,
  p_to       date,
  p_now      timestamptz default now()
) returns table (
  member_id                 uuid,
  display_name              text,
  role                      public.shop_role,
  active                    boolean,
  worked_seconds            bigint,
  hours                     numeric,
  jobs_completed            bigint,
  revenue_cents             bigint,
  pre_tax_revenue_cents     bigint,
  hourly_rate_cents         bigint,
  commission_bps            integer,
  commission_cents          bigint,
  labor_cost_cents          bigint,
  tips_cents                bigint,
  service_commission_cents  bigint,
  sales_commission_cents    bigint,
  total_earnings_cents      bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role  public.shop_role := public.report_caller_role(p_shop_id, true);
  v_self  uuid := public.report_caller_member(p_shop_id);
  v_tz    text;
  v_s     timestamptz;
  v_e     timestamptz;
begin
  perform public.report_check_range(p_from, p_to);
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  return query
  with clipped as (
    select t.member_id as mid,
           greatest(t.clock_in, v_s) as lo,
           least(coalesce(t.clock_out, p_now), v_e) as hi
    from public.time_entries t
    where t.shop_id = p_shop_id
      and t.clock_in < v_e
      and coalesce(t.clock_out, p_now) > v_s
  ), worked as (
    select x.mid, sum(extract(epoch from (upper(r) - lower(r))))::bigint as secs
    from (select c.mid, range_agg(tstzrange(c.lo, c.hi, '[)')) as mr
          from clipped c
          where c.lo < c.hi
          group by c.mid) x
    cross join lateral unnest(x.mr) as r
    group by x.mid
  ), attributed as (
    select jr.member_id as mid,
           count(*) filter (where jr.is_assignee) as jobs,
           sum(jr.revenue_share)::bigint as rev,
           sum(jr.pre_tax_share)::bigint as pre,
           sum(jr.commission_base_share)::bigint as cbase,
           sum(jr.service_commission)::bigint as svc,
           sum(jr.tips)::bigint as tips,
           sum(jr.sales_base)::bigint as sales
    from public.report_team_job_rows(p_shop_id, v_s, v_e) jr
    group by jr.member_id
  ), rows_ as (
    select m.id as mid, m.display_name as dn, m.role as rl, m.active as act,
           coalesce(w.secs, 0) as secs,
           coalesce(a.jobs, 0) as jobs,
           coalesce(a.rev, 0) as rev,
           coalesce(a.pre, 0) as pre,
           coalesce(a.cbase, 0) as cbase,
           coalesce(a.svc, 0) as svc,
           coalesce(a.tips, 0) as tips,
           coalesce(a.sales, 0) as sales,
           coalesce(mc.hourly_rate_cents, 0) as rate,
           coalesce(mc.commission_bps, 0) as bps,
           coalesce(mc.sales_commission_bps, 0) as sales_bps,
           (v_role in ('owner', 'admin') or (v_role = 'technician' and m.id = v_self)) as show_pay
    from public.shop_members m
    left join worked w on w.mid = m.id
    left join attributed a on a.mid = m.id
    left join public.member_compensation mc on mc.shop_id = m.shop_id and mc.member_id = m.id
    where m.shop_id = p_shop_id
      and (m.active or w.secs > 0 or a.jobs > 0 or a.sales > 0)
      and (v_role <> 'technician' or m.id = v_self)
  ), pay as (
    select r.*,
           round(r.cbase::numeric * r.bps / 10000)::bigint as comm,
           round(r.secs::numeric * r.rate / 3600)::bigint as labor,
           round(r.sales::numeric * r.sales_bps / 10000)::bigint as sales_comm
    from rows_ r
  )
  select p.mid, p.dn, p.rl, p.act,
         p.secs,
         round(p.secs / 3600.0, 2),
         p.jobs, p.rev, p.pre,
         case when p.show_pay then p.rate end,
         case when p.show_pay then p.bps end,
         case when p.show_pay then p.comm end,
         case when p.show_pay then p.labor end,
         case when p.show_pay then p.tips end,
         case when p.show_pay then p.svc end,
         case when p.show_pay then p.sales_comm end,
         case when p.show_pay then p.labor + p.comm + p.svc + p.sales_comm + p.tips end
  from pay p
  order by p.act desc, p.dn, p.mid;
end
$$;

comment on function public.report_team(uuid, date, date, timestamptz) is
  'Per-member hours, completed jobs, attributed revenue, commission, labor cost, tips, service / sales commission and total earnings. Managers: pay columns null; technicians: own row. @nullable: hourly_rate_cents, commission_bps, commission_cents, labor_cost_cents, tips_cents, service_commission_cents, sales_commission_cents, total_earnings_cents';

-- ---------------------------------------------------------------------------
-- report_member_earnings — the jobs behind one member's report_team row:
-- one row per completed job in [p_from, p_to] (shop time zone) the member
-- is assigned to or sold. revenue_share_cents = the member's pre-tax
-- revenue share; commission / sales commission are the member's rounded
-- totals allocated over the jobs (completed_at, id) with cumulative
-- rounding, so every money column adds up to the member's report_team row.
-- hours = the member's job time entries on that job (open ones until now).
-- Owners / admins: any member; managers and technicians: only themselves
-- (42501 otherwise). A member id not of this shop: P0002.
-- customer_label follows the customers RLS (SPEC §3): owners / admins /
-- managers always see it; a technician only for a customer of a job assigned
-- to them (is_customer_on_assigned_job). A seller who is not assigned keeps
-- the job's money row (sales commission), job number and completion time,
-- but gets customer_label null — pay reporting must not become a way around
-- the customer RLS.
-- ---------------------------------------------------------------------------
create function public.report_member_earnings(p_shop_id uuid, p_member_id uuid, p_from date, p_to date)
returns table (
  job_id                    uuid,
  job_number                bigint,
  completed_at              timestamptz,
  customer_label            text,
  hours                     numeric,
  revenue_share_cents       bigint,
  commission_cents          bigint,
  service_commission_cents  bigint,
  sales_commission_cents    bigint,
  tips_cents                bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role   public.shop_role := public.report_caller_role(p_shop_id, true);
  v_self   uuid := public.report_caller_member(p_shop_id);
  v_tz     text;
  v_s      timestamptz;
  v_e      timestamptz;
  v_bps    integer;
  v_sbps   integer;
begin
  perform public.report_check_range(p_from, p_to);
  if not exists (select 1 from public.shop_members m where m.id = p_member_id and m.shop_id = p_shop_id) then
    raise exception 'team member not found' using errcode = 'P0002';
  end if;
  if v_role not in ('owner', 'admin') and p_member_id is distinct from v_self then
    raise exception 'you can only see your own earnings' using errcode = '42501';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);
  select coalesce(mc.commission_bps, 0), coalesce(mc.sales_commission_bps, 0) into v_bps, v_sbps
    from public.shop_members m
    left join public.member_compensation mc on mc.shop_id = m.shop_id and mc.member_id = m.id
   where m.id = p_member_id and m.shop_id = p_shop_id;

  return query
  with mine as (
    select jr.*, j.number, j.completed_at as done_at, j.customer_id,
           sum(jr.commission_base_share) over w as cum_c,
           sum(jr.sales_base) over w as cum_s
    from public.report_team_job_rows(p_shop_id, v_s, v_e) jr
    join public.jobs j on j.id = jr.job_id and j.shop_id = p_shop_id
    where jr.member_id = p_member_id
    window w as (order by j.completed_at, j.id rows between unbounded preceding and current row)
  )
  select x.job_id, x.number, x.done_at,
         case when v_role in ('owner', 'admin', 'manager') or public.is_customer_on_assigned_job(x.customer_id)
              then public.report_customer_label(c.first_name, c.last_name, c.company) end,
         coalesce((select round(sum(extract(epoch from (coalesce(t.clock_out, now()) - t.clock_in))) / 3600.0, 2)
                     from public.time_entries t
                    where t.shop_id = p_shop_id and t.member_id = p_member_id and t.job_id = x.job_id
                      and t.kind = 'job'), 0),
         x.pre_tax_share,
         (round(x.cum_c::numeric * v_bps / 10000) - round((x.cum_c - x.commission_base_share)::numeric * v_bps / 10000))::bigint,
         x.service_commission,
         (round(x.cum_s::numeric * v_sbps / 10000) - round((x.cum_s - x.sales_base)::numeric * v_sbps / 10000))::bigint,
         x.tips
  from mine x
  left join public.customers c on c.id = x.customer_id and c.shop_id = p_shop_id
  order by x.done_at, x.job_id;
end
$$;

comment on function public.report_member_earnings(uuid, uuid, date, date) is
  'Per-job earnings of one member (report_team drill-down): pre-tax revenue share, commission, service / sales commission, tips, hours. Owners/admins any member; others only themselves. customer_label is null for a technician unless the customer is on a job assigned to them (customers RLS). @nullable: customer_label';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.jobs_money_sold_by_default(),
  public.services_money_commission_guard()
from public, anon, authenticated;

revoke execute on function public.report_team_job_rows(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.report_team_job_rows(uuid, timestamptz, timestamptz) to service_role;

revoke execute on function
  public.report_team(uuid, date, date, timestamptz),
  public.report_member_earnings(uuid, uuid, date, date)
from public, anon;
grant execute on function
  public.report_team(uuid, date, date, timestamptz),
  public.report_member_earnings(uuid, uuid, date, date)
to authenticated, service_role;
