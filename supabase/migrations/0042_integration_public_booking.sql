-- ============================================================================
-- 0042 — Public online booking (SPEC §4.9, §6 /book/:slug and
-- /booking/:token): public_shop_profile, public_booking_catalog,
-- public_validate_coupon, create_online_booking, public_get_booking,
-- public_cancel_booking. All anon + authenticated, SECURITY DEFINER, curated
-- JSON only.
--
-- Trust rules
--   * Prices, durations, totals, taxes and deposits come ONLY from the
--     catalog and shop settings; any price-like keys in the payload are
--     ignored. The slot is re-validated with the exact get_available_slots
--     rules while holding a per-shop transaction advisory lock, so two
--     concurrent bookings can never both take the last capacity.
--   * Time checks use the server clock for API callers (effective_now, 0040).
--   * Membership pricing applies only when the caller is the signed-in client
--     linked to the customer (a confirmed email): typing a member's email
--     address into the public form never unlocks their benefits.
--   * Abuse limit: at most 5 online bookings per email address or phone
--     number per shop in any rolling 24 hours (wall clock), error PT429
--     (PostgREST answers HTTP 429).
--
-- Customer matching (within the shop, non-archived customers only)
--   1. same email (case-insensitive) — the signed-in caller's linked record
--      first, then one with the phone the form gives, then the most recent —
--      skipping a record whose phone is UNVERIFIED (below) unless the form
--      gives that same phone or the caller is the verified owner of the email
--   2. else same phone, among customers WITHOUT an email (a phone shared by
--      someone with a different email is a different person)
--   3. else a new customer (source online_booking)
-- Unverified phones: a public form proves neither the email nor the phone.
-- Whoever books first with an email creates its customer with THEIR phone,
-- and every text about that customer's jobs (confirmation, reminders, each
-- with the /booking link that reads and cancels the job) goes to that phone.
-- If a later booking with the same email were attached to that record, a
-- stranger who booked first with someone's email would receive that
-- person's appointments, service address and booking links. So a customer
-- created by a booking that did not prove the email (anonymous, or signed in
-- as someone else) with a phone is marked phone_unverified; a later booking
-- with a different phone (or none) gets its own customer instead, with
-- exactly the details entered. The mark clears when anyone else sets the
-- phone (staff, imports), and the verified owner of the email (signed in,
-- confirmed, or linked) replaces an unverified phone with the one they give
-- (or none) and that booking's SMS opt-in. (The record's SMS opt-out follows
-- the new number, 0033 customers_comms_suppressed: a STOP from the old
-- number keeps that number suppressed but does not block the owner's own.)
-- Otherwise a matched customer is never overwritten. An anonymous (unverified)
-- booking may only fill EMPTY names on it; contact details, opt-ins, the
-- address (a mobile service address, only when the customer has no address
-- fields on file at all) and the reused vehicle are filled (only where
-- empty) solely when the booking is trusted to be that customer: the customer was created by
-- this booking, or the caller is the signed-in client linked to it (or whose
-- confirmed email is its email, which also links it). Otherwise a stranger
-- could attach their own phone/email to someone else's record and receive
-- (or, through portal_claim_customers, take over) that customer's messages.
-- A signed-in client may instead book one of their own saved vehicles
-- (vehicle.id), which books for that vehicle's customer.
-- A trusted booking reuses the customer's vehicle with the same make/model
-- (and compatible year), else creates one; a reused (or saved) vehicle's
-- on-file category decides price, duration and the slot check, the form's
-- category only fills a vehicle that has none. An untrusted booking always
-- creates a new vehicle from the submitted fields only: reusing a matched
-- customer's vehicle would show its on-file year/trim/color on the booking
-- and form pages (whose tokens the anonymous caller holds) and attach a
-- stranger's booking to that vehicle's service history.
--
-- starts_at: an ISO-8601 date-time. With an offset ('Z', '+02', '-05:00')
-- it is that instant; without one it is wall-clock time in the SHOP's time
-- zone (never the database session's). A local time that does not exist or
-- occurs twice there (daylight-saving changes) must carry an offset.
--
-- The job token is the customer's credential. Whoever holds it can, without
-- signing in, read the booking page (with the invoice link, paid total and
-- balance) and cancel the appointment, i.e. act as the customer. So staff
-- roles that may not do that must never see it: `authenticated` gets SELECT
-- on every jobs column EXCEPT public_token (a technician reads their
-- assigned jobs but not the token; SPEC §3 money row + §4.4 no cancelling),
-- and owners/admins/managers fetch it with job_booking_token(job_id) to
-- share the /booking link. Realtime honours the same column privileges.
-- A migration that adds a jobs column must grant SELECT on it to
-- authenticated (40_booking_token_privacy.sql checks the whole column set).
-- Defence in depth: public_cancel_booking still refuses a signed-in
-- technician of the job's shop (42501) unless they are the client linked to
-- the job's customer.
--
-- Error codes: P0002 unknown shop/booking/vehicle; 55000 online booking off;
-- 22023 invalid input (message says which field); 23P01 slot no longer
-- available; PT429 daily limit reached.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Why a coupon cannot be redeemed at p_now (null = redeemable).
create function public.coupon_unavailable_reason(p_coupon public.coupons, p_now timestamptz) returns text
language sql stable
set search_path = ''
as $$
  select case
    when p_coupon.id is null then 'this coupon code is not valid'
    when not p_coupon.active then 'this coupon is no longer active'
    when p_coupon.starts_at is not null and p_now < p_coupon.starts_at then 'this coupon is not active yet'
    when p_coupon.ends_at is not null and p_now >= p_coupon.ends_at then 'this coupon has expired'
    when p_coupon.max_redemptions is not null and p_coupon.redemptions >= p_coupon.max_redemptions
      then 'this coupon has been fully redeemed'
  end
$$;

-- Raises 22023 unless every id is an active, online-bookable, non-archived
-- service of the shop whose kind is one of p_kinds.
create function public.booking_check_bookable(
  p_shop_id  uuid,
  p_ids      uuid[],
  p_kinds    public.service_kind[],
  p_label    text
) returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if exists (select 1 from unnest(coalesce(p_ids, '{}'::uuid[])) as x
             where not exists (select 1 from public.services s
                               where s.id = x and s.shop_id = p_shop_id and s.active and s.online_bookable
                                 and s.archived_at is null and s.kind = any (p_kinds))) then
    raise exception 'one or more % are not available for online booking', p_label using errcode = '22023';
  end if;
end
$$;

-- Reads a booking start (see the header): an ISO-8601 date-time with an
-- offset is that instant; one without an offset is wall-clock time in p_tz.
-- 22023 for anything else, and for local times that do not exist or are
-- ambiguous in p_tz (DST changes). Transitions are never closer than a few
-- days apart, so the offsets in effect one day either side are the only
-- candidates.
create function public.booking_parse_start(p_raw text, p_tz text) returns timestamptz
language plpgsql stable
set search_path = ''
as $$
declare
  c_local  constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?';
  v_local  timestamp;
  v_guess  timestamptz;
  v_found  timestamptz[];
begin
  if p_raw ~ (c_local || '([Zz]|[+-][0-9]{2}(:?[0-9]{2})?)$') then
    begin
      return p_raw::timestamptz;
    exception when others then
      raise exception 'starts_at must be an ISO-8601 date and time' using errcode = '22023';
    end;
  end if;
  if p_raw !~ (c_local || '$') then
    raise exception 'starts_at must be an ISO-8601 date and time' using errcode = '22023';
  end if;
  begin
    v_local := p_raw::timestamp;
  exception when others then
    raise exception 'starts_at must be an ISO-8601 date and time' using errcode = '22023';
  end;
  v_guess := v_local at time zone p_tz;
  -- every instant whose local wall time in p_tz is exactly v_local
  select coalesce(array_agg(distinct c.t), '{}') into v_found
    from (select (v_local - ((x at time zone p_tz) - (x at time zone 'UTC'))) at time zone 'UTC' as t
            from unnest(array[v_guess - interval '1 day', v_guess, v_guess + interval '1 day']) as x) c
   where (c.t at time zone p_tz) = v_local;
  if cardinality(v_found) = 0 then
    raise exception 'starts_at % does not exist in the shop''s time zone (daylight saving change); send the time with its UTC offset', p_raw
      using errcode = '22023';
  end if;
  if cardinality(v_found) > 1 then
    raise exception 'starts_at % occurs twice in the shop''s time zone (daylight saving change); send the time with its UTC offset', p_raw
      using errcode = '22023';
  end if;
  return v_found[1];
end
$$;

-- Canonical-totals input lines from a price_services_core result.
create function public.booking_document_lines(p_pricing jsonb) returns jsonb
language sql immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('quantity', 1,
                                               'unit_price_cents', (e ->> 'unit_price_cents')::bigint,
                                               'taxable', (e ->> 'taxable')::boolean) order by o), '[]'::jsonb)
  from jsonb_array_elements(p_pricing -> 'lines') with ordinality as t(e, o)
