-- ============================================================================
-- 0040 — Integration layer (SPEC §4.9): shared helpers for the public booking
-- and portal RPCs, and catalog pricing with memberships.
--
-- Range layout (0040-0044 = integration):
--   0040  JSON payload readers, phone/postal helpers,
--         price_services (staff) + price_services_core (internal)
--   0041  cross-domain side effects: integration_events ledger + triggers
--         (staff notifications and customer messages)
--   0042  public booking: public_shop_profile, public_booking_catalog,
--         public_validate_coupon, create_online_booking, public_get_booking,
--         public_cancel_booking
--   0043  client portal: portal_claim_customers, portal_overview
--   0044  realtime publication + privilege hardening
--
-- The request clock (public.is_api_request / public.effective_now) is
-- defined in 0001 because foundation's get_available_slots (0007) already
-- needs it. Time-dependent RPCs take an optional p_now so tests and trusted
-- callers (service_role: edge functions, cron; direct database sessions) can
-- run them at a fixed instant. Requests made as anon/authenticated
-- (PostgREST) ALWAYS use the server clock: a caller-supplied time could
-- otherwise book in the past, redeem an expired coupon or cancel after the
-- cancellation deadline.
-- ============================================================================

-- Lower-cased email of the signed-in caller when it is CONFIRMED (and the
-- account is a real, non-anonymous, non-deleted user); null otherwise. The
-- only identity the client portal trusts for linking customer records.
create function public.portal_confirmed_email() returns text
language sql stable
set search_path = ''
as $$
  select lower(u.email)
  from auth.users u
  where u.id = auth.uid()
    and u.email is not null
    and u.email_confirmed_at is not null
    and not u.is_anonymous
    and u.deleted_at is null
$$;

-- ---------------------------------------------------------------------------
-- JSON payload readers for public RPCs. Each raises 22023 with a readable
-- message naming the field; absent keys and JSON null read as null.
-- ---------------------------------------------------------------------------

