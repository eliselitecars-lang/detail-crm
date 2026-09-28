-- ============================================================================
-- 0067 — Quotes v2: proposal options (P-15) and customer self-scheduling of
-- an approved quote with its deposit (P-16).
--
-- Options (good / better / best): a quote may have up to 4 quote_options;
-- a line with option_id belongs to that option, a line without is shared.
-- The quote counts the shared lines plus the lines of its effective option
-- (quotes.selected_option_id, else the lowest-sort option); optional lines
-- still count only when selected. Every option's totals (shared lines +
-- its own, same discount and tax) are kept on quote_options. Staff edit
-- options, like lines, only while the quote is draft / sent / viewed; the
-- customer picks one when approving (public_respond_quote p_option_id);
-- staff may preselect one on a draft. Converting copies the effective
-- option's lines only.
--
-- Self-scheduling: when booking_settings.quote_self_schedule is on, the
-- quote allows it (quotes.self_schedule) and online booking is enabled, the
-- customer picks a time for the APPROVED quote on its /q page
-- (public_quote_slots / public_schedule_quote). The slot comes from the
-- online booking engine (sched's booking_slots_core: capacity, hours,
-- buffers, the lines' service categories) and is taken under the same
-- per-shop advisory lock as create_online_booking, so the two can never
-- both take the last capacity. The quote converts to a job (status per
-- auto_confirm) with the shop's deposit rule; its /q page then shows the
-- job's booking link (self_schedule.job_token — only for a quote the
-- customer scheduled this way) for paying the deposit (payments edge
-- quote_deposit_checkout).
--
-- Plan notes (deviations recorded here):
--   * quote_line_items_client_guard (0010) is NOT redefined although the
--     plan listed it: option_id needs no client-context rule of its own —
--     quote_line_items_validate (below) checks the option belongs to the
--     same quote in every context, and the 0010 guard already freezes lines
--     of answered quotes.
--   * convert_quote_to_job_core copies each line's discount_eligible, and
--     job lines of a coupon-less job keep it (0062), so the converted job's
--     total equals the approved quote.
--   * staff_record_quote_response (0093, written after the plan) applies
--     the same option rules as public_respond_quote: p_option_id is
--     required for a quote with options, optional lines must be shared or
--     of that option. It is replaced in 0094 (fix forward, numbered above
--     0093 so it also reaches a database that already applied 0093).
-- ============================================================================

-- The option a quote counts: its selection, else its first option.
create function public.quote_effective_option(p_quote_id uuid, p_selected uuid) returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(p_selected,
                  (select o.id from public.quote_options o
                    where o.quote_id = p_quote_id
                    order by o.sort, o.created_at, o.id limit 1))
$$;

-- ---------------------------------------------------------------------------
-- quote_options triggers
-- ---------------------------------------------------------------------------
-- Staff (client context) edit options only while the quote is draft / sent /
-- viewed (the quote row is locked first, like quote lines); totals are
-- server-maintained; options never move between quotes.
create function public.quote_options_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.quote_status;
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and new.quote_id is distinct from old.quote_id then
    raise exception 'options cannot move between quotes' using errcode = '42501';
  end if;
  select q.status into v_status
    from public.quotes q
   where q.id = case when tg_op = 'DELETE' then old.quote_id else new.quote_id end
     and q.shop_id = case when tg_op = 'DELETE' then old.shop_id else new.shop_id end
     for no key update;
  if found and v_status not in ('draft', 'sent', 'viewed') then
    raise exception 'options of a % quote cannot be changed; revise it back to draft first', v_status
      using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    new.subtotal_cents := 0; new.discount_cents := 0; new.tax_cents := 0; new.total_cents := 0;
  elsif tg_op = 'UPDATE' then
    new.subtotal_cents := old.subtotal_cents; new.discount_cents := old.discount_cents;
    new.tax_cents := old.tax_cents; new.total_cents := old.total_cents;
  end if;
  return coalesce(new, old);
end
$$;

-- At most 4 options per quote (the quote row is locked so two inserts
-- cannot both pass).
create function public.quote_options_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  if tg_op = 'INSERT' then
    perform 1 from public.quotes q where q.id = new.quote_id and q.shop_id = new.shop_id for no key update;
    if (select count(*) from public.quote_options o where o.quote_id = new.quote_id and o.shop_id = new.shop_id) >= 4 then
      raise exception 'a quote can have at most 4 options' using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;