$$;

-- ---------------------------------------------------------------------------
-- public_shop_profile(slug) — booking page header. Works while online
-- booking is disabled (booking.enabled tells the page what to show).
-- ---------------------------------------------------------------------------
create function public.public_shop_profile(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_bs   public.booking_settings;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  return jsonb_build_object(
    'name', v_shop.name,
    'slug', v_shop.slug,
    'logo_path', v_shop.logo_path,
    'brand_color', v_shop.brand_color,
    'phone', v_shop.phone,
    'website', v_shop.website,
    'city', v_shop.city,
    'region', v_shop.region,
    'country', v_shop.country,
    'timezone', v_shop.timezone,
    'currency', v_shop.currency,
    'business_type', v_shop.business_type,
    'tax_rate_bps', v_shop.tax_rate_bps,
    'booking', jsonb_build_object(
      'enabled', coalesce(v_bs.enabled, false),
      'auto_confirm', coalesce(v_bs.auto_confirm, false),
      'lead_time_minutes', v_bs.lead_time_minutes,
      'max_days_ahead', v_bs.max_days_ahead,
      'slot_interval_minutes', v_bs.slot_interval_minutes,
      'require_deposit', coalesce(v_bs.require_deposit, false),
      'deposit_type', case when v_bs.require_deposit then v_bs.deposit_type end,
      'deposit_value', case when v_bs.require_deposit then v_bs.deposit_value end,
      'service_area_limited', coalesce(cardinality(v_bs.service_area_postal_codes), 0) > 0,
      'booking_message', v_bs.booking_message,
      'cancellation_policy', v_bs.cancellation_policy,
      'allow_client_cancel_hours', v_bs.allow_client_cancel_hours));
end
$$;

-- ---------------------------------------------------------------------------
-- public_booking_catalog(slug) — what can be booked online: active,
-- online-bookable, non-archived services/packages/add-ons that have at
-- least one price. Prices are resolved per vehicle category (category price,
-- else base) plus the base price for "no category". addon_ids lists the
-- bookable add-ons offered with each service (a service without explicit
-- add-on links offers every bookable add-on). Packages list the names of
-- what they include.
-- ---------------------------------------------------------------------------
create function public.public_booking_catalog(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop    public.shops;
  v_enabled boolean;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;

  return (
    with bookable as (
      select s.*
      from public.services s
      where s.shop_id = v_shop.id and s.active and s.online_bookable and s.archived_at is null
        and s.kind in ('service', 'package', 'addon')
        and exists (select 1 from public.service_prices sp where sp.service_id = s.id and sp.shop_id = s.shop_id)
    ),
    item as (
      select b.id, b.kind, b.sort, b.name,
             jsonb_build_object(
               'id', b.id,
               'category_id', b.category_id,
               'name', b.name,
               'description', b.description,
               'kind', b.kind,
               'image_path', b.image_path,
               'duration_minutes', b.duration_minutes,
               'base_price_cents', (select pr.price_cents from public.service_price_for(b.id, null) pr),
               'prices', coalesce((
                 select jsonb_agg(jsonb_build_object('vehicle_category_id', vc.id,
                                                     'price_cents', pr.price_cents,
                                                     'duration_minutes', pr.duration_minutes)
                                  order by vc.sort, vc.name, vc.id)
                 from public.vehicle_categories vc
                 cross join lateral public.service_price_for(b.id, vc.id) pr
                 where vc.shop_id = v_shop.id and pr.price_cents is not null), '[]'::jsonb)) as base,
             case when b.kind = 'package' then coalesce((
               select jsonb_agg(inc.name order by pi.sort, inc.name, inc.id)
               from public.package_items pi
               join public.services inc on inc.id = pi.service_id and inc.shop_id = pi.shop_id
               where pi.package_id = b.id and pi.shop_id = b.shop_id), '[]'::jsonb)
             else '[]'::jsonb end as includes,
             case when exists (select 1 from public.service_addons sa where sa.service_id = b.id and sa.shop_id = b.shop_id)
               then coalesce((select jsonb_agg(a.id order by a.sort, a.name, a.id)
                                from public.service_addons sa
                                join bookable a on a.id = sa.addon_id and a.kind = 'addon'
                               where sa.service_id = b.id and sa.shop_id = b.shop_id), '[]'::jsonb)
               else coalesce((select jsonb_agg(a.id order by a.sort, a.name, a.id) from bookable a where a.kind = 'addon'),
                             '[]'::jsonb)
             end as addon_ids
      from bookable b
    )
    select jsonb_build_object(
      'vehicle_categories', coalesce((
        select jsonb_agg(jsonb_build_object('id', vc.id, 'name', vc.name) order by vc.sort, vc.name, vc.id)
        from public.vehicle_categories vc where vc.shop_id = v_shop.id), '[]'::jsonb),
      'service_categories', coalesce((
        select jsonb_agg(jsonb_build_object('id', sc.id, 'name', sc.name) order by sc.sort, sc.name, sc.id)
        from public.service_categories sc
        where sc.shop_id = v_shop.id and exists (select 1 from bookable b where b.category_id = sc.id)), '[]'::jsonb),
      'services', coalesce((
        select jsonb_agg(i.base || jsonb_build_object('includes', i.includes, 'addon_ids', i.addon_ids)
                         order by i.sort, i.name, i.id)
        from item i where i.kind in ('service', 'package')), '[]'::jsonb),
      'addons', coalesce((
        select jsonb_agg(i.base order by i.sort, i.name, i.id)
        from item i where i.kind = 'addon'), '[]'::jsonb))
  );
end
$$;

-- ---------------------------------------------------------------------------
-- public_validate_coupon — discount preview for the booking wizard. Invalid
-- codes are an answer, not an error: {valid: false, message}. Services (and
-- add-ons) must be bookable and priced for the vehicle category.
-- Result keys: valid, message, code, kind, value, description,
-- subtotal_cents, discount_cents, tax_cents, total_cents.
-- ---------------------------------------------------------------------------
create function public.public_validate_coupon(
  p_slug                 text,
  p_code                 text,
  p_service_ids          uuid[],
  p_vehicle_category_id  uuid,
  p_now                  timestamptz default now()
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_now     timestamptz := public.effective_now(p_now);
  v_shop    public.shops;
  v_enabled boolean;
  v_code    text := nullif(btrim(p_code), '');
  v_ids     uuid[];
  v_pricing jsonb;
  v_coupon  public.coupons;
  v_reason  text;
  v_t       public.document_totals;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if p_vehicle_category_id is not null and not exists (
       select 1 from public.vehicle_categories vc where vc.id = p_vehicle_category_id and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  v_ids := array(select distinct x from unnest(p_service_ids) as x where x is not null);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 40 then
    raise exception 'too many services (max 40)' using errcode = '22023';
  end if;
  perform public.booking_check_bookable(v_shop.id, v_ids, array['service', 'package', 'addon']::public.service_kind[],
                                        'services');
  v_pricing := public.price_services_core(v_shop.id, null, p_vehicle_category_id, v_ids, null, false);
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;

  if v_code is null or char_length(v_code) > 40 or v_code !~ '^[A-Za-z0-9_-]+$' then
    v_reason := 'this coupon code is not valid';
  else
    select * into v_coupon from public.coupons c where c.shop_id = v_shop.id and lower(c.code::text) = lower(v_code);
    v_reason := public.coupon_unavailable_reason(v_coupon, v_now);
  end if;

  if v_reason is not null then
    return jsonb_build_object(
      'valid', false,
      'message', v_reason,
      'code', left(v_code, 40),
      'kind', null,
      'value', null,
      'description', null,
      'subtotal_cents', (v_pricing #>> '{totals,subtotal_cents}')::bigint,
      'discount_cents', 0,
      'tax_cents', (v_pricing #>> '{totals,tax_cents}')::bigint,
      'total_cents', (v_pricing #>> '{totals,total_cents}')::bigint);
  end if;

  v_t := public.compute_document_totals(public.booking_document_lines(v_pricing),
                                        v_coupon.kind::text::public.discount_kind, v_coupon.value, v_shop.tax_rate_bps);
  return jsonb_build_object(
    'valid', true,
    'message', null,
    'code', v_coupon.code::text,
    'kind', v_coupon.kind,
    'value', v_coupon.value,
    'description', v_coupon.description,
    'subtotal_cents', v_t.subtotal_cents,
    'discount_cents', v_t.discount_cents,
    'tax_cents', v_t.tax_cents,
    'total_cents', v_t.total_cents);
end
$$;

-- ---------------------------------------------------------------------------
-- customers.phone_unverified — provenance of the phone on file (see the
-- header, "Customer matching"). Set only by create_online_booking when a
-- booking that did not prove the email (anonymous, or signed in as someone
-- else) creates the customer with a phone. Cleared whenever the phone is set
-- by anyone else (staff, imports, the verified email owner), or confirmed by
-- the verified email owner.
-- ---------------------------------------------------------------------------
alter table public.customers
  add column phone_unverified boolean not null default false;

comment on column public.customers.phone_unverified is
  'True when the phone came from the public booking form of a booker who did not prove this email (they created the record): it may be a stranger''s number. Later online bookings with this email reuse the record only with the same phone; the verified email owner replaces it. Cleared when anyone else sets the phone.';

create function public.customers_phone_unverified_reset() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.phone is distinct from old.phone and new.phone_unverified is not distinct from old.phone_unverified then
    new.phone_unverified := false;
  end if;
  return new;
end
$$;

create trigger customers_40_phone_unverified_reset before update of phone on public.customers
  for each row execute function public.customers_phone_unverified_reset();

-- ---------------------------------------------------------------------------
-- create_online_booking(slug, payload, p_now) — see the header for the rules.
-- Payload:
--   customer   {first_name*, last_name, email*, phone, sms_opt_in, email_opt_in}
--              (* not needed when booking a saved vehicle)
--   vehicle    {year, make*, model*, trim, color, license_plate, vin, category_id}
--              or {id} of the signed-in client's own vehicle (+ optional
--              category_id used only when that vehicle has none)
--   service_ids [uuid] (services / packages, 1-20), addon_ids [uuid] (0-20)
--   starts_at  ISO-8601 timestamp of one of get_available_slots' starts
--              (with an offset; without one it is shop-local wall time)
--   location   {type: 'shop'|'mobile', address_line1*, address_line2, city*,
--              region, postal_code*} (* for mobile; type defaults to what
--              the shop offers)
--   notes (≤2000), coupon_code
-- Returns {job_token, job_number, status, total_cents, deposit_required_cents}.
-- ---------------------------------------------------------------------------
create function public.create_online_booking(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_max_items     constant integer := 20;
  c_daily_limit   constant integer := 5;
  v_now           timestamptz := public.effective_now(p_now);
  v_uid           uuid := auth.uid();
  v_portal_email  text := public.portal_confirmed_email();
  v_shop          public.shops;
  v_bs            public.booking_settings;
  v_cust_in       jsonb;
  v_veh_in        jsonb;
  v_loc_in        jsonb;
  v_first         text;
  v_last          text;
  v_email         text;
  v_phone_raw     text;
  v_phone         text;
  v_sms_opt       boolean;
  v_email_opt     boolean;
  v_veh_id        uuid;
  v_year          integer;
  v_make          text;
  v_model         text;
  v_trim          text;
  v_color         text;
  v_plate         text;
  v_vin           text;
  v_cat           uuid;
  v_service_ids   uuid[];
  v_addon_ids     uuid[];
  v_all_ids       uuid[];
  v_start_raw     text;
  v_start         timestamptz;
  v_end           timestamptz;
  v_loc_raw       text;
  v_loc_type      public.location_type;
  v_line1         text;
  v_line2         text;
  v_city          text;
  v_region        text;
  v_postal        text;
  v_notes         text;
  v_code          text;
  v_coupon        public.coupons;
  v_reason        text;
  v_customer      public.customers;
  v_vehicle       public.vehicles;
  v_pricing       jsonb;
  v_line          record;
  v_job           public.jobs;
  v_disc_kind     public.discount_kind := 'none';
  v_disc_value    bigint := 0;
  v_deposit       bigint := 0;
  v_recent        integer;
  v_created       boolean := false;
  v_trusted       boolean;
  v_fill_addr     boolean;
  v_new_phone     boolean;
begin
  -- ------------------------------------------------------------ shop
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  if not found or not v_bs.enabled then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;

  -- ------------------------------------------------------------ payload shape
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'booking details must be a JSON object' using errcode = '22023';
  end if;
  v_cust_in := p_payload -> 'customer';
  v_veh_in := p_payload -> 'vehicle';
  v_loc_in := p_payload -> 'location';
  if coalesce(jsonb_typeof(v_cust_in), 'null') not in ('object', 'null') then
    raise exception 'customer must be an object' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(v_veh_in), 'null') <> 'object' then
    raise exception 'vehicle details are required' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(v_loc_in), 'null') not in ('object', 'null') then
    raise exception 'location must be an object' using errcode = '22023';
  end if;

  -- ------------------------------------------------------------ services
  v_service_ids := public.payload_uuid_array(p_payload, 'service_ids', 'services', c_max_items);
  v_addon_ids := public.payload_uuid_array(p_payload, 'addon_ids', 'add-ons', c_max_items);
  if cardinality(v_service_ids) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  v_addon_ids := array(select a.id from unnest(v_addon_ids) with ordinality as a(id, o)
                        where a.id <> all (v_service_ids) order by a.o);
  perform public.booking_check_bookable(v_shop.id, v_service_ids, array['service', 'package']::public.service_kind[],
                                        'services');
  perform public.booking_check_bookable(v_shop.id, v_addon_ids, array['addon']::public.service_kind[], 'add-ons');
  -- an add-on must be offered with at least one chosen service (a service
  -- without add-on links offers every add-on)
  if exists (
       select 1 from unnest(v_addon_ids) as a
       where not exists (
         select 1 from unnest(v_service_ids) as s
         where not exists (select 1 from public.service_addons sa where sa.service_id = s and sa.shop_id = v_shop.id)
            or exists (select 1 from public.service_addons sa
                       where sa.service_id = s and sa.addon_id = a and sa.shop_id = v_shop.id))) then
    raise exception 'one or more add-ons are not offered with the selected services' using errcode = '22023';
  end if;
  v_all_ids := v_service_ids || v_addon_ids;

  -- ------------------------------------------------------------ when
  v_start_raw := public.payload_text(p_payload, 'starts_at', 64, 'starts_at', true);
  v_start := public.booking_parse_start(v_start_raw, v_shop.timezone);

  -- ------------------------------------------------------------ vehicle
  v_veh_id := public.payload_uuid(v_veh_in, 'id', 'vehicle id');
  v_cat := public.payload_uuid(v_veh_in, 'category_id', 'vehicle category');
  if v_cat is not null and not exists (
       select 1 from public.vehicle_categories vc where vc.id = v_cat and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  if v_veh_id is not null then
    -- a saved vehicle: only the signed-in client linked to its owner may book it
    select v.* into v_vehicle
      from public.vehicles v
      join public.customers c on c.id = v.customer_id and c.shop_id = v.shop_id
     where v.id = v_veh_id and v.shop_id = v_shop.id and v.archived_at is null and c.archived_at is null
       and v_uid is not null and c.portal_user_id = v_uid;
    if not found then
      raise exception 'vehicle not found' using errcode = 'P0002';
    end if;
    v_cat := coalesce(v_vehicle.category_id, v_cat);
    select * into v_customer from public.customers c where c.id = v_vehicle.customer_id and c.shop_id = v_shop.id;
  else
    v_year := public.payload_int(v_veh_in, 'year', 'vehicle year', 1886, 2100);
    v_make := public.payload_text(v_veh_in, 'make', 60, 'vehicle make', true);
    v_model := public.payload_text(v_veh_in, 'model', 60, 'vehicle model', true);
    v_trim := public.payload_text(v_veh_in, 'trim', 60, 'vehicle trim');
    v_color := public.payload_text(v_veh_in, 'color', 40, 'vehicle color');
    v_plate := upper(public.payload_text(v_veh_in, 'license_plate', 15, 'license plate'));
    v_vin := nullif(upper(regexp_replace(coalesce(public.payload_text(v_veh_in, 'vin', 40, 'VIN'), ''),
                                         '[[:space:]-]', '', 'g')), '');
    if v_vin is not null and v_vin !~ '^[A-Z0-9]{5,17}$' then
      raise exception 'VIN must be 5-17 letters and digits' using errcode = '22023';
    end if;
  end if;

  -- ------------------------------------------------------------ contact
  if v_customer.id is null and coalesce(jsonb_typeof(v_cust_in), 'null') <> 'object' then
    raise exception 'contact details are required' using errcode = '22023';
  end if;
  v_first := public.payload_text(v_cust_in, 'first_name', 100, 'first name', v_customer.id is null);
  v_last := public.payload_text(v_cust_in, 'last_name', 100, 'last name');
  v_email := lower(public.payload_text(v_cust_in, 'email', 254, 'email', v_customer.id is null));
  if v_email is not null and not public.is_valid_email(v_email) then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  v_phone_raw := public.payload_text(v_cust_in, 'phone', 32, 'phone');
  if v_phone_raw is not null then
    v_phone := public.normalize_phone_e164(v_phone_raw, v_shop.country);
    if v_phone is null then
      raise exception 'enter a valid phone number' using errcode = '22023';
    end if;
  end if;
  v_sms_opt := public.payload_bool(v_cust_in, 'sms_opt_in', 'sms_opt_in');
  v_email_opt := public.payload_bool(v_cust_in, 'email_opt_in', 'email_opt_in');

  -- ------------------------------------------------------------ where
  v_loc_raw := lower(public.payload_text(v_loc_in, 'type', 10, 'location type'));
  if v_loc_raw is null then
    v_loc_type := case when v_shop.business_type = 'mobile' then 'mobile' else 'shop' end;
  elsif v_loc_raw in ('shop', 'mobile') then
    v_loc_type := v_loc_raw::public.location_type;
  else
    raise exception 'location type must be shop or mobile' using errcode = '22023';
  end if;
  if v_loc_type = 'shop' and v_shop.business_type = 'mobile' then
    raise exception 'this shop only offers mobile service; enter the service address' using errcode = '22023';
  end if;
  if v_loc_type = 'mobile' and v_shop.business_type = 'fixed' then
    raise exception 'this shop does not offer mobile service' using errcode = '22023';
  end if;
  if v_loc_type = 'mobile' then
    v_line1 := public.payload_text(v_loc_in, 'address_line1', 200, 'street address', true);
    v_line2 := public.payload_text(v_loc_in, 'address_line2', 200, 'address line 2');
    v_city := public.payload_text(v_loc_in, 'city', 100, 'city', true);
    v_region := public.payload_text(v_loc_in, 'region', 100, 'state / region');
    v_postal := upper(public.payload_text(v_loc_in, 'postal_code', 20, 'postal code', true));
    if not public.postal_code_in_area(v_postal, v_bs.service_area_postal_codes) then
      raise exception 'this address is outside our service area' using errcode = '22023';
    end if;
  end if;

  v_notes := public.payload_text(p_payload, 'notes', 2000, 'notes');
  v_code := public.payload_text(p_payload, 'coupon_code', 40, 'coupon code');

  -- every chosen service must have a catalog price for this vehicle category
  v_pricing := public.price_services_core(v_shop.id, null, v_cat, v_all_ids, null, false);
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;

  -- ------------------------------------------------------------ serialize this shop's online bookings
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.create_online_booking:' || v_shop.id::text, 0));

  -- coupon: row-locked so the redemption limit is checked and consumed atomically
  if v_code is not null then
    select * into v_coupon from public.coupons c
     where c.shop_id = v_shop.id and lower(c.code::text) = lower(v_code)
     for update;
    v_reason := public.coupon_unavailable_reason(v_coupon, v_now);
    if v_reason is not null then
      raise exception '%', v_reason using errcode = '22023';
    end if;
  end if;

  -- abuse limit (wall clock, independent of p_now)
  select count(*) into v_recent
    from public.jobs j
    join public.customers c on c.id = j.customer_id and c.shop_id = j.shop_id
   where j.shop_id = v_shop.id
     and j.source = 'online_booking'
     and j.created_at > now() - interval '24 hours'
     and ((v_email is not null and lower(c.email::text) = v_email)
          or (v_phone is not null and c.phone = v_phone)
          or (v_customer.id is not null and c.id = v_customer.id));
  if v_recent >= c_daily_limit then
    raise exception 'too many online bookings for this contact today; please call the shop' using errcode = 'PT429';
  end if;

  -- ------------------------------------------------------------ customer
  if v_customer.id is null then
    -- never a record whose phone came from someone else's unverified form
    -- (unless this booker gives that same phone, or is the verified owner of
    -- the email, whose booking replaces that phone below): the booking would
    -- be texted, booking link included, to that stranger (see the header)
    select * into v_customer from public.customers c
     where c.shop_id = v_shop.id and c.archived_at is null and c.email is not null
       and lower(c.email::text) = v_email
       and (not c.phone_unverified or c.phone is null or c.phone = v_phone
            or coalesce(v_uid is not null
                        and (c.portal_user_id = v_uid
                             or (c.portal_user_id is null and v_portal_email = v_email)), false))
     order by coalesce(v_uid is not null and c.portal_user_id = v_uid, false) desc,
              coalesce(c.phone = v_phone, false) desc, c.created_at desc, c.id
     limit 1;
    if v_customer.id is null and v_phone is not null then
      select * into v_customer from public.customers c
       where c.shop_id = v_shop.id and c.archived_at is null and c.email is null and c.phone = v_phone
       order by c.created_at desc, c.id
       limit 1;
    end if;
    if v_customer.id is null then
      insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, source,
                                    phone_unverified)
      values (v_shop.id, v_first, v_last, v_email::extensions.citext, v_phone, v_sms_opt, v_email_opt, 'online_booking',
              v_phone is not null and v_portal_email is distinct from v_email)
      returning * into v_customer;
      v_created := true;
    end if;
  end if;
  -- Who may change the customer record beyond empty names? Only a customer
  -- created by this booking, or the signed-in client proven to be it (linked
  -- already, or an unlinked record whose email is the caller's confirmed
  -- email). A public form proves nothing: filling a matched customer's empty
  -- phone/email from it would let a stranger redirect that customer's
  -- messages (and, via a confirmed email, claim their portal).
  v_trusted := v_created
            or coalesce(v_uid is not null
                        and (v_customer.portal_user_id = v_uid
                             or (v_customer.portal_user_id is null and v_portal_email is not null
                                 and lower(v_customer.email::text) = v_portal_email)), false);
  -- the verified owner of the email replaces a phone that came from an
  -- unverified form (and that phone's opt-in): it may be a stranger's, and
  -- every text about this customer would go to it
  v_new_phone := v_trusted and not v_created and v_customer.phone_unverified;
  v_fill_addr := v_trusted and v_loc_type = 'mobile'
                 and v_customer.address_line1 is null and v_customer.address_line2 is null
                 and v_customer.city is null and v_customer.region is null and v_customer.postal_code is null
                 and v_customer.lat is null;
  -- fill only what is missing; never overwrite (but for an unverified phone,
  -- above), never opt anyone out
  update public.customers c
     set first_name = coalesce(nullif(btrim(c.first_name), ''), v_first),
         last_name = coalesce(nullif(btrim(c.last_name), ''), v_last),
         email = case when v_trusted then coalesce(c.email, v_email::extensions.citext) else c.email end,
         phone = case when v_new_phone then v_phone
                      when v_trusted then coalesce(c.phone, v_phone)
                      else c.phone end,
         phone_unverified = case when v_new_phone then false else c.phone_unverified end,
         sms_opt_in = case when v_new_phone then coalesce(v_phone is not null and v_sms_opt, false)
                           else c.sms_opt_in or (v_trusted and v_sms_opt) end,
         email_opt_in = c.email_opt_in or (v_trusted and v_email_opt),
         -- the service address becomes the customer's address only when they
         -- have none on file at all: merging it into a partial address (a
         -- city, ZIP or gate code staff entered) would overwrite or mix it
         address_line1 = case when v_fill_addr then v_line1 else c.address_line1 end,
         address_line2 = case when v_fill_addr then v_line2 else c.address_line2 end,
         city = case when v_fill_addr then v_city else c.city end,
         region = case when v_fill_addr then v_region else c.region end,
         postal_code = case when v_fill_addr then v_postal else c.postal_code end,
         portal_user_id = case
           when c.portal_user_id is null and v_uid is not null and v_portal_email is not null
                and lower(coalesce(c.email::text, case when v_trusted then v_email end)) = v_portal_email then v_uid
           else c.portal_user_id end
   where c.id = v_customer.id and c.shop_id = v_shop.id
  returning * into v_customer;

  -- ------------------------------------------------------------ vehicle
  if v_vehicle.id is null then
    -- only a trusted booking may reuse (and see, through the booking page)
    -- one of the customer's vehicles
    if v_trusted then
      select * into v_vehicle from public.vehicles v
       where v.shop_id = v_shop.id and v.customer_id = v_customer.id and v.archived_at is null
         and lower(btrim(v.make)) = lower(v_make) and lower(btrim(v.model)) = lower(v_model)
         and (v_year is null or v.year is null or v.year = v_year)
       order by (v.year is not distinct from v_year) desc, v.created_at desc, v.id
       limit 1;
      -- a reused vehicle is priced and scheduled for its on-file category
      -- (like a saved-vehicle booking); the form's category only fills a gap
      v_cat := coalesce(v_vehicle.category_id, v_cat);
    end if;
    if v_vehicle.id is null then
      insert into public.vehicles (shop_id, customer_id, year, make, model, trim, color, license_plate, vin, category_id)
      values (v_shop.id, v_customer.id, v_year, v_make, v_model, v_trim, v_color, v_plate, v_vin, v_cat)
      returning * into v_vehicle;
    else
      update public.vehicles v
         set year = coalesce(v.year, v_year),
             trim = coalesce(v.trim, v_trim),
             color = coalesce(v.color, v_color),
             license_plate = coalesce(v.license_plate, v_plate),
             vin = coalesce(v.vin, v_vin),
             category_id = coalesce(v.category_id, v_cat)
       where v.id = v_vehicle.id and v.shop_id = v_shop.id
      returning * into v_vehicle;
    end if;
  elsif v_vehicle.category_id is null and v_cat is not null then
    update public.vehicles v set category_id = v_cat where v.id = v_vehicle.id and v.shop_id = v_shop.id
    returning * into v_vehicle;
  end if;

  -- ------------------------------------------------------------ price (catalog only)
  -- v_cat is final here: a reused vehicle's on-file category wins over the form's
  v_pricing := public.price_services_core(v_shop.id, v_customer.id, v_cat, v_all_ids, v_vehicle.id,
                                          v_uid is not null and v_customer.portal_user_id = v_uid);
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;

  -- ------------------------------------------------------------ slot (final category)
  -- The exact slot must still be offered (same rules as get_available_slots),
  -- checked for the category the job is actually priced and scheduled with:
  -- a reused vehicle's on-file category may differ from the form's (its
  -- durations too), so this runs only once the vehicle is settled. Still
  -- under the advisory lock; any failure rolls the whole booking back.
  select s.ends_at into v_end
    from public.get_available_slots(v_shop.slug, v_all_ids, v_cat, (v_start at time zone v_shop.timezone)::date,
                                    (v_start at time zone v_shop.timezone)::date, v_now) s
   where s.starts_at = v_start;
  if v_end is null then
    raise exception 'that time is no longer available; please choose another time' using errcode = '23P01';
  end if;

  -- ------------------------------------------------------------ discount
  if v_coupon.id is not null then
    update public.coupons c
       set redemptions = c.redemptions + 1
     where c.id = v_coupon.id and (c.max_redemptions is null or c.redemptions < c.max_redemptions);
    if not found then
      raise exception 'this coupon has been fully redeemed' using errcode = '22023';
    end if;
    v_disc_kind := v_coupon.kind::text::public.discount_kind;
    v_disc_value := v_coupon.value;
  elsif (v_pricing ->> 'suggested_discount_value')::bigint > 0 then
    v_disc_kind := 'percent';
    v_disc_value := (v_pricing ->> 'suggested_discount_value')::bigint;
  end if;

  -- ------------------------------------------------------------ job
  insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end, location_type,
                           service_address_line1, service_address_line2, service_city, service_region,
                           service_postal_code, notes, source, coupon_id, discount_kind, discount_value)
  values (v_shop.id, v_customer.id, v_vehicle.id,
          case when v_bs.auto_confirm then 'scheduled' else 'requested' end::public.job_status,
          v_start, v_end, v_loc_type, v_line1, v_line2, v_city, v_region, v_postal, v_notes, 'online_booking',
          v_coupon.id, v_disc_kind, v_disc_value)
  returning * into v_job;

  for v_line in
    select e, o from jsonb_array_elements(v_pricing -> 'lines') with ordinality as t(e, o) order by o
  loop
    insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                       unit_price_cents, taxable, duration_minutes, sort)
    values (v_shop.id, v_job.id, (v_line.e ->> 'service_id')::uuid, v_vehicle.id, v_line.e ->> 'name',
            v_line.e ->> 'note', 1, (v_line.e ->> 'unit_price_cents')::bigint, (v_line.e ->> 'taxable')::boolean,
            (v_line.e ->> 'duration_minutes')::integer, v_line.o::integer);
  end loop;

  select * into v_job from public.jobs j where j.id = v_job.id;
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
    'deposit_required_cents', v_job.deposit_required_cents);
end
$$;

-- ---------------------------------------------------------------------------
-- booking_public_json — curated booking page document (internal builder).
-- Deliberately no customer details: a booking token can be minted by anyone
-- who types an email address into the public form, so the page must not
-- reveal what the shop has on file about that customer.
-- ---------------------------------------------------------------------------
create function public.booking_public_json(p_job_id uuid, p_now timestamptz) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_job       public.jobs;
  v_bs        public.booking_settings;
  v_inv       public.invoices;
  v_paid      bigint;
  v_dep_paid  bigint;
  v_pending   boolean;
  v_dep_due   bigint;
  v_deadline  timestamptz;
  v_can       boolean;
  v_coupon    text;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    return null;
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_job.shop_id;
  select * into v_inv from public.invoices i
   where i.shop_id = v_job.shop_id and i.job_id = v_job.id and i.status <> 'void'
   order by i.created_at desc limit 1;
  select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                    filter (where p.kind = 'deposit'), 0),
         coalesce(bool_or(p.status = 'pending'), false)
    into v_paid, v_dep_paid, v_pending
    from public.payments p
   where p.shop_id = v_job.shop_id and p.job_id = v_job.id;
  -- same rule as job_payment_summary (0013): the deposit is capped by what
  -- is actually owed, i.e. the invoice total once there is one (a discount
  -- or edited lines at invoicing can bring it below the job's total)
  v_dep_due := greatest(least(v_job.deposit_required_cents, coalesce(v_inv.total_cents, v_job.total_cents)) - v_paid, 0);

  if v_job.scheduled_start is not null then
    v_deadline := v_job.scheduled_start - make_interval(hours => coalesce(v_bs.allow_client_cancel_hours, 0));
  end if;
  v_can := v_job.status in ('requested', 'scheduled', 'confirmed') and (v_deadline is null or p_now <= v_deadline);
  select c.code::text into v_coupon from public.coupons c where c.id = v_job.coupon_id and c.shop_id = v_job.shop_id;

  return jsonb_build_object(
    'shop', public.money_public_shop_json(v_job.shop_id),
    'booking_message', v_bs.booking_message,
    'booking', jsonb_build_object(
      'number', v_job.number,
      'status', v_job.status,
      'scheduled_start', v_job.scheduled_start,
      'scheduled_end', v_job.scheduled_end,
      'location_type', v_job.location_type,
      'service_address', case when v_job.location_type = 'mobile' then jsonb_build_object(
                            'address_line1', v_job.service_address_line1,
                            'address_line2', v_job.service_address_line2,
                            'city', v_job.service_city,
                            'region', v_job.service_region,
                            'postal_code', v_job.service_postal_code) end,
      'notes', v_job.notes,
      'created_at', v_job.created_at,
      'confirmed_at', v_job.confirmed_at,
      'completed_at', v_job.completed_at,
      'cancelled_at', v_job.cancelled_at,
      'cancel_reason', v_job.cancel_reason),
    'vehicle', public.money_public_vehicle_json(v_job.shop_id, v_job.vehicle_id),
    'line_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', li.name,
               'description', li.description,
               'vehicle_label', public.money_vehicle_label(li.shop_id, li.vehicle_id),
               'quantity', li.quantity,
               'unit_price_cents', li.unit_price_cents,
               'discount_cents', li.discount_cents,
               'taxable', li.taxable,
               'total_cents', li.total_cents)
             order by li.sort, li.created_at, li.id)
      from public.job_line_items li
      where li.job_id = v_job.id and li.shop_id = v_job.shop_id), '[]'::jsonb),
    'totals', jsonb_build_object(
      'subtotal_cents', v_job.subtotal_cents,
      'discount_cents', v_job.discount_cents,
      'coupon_code', v_coupon,
      'tax_rate_bps', v_job.tax_rate_bps,
      'tax_cents', v_job.tax_cents,
      'total_cents', v_job.total_cents,
      'paid_cents', v_paid,
      'balance_cents', coalesce(v_inv.balance_cents, v_job.total_cents - v_paid)),
    'deposit', jsonb_build_object(
      'required_cents', v_job.deposit_required_cents,
      'paid_cents', v_dep_paid,
      'due_cents', v_dep_due,
      'status', case when v_job.deposit_required_cents = 0 then 'not_required'
                     when v_dep_due = 0 then 'paid'
                     else 'due' end,
      'payment_pending', v_pending,
      'card_payments_enabled', coalesce((select a.charges_enabled from public.shop_stripe_accounts a
                                         where a.shop_id = v_job.shop_id), false)),
    'cancellation', jsonb_build_object(
      'allowed', v_can,
      'deadline', v_deadline,
      'allow_client_cancel_hours', v_bs.allow_client_cancel_hours,
      'policy', v_bs.cancellation_policy),
    'forms', coalesce((
      select jsonb_agg(jsonb_build_object(
               'title', fs.title,
               'requires_signature', fs.requires_signature,
               'status', case when fs.signed_at is not null then 'signed'
                              when v_job.status in ('cancelled', 'no_show') then 'void'
                              else 'pending' end,
               'signed_at', fs.signed_at,
               'token', fs.public_token)
             order by fs.created_at, fs.id)
      from public.form_submissions fs
      -- only the current customer's forms: a form signed before the job
      -- moved to another customer stays the previous customer's document
      -- (0023 moves and re-tokens only unsigned ones)
      where fs.job_id = v_job.id and fs.shop_id = v_job.shop_id
        and (fs.signed_at is null or fs.customer_id = v_job.customer_id)), '[]'::jsonb),
    'invoice', case when v_inv.id is not null and v_inv.status <> 'draft' then jsonb_build_object(
      'token', v_inv.public_token,
      'number', v_inv.number,
      'status', v_inv.status,
      'total_cents', v_inv.total_cents,
      'balance_cents', v_inv.balance_cents,
      'due_at', v_inv.due_at) end);
