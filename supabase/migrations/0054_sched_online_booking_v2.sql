-- ============================================================================
-- 0054 — create_online_booking v2 (P-17 / P-9). Same signature, trust rules,
-- customer matching, PT429 limit, coupon, deposit and per-shop advisory lock
-- as 0042 (read its header). Changes:
--   * payload.link_token — a live private booking link of the shop (0053;
--     else PT404): services and add-ons are validated against the link
--     instead of online_bookable (add-ons must still be offered with a chosen
--     service; prices always come from the catalog);
--   * payload.answers — {question_key: value} (object, <= 50 keys, keys like
--     custom field keys) stored in jobs.custom_data in the INSERT itself, so
--     the comms range's BEFORE INSERT validation (required booking
--     questions) sees them;
--   * the slot check runs booking_slots_core with the booking's location
--     type (per-location capacity) and its services' categories (bookable
--     weekdays); a multi-day booking gets the engine's wrap end.
-- Error codes as 0042 (PT404 also for an unknown / inactive / expired link).
-- Later ranges (the range is merged and deployable on its own):
-- price_services_core's p_starts_at (money 0069) and line membership_id
-- (money 0061) are used only once they exist (to_regprocedure / to_regclass
-- checks; the statements behind them are planned only when reached).
-- ============================================================================

create or replace function public.create_online_booking(p_slug text, p_payload jsonb, p_now timestamptz default now())
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
  v_link_token    uuid;
  v_link_ids      uuid[];
  v_answers       jsonb := '{}'::jsonb;
  v_duration      integer;
  v_cats          uuid[];