-- Adding, removing or reordering options changes what the quote counts.
create function public.quote_options_touch_quote() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.quotes q set updated_at = now()
   where q.id = case when tg_op = 'DELETE' then old.quote_id else new.quote_id end
     and q.shop_id = case when tg_op = 'DELETE' then old.shop_id else new.shop_id end;
  return null;
end
$$;

create trigger quote_options_10_client_guard before insert or update or delete on public.quote_options
  for each row execute function public.quote_options_client_guard();
create trigger quote_options_20_before_write before insert or update on public.quote_options
  for each row execute function public.quote_options_before_write();
create trigger quote_options_touch_quote after insert or delete or update of sort on public.quote_options
  for each row execute function public.quote_options_touch_quote();

-- ---------------------------------------------------------------------------
-- quote lines: a line's option belongs to the same quote (0010 + option).
-- ---------------------------------------------------------------------------
create or replace function public.quote_line_items_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id or new.quote_id is distinct from old.quote_id)
     and not exists (select 1
                     from public.quotes q
                     join public.vehicles v on v.customer_id = q.customer_id and v.shop_id = q.shop_id
                     where q.id = new.quote_id and q.shop_id = new.shop_id and v.id = new.vehicle_id) then
    raise exception 'the vehicle does not belong to this quote''s customer' using errcode = '23514';
  end if;
  if new.option_id is not null
     and (tg_op = 'INSERT' or new.option_id is distinct from old.option_id or new.quote_id is distinct from old.quote_id)
     and not exists (select 1 from public.quote_options o
                     where o.id = new.option_id and o.shop_id = new.shop_id and o.quote_id = new.quote_id) then
    raise exception 'the option belongs to another quote' using errcode = '23514';
  end if;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- quotes: selected_option_id and self_scheduled_at are server-set in client
