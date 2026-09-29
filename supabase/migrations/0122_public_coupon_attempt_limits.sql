-- ============================================================================
-- 0122 — Coupon codes on the public booking page are attempt-limited.
--
-- public_validate_coupon (0062; anon, the /book page's coupon box and price
-- preview) answered every code without limit: valid (kind, value,
-- description) or the specific reason a code is unavailable, and for an
-- existing but restricted code also restrictions_text — so anyone could
-- run a dictionary of short human-chosen codes against a shop and find the
-- ones it never published (staff, friends-and-family, in-person codes),
-- then use them online. Gift card codes were limited (0066 / 0105), coupon
-- codes were not. The booking itself (create_online_booking) was a second
-- unlimited oracle: an unknown code fails with 'this coupon code is not
-- valid', a known one gets further (and a failed booking is never counted).
--
-- Now:
--   * coupon_code_attempts (new, internal: no client access): one row per
--     coupon code a public caller had looked up — shop, the caller's
--     connection (client_ip_scope of form_signer_ip: an IPv4 address or an
--     IPv6 /64; null when unknown), a hash of the code (the code itself is
--     not kept), whether the shop has such a code, and when. Rows older
--     than 2 days are dropped as new ones arrive.
--   * public_validate_coupon (0062 body; now VOLATILE, same signature and
--     grants): a well-formed, non-empty code is looked up only when the
--     connection has looked up fewer than 10 different unknown codes in
--     the shop in the last hour AND the shop has seen fewer than 200
--     different unknown codes from all callers in the last hour — or when
--     this connection looked the same code up in the last 24 hours (a
--     re-check tells it nothing new). Otherwise nothing is looked up and
--     the answer is valid=false with the message
--       'too many coupon codes were tried; please try again later'
--     and the undiscounted totals (restrictions_text null), so the price
--     preview keeps working. An empty code (the plain price preview) is
--     never limited or recorded.
--   * create_online_booking (0105 body): a booking carrying a coupon code
--     from a known connection needs that connection to have looked the
--     code up (found in the shop) through public_validate_coupon in the
--     last 24 hours — the booking page always does before it applies a
--     code. Otherwise, whether or not the code exists:
--       22023 'enter the coupon code again on the booking page, or book
--              without it'  HINT 'coupon_not_checked'
--     so the booking reveals nothing the limited check did not.
--   Staff surfaces (coupons on jobs, quotes and invoices) are unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- coupon_code_attempts
-- ---------------------------------------------------------------------------
create table public.coupon_code_attempts (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  client_scope  inet,
  code_hash     text not null check (code_hash ~ '^[0-9a-f]{64}$'),
  found         boolean not null,
  created_at    timestamptz not null default now(),
  constraint coupon_code_attempts_shop_id_id_key unique (shop_id, id)
);
create index coupon_code_attempts_shop_created_idx on public.coupon_code_attempts (shop_id, created_at);
create index coupon_code_attempts_shop_scope_idx on public.coupon_code_attempts (shop_id, client_scope, created_at)
  where client_scope is not null;

comment on table public.coupon_code_attempts is
  'Internal (0122): one row per coupon code a public caller had looked up (public_validate_coupon) — shop, connection (client_ip_scope: an IPv4 address or an IPv6 /64; null when unknown), sha256 of the shop and the lower-cased code, whether the shop has that code, when. Limits: 10 different unknown codes per connection per shop and 200 per shop an hour; create_online_booking takes a code only after the connection looked it up. Rows older than 2 days are pruned. No client access.';

alter table public.coupon_code_attempts enable row level security;
revoke all on table public.coupon_code_attempts from public, anon, authenticated;
grant select, insert, delete on table public.coupon_code_attempts to service_role;

-- ---------------------------------------------------------------------------
-- Helpers (internal)
-- ---------------------------------------------------------------------------
create function public.coupon_code_attempt_hash(p_shop_id uuid, p_code text) returns text
language sql immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_shop_id::text || ':' || lower(btrim(coalesce(p_code, ''), E' \t\r\n')), 'UTF8')), 'hex')
$$;

comment on function public.coupon_code_attempt_hash(uuid, text) is
  'Internal (0122): sha256 hex of "<shop id>:<code lower-cased and trimmed>" (coupon_code_attempts.code_hash).';

create function public.coupon_code_attempts_message() returns text
language sql immutable
set search_path = ''
as $$
  select 'too many coupon codes were tried; please try again later'::text
$$;

-- Did this connection look the code up (and the shop has it) lately?
create function public.coupon_code_checked_by(p_shop_id uuid, p_scope inet, p_hash text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.coupon_code_attempts a
                  where a.shop_id = p_shop_id and a.client_scope = p_scope and a.code_hash = p_hash
                    and a.found and a.created_at > now() - interval '24 hours')
