-- ============================================================================
-- 0110 — The public membership join (/join/<slug>) and online gift card
-- (/gift/<slug>) pages get the per-connection and per-shop limits of the
-- other anonymous forms (0104 / 0105), and a join creates a lead without
-- marketing consent until its Checkout is paid.
--
-- Both pages are anonymous (slug only) and prove nothing about the email
-- typed into them. membership_join_prepare (0069 / 0095 / 0103) was bounded
-- only by 3 joins per email a day and gift_card_order_prepare (0066 / 0095 /
-- 0103) by 5 orders per purchaser email a day, so a script rotating emails
-- could, from one connection, add any number of customers (lifecycle
-- 'customer', email_opt_in from the payload: any third-party address went
-- onto the shop's email-marketing list), vehicles, incomplete memberships
-- and pending gift card orders — each one also a Stripe customer and
-- Checkout Session on the shop's connected account (4+ Stripe API calls
-- per anonymous request).
--
-- The payments edge function calls these RPCs as service_role, so
-- form_signer_ip() sees the function's own request, not the visitor's. The
-- function now passes the visitor's address:
--   * membership_join_prepare(p_slug, p_plan_id, p_payload, p_now,
--     p_client_ip inet default null) and gift_card_order_prepare(p_slug,
--     p_payload, p_now, p_client_ip inet default null) — DROP + CREATE with
--     the trailing p_client_ip (still service_role only). Without it (an
--     older edge function) the per-connection limit is skipped; the shop
--     limit always applies. The order's signer_ip is p_client_ip when
--     given.
--
-- Abuse limits (PT429; rolling 24 h, wall clock; serialised per shop with an
-- advisory lock; only attempts that were NOT paid count, so real members
-- and gift card buyers never use up the allowance):
--   * joins: 10 per connection (client_ip_scope: an IPv6 /64) per shop and
--     100 per shop. An attempt is one accepted membership_join_prepare call
--     (a retry of the same join counts again: it makes new Stripe calls);
--     it is paid once its membership has started (started_at, set when the
--     subscription becomes active / past_due). Attempts are recorded in
--     membership_join_log (internal; rows older than 7 days are dropped as
--     new ones arrive).
--   * gift card orders: 10 per connection per shop and 100 per shop, counting
--     orders still pending or expired (gift_card_orders.signer_ip /
--     created_at).
--   The per-email limits (3 joins, 5 orders) are unchanged.
--
-- A join no longer writes anything the visitor claims about consent until
-- it is paid:
--   * membership_join_prepare_core (0095 body, same signature): a customer
--     the join creates is a 'lead' with sms_opt_in / email_opt_in false.
--     The consent the visitor asked for is kept in membership_join_log.
--     Matched customers are still never modified.
--   * memberships_zz_money_join_paid (new): when an online join's membership
--     becomes active (incomplete -> active, created_by null), its customer
--     becomes a 'customer'; a customer the join created also gets the
--     consent of the latest attempt for that membership (a consent is only
--     ever added, never withdrawn here).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- membership_join_log — one row per accepted online join attempt
-- ---------------------------------------------------------------------------
create table public.membership_join_log (
  id             uuid primary key default gen_random_uuid(),
  shop_id        uuid not null references public.shops (id) on delete cascade,
  membership_id  uuid not null,
  customer_id    uuid not null,
  new_customer   boolean not null,
  client_ip      inet,
  email_opt_in   boolean not null default false,
  sms_opt_in     boolean not null default false,
  created_at     timestamptz not null default now(),
  constraint membership_join_log_shop_id_id_key unique (shop_id, id)
);
create index membership_join_log_shop_created_idx on public.membership_join_log (shop_id, created_at);
create index membership_join_log_shop_scope_idx on public.membership_join_log
  (shop_id, public.client_ip_scope(client_ip), created_at) where client_ip is not null;
create index membership_join_log_membership_idx on public.membership_join_log (membership_id, created_at);

