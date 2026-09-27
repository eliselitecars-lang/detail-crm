-- ============================================================================
-- 0043 — Client portal (SPEC §4.9, §6 /portal). Clients are ordinary auth
-- users linked to customers.portal_user_id; they have no table access and
-- see only these curated documents.
--
--   portal_claim_customers()  links every non-archived, unlinked customer (in
--                             any shop) whose email equals the caller's
--                             CONFIRMED auth email. Unconfirmed / anonymous
--                             accounts are refused (42501). Returns how many
--                             customer records were linked by this call.
--   portal_overview()         everything linked to the caller across shops.
--                             Jobs, quotes and invoices are referenced by
--                             their public tokens (the /booking, /q and /i
--                             pages); vehicles carry their id and category
--                             so they can be booked again. Never included:
--                             internal notes, customer notes/tags, staff,
--                             pay, Stripe ids, other customers' data.
-- ============================================================================

create function public.portal_claim_customers() returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := public.portal_confirmed_email();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  if v_email is null then
    raise exception 'confirm your email address before linking your records' using errcode = '42501';
  end if;
  update public.customers c
     set portal_user_id = v_uid
   where c.email is not null
     and lower(c.email::text) = v_email
     and c.portal_user_id is null
     and c.archived_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

create function public.portal_overview() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;

  return (
    with mine as (
      select c.*
      from public.customers c
      where c.portal_user_id = v_uid and c.archived_at is null
    ),
    shops as (
      select s.*
      from public.shops s
      where s.id in (select m.shop_id from mine m)
    ),
    my_jobs as (
      select j.*, s.slug as shop_slug,
             public.money_vehicle_label(j.shop_id, j.vehicle_id) as vehicle_label,
             (select string_agg(li.name, ', ' order by li.sort, li.created_at, li.id)
                from public.job_line_items li where li.job_id = j.id and li.shop_id = j.shop_id) as services,
             j.status in ('requested', 'scheduled', 'confirmed', 'en_route', 'in_progress') as is_upcoming
      from public.jobs j
      join mine m on m.id = j.customer_id and m.shop_id = j.shop_id
      join shops s on s.id = j.shop_id
    )
    select jsonb_build_object(
      'shops', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'slug', s.slug,
                 'name', s.name,
                 'logo_path', s.logo_path,
                 'brand_color', s.brand_color,
                 'phone', s.phone,
                 'email', s.email::text,
                 'website', s.website,
                 'city', s.city,
                 'region', s.region,
                 'timezone', s.timezone,
                 'currency', s.currency,
                 'booking_enabled', coalesce((select b.enabled from public.booking_settings b where b.shop_id = s.id), false))
               order by s.name, s.slug)
        from shops s), '[]'::jsonb),
      'customers', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'shop_slug', s.slug,
                 'first_name', m.first_name,
                 'last_name', m.last_name,
                 'company', m.company,
                 'email', m.email::text,
                 'phone', m.phone,
                 'sms_opt_in', m.sms_opt_in,
                 'email_opt_in', m.email_opt_in)
               order by s.name, m.created_at, m.id)
        from mine m join shops s on s.id = m.shop_id), '[]'::jsonb),
      'vehicles', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', v.id,
                 'shop_slug', s.slug,
                 'year', v.year,
                 'make', v.make,
                 'model', v.model,
                 'trim', v.trim,
                 'color', v.color,
                 'license_plate', v.license_plate,
                 'category_id', v.category_id,
                 'category_name', vc.name)
               order by s.name, v.created_at, v.id)
        from public.vehicles v
        join mine m on m.id = v.customer_id and m.shop_id = v.shop_id
        join shops s on s.id = v.shop_id
        left join public.vehicle_categories vc on vc.id = v.category_id and vc.shop_id = v.shop_id
        where v.archived_at is null), '[]'::jsonb),
      'upcoming_jobs', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'token', j.public_token,
                 'shop_slug', j.shop_slug,
                 'number', j.number,
                 'status', j.status,
                 'scheduled_start', j.scheduled_start,
                 'scheduled_end', j.scheduled_end,
                 'location_type', j.location_type,
                 'vehicle', j.vehicle_label,
                 'services', j.services,
                 'total_cents', j.total_cents,
                 'deposit_required_cents', j.deposit_required_cents)
               order by j.scheduled_start nulls last, j.created_at, j.id)
        from my_jobs j where j.is_upcoming), '[]'::jsonb),
      'past_jobs', coalesce((
        select jsonb_agg(x.doc order by x.sort_at desc, x.id)
        from (select j.id, coalesce(j.completed_at, j.cancelled_at, j.scheduled_start, j.created_at) as sort_at,
                     jsonb_build_object(
                       'token', j.public_token,
                       'shop_slug', j.shop_slug,
                       'number', j.number,
                       'status', j.status,
                       'scheduled_start', j.scheduled_start,
                       'scheduled_end', j.scheduled_end,
                       'completed_at', j.completed_at,
                       'location_type', j.location_type,
                       'vehicle', j.vehicle_label,
                       'services', j.services,
                       'total_cents', j.total_cents) as doc
                from my_jobs j where not j.is_upcoming
                order by 2 desc, 1 limit 100) x), '[]'::jsonb),
      'quotes', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'token', q.public_token,
                 'shop_slug', s.slug,
                 'number', q.number,
                 'status', q.status,
                 'total_cents', q.total_cents,
                 'valid_until', q.valid_until,
                 'sent_at', q.sent_at,
                 'vehicle', public.money_vehicle_label(q.shop_id, q.vehicle_id))
               order by q.sent_at desc nulls last, q.id)
        from public.quotes q
        join mine m on m.id = q.customer_id and m.shop_id = q.shop_id
        join shops s on s.id = q.shop_id
        where q.status in ('sent', 'viewed', 'approved')), '[]'::jsonb),
      'invoices', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'token', i.public_token,
                 'shop_slug', s.slug,
                 'number', i.number,
                 'status', i.status,
                 'total_cents', i.total_cents,
                 'amount_paid_cents', i.amount_paid_cents,
                 'balance_cents', i.balance_cents,
                 'issued_at', i.issued_at,
                 'due_at', i.due_at)
               order by i.issued_at desc nulls last, i.id)
        from public.invoices i
        join mine m on m.id = i.customer_id and m.shop_id = i.shop_id
        join shops s on s.id = i.shop_id
        where i.status in ('open', 'partially_paid', 'paid')), '[]'::jsonb),
      'memberships', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'shop_slug', s.slug,
                 'plan_name', p.name,
                 'plan_description', p.description,
                 'status', ms.status,
                 -- what this membership is billed (not the plan's current price)
                 'price_cents', ms.price_cents,
                 'interval', ms.interval,
                 'interval_count', ms.interval_count,
                 'discount_bps', p.discount_bps,
                 'included_services', coalesce((
                   select jsonb_agg(sv.name order by sv.sort, sv.name, sv.id)
                   from public.services sv
                   where sv.shop_id = p.shop_id and sv.id = any (p.included_service_ids)), '[]'::jsonb),
                 'vehicle', public.money_vehicle_label(ms.shop_id, ms.vehicle_id),
                 'current_period_end', ms.current_period_end,
                 'cancel_at_period_end', ms.cancel_at_period_end,
                 'started_at', ms.started_at)
               order by s.name, ms.started_at, ms.id)
        from public.memberships ms
        join mine m on m.id = ms.customer_id and m.shop_id = ms.shop_id
        join public.membership_plans p on p.id = ms.plan_id and p.shop_id = ms.shop_id
        join shops s on s.id = ms.shop_id
        where ms.status in ('active', 'past_due')), '[]'::jsonb))
  );
end
$$;

revoke execute on function public.portal_claim_customers(), public.portal_overview() from public, anon;
grant execute on function public.portal_claim_customers(), public.portal_overview() to authenticated, service_role;