begin
  -- ------------------------------------------------------------ shop
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
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
  -- a private booking link offers exactly its services (online-bookable or
  -- not) instead of the online catalog
  v_link_token := public.payload_uuid(p_payload, 'link_token', 'booking link');
  if v_link_token is not null then
    v_link_ids := public.booking_link_service_ids(v_shop.id, v_link_token);
    if v_link_ids is null then
      raise exception 'booking link not found' using errcode = 'PT404';
    end if;
    if exists (select 1 from unnest(v_service_ids) as x
               where not (x = any (v_link_ids))
                  or not exists (select 1 from public.services s
                                 where s.id = x and s.shop_id = v_shop.id and s.kind in ('service', 'package'))) then
      raise exception 'one or more services are not available for online booking' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(v_addon_ids) as x
               where not (x = any (v_link_ids))
                  or not exists (select 1 from public.services s
                                 where s.id = x and s.shop_id = v_shop.id and s.kind = 'addon')) then
      raise exception 'one or more add-ons are not available for online booking' using errcode = '22023';
    end if;
  else
    perform public.booking_check_bookable(v_shop.id, v_service_ids, array['service', 'package']::public.service_kind[],
                                          'services');
    perform public.booking_check_bookable(v_shop.id, v_addon_ids, array['addon']::public.service_kind[], 'add-ons');
  end if;
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
      raise exception 'vehicle not found' using errcode = 'PT404';
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
    -- (public_booking_slots / get_available_slots list the slots of the same
    -- default, so every slot they offer can be booked without a location)
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

  -- answers to the shop's booking questions -> jobs.custom_data (the comms
  -- range validates them against the shop's fields when the job is written)
  if p_payload ? 'answers' and jsonb_typeof(p_payload -> 'answers') <> 'null' then
    v_answers := p_payload -> 'answers';
    if jsonb_typeof(v_answers) <> 'object' then
      raise exception 'answers must be an object' using errcode = '22023';
    end if;
    if (select count(*) from jsonb_object_keys(v_answers)) > 50 then
      raise exception 'too many answers (max 50)' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_object_keys(v_answers) k where k !~ '^[a-z][a-z0-9_]{0,39}$') then
      raise exception 'answers must be keyed by question keys' using errcode = '22023';
    end if;
    if octet_length(v_answers::text) > 60000 then
      raise exception 'answers are too long' using errcode = '22023';
    end if;
  end if;

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
  -- v_cat is final here: a reused vehicle's on-file category wins over the form's.
  -- Membership uses are counted in the billing period of the booked start
  -- (money 0069), the period the line trigger checks; without 0069 the 0040
  -- pricing (no billing periods).
  if to_regprocedure('public.price_services_core(uuid,uuid,uuid,uuid[],uuid,boolean,timestamptz)') is not null then
    v_pricing := public.price_services_core(v_shop.id, v_customer.id, v_cat, v_all_ids, v_vehicle.id,
                                            v_uid is not null and v_customer.portal_user_id = v_uid, v_start);
  else
    v_pricing := public.price_services_core(v_shop.id, v_customer.id, v_cat, v_all_ids, v_vehicle.id,
                                            v_uid is not null and v_customer.portal_user_id = v_uid);
  end if;
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;

  -- ------------------------------------------------------------ slot (final category)
  -- The exact slot must still be offered (the slot engine public_booking_slots
  -- uses, for this booking's location type — per-location capacity — and its
  -- services' categories), checked for the category the job is actually
  -- priced and scheduled with: a reused vehicle's on-file category may differ
  -- from the form's (its durations too), so this runs only once the vehicle
  -- is settled. A multi-day booking ends where the slot engine says. Still
  -- under the advisory lock; any failure rolls the whole booking back.
  v_duration := (v_pricing ->> 'duration_minutes')::integer;
  if coalesce(v_duration, 0) <= 0 then
    raise exception 'the selected services have no duration' using errcode = '22023';
  end if;
  v_cats := array(select distinct s.category_id from public.services s
                   where s.id = any (v_all_ids) and s.shop_id = v_shop.id and s.category_id is not null);
  select s.ends_at into v_end
    from public.booking_slots_core(v_shop.id, v_duration, (v_start at time zone v_shop.timezone)::date,
                                   (v_start at time zone v_shop.timezone)::date, v_now, v_loc_type, v_cats) s
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
                           service_postal_code, notes, source, coupon_id, discount_kind, discount_value, custom_data)
  values (v_shop.id, v_customer.id, v_vehicle.id,
          case when v_bs.auto_confirm then 'scheduled' else 'requested' end::public.job_status,
          v_start, v_end, v_loc_type, v_line1, v_line2, v_city, v_region, v_postal, v_notes, 'online_booking',
          v_coupon.id, v_disc_kind, v_disc_value, v_answers)
  returning * into v_job;

  -- A line priced as included in a membership names that membership, so the
  -- line trigger (money 0069) re-checks it has a use left in the job's
  -- billing period: a concurrent staff job that took the last use fails the
  -- booking (22023) instead of leaving a free line no membership covers.
  for v_line in
    select e, o from jsonb_array_elements(v_pricing -> 'lines') with ordinality as t(e, o) order by o
  loop
    if to_regclass('public.invoice_jobs') is not null then   -- money 0061: lines carry membership_id
      insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                         unit_price_cents, taxable, duration_minutes, sort, membership_id)
      values (v_shop.id, v_job.id, (v_line.e ->> 'service_id')::uuid, v_vehicle.id, v_line.e ->> 'name',
              v_line.e ->> 'note', 1, (v_line.e ->> 'unit_price_cents')::bigint, (v_line.e ->> 'taxable')::boolean,
              (v_line.e ->> 'duration_minutes')::integer, v_line.o::integer, (v_line.e ->> 'membership_id')::uuid);
    else
      insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                         unit_price_cents, taxable, duration_minutes, sort)
      values (v_shop.id, v_job.id, (v_line.e ->> 'service_id')::uuid, v_vehicle.id, v_line.e ->> 'name',
              v_line.e ->> 'note', 1, (v_line.e ->> 'unit_price_cents')::bigint, (v_line.e ->> 'taxable')::boolean,
              (v_line.e ->> 'duration_minutes')::integer, v_line.o::integer);
    end if;
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


comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap).';