comment on table public.membership_join_log is
  'Internal (0110): one row per accepted online membership join (membership_join_prepare) — its shop, membership and customer, whether the join created that customer, the visitor''s IP (null when the edge function passed none) and the email / text consent the visitor asked for (applied only when the membership is paid). Abuse limits: 10 unpaid joins per connection (an IPv6 /64) per shop and 100 per shop in any rolling 24 hours. Rows older than 7 days are dropped. No client access.';
comment on column public.membership_join_log.new_customer is
  'The join created the customer (a lead without consent until paid); false when an existing customer was matched (never modified).';
comment on column public.membership_join_log.client_ip is
  'The visitor''s IP as the payments edge function passed it (p_client_ip), or null.';

alter table public.membership_join_log enable row level security;
revoke all on table public.membership_join_log from public, anon, authenticated;
grant select, insert, delete on table public.membership_join_log to service_role;

create index gift_card_orders_shop_created_idx on public.gift_card_orders (shop_id, created_at);

-- ---------------------------------------------------------------------------
-- membership_join_prepare_core (0095 body; same signature, grants) — a new
-- customer is a lead without consent; answers new_customer (the wrapper
-- strips it).
-- ---------------------------------------------------------------------------
create or replace function public.membership_join_prepare_core(
  p_slug     text,
  p_plan_id  uuid,
  p_payload  jsonb,
  p_now      timestamptz default now()
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop       public.shops;
  v_plan       public.membership_plans;
  v_cust_in    jsonb;
  v_veh_in     jsonb;
  v_first      text;
  v_last       text;
  v_email      text;
  v_phone_raw  text;
  v_phone      text;
  v_sms        boolean;
  v_email_opt  boolean;
  v_customer   uuid;
  v_new_cust   boolean := false;
  v_vehicle    uuid;
  v_year       integer;
  v_make       text;
  v_model      text;
  v_m          public.memberships;
begin
  -- (p_now is accepted for symmetry with the other entry points; the abuse
  -- limit always uses the wall clock)
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_plan from public.membership_plans p
   where p.id = p_plan_id and p.shop_id = v_shop.id and p.active and p.archived_at is null and p.online_joinable;
  if not found then
    raise exception 'this membership plan is not available online' using errcode = '55000';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'join details must be a JSON object' using errcode = '22023';
  end if;
  v_cust_in := p_payload -> 'customer';
  v_veh_in := p_payload -> 'vehicle';
  if coalesce(jsonb_typeof(v_cust_in), 'null') <> 'object' then
    raise exception 'contact details are required' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(v_veh_in), 'null') not in ('object', 'null') then
    raise exception 'vehicle must be an object' using errcode = '22023';
  end if;
  v_first := public.payload_text(v_cust_in, 'first_name', 100, 'first name', true);
  v_last := public.payload_text(v_cust_in, 'last_name', 100, 'last name');
  v_email := lower(public.payload_text(v_cust_in, 'email', 254, 'email', true));
  if not public.is_valid_email(v_email) then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  v_phone_raw := public.payload_text(v_cust_in, 'phone', 32, 'phone');
  if v_phone_raw is not null then
    v_phone := public.normalize_phone_e164(v_phone_raw, v_shop.country);
    if v_phone is null then
      raise exception 'enter a valid phone number' using errcode = '22023';
    end if;
  end if;
  v_sms := public.payload_bool(v_cust_in, 'sms_opt_in', 'sms_opt_in');
  v_email_opt := public.payload_bool(v_cust_in, 'email_opt_in', 'email_opt_in');
  if jsonb_typeof(v_veh_in) = 'object' then
    v_year := public.payload_int(v_veh_in, 'year', 'vehicle year', 1886, 2100);
    v_make := public.payload_text(v_veh_in, 'make', 60, 'vehicle make', true);
    v_model := public.payload_text(v_veh_in, 'model', 60, 'vehicle model', true);
  end if;

  -- abuse limit (wall clock): online joins (created_by null) per email
  if (select count(*) from public.memberships m
        join public.customers c on c.id = m.customer_id and c.shop_id = m.shop_id
       where m.shop_id = v_shop.id and m.created_by is null and c.email is not null
         and lower(c.email::text) = v_email and m.created_at > now() - interval '24 hours') >= 3 then
    raise exception 'too many membership sign-ups for this email today; please contact the shop' using errcode = 'PT429';
  end if;

  select c.id into v_customer from public.customers c
   where c.shop_id = v_shop.id and c.archived_at is null and c.email is not null and lower(c.email::text) = v_email
     and (not c.phone_unverified or c.phone is null or c.phone = v_phone)
   order by coalesce(c.phone = v_phone, false) desc, c.created_at desc, c.id
   limit 1;
  if v_customer is null and v_phone is not null then
    select c.id into v_customer from public.customers c
     where c.shop_id = v_shop.id and c.archived_at is null and c.email is null and c.phone = v_phone
     order by c.created_at desc, c.id limit 1;
  end if;
  if v_customer is null then
    -- 0110: a lead without consent until the membership is paid
    -- (memberships_zz_money_join_paid applies the consent asked for)
    insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, source,
                                  lifecycle, phone_unverified)
    values (v_shop.id, v_first, v_last, v_email::extensions.citext, v_phone, false, false,
            'online_booking', 'lead', v_phone is not null)
    returning id into v_customer;
    v_new_cust := true;
  end if;
  if v_make is not null then
    -- a retried join finds the vehicle it created (nothing about the
    -- customer's vehicles is returned to the caller)
    select v.id into v_vehicle from public.vehicles v
     where v.shop_id = v_shop.id and v.customer_id = v_customer and v.archived_at is null
       and lower(btrim(v.make)) = lower(v_make) and lower(btrim(v.model)) = lower(v_model)
       and v.year is not distinct from v_year
     order by v.created_at desc, v.id limit 1;
    if v_vehicle is null then
      insert into public.vehicles (shop_id, customer_id, year, make, model)
      values (v_shop.id, v_customer, v_year, v_make, v_model)
      returning id into v_vehicle;
    end if;
  end if;

  select * into v_m from public.memberships m
   where m.shop_id = v_shop.id and m.plan_id = v_plan.id and m.customer_id = v_customer
     and m.vehicle_id is not distinct from v_vehicle and m.status <> 'cancelled';
  if found then
    if v_m.status <> 'incomplete' or v_m.stripe_subscription_id is not null then
      raise exception 'this customer already has this membership' using errcode = '22023', hint = 'already_member';
    end if;
  else
    v_m := public.create_membership_core(v_plan.id, v_customer, v_vehicle);
  end if;
  return jsonb_build_object('membership_id', v_m.id, 'customer_id', v_customer, 'shop_id', v_shop.id,
                            'email', v_email, 'new_customer', v_new_cust,
                            'email_opt_in', v_email_opt, 'sms_opt_in', v_sms and v_phone is not null);
end
$$;

comment on function public.membership_join_prepare_core(text, uuid, jsonb, timestamptz) is
  'Internal (0103; 0110): the online membership join of 0069 / 0095 — a customer it creates is a lead without consent (new_customer, email_opt_in / sms_opt_in in the answer are what the visitor asked for). Called only by membership_join_prepare, which refuses lapsed shops and applies the abuse limits first.';

-- ---------------------------------------------------------------------------
-- membership_join_prepare — + p_client_ip and the connection / shop limits
-- ---------------------------------------------------------------------------
drop function public.membership_join_prepare(text, uuid, jsonb, timestamptz);

create function public.membership_join_prepare(
  p_slug       text,
  p_plan_id    uuid,
  p_payload    jsonb,
  p_now        timestamptz default now(),
  p_client_ip  inet default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_conn_daily_limit constant integer := 10;
  c_shop_daily_limit constant integer := 100;
  v_shop    uuid;
  v_ip      inet := pg_catalog.host(p_client_ip)::inet;
  v_scope   inet := public.client_ip_scope(pg_catalog.host(p_client_ip)::inet);
  v_recent  integer;
  v_result  jsonb;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'this membership plan is not available online' using errcode = '55000';
  end if;
  if v_shop is null then
    return public.membership_join_prepare_core(p_slug, p_plan_id, p_payload, p_now);   -- answers PT404
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.membership_join_prepare:' || v_shop::text, 0));

  -- abuse limits (wall clock): join attempts not paid (their membership
  -- never started) in the last 24 hours
  if v_scope is not null then
    select count(*) into v_recent from public.membership_join_log l
     where l.shop_id = v_shop and l.client_ip is not null and public.client_ip_scope(l.client_ip) = v_scope
       and l.created_at > now() - interval '24 hours'
       and not exists (select 1 from public.memberships m where m.id = l.membership_id and m.started_at is not null);
    if v_recent >= c_conn_daily_limit then
      raise exception 'too many membership sign-ups from this connection today; please contact the shop'
        using errcode = 'PT429';
    end if;
  end if;
  select count(*) into v_recent from public.membership_join_log l
   where l.shop_id = v_shop and l.created_at > now() - interval '24 hours'
     and not exists (select 1 from public.memberships m where m.id = l.membership_id and m.started_at is not null);
  if v_recent >= c_shop_daily_limit then
    raise exception 'this shop is receiving too many membership sign-ups right now; please try again later or contact the shop'
      using errcode = 'PT429';
  end if;

  v_result := public.membership_join_prepare_core(p_slug, p_plan_id, p_payload, p_now);

  delete from public.membership_join_log l
   where l.shop_id = v_shop and l.created_at < now() - interval '7 days';
  insert into public.membership_join_log (shop_id, membership_id, customer_id, new_customer, client_ip,
                                          email_opt_in, sms_opt_in)
  values (v_shop, (v_result ->> 'membership_id')::uuid, (v_result ->> 'customer_id')::uuid,
          coalesce((v_result ->> 'new_customer')::boolean, false), v_ip,
          coalesce((v_result ->> 'email_opt_in')::boolean, false), coalesce((v_result ->> 'sms_opt_in')::boolean, false));
  return v_result - 'new_customer' - 'email_opt_in' - 'sms_opt_in';
end
$$;

comment on function public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet) is
  'service_role (payments membership_join_checkout): customer, vehicle and incomplete membership of an online join (0069 rules; 0095 HINT already_member; 0103: a lapsed shop answers 55000 before creating anything; 0110: p_client_ip = the visitor''s IP; PT429 past 10 unpaid joins per connection — an IPv6 /64 — per shop or 100 per shop in any rolling 24 hours, besides 3 per email; a customer it creates is a lead without consent until paid). {membership_id, customer_id, shop_id, email}.';
revoke execute on function public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet) from public, anon, authenticated;
grant execute on function public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet) to service_role;