-- context (a draft's option may be preselected by staff).
-- ---------------------------------------------------------------------------
create or replace function public.quotes_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'new quotes start as drafts' using errcode = '23514';
    end if;
    new.public_token := gen_random_uuid();
    new.converted_job_id := null;
    new.self_scheduled_at := null;
    return new;
  end if;

  if new.number <> old.number then
    raise exception 'quote numbers cannot be changed' using errcode = '42501';
  end if;
  if new.public_token <> old.public_token then
    raise exception 'quote public_token cannot be changed' using errcode = '42501';
  end if;
  new.converted_job_id := old.converted_job_id;
  new.self_scheduled_at := old.self_scheduled_at;
  if old.status <> 'draft' then
    new.selected_option_id := old.selected_option_id;   -- the customer's choice
  end if;

  if old.status not in ('draft', 'sent', 'viewed')
     and new.status is not distinct from old.status
     and (new.customer_id, new.vehicle_id, new.valid_until, new.notes, new.terms,
          new.discount_kind, new.discount_value, new.tax_rate_bps)
         is distinct from
         (old.customer_id, old.vehicle_id, old.valid_until, old.notes, old.terms,
          old.discount_kind, old.discount_value, old.tax_rate_bps) then
    raise exception 'a % quote cannot be edited; revise it back to draft first', old.status
      using errcode = '23514';
  end if;
  return new;
end
$$;

-- An option chosen for a quote is one of ITS options.
create function public.quotes_money_option_check() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.selected_option_id is not null
     and not exists (select 1 from public.quote_options o
                     where o.id = new.selected_option_id and o.shop_id = new.shop_id and o.quote_id = new.id) then
    raise exception 'the selected option belongs to another quote' using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger quotes_zz_money_option_check after insert or update of selected_option_id on public.quotes
  for each row execute function public.quotes_money_option_check();

-- ---------------------------------------------------------------------------
-- quotes_compute_totals — shared lines + the effective option's lines
-- (optional ones only when selected), discount-eligible aware; every
-- option's own totals are refreshed in the same pass.
-- ---------------------------------------------------------------------------
create or replace function public.quotes_compute_totals() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t    public.document_totals;
  v_opt  uuid;
  o      record;
begin
  v_opt := case when tg_op = 'UPDATE' then public.quote_effective_option(new.id, new.selected_option_id) end;
  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(jsonb_build_object(
                             'quantity', li.quantity,
                             'unit_price_cents', li.unit_price_cents,
                             'discount_cents', li.discount_cents,
                             'taxable', li.taxable,
                             'discount_eligible', li.discount_eligible)), '[]'::jsonb)
              from public.quote_line_items li
             where li.quote_id = new.id and li.shop_id = new.shop_id
               and (not li.optional or li.selected)
               and (li.option_id is null or li.option_id = v_opt)),
           new.discount_kind, new.discount_value, new.tax_rate_bps);
  new.subtotal_cents := v_t.subtotal_cents;
  new.discount_cents := v_t.discount_cents;
  new.tax_cents := v_t.tax_cents;
  new.total_cents := v_t.total_cents;

  if tg_op = 'UPDATE' then
    for o in select qo.id from public.quote_options qo where qo.quote_id = new.id and qo.shop_id = new.shop_id loop
      v_t := public.compute_document_totals(
               (select coalesce(jsonb_agg(jsonb_build_object(
                                 'quantity', li.quantity,
                                 'unit_price_cents', li.unit_price_cents,
                                 'discount_cents', li.discount_cents,
                                 'taxable', li.taxable,
                                 'discount_eligible', li.discount_eligible)), '[]'::jsonb)
                  from public.quote_line_items li
                 where li.quote_id = new.id and li.shop_id = new.shop_id
                   and (not li.optional or li.selected)
                   and (li.option_id is null or li.option_id = o.id)),
               new.discount_kind, new.discount_value, new.tax_rate_bps);
      update public.quote_options qo
         set subtotal_cents = v_t.subtotal_cents, discount_cents = v_t.discount_cents,
             tax_cents = v_t.tax_cents, total_cents = v_t.total_cents
       where qo.id = o.id
         and (qo.subtotal_cents, qo.discount_cents, qo.tax_cents, qo.total_cents)
             is distinct from (v_t.subtotal_cents, v_t.discount_cents, v_t.tax_cents, v_t.total_cents);
    end loop;
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- convert_quote_to_job_core — INTERNAL (no caller checks): approved quote
-- -> new job (source 'quote') with the quote's customer, vehicle, notes,
-- discount and tax rate and its counted lines (shared + effective option,
-- optional ones when selected; fee links kept); links job.quote_id and the
-- quote's converted_job_id. p_location {type 'shop'|'mobile',
-- address_line1, address_line2, city, region, postal_code} sets the job's
-- location (already validated by the caller). sold_by = the quote creator's
-- membership.
-- ---------------------------------------------------------------------------
create function public.convert_quote_to_job_core(
  p_quote_id  uuid,
  p_start     timestamptz,
  p_end       timestamptz,
  p_status    public.job_status,
  p_location  jsonb default null
) returns public.jobs
language plpgsql volatile
set search_path = ''
as $$
declare
  v_q      public.quotes;
  v_job    public.jobs;
  v_num    bigint;
  v_opt    uuid;
  v_loc    public.location_type := 'shop';
  v_seller uuid;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if v_q.status = 'converted' then
    select j.number into v_num from public.jobs j where j.id = v_q.converted_job_id and j.shop_id = v_q.shop_id;
    raise exception 'this quote was already converted%', coalesce(' to job #' || v_num, '') using errcode = '22023';
  end if;
  if v_q.status <> 'approved' then
    raise exception 'only approved quotes can be converted (this one is %)', v_q.status using errcode = '22023';
  end if;
  if (p_start is null) <> (p_end is null) then
    raise exception 'provide both a start and an end time, or neither' using errcode = '22023';
  end if;
  if p_start is not null and p_end <= p_start then
    raise exception 'the end time must be after the start time' using errcode = '22023';
  end if;
  if jsonb_typeof(p_location -> 'type') = 'string' and (p_location ->> 'type') in ('shop', 'mobile') then
    v_loc := (p_location ->> 'type')::public.location_type;
  end if;
  v_opt := public.quote_effective_option(v_q.id, v_q.selected_option_id);
  select m.id into v_seller from public.shop_members m
   where m.shop_id = v_q.shop_id and m.user_id = v_q.created_by;

  insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end,
                           notes, internal_notes, source, quote_id, discount_kind, discount_value, tax_rate_bps,
                           location_type, service_address_line1, service_address_line2, service_city,
                           service_region, service_postal_code, sold_by_member_id)
  values (v_q.shop_id, v_q.customer_id, v_q.vehicle_id,
          coalesce(p_status, case when p_start is null then 'requested' else 'scheduled' end::public.job_status),
          p_start, p_end, v_q.notes, v_q.internal_notes, 'quote', v_q.id,
          v_q.discount_kind, v_q.discount_value, v_q.tax_rate_bps,
          v_loc,
          case when v_loc = 'mobile' then p_location ->> 'address_line1' end,
          case when v_loc = 'mobile' then p_location ->> 'address_line2' end,
          case when v_loc = 'mobile' then p_location ->> 'city' end,
          case when v_loc = 'mobile' then p_location ->> 'region' end,
          case when v_loc = 'mobile' then p_location ->> 'postal_code' end,
          v_seller)
  returning * into v_job;

  -- discount_eligible is copied: the job (no coupon) keeps it (0062), so
  -- its total equals the approved quote's
  insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                     unit_price_cents, discount_cents, taxable, discount_eligible, duration_minutes,
                                     fee_id, sort)
  select v_q.shop_id, v_job.id, li.service_id, li.vehicle_id, li.name, li.description, li.quantity,
         li.unit_price_cents, li.discount_cents, li.taxable, li.discount_eligible, li.duration_minutes, li.fee_id,
         row_number() over (order by li.sort, li.created_at, li.id)::integer
  from public.quote_line_items li
  where li.quote_id = v_q.id and li.shop_id = v_q.shop_id
    and (not li.optional or li.selected)
    and (li.option_id is null or li.option_id = v_opt);

  update public.quotes set status = 'converted', converted_job_id = v_job.id where id = v_q.id;

  select * into v_job from public.jobs j where j.id = v_job.id;
  return v_job;