end
$$;

-- ---------------------------------------------------------------------------
-- public_get_booking(token) — the customer's booking page (any job token:
-- online bookings and staff-created appointments alike).
-- ---------------------------------------------------------------------------
create function public.public_get_booking(p_token uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select j.id into v_id from public.jobs j where j.public_token = p_token;
  if v_id is null then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  return public.booking_public_json(v_id, public.effective_now(p_now));
end
$$;

-- ---------------------------------------------------------------------------
-- public_cancel_booking(token, reason, p_now) — customer self-cancellation.
-- Allowed while the job is requested / scheduled / confirmed and, for a
-- scheduled job, until allow_client_cancel_hours before its start (0 = up to
-- the start time). Owner/admin/manager get a booking_cancelled notification.
-- Deposits are not refunded automatically and a redeemed coupon stays
-- redeemed (the shop decides). Technicians may not cancel jobs (SPEC §4.4):
-- they cannot read job tokens (column privileges below), and a signed-in
-- active member of the job's shop below manager who presents one anyway is
-- refused (42501) unless they are the client linked to the job's customer.
-- ---------------------------------------------------------------------------
create function public.public_cancel_booking(p_token uuid, p_reason text default null,
                                             p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v_job      public.jobs;
  v_hours    integer;
  v_deadline timestamptz;
  v_reason   text := nullif(btrim(coalesce(p_reason, ''), E' \t\r\n'), '');
  v_vars     jsonb;
begin
  select * into v_job from public.jobs j where j.public_token = p_token for update;
  if not found then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null and public.is_shop_member(v_job.shop_id) and not public.is_shop_manager(v_job.shop_id)
     and not exists (select 1 from public.customers c
                      where c.id = v_job.customer_id and c.shop_id = v_job.shop_id and c.portal_user_id = auth.uid()) then
    raise exception 'only owners, admins and managers can cancel appointments' using errcode = '42501';
  end if;
  if v_job.status not in ('requested', 'scheduled', 'confirmed') then
    raise exception 'this booking can no longer be cancelled online (it is %)', replace(v_job.status::text, '_', ' ')
      using errcode = '22023';
  end if;
  if char_length(v_reason) > 1000 then
    raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
  end if;
  select b.allow_client_cancel_hours into v_hours from public.booking_settings b where b.shop_id = v_job.shop_id;
  if v_job.scheduled_start is not null then
    v_deadline := v_job.scheduled_start - make_interval(hours => coalesce(v_hours, 0));
    if v_now > v_deadline then
      raise exception 'online cancellation closed % hours before the appointment; please call the shop', coalesce(v_hours, 0)
        using errcode = '22023';
    end if;
  end if;

  update public.jobs j
     set status = 'cancelled',
         cancel_reason = coalesce(v_reason, 'Cancelled by the customer online')
   where j.id = v_job.id
  returning * into v_job;

  begin
    v_vars := public.comms_job_vars(v_job.id);
    perform public.notify_shop_staff(
      v_job.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'booking_cancelled',
      'Booking cancelled by ' || public.integration_customer_label(v_job.shop_id, v_job.customer_id),
      concat_ws(' · ', 'Job #' || v_job.number::text,
                nullif(concat_ws(' at ', v_vars ->> 'job_date', v_vars ->> 'job_time'), ''), v_reason),
      v_job.id, null);
  exception when others then
    raise warning 'booking cancellation notification failed for job %: % (%)', v_job.id, sqlerrm, sqlstate;
  end;

  return public.booking_public_json(v_job.id, v_now);
end
$$;

-- ---------------------------------------------------------------------------
-- job_booking_token(job_id) — the /booking/<token> credential for staff who
-- may act for the customer (owner/admin/manager). Technicians: 42501.
-- Unknown job or another shop's job: P0002.
-- ---------------------------------------------------------------------------
create function public.job_booking_token(p_job_id uuid) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop  uuid;
  v_token uuid;
begin
  select j.shop_id, j.public_token into v_shop, v_token from public.jobs j where j.id = p_job_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can share the booking link' using errcode = '42501';
  end if;
  return v_token;
end
$$;

-- ---------------------------------------------------------------------------
-- jobs.public_token column privilege (see the header): authenticated reads
-- every jobs column except the token. service_role keeps full access (edge
-- functions resolve tokens); anon has no table access (0006).
-- ---------------------------------------------------------------------------
revoke select on public.jobs from authenticated;
do $$
declare
  v_cols text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.jobs'::regclass
     and a.attnum > 0
     and not a.attisdropped
     and a.attname <> 'public_token';
  execute format('grant select (%s) on public.jobs to authenticated', v_cols);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.job_booking_token(uuid) from public, anon, service_role;
grant execute on function public.job_booking_token(uuid) to authenticated;

revoke execute on function public.customers_phone_unverified_reset() from public, anon, authenticated;

revoke execute on function
  public.coupon_unavailable_reason(public.coupons, timestamptz),
  public.booking_parse_start(text, text),
  public.booking_check_bookable(uuid, uuid[], public.service_kind[], text),
  public.booking_document_lines(jsonb),
  public.booking_public_json(uuid, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.coupon_unavailable_reason(public.coupons, timestamptz),
  public.booking_parse_start(text, text),
  public.booking_check_bookable(uuid, uuid[], public.service_kind[], text),
  public.booking_document_lines(jsonb),
  public.booking_public_json(uuid, timestamptz)
to service_role;

revoke execute on function
  public.public_shop_profile(text),
  public.public_booking_catalog(text),
  public.public_validate_coupon(text, text, uuid[], uuid, timestamptz),
  public.create_online_booking(text, jsonb, timestamptz),
  public.public_get_booking(uuid, timestamptz),
  public.public_cancel_booking(uuid, text, timestamptz)
from public;
grant execute on function
  public.public_shop_profile(text),
  public.public_booking_catalog(text),
  public.public_validate_coupon(text, text, uuid[], uuid, timestamptz),
  public.create_online_booking(text, jsonb, timestamptz),
  public.public_get_booking(uuid, timestamptz),
  public.public_cancel_booking(uuid, text, timestamptz)
to anon, authenticated, service_role;
