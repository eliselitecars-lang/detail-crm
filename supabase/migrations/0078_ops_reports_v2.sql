-- ============================================================================
-- 0078 — Reports v2 (P-33 lead sources and quote conversion; P-28 job and
-- service profit). Conventions of 0045: SECURITY DEFINER, owner/admin/
-- manager only (technicians and outsiders 42501), inclusive local date
-- ranges [p_from, p_to] in the shop's time zone (report_check_range, at most
-- 10 years), integer cents.
--
--   report_job_profit(shop, from, to)      completed jobs by completed_at:
--     revenue    pre-tax revenue = subtotal − document discount
--     materials  Σ consume movements × the product cost when consumed
--     labor      Σ job time entries (open ones until now) × the member's
--                hourly rate — pay data: owners/admins only; null for
--                managers, and so are profit and margin
--     profit = revenue − materials − labor; margin_bps = profit / revenue
--                (null when revenue is 0)
--   report_service_profit(shop, from, to)  per catalog service on those
--     jobs: revenue = the lines' pre-tax net (the document discount spread
--     over discount-eligible lines, as report_team does), materials = the
--     share of each consume movement the service used (allocation),
--     gross_profit = revenue − materials (no labor: time is per job).
--   report_lead_sources(shop, from, to)    customers created in range (not
--     merged duplicates) by source: converted = lifecycle 'customer' or a
--     completed job by the end of the range; leads = the rest (still open);
--     first_job_revenue = pre-tax revenue of each customer's first completed
--     job (through p_to); revenue = net received from them through p_to
--     (payment_net_amount: tips and refunds excluded).
--   report_quote_conversion(shop, from, to) quotes sent in range (by
--     sent_at): how many were viewed / approved (incl. converted) /
--     declined / expired / converted, approval rate, average quote and
--     approved totals, median hours from sent to approved, and per
--     shop-local month (every month of the range).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- report_job_profit
-- ---------------------------------------------------------------------------
create function public.report_job_profit(p_shop_id uuid, p_from date, p_to date)
returns table (
  job_id           uuid,
  job_number       bigint,
  completed_at     timestamptz,
  customer_label   text,
  revenue_cents    bigint,
  materials_cents  bigint,
  labor_cents      bigint,
  profit_cents     bigint,
  margin_bps       integer
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role  public.shop_role := public.report_caller_role(p_shop_id, false);
  v_pay   boolean;
  v_tz    text;
  v_s     timestamptz;
  v_e     timestamptz;
begin
  perform public.report_check_range(p_from, p_to);
  v_pay := v_role in ('owner', 'admin');
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  return query
  with done as (
    select j.id, j.number, j.completed_at, j.customer_id, (j.subtotal_cents - j.discount_cents) as rev
      from public.jobs j
     where j.shop_id = p_shop_id and j.status = 'completed'
       and j.completed_at >= v_s and j.completed_at < v_e
  ), mat as (
    select m.job_id, round(sum(-m.quantity * coalesce(m.unit_cost_cents, 0)))::bigint as cents
      from public.inventory_movements m
     where m.shop_id = p_shop_id and m.kind = 'consume' and m.job_id in (select d.id from done d)
     group by m.job_id
  ), lab as (
    select t.job_id,
           round(sum(greatest(extract(epoch from (coalesce(t.clock_out, now()) - t.clock_in)), 0)
                     * coalesce(mc.hourly_rate_cents, 0)) / 3600)::bigint as cents
      from public.time_entries t
      left join public.member_compensation mc on mc.member_id = t.member_id and mc.shop_id = t.shop_id
     where t.shop_id = p_shop_id and t.kind = 'job' and t.job_id in (select d.id from done d)
     group by t.job_id
  ), rows as (
    select d.*, coalesce(m.cents, 0) as mat_cents, case when v_pay then coalesce(l.cents, 0) end as lab_cents
      from done d
      left join mat m on m.job_id = d.id
      left join lab l on l.job_id = d.id
  )
  select r.id, r.number, r.completed_at,
         public.report_customer_label(c.first_name, c.last_name, c.company),
         r.rev, r.mat_cents, r.lab_cents,
         r.rev - r.mat_cents - r.lab_cents,
         case when r.rev > 0 and r.lab_cents is not null
              then round((r.rev - r.mat_cents - r.lab_cents) * 10000.0 / r.rev)::integer end
    from rows r
    join public.customers c on c.id = r.customer_id and c.shop_id = p_shop_id
   order by r.completed_at, r.number;
end
$$;

comment on function public.report_job_profit(uuid, date, date) is '@nullable: labor_cents, profit_cents, margin_bps';

-- ---------------------------------------------------------------------------
-- report_service_profit
-- ---------------------------------------------------------------------------
create function public.report_service_profit(p_shop_id uuid, p_from date, p_to date)
returns table (
  service_id          uuid,
  service_name        text,
  jobs_count          bigint,
  revenue_cents       bigint,
  materials_cents     bigint,
  gross_profit_cents  bigint,
  margin_bps          integer
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tz  text;
  v_s   timestamptz;
  v_e   timestamptz;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  return query
  with done as (
    select j.id, j.discount_cents as d
      from public.jobs j
     where j.shop_id = p_shop_id and j.status = 'completed'
       and j.completed_at >= v_s and j.completed_at < v_e
  ), lines as (
    select li.job_id, li.service_id as svc, li.name, li.total_cents as t, li.discount_eligible as elig, d.d,
           sum(li.total_cents) filter (where li.discount_eligible) over (partition by li.job_id) as e,
           sum(li.total_cents) filter (where li.discount_eligible)
             over (partition by li.job_id order by li.sort, li.created_at, li.id
                   rows between unbounded preceding and current row) as cum
      from done d
      join public.job_line_items li on li.shop_id = p_shop_id and li.job_id = d.id
  ), nets as (
    select l.job_id, l.svc, l.name,
           l.t - case when l.elig and l.e > 0 and l.d > 0
                      then round(l.d::numeric * l.cum / l.e)::bigint
                         - round(l.d::numeric * (l.cum - l.t) / l.e)::bigint
                      else 0 end as net
      from lines l
     where l.svc is not null
  ), rev as (
    select n.svc, sum(n.net)::bigint as revenue, count(distinct n.job_id) as jobs, min(n.name) as any_name
      from nets n
     group by n.svc
  ), mat as (
    select a.key::uuid as svc, round(sum(a.value::numeric * coalesce(m.unit_cost_cents, 0)))::bigint as cents
      from public.inventory_movements m
      cross join lateral jsonb_each_text(m.allocation) as a(key, value)
     where m.shop_id = p_shop_id and m.kind = 'consume' and m.job_id in (select d.id from done d)
     group by a.key
  ), rows as (
    select coalesce(r.svc, m.svc) as svc, r.any_name, coalesce(r.jobs, 0) as jobs,
           coalesce(r.revenue, 0) as revenue, coalesce(m.cents, 0) as materials
      from rev r
      full join mat m on m.svc = r.svc
  )
  select x.svc,
         coalesce(s.name, x.any_name),
         x.jobs,
         x.revenue,
         x.materials,
         x.revenue - x.materials,
         case when x.revenue > 0 then round((x.revenue - x.materials) * 10000.0 / x.revenue)::integer end
    from rows x
    left join public.services s on s.shop_id = p_shop_id and s.id = x.svc
   order by 6 desc, 2, 1;
end
$$;

comment on function public.report_service_profit(uuid, date, date) is '@nullable: service_name, margin_bps';

-- ---------------------------------------------------------------------------
-- report_lead_sources
-- ---------------------------------------------------------------------------
create function public.report_lead_sources(p_shop_id uuid, p_from date, p_to date)
returns table (
  source                    public.customer_source,
  customers_count           bigint,
  leads_count               bigint,
  converted_count           bigint,
  first_job_revenue_cents   bigint,
  revenue_cents             bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tz  text;
  v_s   timestamptz;
  v_e   timestamptz;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  return query
  with cust as (
    select c.id, c.source, c.lifecycle
      from public.customers c
     where c.shop_id = p_shop_id and c.merged_into_id is null
       and c.created_at >= v_s and c.created_at < v_e
  ), first_job as (
    select distinct on (j.customer_id) j.customer_id, (j.subtotal_cents - j.discount_cents) as rev
      from public.jobs j
     where j.shop_id = p_shop_id and j.status = 'completed' and j.completed_at < v_e
       and j.customer_id in (select c.id from cust c)
     order by j.customer_id, j.completed_at, j.number
  ), paid as (
    select p.customer_id,
           sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))::bigint as net
      from public.payments p
     where p.shop_id = p_shop_id and p.status in ('succeeded', 'partially_refunded', 'refunded')
       and p.paid_at < v_e and p.customer_id in (select c.id from cust c)
     group by p.customer_id
  ), x as (
    select c.source, (c.lifecycle = 'customer' or f.customer_id is not null) as converted,
           f.rev, pd.net
      from cust c
      left join first_job f on f.customer_id = c.id
      left join paid pd on pd.customer_id = c.id
  )
  select x.source,
         count(*),
         count(*) filter (where not x.converted),
         count(*) filter (where x.converted),
         coalesce(sum(x.rev), 0)::bigint,
         coalesce(sum(x.net), 0)::bigint
    from x
   group by x.source
   order by x.source;
end
$$;

-- ---------------------------------------------------------------------------
-- report_quote_conversion
--   {sent, viewed, approved, declined, expired, converted,
--    conversion_rate_bps, average_quote_cents, average_approved_cents,
--    median_hours_to_approve, by_month: [{month 'YYYY-MM', sent, approved,
--    approved_cents}]}
-- approved counts approved and converted quotes; rates / averages / median
-- are null when there is nothing to divide.
-- ---------------------------------------------------------------------------
create function public.report_quote_conversion(p_shop_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tz  text;
  v_s   timestamptz;
  v_e   timestamptz;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);

  return (
    with q as (
      select q.id, q.status, q.total_cents, q.sent_at, q.viewed_at, q.approved_at,
             q.status in ('approved', 'converted') as is_approved,
             to_char(q.sent_at at time zone v_tz, 'YYYY-MM') as month
        from public.quotes q
       where q.shop_id = p_shop_id and q.sent_at >= v_s and q.sent_at < v_e
    ), months as (
      select to_char(m, 'YYYY-MM') as month
        from generate_series(date_trunc('month', p_from::timestamp), date_trunc('month', p_to::timestamp),
                             interval '1 month') as m
    ), totals as (
      select count(*) as sent,
             count(*) filter (where q.viewed_at is not null) as viewed,
             count(*) filter (where q.is_approved) as approved,
             count(*) filter (where q.status = 'declined') as declined,
             count(*) filter (where q.status = 'expired') as expired,
             count(*) filter (where q.status = 'converted') as converted,
             round(avg(q.total_cents))::bigint as avg_quote,
             round(avg(q.total_cents) filter (where q.is_approved))::bigint as avg_approved,
             percentile_cont(0.5) within group (order by extract(epoch from (q.approved_at - q.sent_at)) / 3600.0)
               filter (where q.is_approved and q.approved_at is not null and q.approved_at >= q.sent_at) as median_h
        from q
    )
    select jsonb_build_object(
      'sent', t.sent,
      'viewed', t.viewed,
      'approved', t.approved,
      'declined', t.declined,
      'expired', t.expired,
      'converted', t.converted,
      'conversion_rate_bps', case when t.sent > 0 then round(t.approved * 10000.0 / t.sent)::integer end,
      'average_quote_cents', t.avg_quote,
      'average_approved_cents', t.avg_approved,
      'median_hours_to_approve', round(t.median_h::numeric, 2),
      'by_month', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'month', m.month,
                 'sent', (select count(*) from q where q.month = m.month),
                 'approved', (select count(*) from q where q.month = m.month and q.is_approved),
                 'approved_cents', (select coalesce(sum(q.total_cents), 0) from q
                                     where q.month = m.month and q.is_approved)) order by m.month)
          from months m), '[]'::jsonb))
    from totals t);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.report_job_profit(uuid, date, date),
  public.report_service_profit(uuid, date, date),
  public.report_lead_sources(uuid, date, date),
  public.report_quote_conversion(uuid, date, date)
from public, anon;
grant execute on function
  public.report_job_profit(uuid, date, date),
  public.report_service_profit(uuid, date, date),
  public.report_lead_sources(uuid, date, date),
  public.report_quote_conversion(uuid, date, date)
to authenticated, service_role;