end
$$;

-- convert_quote_to_job — staff (manager+), same signature and rules as 0010.
create or replace function public.convert_quote_to_job(
  p_quote_id  uuid,
  p_start     timestamptz default null,
  p_end       timestamptz default null
) returns public.jobs
language plpgsql security definer
set search_path = ''
as $$
declare
  v_q public.quotes;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id;
  if not found or not public.is_shop_member(v_q.shop_id) then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_q.shop_id) then
    raise exception 'only owners, admins and managers can convert quotes' using errcode = '42501';
  end if;
  return public.convert_quote_to_job_core(p_quote_id, p_start, p_end,
                                          case when p_start is null then 'requested' else 'scheduled' end::public.job_status,
                                          null);
end
$$;

-- ---------------------------------------------------------------------------
-- Self-scheduling helpers (internal)
-- ---------------------------------------------------------------------------
-- Why an approved quote cannot be scheduled online now (null = it can).
create function public.quote_self_schedule_reason(p_quote public.quotes) returns text
language sql stable
set search_path = ''
as $$
  select case
    when p_quote.status = 'converted' then 'this quote has already been scheduled'
    when p_quote.status <> 'approved' then 'approve the quote before scheduling it'
    when not p_quote.self_schedule then 'this quote cannot be scheduled online; please contact the shop'
    when not coalesce((select b.enabled and b.quote_self_schedule from public.booking_settings b
                        where b.shop_id = p_quote.shop_id), false)
      then 'online scheduling is not available; please contact the shop'
  end
$$;