-- ---------------------------------------------------------------------------
-- gift_card_order_prepare — + p_client_ip and the connection / shop limits
-- (the order itself: gift_card_order_prepare_core, 0095 body, unchanged)
-- ---------------------------------------------------------------------------
drop function public.gift_card_order_prepare(text, jsonb, timestamptz);

create function public.gift_card_order_prepare(
  p_slug       text,
  p_payload    jsonb,
  p_now        timestamptz default now(),
  p_client_ip  inet default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_conn_daily_limit constant integer := 10;
  c_shop_daily_limit constant integer := 100;
  v_shop    uuid;
  v_ip      inet := pg_catalog.host(p_client_ip)::inet;
  v_scope   inet := public.client_ip_scope(pg_catalog.host(p_client_ip)::inet);
  v_recent  integer;
  v_result  jsonb;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'online gift card sales are not enabled for this shop' using errcode = '55000';
  end if;
  if v_shop is null then
    return public.gift_card_order_prepare_core(p_slug, p_payload, p_now);   -- answers PT404
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.gift_card_order_prepare:' || v_shop::text, 0));

  -- abuse limits (wall clock): orders not paid in the last 24 hours
  if v_scope is not null then
    select count(*) into v_recent from public.gift_card_orders o
     where o.shop_id = v_shop and o.signer_ip is not null and public.client_ip_scope(o.signer_ip) = v_scope
       and o.status in ('pending', 'expired') and o.created_at > now() - interval '24 hours';
    if v_recent >= c_conn_daily_limit then
      raise exception 'too many gift card orders from this connection today; please contact the shop'
        using errcode = 'PT429';
    end if;
  end if;
  select count(*) into v_recent from public.gift_card_orders o
   where o.shop_id = v_shop and o.status in ('pending', 'expired') and o.created_at > now() - interval '24 hours';
  if v_recent >= c_shop_daily_limit then
    raise exception 'this shop is receiving too many gift card orders right now; please try again later or contact the shop'
      using errcode = 'PT429';
  end if;

  v_result := public.gift_card_order_prepare_core(p_slug, p_payload, p_now);
  if v_ip is not null then
    update public.gift_card_orders o set signer_ip = v_ip
     where o.id = (v_result ->> 'order_id')::uuid and o.shop_id = v_shop;
  end if;
  return v_result;
end
$$;

comment on function public.gift_card_order_prepare(text, jsonb, timestamptz, inet) is
  'service_role (payments gift_card_checkout): the pending order of an online gift card sale (0066 rules; 0095 HINT amount_out_of_range; 0103: a lapsed shop answers 55000 before creating it; 0110: p_client_ip = the visitor''s IP, stored as signer_ip; PT429 past 10 unpaid orders per connection — an IPv6 /64 — per shop or 100 per shop in any rolling 24 hours, besides 5 per purchaser email). {order_id, token, shop_id, value_cents, price_cents, currency, purchaser_email}.';
revoke execute on function public.gift_card_order_prepare(text, jsonb, timestamptz, inet) from public, anon, authenticated;
grant execute on function public.gift_card_order_prepare(text, jsonb, timestamptz, inet) to service_role;

-- ---------------------------------------------------------------------------
-- memberships_zz_money_join_paid — a paid online join makes its customer a
-- customer and applies the consent asked for (see the header).
-- ---------------------------------------------------------------------------
create function public.memberships_money_join_paid() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_log public.membership_join_log;
begin
  select * into v_log from public.membership_join_log l
   where l.shop_id = new.shop_id and l.membership_id = new.id and l.customer_id = new.customer_id
   order by l.created_at desc, l.id desc limit 1;
  if v_log.id is not null
     and exists (select 1 from public.membership_join_log l
                  where l.shop_id = new.shop_id and l.customer_id = new.customer_id and l.new_customer) then
    update public.customers c
       set lifecycle = 'customer',
           email_opt_in = c.email_opt_in or (v_log.email_opt_in and c.email is not null),
           sms_opt_in = c.sms_opt_in or (v_log.sms_opt_in and c.phone is not null)
     where c.id = new.customer_id and c.shop_id = new.shop_id;
  else
    update public.customers c
       set lifecycle = 'customer'
     where c.id = new.customer_id and c.shop_id = new.shop_id and c.lifecycle = 'lead';
  end if;
  return null;
end
$$;

comment on function public.memberships_money_join_paid() is
  'Internal (0110): an online join''s membership became active — its customer becomes a customer; a customer the join created also gets the email / text consent the visitor asked for (latest attempt, membership_join_log).';
revoke execute on function public.memberships_money_join_paid() from public, anon, authenticated;

create trigger memberships_zz_money_join_paid after update of status on public.memberships
  for each row when (old.status = 'incomplete' and new.status = 'active' and new.created_by is null)
  execute function public.memberships_money_join_paid();