$$;

-- May a public caller look this code up now? (see the header)
create function public.coupon_code_lookup_allowed(p_shop_id uuid, p_scope inet, p_hash text) returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c_conn_hourly_misses constant integer := 10;
  c_shop_hourly_misses constant integer := 200;
  v_n integer;
begin
  -- a code this connection already looked up: nothing new to learn
  if p_scope is not null and exists (
       select 1 from public.coupon_code_attempts a
        where a.shop_id = p_shop_id and a.client_scope = p_scope and a.code_hash = p_hash
          and a.created_at > now() - interval '24 hours') then
    return true;
  end if;
  if p_scope is not null then
    select count(distinct a.code_hash) into v_n from public.coupon_code_attempts a
     where a.shop_id = p_shop_id and a.client_scope = p_scope and not a.found
       and a.created_at > now() - interval '1 hour';
    if v_n >= c_conn_hourly_misses then
      return false;
    end if;
  end if;
  select count(distinct a.code_hash) into v_n from public.coupon_code_attempts a
   where a.shop_id = p_shop_id and not a.found and a.created_at > now() - interval '1 hour';
  return v_n < c_shop_hourly_misses;
end
$$;

-- Records one lookup (and prunes the shop's rows older than 2 days).
create function public.coupon_code_log_attempt(p_shop_id uuid, p_scope inet, p_hash text, p_found boolean) returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.coupon_code_attempts a
   where a.shop_id = p_shop_id and a.created_at < now() - interval '2 days';
  insert into public.coupon_code_attempts (shop_id, client_scope, code_hash, found)
  values (p_shop_id, p_scope, p_hash, coalesce(p_found, false));
$$;

revoke execute on function
  public.coupon_code_attempt_hash(uuid, text),
  public.coupon_code_attempts_message(),
  public.coupon_code_checked_by(uuid, inet, text),
  public.coupon_code_lookup_allowed(uuid, inet, text),
  public.coupon_code_log_attempt(uuid, inet, text, boolean)
from public, anon, authenticated;
grant execute on function
  public.coupon_code_attempt_hash(uuid, text),
  public.coupon_code_attempts_message(),
  public.coupon_code_checked_by(uuid, inet, text),
  public.coupon_code_lookup_allowed(uuid, inet, text)
to service_role;

-- ---------------------------------------------------------------------------
-- public_validate_coupon — 0062 body + the attempt limits (VOLATILE)
-- ---------------------------------------------------------------------------
create or replace function public.public_validate_coupon(
  p_slug                 text,
  p_code                 text,
  p_service_ids          uuid[],
  p_vehicle_category_id  uuid default null,
  p_now                  timestamptz default now(),
  p_link_token           uuid default null,
  p_location_type        public.location_type default null,
  p_vehicle_id           uuid default null,
  p_starts_at            text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now       timestamptz := public.effective_now(p_now);
  v_uid       uuid := auth.uid();
  v_shop      public.shops;
  v_enabled   boolean;
  v_code      text := nullif(btrim(p_code), '');
  v_ids       uuid[];
  v_link_ids  uuid[];
  v_pricing   jsonb;
  v_lines     jsonb;
  v_coupon    public.coupons;
  v_customer  uuid;
  v_reason    text;
  v_t         public.document_totals;
  v_base      public.document_totals;
  v_eligible  uuid[];
  v_loc       public.location_type;
  v_fees      jsonb;
  v_cat       uuid := p_vehicle_category_id;
  v_vehicle   uuid;
  v_start     timestamptz;
  v_scope     inet := public.client_ip_scope(public.form_signer_ip());   -- 0122
  v_hash      text;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
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
  if p_link_token is not null then
    v_link_ids := public.booking_link_service_ids(v_shop.id, p_link_token);
    if v_link_ids is null then
      raise exception 'booking link not found' using errcode = 'PT404';
    end if;
    if exists (select 1 from unnest(v_ids) as x where not (x = any (v_link_ids))) then
      raise exception 'one or more services are not available for online booking' using errcode = '22023';
    end if;
  else
    perform public.booking_check_bookable(v_shop.id, v_ids, array['service', 'package', 'addon']::public.service_kind[],
                                          'services');
  end if;
  if p_starts_at is not null then
    v_start := public.booking_parse_start(p_starts_at, v_shop.timezone);
  end if;
  -- the signed-in client's own customer record in this shop, if any: the
  -- saved vehicle's owner (as the booking), else the newest linked record
  if p_vehicle_id is not null then
    select v.id, v.customer_id, coalesce(v.category_id, v_cat) into v_vehicle, v_customer, v_cat
      from public.vehicles v
      join public.customers c on c.id = v.customer_id and c.shop_id = v.shop_id
     where v.id = p_vehicle_id and v.shop_id = v_shop.id and v.archived_at is null and c.archived_at is null
       and v_uid is not null and c.portal_user_id = v_uid;
    if v_vehicle is null then
      raise exception 'vehicle not found' using errcode = 'PT404';
    end if;
  elsif v_uid is not null then
    select c.id into v_customer from public.customers c
     where c.shop_id = v_shop.id and c.portal_user_id = v_uid and c.archived_at is null
     order by c.created_at desc, c.id limit 1;
  end if;
  -- every chosen service has a catalog price for the category (as the booking)
  v_pricing := public.price_services_core(v_shop.id, null, v_cat, v_ids, null, false);
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;
  -- a member's included services, as the booking prices them (0069)
  if v_customer is not null then
    v_pricing := public.price_services_core(v_shop.id, v_customer, v_cat, v_ids, v_vehicle, true, v_start);
  end if;
  v_lines := coalesce((select jsonb_agg(jsonb_build_object(
                                'service_id', e ->> 'service_id',
                                'quantity', 1,
                                'unit_price_cents', (e ->> 'unit_price_cents')::bigint,
                                'taxable', (e ->> 'taxable')::boolean) order by o)
                         from jsonb_array_elements(v_pricing -> 'lines') with ordinality as t(e, o)), '[]'::jsonb);
  -- the booking's auto-applied fees (no service: eligible only under a
  -- coupon without a service list, as job_line_items_60_money stamps them)
  v_loc := coalesce(p_location_type,
                    case when v_shop.business_type = 'mobile' then 'mobile' else 'shop' end::public.location_type);
  v_fees := coalesce((select jsonb_agg(jsonb_build_object(
                               'service_id', null,
                               'quantity', 1,
                               'unit_price_cents', f.amount_cents,
                               'taxable', f.taxable) order by f.sort, f.name, f.id)
                        from public.shop_fees f
                       where f.shop_id = v_shop.id and f.active and f.archived_at is null
                         and (f.auto_apply = 'both' or f.auto_apply::text = v_loc::text)), '[]'::jsonb);
  v_lines := v_lines || v_fees;
  v_base := public.compute_document_totals(v_lines, 'none', 0, v_shop.tax_rate_bps);

  if v_code is null or char_length(v_code) > 40 or v_code !~ '^[A-Za-z0-9_-]+$' then
    v_reason := 'this coupon code is not valid';
  else
    -- 0122: the code is looked up only within the attempt limits, and every
    -- lookup is recorded (serialised per shop, so a burst cannot overshoot)
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('public.coupon_code_attempts:' || v_shop.id::text, 0));
    v_hash := public.coupon_code_attempt_hash(v_shop.id, v_code);
    if not public.coupon_code_lookup_allowed(v_shop.id, v_scope, v_hash) then
      v_reason := public.coupon_code_attempts_message();
    else
      select * into v_coupon from public.coupons c where c.shop_id = v_shop.id and lower(c.code::text) = lower(v_code);
      perform public.coupon_code_log_attempt(v_shop.id, v_scope, v_hash, v_coupon.id is not null);
      v_reason := public.coupon_unavailable_reason(v_coupon, v_now);
      if v_reason is null then
        v_reason := public.coupon_restriction_reason(v_coupon, v_customer, v_lines, v_now);
      end if;
    end if;
  end if;

  if v_reason is not null then
    return jsonb_build_object(
      'valid', false,
      'message', v_reason,
      'code', left(v_code, 40),
      'kind', null,
      'value', null,
      'description', null,
      'subtotal_cents', v_base.subtotal_cents,
      'discount_cents', 0,
      'tax_cents', v_base.tax_cents,
      'total_cents', v_base.total_cents,
      'eligible_service_ids', '[]'::jsonb,
      'restrictions_text', case when v_coupon.id is not null
                                     and public.coupon_unavailable_reason(v_coupon, v_now) is null
                                then public.coupon_restrictions_text(v_coupon) end);
  end if;

  -- in the order the services were chosen
  v_eligible := array(select u.x from unnest(p_service_ids) with ordinality as u(x, o)
                       where u.x = any (v_ids) and (v_coupon.service_ids is null or u.x = any (v_coupon.service_ids))
                       group by u.x order by min(u.o));
  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(l || jsonb_build_object(
                                        'discount_eligible', v_coupon.service_ids is null
                                                             or coalesce((l ->> 'service_id')::uuid = any (v_coupon.service_ids),
                                                                         false))),
                            '[]'::jsonb)
              from jsonb_array_elements(v_lines) l),
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
    'total_cents', v_t.total_cents,
    'eligible_service_ids', to_jsonb(v_eligible),
    'restrictions_text', public.coupon_restrictions_text(v_coupon));