-- Duration (minutes; each line's duration × whole units, 15 .. 44640) and
-- service categories of what the quote counts.
create function public.quote_schedule_needs(p_quote public.quotes, out duration_minutes integer, out category_ids uuid[])
language sql stable
set search_path = ''
as $$
  select greatest(15, least(44640, coalesce(sum(li.duration_minutes * ceil(li.quantity)), 0)))::integer,
         array(select distinct s.category_id
                 from public.quote_line_items l2
                 join public.services s on s.id = l2.service_id and s.shop_id = l2.shop_id
                where l2.quote_id = p_quote.id and l2.shop_id = p_quote.shop_id and s.category_id is not null
                  and (not l2.optional or l2.selected)
                  and (l2.option_id is null
                       or l2.option_id = public.quote_effective_option(p_quote.id, p_quote.selected_option_id)))
  from public.quote_line_items li
  where li.quote_id = p_quote.id and li.shop_id = p_quote.shop_id
    and (not li.optional or li.selected)
    and (li.option_id is null or li.option_id = public.quote_effective_option(p_quote.id, p_quote.selected_option_id))
$$;

-- The location type for a public schedule request (default: the shop's).
create function public.quote_location_type(p_business public.business_type, p_raw text) returns public.location_type
language plpgsql immutable
set search_path = ''
as $$
declare
  v_raw text := lower(nullif(btrim(p_raw), ''));
begin
  if v_raw is null then
    return case when p_business = 'mobile' then 'mobile' else 'shop' end;
  end if;
  if v_raw not in ('shop', 'mobile') then
    raise exception 'location type must be shop or mobile' using errcode = '22023';
  end if;
  if v_raw = 'shop' and p_business = 'mobile' then
    raise exception 'this shop only offers mobile service; enter the service address' using errcode = '22023';
  end if;
  if v_raw = 'mobile' and p_business = 'fixed' then
    raise exception 'this shop does not offer mobile service' using errcode = '22023';
  end if;
  return v_raw::public.location_type;
end
$$;

-- ---------------------------------------------------------------------------
-- money_public_quote_json — curated /q document (0014) plus options and the
-- self-scheduling block:
--   quote.has_options, quote.selected_option_id (the effective option),
--   options [{id, name, description, sort, subtotal_cents, discount_cents,
--            tax_cents, total_cents}], line option_id,
--   self_schedule {available, converted, job_token, deposit_due_cents,
--                  payment_pending}:
--     job_token / deposit_due_cents / payment_pending only for a quote the
--     customer scheduled on this page (never for a staff conversion), and
--     only while the job still belongs to the quote's customer (null once
--     staff moved it to someone else).
--     payment_pending = a payment of the job is on its way (a pending card
--     attempt, or an ACH / pay-later payment still 'processing' — in flight
--     for days, payment_in_flight): deposit_due_cents counts only money
--     received, so a client must not ask for the deposit again while it is
--     true (same rule as public_get_booking's deposit.payment_pending).
--     Once the job is on a live invoice (single-job or grouped, through
--     invoice_jobs) the deposit is capped at the invoice's total and never
--     exceeds what the invoice still owes, and a payment in flight on a
--     grouped invoice (its payments carry no job_id) counts as pending —
--     the /booking page's rules (booking_public_json, 0064), so a job on a
--     paid fleet invoice shows no deposit due.
-- ---------------------------------------------------------------------------
create or replace function public.money_public_quote_json(p_quote_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', public.money_public_shop_json(q.shop_id),
    'quote', jsonb_build_object(
      'number', q.number,
      'status', q.status,
      'valid_until', q.valid_until,
      'expires_at', case when q.valid_until is not null then public.quote_validity_end(q.valid_until, s.timezone) end,
      'notes', q.notes,
      'terms', q.terms,
      'subtotal_cents', q.subtotal_cents,
      'discount_cents', q.discount_cents,
      'tax_rate_bps', q.tax_rate_bps,
      'tax_cents', q.tax_cents,
      'total_cents', q.total_cents,
      'sent_at', q.sent_at,
      'viewed_at', q.viewed_at,
      'approved_at', q.approved_at,
      'approved_by_name', q.approved_by_name,
      'declined_at', q.declined_at,
      'declined_reason', q.declined_reason,
      'expired_at', q.expired_at,
      'can_respond', q.status in ('sent', 'viewed')
                     and (q.valid_until is null or public.quote_validity_end(q.valid_until, s.timezone) > now()),
      'has_options', exists (select 1 from public.quote_options o where o.quote_id = q.id and o.shop_id = q.shop_id),
      'selected_option_id', public.quote_effective_option(q.id, q.selected_option_id)),
    'customer', jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'company', c.company),
    'vehicle', public.money_public_vehicle_json(q.shop_id, q.vehicle_id),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id,
               'name', o.name,
               'description', o.description,
               'sort', o.sort,
               'subtotal_cents', o.subtotal_cents,
               'discount_cents', o.discount_cents,
               'tax_cents', o.tax_cents,
               'total_cents', o.total_cents)
             order by o.sort, o.created_at, o.id)
      from public.quote_options o
      where o.quote_id = q.id and o.shop_id = q.shop_id), '[]'::jsonb),
    'line_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', li.id,
               'option_id', li.option_id,
               'name', li.name,
               'description', li.description,
               'vehicle_label', public.money_vehicle_label(li.shop_id, li.vehicle_id),
               'quantity', li.quantity,
               'unit_price_cents', li.unit_price_cents,
               'discount_cents', li.discount_cents,
               'taxable', li.taxable,
               'total_cents', li.total_cents,
               'optional', li.optional,
               'selected', li.selected)
             order by li.sort, li.created_at, li.id)
      from public.quote_line_items li
      where li.quote_id = q.id and li.shop_id = q.shop_id), '[]'::jsonb),
    'self_schedule', jsonb_build_object(
      'available', public.quote_self_schedule_reason(q) is null,
      'converted', q.status = 'converted',
      'job_token', case when q.self_scheduled_at is not null then j.public_token end,
      'deposit_due_cents', case when q.self_scheduled_at is not null and j.id is not null then
        case when inv.id is null then dep.job_due
             else least(dep.job_due, greatest(inv.balance_cents, 0)) end end,
      'payment_pending', case when q.self_scheduled_at is not null and j.id is not null then
        exists (select 1 from public.payments p
                 where p.shop_id = j.shop_id
                   and (p.job_id = j.id or (inv.id is not null and inv.job_id is null and p.invoice_id = inv.id))
                   and (p.status = 'pending' or public.payment_in_flight(p.status, p.created_at))) end))
  from public.quotes q
  join public.shops s on s.id = q.shop_id
  join public.customers c on c.id = q.customer_id and c.shop_id = q.shop_id
  -- the converted job only while it is still this customer's: a job moved
  -- to another customer gets a new booking token (jobs_customer_change),
  -- which the previous customer's quote link must not hand out (same rule
  -- as comms_document_vars, 0090)
  left join public.jobs j on j.id = q.converted_job_id and j.shop_id = q.shop_id
                         and j.customer_id = q.customer_id
  -- the job's live invoice (at most one: invoice_jobs_one_live_invoice)
  left join lateral (
    select i.id, i.job_id, i.total_cents, i.balance_cents
      from public.invoice_jobs ij
      join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
     where ij.shop_id = j.shop_id and ij.job_id = j.id and not ij.voided and i.status <> 'void'
     order by i.created_at desc
     limit 1) inv on true
  left join lateral (
    select greatest(least(j.deposit_required_cents, coalesce(inv.total_cents, j.total_cents))
                    - coalesce((select sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                                  from public.payments p where p.shop_id = j.shop_id and p.job_id = j.id), 0), 0)::bigint
             as job_due) dep on true
  where q.id = p_quote_id
