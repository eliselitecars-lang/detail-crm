-- ============================================================================
-- 0048 — Work (accrual) reports (SPEC §4.8): report_sales_by_service,
-- report_team, report_customers.
--
-- Basis: COMPLETED JOBS dated by completed_at in the shop time zone —
-- work delivered in the period, independent of when it is paid (cash lives
-- in report_revenue / report_payments). Using jobs for all three keeps them
-- consistent: Σ sales-by-service net = Σ completed jobs' pre-tax revenue =
-- Σ team pre-tax attribution (for jobs with at least one assignee).
--   pre-tax revenue of a job = subtotal − document discount (tax excluded)
--   a line's share of the document discount is allocated cumulatively in
--   line order (sort, created_at, id): share_i = round(D·cum_i/S) −
--   round(D·cum_{i−1}/S), so shares always add up to exactly D.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- report_sales_by_service — owner/admin/manager. One row per catalog
-- service (current name / category) and one per distinct custom line name
-- (service_id null). quantity = Σ line quantity; jobs_count = distinct jobs;
-- gross = Σ line totals (after line discounts); discount = allocated
-- document discount; net = gross − discount (pre-tax). Ordered by net desc.
-- ---------------------------------------------------------------------------
create function public.report_sales_by_service(p_shop_id uuid, p_from date, p_to date)
returns table (
  service_id      uuid,
  service_name    text,
  service_kind    public.service_kind,
  category_id     uuid,
  category_name   text,
  quantity        numeric,
  jobs_count      bigint,
  gross_cents     bigint,
  discount_cents  bigint,
  net_cents       bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tz text;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;

  return query
  with done as (
    select j.id, j.subtotal_cents, j.discount_cents
    from public.jobs j
    where j.shop_id = p_shop_id
      and j.status = 'completed'
      and j.completed_at >= public.report_local_start(p_from, v_tz)
      and j.completed_at < public.report_local_start(p_to + 1, v_tz)
  ), lines as (
    select li.job_id, li.service_id as svc_id, li.name, li.quantity, li.total_cents as line_total,
           d.subtotal_cents as doc_subtotal, d.discount_cents as doc_discount,
           sum(li.total_cents) over (partition by li.job_id
                                     order by li.sort, li.created_at, li.id
                                     rows between unbounded preceding and current row) as cum
    from done d
    join public.job_line_items li on li.shop_id = p_shop_id and li.job_id = d.id
  ), alloc as (
    select l.*,
           case when l.doc_subtotal > 0 and l.doc_discount > 0
                then round(l.doc_discount::numeric * l.cum / l.doc_subtotal)::bigint
                   - round(l.doc_discount::numeric * (l.cum - l.line_total) / l.doc_subtotal)::bigint
                else 0 end as line_discount,
           case when l.svc_id is null then lower(btrim(l.name)) end as custom_key
    from lines l
  )
  select a.svc_id,
         coalesce(s.name, min(a.name)),
         s.kind,
         sc.id,
         sc.name,
         sum(a.quantity),
         count(distinct a.job_id),
         sum(a.line_total)::bigint,
         sum(a.line_discount)::bigint,
         (sum(a.line_total) - sum(a.line_discount))::bigint
  from alloc a
  left join public.services s on s.shop_id = p_shop_id and s.id = a.svc_id
  left join public.service_categories sc on sc.shop_id = p_shop_id and sc.id = s.category_id
  group by a.svc_id, a.custom_key, s.name, s.kind, sc.id, sc.name
  order by 10 desc, 2, 1;
end
$$;

-- ---------------------------------------------------------------------------
-- report_team — per member for [p_from, p_to] (p_now caps open time entries):
--   worked_seconds / hours   union of the member's time entries (shift and
--                            job entries together, so job time inside a shift
--                            is not double counted) clipped to the range;
--                            open entries run until p_now
--   jobs_completed           completed jobs in range the member is assigned to
--   revenue_cents            Σ job total_cents split evenly among assignees
--   pre_tax_revenue_cents    Σ (subtotal − discount) split evenly
--                            (split remainders go one cent each to the
--                            earliest assignments: created_at, id)
--   hourly_rate_cents, commission_bps   member_compensation (0 when unset)
--   commission_cents         round(pre_tax_revenue × commission_bps / 10000)
--   labor_cost_cents         round(worked_seconds × hourly_rate / 3600)
-- Rows: active members plus inactive members with hours or jobs in range.
-- Visibility: owner/admin all rows with pay; manager all rows with the four
-- pay columns null (member_compensation is owner/admin only, SPEC §3);
-- technician only their own row, including their own pay.
-- ---------------------------------------------------------------------------
create function public.report_team(
  p_shop_id  uuid,
  p_from     date,
  p_to       date,
  p_now      timestamptz default now()
) returns table (
  member_id              uuid,
  display_name           text,
  role                   public.shop_role,
  active                 boolean,
  worked_seconds         bigint,
  hours                  numeric,
  jobs_completed         bigint,
  revenue_cents          bigint,
  pre_tax_revenue_cents  bigint,
  hourly_rate_cents      bigint,
  commission_bps         integer,
  commission_cents       bigint,
  labor_cost_cents       bigint
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
  ), done as (
    select j.id, j.total_cents, (j.subtotal_cents - j.discount_cents) as pre_tax
    from public.jobs j
    where j.shop_id = p_shop_id
      and j.status = 'completed'
      and j.completed_at >= v_s
      and j.completed_at < v_e
  ), split as (
    select ja.member_id as mid, d.id as job_id, d.total_cents, d.pre_tax,
           count(*) over (partition by d.id) as n,
           row_number() over (partition by d.id order by ja.created_at, ja.id) as rn
    from done d
    join public.job_assignments ja on ja.shop_id = p_shop_id and ja.job_id = d.id
  ), attributed as (
    select sp.mid,
           count(*) as jobs,
           sum(sp.total_cents / sp.n + case when sp.rn <= sp.total_cents % sp.n then 1 else 0 end)::bigint as rev,
           sum(sp.pre_tax / sp.n + case when sp.rn <= sp.pre_tax % sp.n then 1 else 0 end)::bigint as pre
    from split sp
    group by sp.mid
  ), rows_ as (
    select m.id as mid, m.display_name as dn, m.role as rl, m.active as act,
           coalesce(w.secs, 0) as secs,
           coalesce(a.jobs, 0) as jobs,
           coalesce(a.rev, 0) as rev,
           coalesce(a.pre, 0) as pre,
           coalesce(mc.hourly_rate_cents, 0) as rate,
           coalesce(mc.commission_bps, 0) as bps,
           (v_role in ('owner', 'admin') or (v_role = 'technician' and m.id = v_self)) as show_pay
    from public.shop_members m
    left join worked w on w.mid = m.id
    left join attributed a on a.mid = m.id
    left join public.member_compensation mc on mc.shop_id = m.shop_id and mc.member_id = m.id
    where m.shop_id = p_shop_id
      and (m.active or w.secs > 0 or a.jobs > 0)
      and (v_role <> 'technician' or m.id = v_self)
  )
  select r.mid, r.dn, r.rl, r.act,
         r.secs,
         round(r.secs / 3600.0, 2),
         r.jobs, r.rev, r.pre,
         case when r.show_pay then r.rate end,
         case when r.show_pay then r.bps end,
         case when r.show_pay then round(r.pre::numeric * r.bps / 10000)::bigint end,
         case when r.show_pay then round(r.secs::numeric * r.rate / 3600)::bigint end
  from rows_ r
  order by r.act desc, r.dn, r.mid;
