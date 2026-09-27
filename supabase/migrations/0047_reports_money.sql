-- ============================================================================
-- 0047 — Cash reports (SPEC §4.8): report_revenue, report_payments,
-- report_outstanding. Owner/admin/manager only (technicians: 42501).
--
-- Received payments = status succeeded / partially_refunded / refunded,
-- dated by paid_at in the shop time zone. Per payment (cents):
--   gross          amount_cents                     (never includes the tip)
--   refunds        least(refunded, amount)          refunded part of the amount
--   net            gross − refunds                  = payment_net_amount()
--   tips           tip − refunded part of the tip   = payment_net_tip()
--   tip_refunds    greatest(refunded − amount, 0)
-- A refund has no timestamp of its own (payments keep a cumulative
-- refunded_cents), so it is reported in the period of the original payment.
-- Pending / failed / cancelled payments never count. Processor fees are not
-- stored and therefore not reported.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- report_revenue — one row per bucket (day | week | month) covering
-- [p_from, p_to], empty buckets included. bucket_start is the natural start
-- of the bucket (Monday / 1st of the month), which can precede p_from; only
-- payments inside [p_from, p_to] are counted.
-- ---------------------------------------------------------------------------
create function public.report_revenue(
  p_shop_id  uuid,
  p_from     date,
  p_to       date,
  p_bucket   text default 'day'
) returns table (
  bucket_start    date,
  gross_cents     bigint,
  refunds_cents   bigint,
  net_cents       bigint,
  tips_cents      bigint,
  payments_count  bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_unit text := lower(btrim(p_bucket));
  v_tz   text;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  if v_unit is null or v_unit not in ('day', 'week', 'month') then
    raise exception 'bucket must be day, week or month' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;

  return query
  with buckets as (
    select gs::date as b_start
    from generate_series(date_trunc(v_unit, p_from::timestamp), p_to::timestamp,
                         ('1 ' || v_unit)::interval) as gs
  ), received as (
    select date_trunc(v_unit, p.paid_at at time zone v_tz)::date as b_start,
           p.amount_cents,
           least(p.refunded_cents, p.amount_cents) as refunded_amount,
           public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as net,
           public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as tip
    from public.payments p
    where p.shop_id = p_shop_id
      and p.status in ('succeeded', 'partially_refunded', 'refunded')
      and p.paid_at >= public.report_local_start(p_from, v_tz)
      and p.paid_at < public.report_local_start(p_to + 1, v_tz)
  )
  select b.b_start,
         coalesce(sum(r.amount_cents), 0)::bigint,
         coalesce(sum(r.refunded_amount), 0)::bigint,
         coalesce(sum(r.net), 0)::bigint,
         coalesce(sum(r.tip), 0)::bigint,
         count(r.b_start)
  from buckets b
  left join received r on r.b_start = b.b_start
  group by b.b_start
  order by b.b_start;
end
$$;

-- ---------------------------------------------------------------------------
-- report_payments — received payments in [p_from, p_to] per method (every
-- payment_method is returned, zeros included, in enum order).
--   collected_cents = net + tips (money kept, tips included)
-- ---------------------------------------------------------------------------
create function public.report_payments(p_shop_id uuid, p_from date, p_to date)
returns table (
  method             public.payment_method,
  payments_count     bigint,
  gross_cents        bigint,
  refunds_cents      bigint,
  net_cents          bigint,
  tips_cents         bigint,
  tip_refunds_cents  bigint,
  collected_cents    bigint,
  deposits_cents     bigint,
  memberships_cents  bigint
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
  with received as (
    select p.method as m,
           p.kind,
           p.amount_cents,
           least(p.refunded_cents, p.amount_cents) as refunded_amount,
           greatest(p.refunded_cents - p.amount_cents, 0) as refunded_tip,
           public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as net,
           public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as tip
    from public.payments p
    where p.shop_id = p_shop_id
      and p.status in ('succeeded', 'partially_refunded', 'refunded')
      and p.paid_at >= public.report_local_start(p_from, v_tz)
      and p.paid_at < public.report_local_start(p_to + 1, v_tz)
  )
  select pm.m,
         count(r.m),
         coalesce(sum(r.amount_cents), 0)::bigint,
         coalesce(sum(r.refunded_amount), 0)::bigint,
         coalesce(sum(r.net), 0)::bigint,
         coalesce(sum(r.tip), 0)::bigint,
         coalesce(sum(r.refunded_tip), 0)::bigint,
         coalesce(sum(r.net + r.tip), 0)::bigint,
         coalesce(sum(r.net) filter (where r.kind = 'deposit'), 0)::bigint,
         coalesce(sum(r.net) filter (where r.kind = 'membership'), 0)::bigint
  from unnest(enum_range(null::public.payment_method)) as pm (m)
  left join received r on r.m = pm.m
  group by pm.m
  order by pm.m;
end
$$;

-- ---------------------------------------------------------------------------
-- report_outstanding — receivables as of p_now: every open / partially_paid
-- invoice with a positive balance, aged by due date in shop-local days:
--   days_past_due = greatest(local date(p_now) − local date(due_at), 0)
--   bucket '0-30' (incl. not yet due) | '31-60' | '61-90' | '90+' (> 90 days)
-- Returns jsonb:
--   { as_of, timezone, count, balance_cents, overdue_count, overdue_balance_cents,
--     buckets: [{bucket, count, balance_cents} ×4 in order],
--     invoices: [{invoice_id, number, status, customer_id, customer_name, job_id,
--                 issued_at, due_at, total_cents, amount_paid_cents, balance_cents,
--                 days_past_due, overdue, bucket}]  (oldest due first) }
-- ---------------------------------------------------------------------------
create function public.report_outstanding(p_shop_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tz     text;
  v_today  date;
  v_result jsonb;
begin
  perform public.report_caller_role(p_shop_id, false);
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_today := (p_now at time zone v_tz)::date;

  with open_inv as (
    select i.*,
           public.report_customer_label(c.first_name, c.last_name, c.company) as customer_name,
           greatest(v_today - (coalesce(i.due_at, i.issued_at) at time zone v_tz)::date, 0) as days_past_due,
           coalesce(i.due_at, i.issued_at) < p_now as is_overdue
    from public.invoices i
    join public.customers c on c.shop_id = i.shop_id and c.id = i.customer_id
    where i.shop_id = p_shop_id
      and i.status in ('open', 'partially_paid')
      and i.balance_cents > 0
  ), aged as (
    select o.*,
           case when o.days_past_due <= 30 then '0-30'
                when o.days_past_due <= 60 then '31-60'
                when o.days_past_due <= 90 then '61-90'
                else '90+' end as bucket
    from open_inv o
  ), bucket_names (bucket, ord) as (
    values ('0-30', 1), ('31-60', 2), ('61-90', 3), ('90+', 4)
  )
  select jsonb_build_object(
    'as_of', p_now,
    'timezone', v_tz,
    'count', (select count(*) from aged),
    'balance_cents', (select coalesce(sum(a.balance_cents), 0) from aged a),
    'overdue_count', (select count(*) from aged a where a.is_overdue),
    'overdue_balance_cents', (select coalesce(sum(a.balance_cents), 0) from aged a where a.is_overdue),
    'buckets', (select jsonb_agg(jsonb_build_object(
                                   'bucket', bn.bucket,
                                   'count', (select count(*) from aged a where a.bucket = bn.bucket),
                                   'balance_cents', (select coalesce(sum(a.balance_cents), 0) from aged a
                                                      where a.bucket = bn.bucket))
                                 order by bn.ord)
                  from bucket_names bn),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'invoice_id', a.id,
                                   'number', a.number,
                                   'status', a.status,
                                   'customer_id', a.customer_id,
                                   'customer_name', a.customer_name,
                                   'job_id', a.job_id,
                                   'issued_at', a.issued_at,
                                   'due_at', a.due_at,
                                   'total_cents', a.total_cents,
                                   'amount_paid_cents', a.amount_paid_cents,
                                   'balance_cents', a.balance_cents,
                                   'days_past_due', a.days_past_due,
                                   'overdue', a.is_overdue,
                                   'bucket', a.bucket)
                                 order by a.due_at, a.number), '[]'::jsonb)
                   from aged a))
    into v_result;
  return v_result;
end
$$;

comment on function public.report_revenue(uuid, date, date, text) is
  'Cash revenue by day/week/month (shop time zone, empty buckets included): gross, refunds, net (excl. tips), tips, count.';
comment on function public.report_payments(uuid, date, date) is
  'Received payments per method: counts, gross, refunds, net, tips (net), tip refunds, collected, deposits, memberships.';
comment on function public.report_outstanding(uuid, timestamptz) is
  'Open receivables with aging buckets 0-30 / 31-60 / 61-90 / 90+ days past due (shop-local dates).';

revoke execute on function
  public.report_revenue(uuid, date, date, text),
  public.report_payments(uuid, date, date),
  public.report_outstanding(uuid, timestamptz)
from public, anon;
grant execute on function
  public.report_revenue(uuid, date, date, text),
  public.report_payments(uuid, date, date),
  public.report_outstanding(uuid, timestamptz)
to authenticated, service_role;