$$;

-- ---------------------------------------------------------------------------
-- public_respond_quote — 0014 plus p_option_id: approving a quote that has
-- options requires one of ITS options (22023 otherwise); the chosen
-- optional lines must be shared lines or lines of that option. The choice
-- is stored as quotes.selected_option_id (totals recompute server-side).
-- ---------------------------------------------------------------------------
drop function public.public_respond_quote(uuid, text, text, uuid[], text);

create function public.public_respond_quote(
  p_token                      uuid,
  p_action                     text,
  p_signer_name                text default null,
  p_selected_optional_line_ids uuid[] default '{}',
  p_declined_reason            text default null,
  p_option_id                  uuid default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_q       public.quotes;
  v_tz      text;
  v_action  text := lower(btrim(p_action));
  v_signer  text := nullif(btrim(p_signer_name), '');
  v_reason  text := nullif(btrim(p_declined_reason), '');
  v_ids     uuid[];
  v_options boolean;
begin
  select * into v_q from public.quotes q where q.public_token = p_token for update;
  if not found or v_q.status = 'draft' then
    raise exception 'quote not found' using errcode = 'PT404';
  end if;
  if v_action is null or v_action not in ('approve', 'decline') then
    raise exception 'action must be approve or decline' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.status not in ('sent', 'viewed') then
    raise exception 'this quote can no longer be answered (it is %)', v_q.status using errcode = '22023';
  end if;
  if v_q.valid_until is not null and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    raise exception 'this quote has expired' using errcode = '22023';
  end if;

  if v_action = 'approve' then
    if v_signer is null or char_length(v_signer) > 200 then
      raise exception 'type your full name (up to 200 characters) to approve' using errcode = '22023';
    end if;
    v_options := exists (select 1 from public.quote_options o where o.quote_id = v_q.id and o.shop_id = v_q.shop_id);
    if v_options and (p_option_id is null
                      or not exists (select 1 from public.quote_options o
                                     where o.id = p_option_id and o.quote_id = v_q.id and o.shop_id = v_q.shop_id)) then
      raise exception 'choose one of the quote''s options to approve it' using errcode = '22023';
    end if;
    if not v_options and p_option_id is not null then
      raise exception 'this quote has no options to choose from' using errcode = '22023';
    end if;
    v_ids := array(select distinct x from unnest(coalesce(p_selected_optional_line_ids, '{}'::uuid[])) as x
                   where x is not null);
    if exists (select 1 from unnest(v_ids) as x
               where not exists (select 1 from public.quote_line_items li
                                 where li.id = x and li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional
                                   and (li.option_id is null or li.option_id = p_option_id))) then
      raise exception 'selected items must be optional items of this quote (and of the chosen option)' using errcode = '22023';
    end if;
    update public.quote_line_items li
       set selected = (li.id = any (v_ids))
     where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional
       and li.selected is distinct from (li.id = any (v_ids));
    update public.quotes
       set status = 'approved', approved_by_name = v_signer,
           selected_option_id = case when v_options then p_option_id else selected_option_id end
     where id = v_q.id;
  else
    if char_length(v_reason) > 1000 then
      raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
    end if;
    update public.quotes set status = 'declined', declined_reason = v_reason where id = v_q.id;
  end if;
  return public.money_public_quote_json(v_q.id);
end
$$;

-- ---------------------------------------------------------------------------
-- public_quote_slots(token, from, to, location type) — anon / signed-in:
-- start times the customer can book for their approved quote (see the
-- header). Duration: Σ counted line duration × whole units (15 .. 44640
-- minutes); the lines' service categories apply (bookable weekdays); the
-- location type defaults to what the shop offers. 22023 when the quote
-- cannot be scheduled online (the message says why); PT404 unknown token.
-- ---------------------------------------------------------------------------
create function public.public_quote_slots(
  p_token          uuid,
  p_from           date,
  p_to             date,
  p_location_type  public.location_type default null
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_q      public.quotes;
  v_shop   public.shops;
  v_reason text;
  v_loc    public.location_type;
  v_need   record;
begin
  select * into v_q from public.quotes q where q.public_token = p_token;
  if not found or v_q.status = 'draft' then
    raise exception 'quote not found' using errcode = 'PT404';
  end if;
  v_reason := public.quote_self_schedule_reason(v_q);
  if v_reason is not null then
    raise exception '%', v_reason using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.id = v_q.shop_id;
  v_loc := public.quote_location_type(v_shop.business_type, p_location_type::text);
  select * into v_need from public.quote_schedule_needs(v_q);
  return query
  select s.starts_at, s.ends_at
    from public.booking_slots_core(v_q.shop_id, v_need.duration_minutes, p_from, p_to, public.effective_now(null),
                                   v_loc, nullif(v_need.category_ids, '{}')) s;
end
$$;

-- ---------------------------------------------------------------------------
-- public_schedule_quote(token, starts_at, location, now) — anon /
-- signed-in: books the approved quote at one of public_quote_slots' starts
-- (starts_at as in create_online_booking: ISO-8601; without an offset it is
-- shop-local wall time). location {type, address_line1*, address_line2,
-- city*, region, postal_code*} (* for mobile, inside the service area).
-- Serialized with online bookings (same advisory lock), the exact slot is
-- re-validated, the quote converts to a job ('scheduled' with auto-confirm,
-- else 'requested') with the shop's deposit rule, staff are notified and the
-- customer gets the booking confirmation / request message. Returns
-- {job_token, job_number, status, total_cents, deposit_required_cents,
-- deposit_due_cents}. 23P01 slot taken; 22023 not schedulable / invalid
-- input; PT404 unknown token.
-- ---------------------------------------------------------------------------
create function public.public_schedule_quote(
  p_token      uuid,
  p_starts_at  text,
  p_location   jsonb default null,
  p_now        timestamptz default now()
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v_q        public.quotes;
  v_shop     public.shops;
  v_bs       public.booking_settings;
  v_reason   text;
  v_loc      public.location_type;
  v_start    timestamptz;
  v_end      timestamptz;
  v_need     record;
  v_loc_json jsonb;
  v_job      public.jobs;
  v_deposit  bigint := 0;
begin
  select * into v_q from public.quotes q where q.public_token = p_token for update;
  if not found or v_q.status = 'draft' then
    raise exception 'quote not found' using errcode = 'PT404';
  end if;
  v_reason := public.quote_self_schedule_reason(v_q);
  if v_reason is not null then
    raise exception '%', v_reason using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.id = v_q.shop_id;
  select * into v_bs from public.booking_settings b where b.shop_id = v_q.shop_id;
  if p_location is not null and jsonb_typeof(p_location) not in ('object', 'null') then
    raise exception 'location must be an object' using errcode = '22023';
  end if;
  v_loc := public.quote_location_type(v_shop.business_type, public.payload_text(p_location, 'type', 10, 'location type'));
  v_loc_json := jsonb_build_object('type', v_loc);
  if v_loc = 'mobile' then
    v_loc_json := v_loc_json || jsonb_build_object(
      'address_line1', public.payload_text(p_location, 'address_line1', 200, 'street address', true),
      'address_line2', public.payload_text(p_location, 'address_line2', 200, 'address line 2'),
      'city', public.payload_text(p_location, 'city', 100, 'city', true),
      'region', public.payload_text(p_location, 'region', 100, 'state / region'),
      'postal_code', upper(public.payload_text(p_location, 'postal_code', 20, 'postal code', true)));
    if not public.postal_code_in_area(v_loc_json ->> 'postal_code', v_bs.service_area_postal_codes) then
      raise exception 'this address is outside our service area' using errcode = '22023';
    end if;
  end if;
  v_start := public.booking_parse_start(public.payload_text(jsonb_build_object('s', p_starts_at), 's', 64, 'starts_at', true),
                                        v_shop.timezone);
  select * into v_need from public.quote_schedule_needs(v_q);

  -- serialize with this shop's online bookings (create_online_booking)
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.create_online_booking:' || v_shop.id::text, 0));
  select s.ends_at into v_end
    from public.booking_slots_core(v_shop.id, v_need.duration_minutes, (v_start at time zone v_shop.timezone)::date,
                                   (v_start at time zone v_shop.timezone)::date, v_now, v_loc,
                                   nullif(v_need.category_ids, '{}')) s
   where s.starts_at = v_start;
  if v_end is null then
    raise exception 'that time is no longer available; please choose another time' using errcode = '23P01';
  end if;

  v_job := public.convert_quote_to_job_core(v_q.id, v_start, v_end,
                                            case when v_bs.auto_confirm then 'scheduled' else 'requested' end::public.job_status,
                                            v_loc_json);
  update public.quotes q set self_scheduled_at = now() where q.id = v_q.id;
  if v_bs.require_deposit then
    v_deposit := least(case v_bs.deposit_type
                         when 'percent' then round(v_job.total_cents::numeric * v_bs.deposit_value / 10000)::bigint
                         else v_bs.deposit_value
                       end,
                       v_job.total_cents);
  end if;
  update public.jobs j set deposit_required_cents = v_deposit where j.id = v_job.id returning * into v_job;
  perform public.integration_online_booking_created(v_job.id);

  return jsonb_build_object(
    'job_token', v_job.public_token,
    'job_number', v_job.number,
    'status', v_job.status,
    'total_cents', v_job.total_cents,
    'deposit_required_cents', v_job.deposit_required_cents,
    'deposit_due_cents', v_job.deposit_required_cents);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.quote_options_client_guard(),
  public.quote_options_before_write(),
  public.quote_options_touch_quote(),
  public.quotes_money_option_check()
from public, anon, authenticated;

revoke execute on function
  public.quote_effective_option(uuid, uuid),
  public.convert_quote_to_job_core(uuid, timestamptz, timestamptz, public.job_status, jsonb),
  public.quote_self_schedule_reason(public.quotes),
  public.quote_schedule_needs(public.quotes),
  public.quote_location_type(public.business_type, text)
from public, anon, authenticated;
grant execute on function
  public.quote_effective_option(uuid, uuid),
  public.convert_quote_to_job_core(uuid, timestamptz, timestamptz, public.job_status, jsonb),
  public.quote_self_schedule_reason(public.quotes),
  public.quote_schedule_needs(public.quotes),
  public.quote_location_type(public.business_type, text)
to service_role;

revoke execute on function
  public.public_respond_quote(uuid, text, text, uuid[], text, uuid),
  public.public_quote_slots(uuid, date, date, public.location_type),
  public.public_schedule_quote(uuid, text, jsonb, timestamptz)
from public;
grant execute on function
  public.public_respond_quote(uuid, text, text, uuid[], text, uuid),
  public.public_quote_slots(uuid, date, date, public.location_type),
  public.public_schedule_quote(uuid, text, jsonb, timestamptz)
to anon, authenticated, service_role;