end
$$;

-- ---------------------------------------------------------------------------
-- report_customers — owner/admin/manager. jsonb:
--   customers_served     distinct customers with a completed job in range
--   new_customers        … whose first-ever completed job is in the range
--   returning_customers  … who had a completed job before the range
--   customers_created    customer records created in the range
--   completed_jobs, average_ticket_cents (mean job total incl. tax, rounded)
--   top_customers        up to p_limit customers ranked by lifetime net paid
--                        (Σ net payment amounts, tips excluded, paid up to the
--                        end of the range), with lifetime completed jobs and
--                        last completed visit; customers with nothing paid
--                        are omitted
-- ---------------------------------------------------------------------------
create function public.report_customers(p_shop_id uuid, p_from date, p_to date, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tz      text;
  v_s       timestamptz;
  v_e       timestamptz;
  v_result  jsonb;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  with done as (
    select j.id, j.customer_id, j.total_cents
    from public.jobs j
    where j.shop_id = p_shop_id and j.status = 'completed'
      and j.completed_at >= v_s and j.completed_at < v_e
  ), served as (
    select distinct d.customer_id,
           exists (select 1 from public.jobs e
                   where e.shop_id = p_shop_id and e.customer_id = d.customer_id
                     and e.status = 'completed' and e.completed_at < v_s) as returning_
    from done d
  ), lifetime as (
    select p.customer_id,
           sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))::bigint as net_paid
    from public.payments p
    where p.shop_id = p_shop_id
      and p.status in ('succeeded', 'partially_refunded', 'refunded')
      and p.paid_at < v_e
    group by p.customer_id
  ), top_ as (
    select c.id, public.report_customer_label(c.first_name, c.last_name, c.company) as name,
           l.net_paid,
           (select count(*) from public.jobs e
             where e.shop_id = p_shop_id and e.customer_id = c.id
               and e.status = 'completed' and e.completed_at < v_e) as jobs,
           (select max(e.completed_at) from public.jobs e
             where e.shop_id = p_shop_id and e.customer_id = c.id
               and e.status = 'completed' and e.completed_at < v_e) as last_visit
    from lifetime l
    join public.customers c on c.shop_id = p_shop_id and c.id = l.customer_id
    where l.net_paid > 0
    order by l.net_paid desc, name, c.id
    limit p_limit
  )
  select jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'timezone', v_tz,
    'customers_served', (select count(*) from served),
    'new_customers', (select count(*) from served where not returning_),
    'returning_customers', (select count(*) from served where returning_),
    'customers_created', (select count(*) from public.customers c
                           where c.shop_id = p_shop_id and c.created_at >= v_s and c.created_at < v_e),
    'completed_jobs', (select count(*) from done),
    'average_ticket_cents', (select round(avg(d.total_cents))::bigint from done d),
    'top_customers', (select coalesce(jsonb_agg(jsonb_build_object(
                                        'customer_id', t.id,
                                        'name', t.name,
                                        'lifetime_net_cents', t.net_paid,
                                        'completed_jobs', t.jobs,
                                        'last_completed_at', t.last_visit)
                                      order by t.net_paid desc, t.name, t.id), '[]'::jsonb)
                        from top_ t))
    into v_result;
  return v_result;
end
$$;

comment on function public.report_sales_by_service(uuid, date, date) is
  'Completed-job sales per service / custom line: quantity, jobs, gross, allocated discount, pre-tax net.';
comment on function public.report_team(uuid, date, date, timestamptz) is
  'Per-member hours, completed jobs, attributed revenue, commission and labor cost. Managers: pay columns null; technicians: own row.';
comment on function public.report_customers(uuid, date, date, integer) is
  'New vs returning customers, customers created, average ticket and top customers by lifetime net paid.';

revoke execute on function
  public.report_sales_by_service(uuid, date, date),
  public.report_team(uuid, date, date, timestamptz),
  public.report_customers(uuid, date, date, integer)
from public, anon;
grant execute on function
  public.report_sales_by_service(uuid, date, date),
  public.report_team(uuid, date, date, timestamptz),
  public.report_customers(uuid, date, date, integer)
to authenticated, service_role;
