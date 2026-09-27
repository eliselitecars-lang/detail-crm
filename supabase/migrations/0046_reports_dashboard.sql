-- ============================================================================
-- 0046 — dashboard_summary (SPEC §4.8, §6 dashboard / §7 Today tab).
--
-- One call returns everything the staff home screen needs, as jsonb. All
-- day / week / month boundaries are local calendar periods in the SHOP's
-- time zone around p_now (weeks start Monday); periods are whole calendar
-- periods (a payment stamped later today still counts as today).
--
-- scope 'shop' (owner/admin/manager): shop-wide numbers.
-- scope 'own'  (technician): jobs, next job and clock status limited to the
--   caller's assigned jobs / own entries; money, booking-request, quote,
--   invoice and inbox figures are null (SPEC §3: technicians see only their
--   own hours/jobs).
--
-- Keys:
--   shop_id, timezone, as_of, scope, today, week_start, month_start
--   jobs_today       { total, by_status{<every job_status>: n} }
--                    jobs overlapping today; total excludes cancelled/no_show
--   next_job         the earliest not-yet-started job (scheduled / confirmed
--                    / en_route) whose end is after p_now, or null
--   jobs_this_week   jobs overlapping this week, excluding cancelled/no_show
--   pending_booking_requests   online bookings still 'requested'
--   quotes_awaiting_response   sent/viewed quotes still within valid_until
--   open_invoices    { count, balance_cents } open/partially_paid, balance > 0
--   overdue_invoices { count, balance_cents } the open ones with due_at < p_now
--   revenue          { today|week|month: { net_cents, tips_cents, payments_count } }
--                    received payments by paid_at; net excludes tips and is
--                    net of refunds (refunds stay in the original payment's period)
--   unread_inbound_messages
--   clocked_in       { count, members: [{member_id, display_name, since, job_id}] }
--                    members with a time entry spanning p_now
-- ============================================================================

create function public.dashboard_summary(p_shop_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role      public.shop_role := public.report_caller_role(p_shop_id, true);
  v_own       boolean := v_role = 'technician';
  v_self      uuid := public.report_caller_member(p_shop_id);
  v_tz        text;
  v_today     date;
  v_week      date;
  v_month     date;
  v_day_s     timestamptz;
  v_day_e     timestamptz;
  v_week_s    timestamptz;
  v_week_e    timestamptz;
  v_month_s   timestamptz;
  v_month_e   timestamptz;
  v_jobs_today    jsonb;
  v_next_job      jsonb;
  v_jobs_week     bigint;
  v_requests      bigint;
  v_quotes        bigint;
  v_open          jsonb;
  v_overdue       jsonb;
  v_revenue       jsonb;
  v_unread        bigint;
  v_clocked       jsonb;
begin
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;

  v_today   := (p_now at time zone v_tz)::date;
  v_week    := date_trunc('week', v_today::timestamp)::date;
  v_month   := date_trunc('month', v_today::timestamp)::date;
  v_day_s   := public.report_local_start(v_today, v_tz);
  v_day_e   := public.report_local_start(v_today + 1, v_tz);
  v_week_s  := public.report_local_start(v_week, v_tz);
  v_week_e  := public.report_local_start(v_week + 7, v_tz);
  v_month_s := public.report_local_start(v_month, v_tz);
  v_month_e := public.report_local_start((v_month + interval '1 month')::date, v_tz);

  -- ------------------------------------------------------------ jobs
  with visible as (
    select j.*
    from public.jobs j
    where j.shop_id = p_shop_id
      and (not v_own or exists (select 1 from public.job_assignments ja
                                where ja.shop_id = j.shop_id and ja.job_id = j.id and ja.member_id = v_self))
  ), today as (
    select v.status, count(*) as n
    from visible v
    where v.scheduled_start < v_day_e and v.scheduled_end > v_day_s
    group by v.status
  )
  select jsonb_build_object(
           'total', coalesce(sum(t.n) filter (where s.st not in ('cancelled', 'no_show')), 0),
           'by_status', jsonb_object_agg(s.st::text, coalesce(t.n, 0)))
    into v_jobs_today
    from unnest(enum_range(null::public.job_status)) as s (st)
    left join today t on t.status = s.st;

  select count(*) into v_jobs_week
    from public.jobs j
   where j.shop_id = p_shop_id
     and j.scheduled_start < v_week_e and j.scheduled_end > v_week_s
     and j.status not in ('cancelled', 'no_show')
     and (not v_own or exists (select 1 from public.job_assignments ja
                               where ja.shop_id = j.shop_id and ja.job_id = j.id and ja.member_id = v_self));

  select jsonb_build_object(
           'id', j.id,
           'number', j.number,
           'status', j.status,
           'scheduled_start', j.scheduled_start,
           'scheduled_end', j.scheduled_end,
           'location_type', j.location_type,
           'customer_id', j.customer_id,
           'customer_name', public.report_customer_label(c.first_name, c.last_name, c.company),
           'vehicle_id', j.vehicle_id,
           'vehicle_label', public.report_vehicle_label(v.year, v.make, v.model),
           'assigned_member_ids', coalesce((select jsonb_agg(ja.member_id order by ja.created_at, ja.id)
                                              from public.job_assignments ja
                                             where ja.shop_id = j.shop_id and ja.job_id = j.id), '[]'::jsonb))
    into v_next_job
    from public.jobs j
    join public.customers c on c.shop_id = j.shop_id and c.id = j.customer_id
    left join public.vehicles v on v.shop_id = j.shop_id and v.id = j.vehicle_id
   where j.shop_id = p_shop_id
     and j.status in ('scheduled', 'confirmed', 'en_route')
     and j.scheduled_end > p_now
     and (not v_own or exists (select 1 from public.job_assignments ja
                               where ja.shop_id = j.shop_id and ja.job_id = j.id and ja.member_id = v_self))
   order by j.scheduled_start, j.number
   limit 1;

  -- ------------------------------------------------------------ clock
  with on_clock as (
    select m.id as member_id, m.display_name,
           min(t.clock_in) as since,
           (array_agg(t.job_id order by t.clock_in desc) filter (where t.kind = 'job'))[1] as job_id
    from public.time_entries t
    join public.shop_members m on m.shop_id = t.shop_id and m.id = t.member_id
    where t.shop_id = p_shop_id
      and m.active
      and t.clock_in <= p_now
      and (t.clock_out is null or t.clock_out > p_now)
      and (not v_own or m.id = v_self)
    group by m.id, m.display_name
  )
  select jsonb_build_object(
           'count', count(*),
           'members', coalesce(jsonb_agg(jsonb_build_object('member_id', oc.member_id,
                                                            'display_name', oc.display_name,
                                                            'since', oc.since,
                                                            'job_id', oc.job_id)
                                         order by oc.since, oc.display_name, oc.member_id), '[]'::jsonb))
    into v_clocked
    from on_clock oc;

  -- ------------------------------------------------------------ shop-wide figures
  if not v_own then
    select count(*) into v_requests
      from public.jobs j
     where j.shop_id = p_shop_id and j.status = 'requested' and j.source = 'online_booking';

    select count(*) into v_quotes
      from public.quotes q
     where q.shop_id = p_shop_id and q.status in ('sent', 'viewed')
       and (q.valid_until is null or public.quote_validity_end(q.valid_until, v_tz) > p_now);

    select jsonb_build_object('count', count(*), 'balance_cents', coalesce(sum(i.balance_cents), 0)),
           jsonb_build_object('count', count(*) filter (where i.due_at < p_now),
                              'balance_cents', coalesce(sum(i.balance_cents) filter (where i.due_at < p_now), 0))
      into v_open, v_overdue
      from public.invoices i
     where i.shop_id = p_shop_id and i.status in ('open', 'partially_paid') and i.balance_cents > 0;

    with received as (
      select p.paid_at,
             public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as net,
             public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) as tip
      from public.payments p
      where p.shop_id = p_shop_id
        and p.status in ('succeeded', 'partially_refunded', 'refunded')
        and p.paid_at >= least(v_week_s, v_month_s)
        and p.paid_at < greatest(v_week_e, v_month_e)
    )
    select jsonb_build_object(
             'today', jsonb_build_object(
                        'net_cents', coalesce(sum(r.net) filter (where r.paid_at >= v_day_s and r.paid_at < v_day_e), 0),
                        'tips_cents', coalesce(sum(r.tip) filter (where r.paid_at >= v_day_s and r.paid_at < v_day_e), 0),
                        'payments_count', count(*) filter (where r.paid_at >= v_day_s and r.paid_at < v_day_e)),
             'week', jsonb_build_object(
                        'net_cents', coalesce(sum(r.net) filter (where r.paid_at >= v_week_s and r.paid_at < v_week_e), 0),
                        'tips_cents', coalesce(sum(r.tip) filter (where r.paid_at >= v_week_s and r.paid_at < v_week_e), 0),
                        'payments_count', count(*) filter (where r.paid_at >= v_week_s and r.paid_at < v_week_e)),
             'month', jsonb_build_object(
                        'net_cents', coalesce(sum(r.net) filter (where r.paid_at >= v_month_s and r.paid_at < v_month_e), 0),
                        'tips_cents', coalesce(sum(r.tip) filter (where r.paid_at >= v_month_s and r.paid_at < v_month_e), 0),
                        'payments_count', count(*) filter (where r.paid_at >= v_month_s and r.paid_at < v_month_e)))
      into v_revenue
      from received r;

    select count(*) into v_unread
      from public.messages m
     where m.shop_id = p_shop_id and m.direction = 'inbound' and m.read_at is null;
  end if;

  return jsonb_build_object(
    'shop_id', p_shop_id,
    'timezone', v_tz,
    'as_of', p_now,
    'scope', case when v_own then 'own' else 'shop' end,
    'today', v_today,
    'week_start', v_week,
    'month_start', v_month,
    'jobs_today', v_jobs_today,
    'next_job', v_next_job,
    'jobs_this_week', v_jobs_week,
    'pending_booking_requests', v_requests,
    'quotes_awaiting_response', v_quotes,
    'open_invoices', v_open,
    'overdue_invoices', v_overdue,
    'revenue', v_revenue,
    'unread_inbound_messages', v_unread,
    'clocked_in', v_clocked);
end
$$;

comment on function public.dashboard_summary(uuid, timestamptz) is
  'Staff home screen summary in the shop time zone. Technicians get scope "own" (assigned jobs, own clock; money/inbox null).';

revoke execute on function public.dashboard_summary(uuid, timestamptz) from public, anon;
grant execute on function public.dashboard_summary(uuid, timestamptz) to authenticated, service_role;