-- Trimmed text (blank = null). Numbers are accepted as their text form (e.g.
-- a postal code typed as a number); anything else is rejected.
create function public.payload_text(
  p_obj       jsonb,
  p_key       text,
  p_max       integer,
  p_label     text,
  p_required  boolean default false
) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v jsonb := case when jsonb_typeof(p_obj) = 'object' then p_obj -> p_key end;
  t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    t := null;
  elsif jsonb_typeof(v) = 'string' then
    t := nullif(btrim(v #>> '{}', E' \t\r\n'), '');
  elsif jsonb_typeof(v) = 'number' then
    t := v::text;
  else
    raise exception '% must be text', p_label using errcode = '22023';
  end if;
  if t is null and p_required then
    raise exception '% is required', p_label using errcode = '22023';
  end if;
  if char_length(t) > p_max then
    raise exception '% is too long (max % characters)', p_label, p_max using errcode = '22023';
  end if;
  return t;
end
$$;

create function public.payload_bool(p_obj jsonb, p_key text, p_label text, p_default boolean default false)
returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  v jsonb := case when jsonb_typeof(p_obj) = 'object' then p_obj -> p_key end;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return p_default;
  end if;
  if jsonb_typeof(v) <> 'boolean' then
    raise exception '% must be true or false', p_label using errcode = '22023';
  end if;
  return (v #>> '{}')::boolean;
end
$$;

create function public.payload_int(p_obj jsonb, p_key text, p_label text, p_min integer, p_max integer)
returns integer
language plpgsql immutable
set search_path = ''
as $$
declare
  v jsonb := case when jsonb_typeof(p_obj) = 'object' then p_obj -> p_key end;
  t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return null;
  end if;
  t := btrim(v #>> '{}');
  if jsonb_typeof(v) not in ('number', 'string') or t !~ '^-?[0-9]{1,9}$' then
    raise exception '% must be a whole number', p_label using errcode = '22023';
  end if;
  if t::integer < p_min or t::integer > p_max then
    raise exception '% must be between % and %', p_label, p_min, p_max using errcode = '22023';
  end if;
  return t::integer;
end
$$;

create function public.payload_uuid(p_obj jsonb, p_key text, p_label text) returns uuid
language plpgsql immutable
set search_path = ''
as $$
declare
  v jsonb := case when jsonb_typeof(p_obj) = 'object' then p_obj -> p_key end;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return null;
  end if;
  if jsonb_typeof(v) <> 'string'
     or (v #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception '% must be an id', p_label using errcode = '22023';
  end if;
  return (v #>> '{}')::uuid;
end
$$;

-- Array of ids, de-duplicated in first-occurrence order (never null).
create function public.payload_uuid_array(p_obj jsonb, p_key text, p_label text, p_max integer) returns uuid[]
language plpgsql immutable
set search_path = ''
as $$
declare
  v    jsonb := case when jsonb_typeof(p_obj) = 'object' then p_obj -> p_key end;
  v_out uuid[];
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return '{}';
  end if;
  if jsonb_typeof(v) <> 'array' then
    raise exception '% must be a list of ids', p_label using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v) e
             where jsonb_typeof(e) <> 'string'
                or (e #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception '% must be a list of ids', p_label using errcode = '22023';
  end if;
  v_out := array(select x.id
                   from (select (e #>> '{}')::uuid as id, min(o) as first_o
                           from jsonb_array_elements(v) with ordinality as t(e, o)
                          group by 1) x
                  order by x.first_o);
  if cardinality(v_out) > p_max then
    raise exception 'too many % (max %)', p_label, p_max using errcode = '22023';
  end if;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- Phone / postal helpers (pure)
-- ---------------------------------------------------------------------------

-- Normalizes a typed phone number to E.164, or null when it cannot be read.
-- Formatting characters (spaces, dots, dashes, parentheses) are ignored;
-- 10-digit (or 1 + 10-digit) numbers are read as NANP for US/CA shops.
create function public.normalize_phone_e164(p_phone text, p_country text default 'US') returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_phone, ''), '[[:space:]().-]', '', 'g');
begin
  if v = '' then
    return null;
  end if;
  if left(v, 1) = '+' then
    return case when public.is_valid_e164(v) then v end;
  end if;
  if upper(coalesce(p_country, 'US')) in ('US', 'CA') then
    if v ~ '^[2-9][0-9]{9}$' then
      return '+1' || v;
    elsif v ~ '^1[2-9][0-9]{9}$' then
      return '+' || v;
    end if;
  end if;
  return null;
end
$$;

-- Is a postal code inside a service area? Case and spaces are ignored
-- ("sw1a 1aa" = "SW1A1AA"); a US ZIP+4 matches its 5-digit ZIP. An empty
-- area means "no restriction".
create function public.postal_code_in_area(p_postal text, p_area text[]) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(cardinality(p_area), 0) = 0
      or exists (
           select 1
           from unnest(p_area) as a
           cross join lateral (select upper(regexp_replace(coalesce(p_postal, ''), '[[:space:]]', '', 'g')) as pc,
                                      upper(regexp_replace(a, '[[:space:]]', '', 'g')) as ac) n
           where n.pc <> ''
             and (n.pc = n.ac or (n.pc ~ '^[0-9]{5}-[0-9]{4}$' and left(n.pc, 5) = n.ac)))
$$;

-- ---------------------------------------------------------------------------
-- price_services_core — INTERNAL (no caller checks; used by price_services,
-- create_online_booking and public_validate_coupon).
--
-- For each service id (de-duplicated, input order kept) the catalog price
-- and duration for the vehicle category (category row, else base row —
-- public.service_price_for). When p_apply_membership, the customer's ACTIVE
-- memberships apply: shop-wide ones, plus vehicle-scoped ones whose vehicle
-- is p_vehicle_id. A service in any applicable plan's included_service_ids
-- is priced 0 with a note naming the plan; the largest plan discount_bps is
-- returned as the suggested document discount (percent). Callers decide
-- whether a coupon replaces it.
--
-- Result:
--   { vehicle_category_id, tax_rate_bps, duration_minutes, priced,
--     lines: [{service_id, name, kind, taxable, duration_minutes,
--              catalog_price_cents, unit_price_cents, membership_included, note}],
--     memberships: [{membership_id, plan_id, plan_name, discount_bps, vehicle_id}],
--     suggested_discount_kind ('none'|'percent'), suggested_discount_value,
--     totals: {subtotal_cents, discount_cents, tax_cents, total_cents} | null }
-- priced = every line has a price (a missing catalog price is null and the
-- totals are null). Every service must be an active, non-archived service
-- of the shop (22023 otherwise).
-- ---------------------------------------------------------------------------
create function public.price_services_core(
  p_shop_id              uuid,
  p_customer_id          uuid,
  p_vehicle_category_id  uuid,
  p_service_ids          uuid[],
  p_vehicle_id           uuid default null,
  p_apply_membership     boolean default true
) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_ids       uuid[];
  v_found     integer;
  v_members   jsonb := '[]'::jsonb;
  v_disc      integer := 0;
  v_lines     jsonb;
  v_priced    boolean;
  v_duration  integer;
  v_tax       integer;
  v_totals    public.document_totals;
  v_apply     boolean := coalesce(p_apply_membership, false) and p_customer_id is not null;
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
                      'membership_id', m.id,
                      'plan_id', p.id,
                      'plan_name', p.name,
                      'discount_bps', p.discount_bps,
                      'vehicle_id', m.vehicle_id) order by p.name, m.id), '[]'::jsonb),
           coalesce(max(p.discount_bps), 0)
      into v_members, v_disc
      from public.memberships m
      join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
     where m.shop_id = p_shop_id and m.customer_id = p_customer_id and m.status = 'active'
       and (m.vehicle_id is null or m.vehicle_id = p_vehicle_id);
  end if;

  with lines as (
    select u.o, s.id, s.name, s.kind, s.taxable, pr.price_cents, pr.duration_minutes,
           (select p.name
              from public.memberships m
              join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
             where v_apply
               and m.shop_id = p_shop_id and m.customer_id = p_customer_id and m.status = 'active'
               and (m.vehicle_id is null or m.vehicle_id = p_vehicle_id)
               and s.id = any (p.included_service_ids)
             order by p.name, p.id
             limit 1) as included_by
    from unnest(v_ids) with ordinality as u(id, o)
    join public.services s on s.id = u.id and s.shop_id = p_shop_id
    cross join lateral public.service_price_for(s.id, p_vehicle_category_id) pr
  )
  select jsonb_agg(jsonb_build_object(
           'service_id', l.id,
           'name', l.name,
           'kind', l.kind,
           'taxable', l.taxable,
           'duration_minutes', l.duration_minutes,
           'catalog_price_cents', l.price_cents,
           'unit_price_cents', case when l.included_by is not null then 0 else l.price_cents end,
           'membership_included', l.included_by is not null,
           'note', case when l.included_by is not null then 'Included with your ' || l.included_by || ' membership' end)
           order by l.o),
         bool_and(l.price_cents is not null or l.included_by is not null),
         sum(l.duration_minutes)::integer
    into v_lines, v_priced, v_duration
    from lines l;

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
-- price_services — staff (owner/admin/manager) pricing preview for building
-- jobs, quotes and invoices. p_vehicle_id (optional) must belong to the
-- customer (the customer defaults to the vehicle's owner) and supplies the
-- category when p_vehicle_category_id is null; vehicle-scoped memberships
-- apply only to that vehicle. Technicians get 42501 (memberships and pricing
-- rules are manager+ data); non-members get 42501.
-- ---------------------------------------------------------------------------
create function public.price_services(
  p_shop                 uuid,
  p_customer_id          uuid,
  p_service_ids          uuid[],
  p_vehicle_category_id  uuid default null,
  p_vehicle_id           uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_customer  uuid := p_customer_id;
  v_cat       uuid := p_vehicle_category_id;
  v_vehicle   public.vehicles;
begin
  if not public.is_shop_member(p_shop) then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if not public.is_shop_manager(p_shop) then
    raise exception 'only owners, admins and managers can price services' using errcode = '42501';
  end if;
  if p_vehicle_id is not null then
    select * into v_vehicle from public.vehicles v where v.id = p_vehicle_id and v.shop_id = p_shop;
    if not found then
      raise exception 'vehicle not found' using errcode = 'P0002';
    end if;
    if v_customer is null then
      v_customer := v_vehicle.customer_id;
    elsif v_customer <> v_vehicle.customer_id then
      raise exception 'the vehicle does not belong to this customer' using errcode = '22023';
    end if;
    v_cat := coalesce(v_cat, v_vehicle.category_id);
  end if;
  if v_customer is not null
     and not exists (select 1 from public.customers c where c.id = v_customer and c.shop_id = p_shop) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if v_cat is not null
     and not exists (select 1 from public.vehicle_categories vc where vc.id = v_cat and vc.shop_id = p_shop) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  return public.price_services_core(p_shop, v_customer, v_cat, p_service_ids, p_vehicle_id, true);
end
$$;

-- ---------------------------------------------------------------------------
-- Indexes used by the booking / portal lookups (customer by email across or
-- within shops; online bookings per shop by creation time for rate limits).
-- ---------------------------------------------------------------------------
create index customers_lower_email_idx on public.customers (lower(email::text), shop_id) where email is not null;
create index jobs_shop_online_created_idx on public.jobs (shop_id, created_at) where source = 'online_booking';

-- ---------------------------------------------------------------------------
-- Grants: everything here is internal except price_services.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.is_api_request(),
  public.effective_now(timestamptz),
  public.portal_confirmed_email(),
  public.payload_text(jsonb, text, integer, text, boolean),
  public.payload_bool(jsonb, text, text, boolean),
  public.payload_int(jsonb, text, text, integer, integer),
  public.payload_uuid(jsonb, text, text),
  public.payload_uuid_array(jsonb, text, text, integer),
  public.price_services_core(uuid, uuid, uuid, uuid[], uuid, boolean)
from public, anon, authenticated;
grant execute on function
  public.is_api_request(),
  public.effective_now(timestamptz),
  public.portal_confirmed_email(),
  public.payload_text(jsonb, text, integer, text, boolean),
  public.payload_bool(jsonb, text, text, boolean),
  public.payload_int(jsonb, text, text, integer, integer),
  public.payload_uuid(jsonb, text, text),
  public.payload_uuid_array(jsonb, text, text, integer),
  public.price_services_core(uuid, uuid, uuid, uuid[], uuid, boolean)
to service_role;

revoke execute on function public.normalize_phone_e164(text, text), public.postal_code_in_area(text, text[])
  from public, anon;
grant execute on function public.normalize_phone_e164(text, text), public.postal_code_in_area(text, text[])
  to authenticated, service_role;

revoke execute on function public.price_services(uuid, uuid, uuid[], uuid, uuid) from public, anon;
grant execute on function public.price_services(uuid, uuid, uuid[], uuid, uuid) to authenticated, service_role;