end
$$;
comment on function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text) is
  'Booking wizard coupon preview (anon): restrictions (services, minimum, customer rules for the signed-in linked client), optional private booking link, the auto-applied fees of the booking''s location type, a signed-in member''s included services (saved vehicle, booking start). Invalid codes answer valid=false. 0122: a code is looked up only within the attempt limits (10 different unknown codes per connection per shop and 200 per shop an hour; coupon_code_attempts), else valid=false ''too many coupon codes were tried; please try again later''.';

-- ---------------------------------------------------------------------------
-- create_online_booking — 0105 body + a coupon code must have been checked
-- ---------------------------------------------------------------------------
create or replace function public.create_online_booking(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_conn_daily_limit constant integer := 10;
  c_user_daily_limit constant integer := 10;
  c_shop_daily_limit constant integer := 100;   -- per pool: anonymous / signed-in
  v_shop    uuid;
  v_ip      inet := public.form_signer_ip();
  v_scope   inet := public.client_ip_scope(v_ip);
  -- a signed-in client who proved an email (the same test the booking uses
  -- to trust the caller, 0054); anyone else books anonymously
  v_user    uuid := case when public.portal_confirmed_email() is not null then auth.uid() end;
  v_recent  integer;
  v_result  jsonb;
  -- 0122: the coupon code as create_online_booking_core reads it
  v_code    text := case when jsonb_typeof(p_payload) = 'object'
                          and jsonb_typeof(p_payload -> 'coupon_code') in ('string', 'number')
                         then nullif(btrim(p_payload ->> 'coupon_code', E' \t\r\n'), '') end;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if v_shop is null then
    return public.create_online_booking_core(p_slug, p_payload, p_now);   -- answers PT404
  end if;

  -- the same lock create_online_booking_core takes (re-entrant): the counts
  -- below and this booking's row are serialised with every other booking
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.create_online_booking:' || v_shop::text, 0));

  -- abuse limits (wall clock, independent of p_now)
  if v_scope is not null then
    select count(*) into v_recent from public.online_booking_log l
     where l.shop_id = v_shop and l.client_ip is not null and public.client_ip_scope(l.client_ip) = v_scope
       and l.created_at > now() - interval '24 hours';
    if v_recent >= c_conn_daily_limit then
      raise exception 'too many online bookings from this connection today; please call the shop'
        using errcode = 'PT429';
    end if;
  end if;
  if v_user is not null then
    select count(*) into v_recent from public.online_booking_log l
     where l.shop_id = v_shop and l.user_id = v_user and l.created_at > now() - interval '24 hours';
    if v_recent >= c_user_daily_limit then
      raise exception 'too many online bookings from this account today; please call the shop'
        using errcode = 'PT429';
    end if;
  end if;
  select count(*) into v_recent from public.online_booking_log l
   where l.shop_id = v_shop and (l.user_id is null) = (v_user is null) and l.created_at > now() - interval '24 hours';
  if v_recent >= c_shop_daily_limit then
    raise exception 'this shop is receiving too many online bookings right now; please try again later or call the shop'
      using errcode = 'PT429';
  end if;

  -- 0122: a coupon code is looked up only after this connection checked it
  -- on the booking page (public_validate_coupon, attempt-limited): the same
  -- answer for an unknown code and for a known one it never checked, so
  -- the booking is no way around the coupon attempt limits
  if v_code is not null and v_scope is not null
     and not public.coupon_code_checked_by(v_shop, v_scope, public.coupon_code_attempt_hash(v_shop, v_code)) then
    raise exception 'enter the coupon code again on the booking page, or book without it'
      using errcode = '22023', hint = 'coupon_not_checked';
  end if;

  v_result := public.create_online_booking_core(p_slug, p_payload, p_now);

  delete from public.online_booking_log l
   where l.shop_id = v_shop and l.created_at < now() - interval '2 days';
  insert into public.online_booking_log (shop_id, client_ip, user_id) values (v_shop, v_ip, v_user);
  return v_result;
end
$$;
comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap; 0102: a lapsed shop answers 55000; 0104/0105: PT429 past 10 bookings per connection — an IPv6 /64 — per shop, 10 per signed-in account per shop, 100 anonymous and 100 signed-in bookings per shop, in any rolling 24 hours; 0122: a coupon code is taken only after the connection checked it with public_validate_coupon in the last 24 hours, else 22023 HINT coupon_not_checked).';
