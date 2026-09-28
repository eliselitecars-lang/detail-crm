-- ============================================================================
-- 0095 — Integration parity fixes (cross-cutting; range 0090-0099).
--
--   (a) blocked_times, technicians: verified, no change. The 0052 RESTRICTIVE
--       policy blocked_times_select_customer_redaction already hides every
--       row that names a customer (names_customer, sticky after the
--       customer's delete) from members below manager, so a technician can
--       never SELECT a customer-linked event's customer_id, title or reason
--       directly; calendar_events is their only view of it (no customer id,
--       no title of a shop-wide customer event). Covered by
--       tests/95_parity_fixes.sql.
--   (b) upsert_customer_payment_method (0011; same signature): the Stripe
--       customer the caller names is compared with the SAVED CARD's own
--       customer_payment_methods.stripe_customer_id (0071) when the card is
--       already saved — a card moved by merge_customers keeps charging on
--       the Stripe customer that owns it, so the webhook's re-save must not
--       be refused. A new card (or a legacy row without one) is still
--       compared with the customer's stripe_customer_id, and a card saved
--       for another CRM customer is still refused (22023 either way).
--   (c) gift_card_order_expired(p_session_id) — service_role
--       (stripe-webhook, checkout.session.expired of a gift card sale): the
--       pending order of that Checkout Session becomes 'expired'.
--       Idempotent; paid / refunded orders are never touched. 22023 for a
--       malformed session id, P0002 when no order has it. Returns
--       {order_id, status, changed}.
--   (d) Distinct refusals, same SQLSTATE and message as before (22023), now
--       with a machine-readable HINT the payments function can map:
--         membership_join_prepare  'this customer already has this membership'
--                                  HINT 'already_member'
--         gift_card_order_prepare  'amount out of range: choose between … and …'
--                                  HINT 'amount_out_of_range'
--   (e) add_fee_line(p_doc_kind, p_doc_id, p_fee_id, p_request_nonce default
--       null): a retry with the same nonce returns the line the first call
--       added (no second fee). Replaces the 3-argument version (DROP +
--       CREATE); named-argument callers without the nonce keep working.
--   (f) import_customers / import_services(…, p_request_nonce default null):
--       a committed chunk (p_dry_run false) retried with the same nonce
--       returns the first call's result (plus "replayed": true) and imports
--       nothing again. Dry runs ignore the nonce (they write nothing).
--       Replaces the 5-argument versions (DROP + CREATE; bodies unchanged).
--   (g) Additive fields for the web / iOS portal: job_report_public_json's
--       shop gains timezone; every row of portal_documents,
--       portal_job_reports and portal_referrals gains shop_slug, timezone
--       and currency (the shop's).
--
-- Request nonces (e, f): one random value per user action, reused on
-- retries, 8-64 characters [A-Za-z0-9_-] (as messages.request_nonce; 22023
-- otherwise). Scoped to (shop, caller, operation). Reusing a nonce for a
-- DIFFERENT request (another document / fee / chunk) is refused (22023).
-- Kept 7 days (older ones of the shop are pruned as new ones arrive).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- client_requests — the idempotency ledger of (e) and (f). Definer code
-- only (RLS on, no policies, no API grants).
-- ---------------------------------------------------------------------------
create table public.client_requests (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  user_id      uuid,
  kind         text not null check (kind in ('add_fee_line', 'import_customers', 'import_services')),
  nonce        text not null check (nonce ~ '^[A-Za-z0-9_-]{8,64}$'),
  fingerprint  text not null check (fingerprint ~ '^[0-9a-f]{32}$'),
  result       jsonb,
  created_at   timestamptz not null default now(),
  constraint client_requests_shop_id_id_key unique (shop_id, id),
  constraint client_requests_once unique nulls not distinct (shop_id, kind, user_id, nonce)
);
create index client_requests_shop_created_idx on public.client_requests (shop_id, created_at);

comment on table public.client_requests is
  'Idempotency ledger (0095): the result of a request made with a client request nonce (add_fee_line, import_customers / import_services chunks). Definer code only; pruned after 7 days.';

alter table public.client_requests enable row level security;
revoke all on public.client_requests from anon, authenticated;

-- Claims (shop, caller, kind, nonce) for this request, or returns the
-- earlier request's result. result null = claimed now: call
-- client_request_finish(request_id, result) before returning. 22023: a
-- malformed nonce, or a nonce already used for a different request.
create function public.client_request_claim(p_shop_id uuid, p_kind text, p_nonce text, p_fingerprint text)
returns table (request_id uuid, result jsonb)
language plpgsql volatile security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_row public.client_requests;
begin
  if not public.comms_valid_request_nonce(p_nonce) then
    raise exception 'request_nonce must be 8-64 letters, digits, "-" or "_"' using errcode = '22023';
  end if;
  delete from public.client_requests r
   where r.shop_id = p_shop_id and r.created_at < now() - interval '7 days';
  insert into public.client_requests (shop_id, user_id, kind, nonce, fingerprint)
  values (p_shop_id, auth.uid(), p_kind, p_nonce, p_fingerprint)
  on conflict on constraint client_requests_once do nothing
  returning * into v_row;
  if v_row.id is not null then
    return query select v_row.id, null::jsonb;
    return;
  end if;
  select * into v_row from public.client_requests r
   where r.shop_id = p_shop_id and r.kind = p_kind and r.user_id is not distinct from auth.uid() and r.nonce = p_nonce;
  if v_row.fingerprint is distinct from p_fingerprint then
    raise exception 'this request_nonce was already used for a different request' using errcode = '22023';
  end if;
  if v_row.result is null then
    raise exception 'this request is still being processed' using errcode = '55000';
  end if;
  return query select v_row.id, v_row.result;
end
$$;

create function public.client_request_finish(p_request_id uuid, p_result jsonb) returns void
language sql volatile security definer
set search_path = ''
as $$ update public.client_requests r set result = p_result where r.id = p_request_id $$;

-- ---------------------------------------------------------------------------
-- (b) upsert_customer_payment_method (0011, same signature)
-- ---------------------------------------------------------------------------
create or replace function public.upsert_customer_payment_method(
  p_shop_id                   uuid,
  p_customer_id               uuid,
  p_stripe_payment_method_id  text,
  p_brand                     text default null,
  p_last4                     text default null,
  p_exp_month                 integer default null,
  p_exp_year                  integer default null,
  p_make_default              boolean default false,
  p_stripe_customer_id        text default null
) returns public.customer_payment_methods
language plpgsql security definer
set search_path = ''
as $$
declare
  v_existing  public.customer_payment_methods;
  v_row       public.customer_payment_methods;
  v_default   boolean;
  v_stripe    text;
begin
  -- serializes default switching per customer
  select c.stripe_customer_id into v_stripe
    from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id for update;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  select * into v_existing from public.customer_payment_methods pm
   where pm.shop_id = p_shop_id and pm.stripe_payment_method_id = p_stripe_payment_method_id;
  if found and v_existing.customer_id <> p_customer_id then
    raise exception 'payment method belongs to another customer' using errcode = '22023';
  end if;
  -- the Stripe customer the card is attached to (when the caller knows it):
  -- a saved card's own (a merge moves cards between CRM customers; they keep
  -- charging on the Stripe customer that owns them), else this customer's —
  -- a card saved for a Stripe customer the CRM customer has since been
  -- unlinked from is never listed as theirs
  if p_stripe_customer_id is not null
     and p_stripe_customer_id is distinct from coalesce(v_existing.stripe_customer_id, v_stripe) then
    raise exception 'payment method belongs to another Stripe customer' using errcode = '22023';
  end if;

  v_default := coalesce(p_make_default, false)
            or coalesce(v_existing.is_default, false)
            or not exists (select 1 from public.customer_payment_methods pm
                           where pm.shop_id = p_shop_id and pm.customer_id = p_customer_id and pm.is_default);
  if v_default then
    update public.customer_payment_methods pm
       set is_default = false
     where pm.shop_id = p_shop_id and pm.customer_id = p_customer_id and pm.is_default
       and pm.stripe_payment_method_id <> p_stripe_payment_method_id;
  end if;

  insert into public.customer_payment_methods as pm
    (shop_id, customer_id, stripe_payment_method_id, brand, last4, exp_month, exp_year, is_default)
  values (p_shop_id, p_customer_id, p_stripe_payment_method_id, lower(nullif(btrim(p_brand), '')),
          p_last4, p_exp_month, p_exp_year, v_default)
  on conflict (shop_id, stripe_payment_method_id) do update
    set brand = coalesce(excluded.brand, pm.brand),
        last4 = coalesce(excluded.last4, pm.last4),
        exp_month = coalesce(excluded.exp_month, pm.exp_month),
        exp_year = coalesce(excluded.exp_year, pm.exp_year),
        is_default = excluded.is_default
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- (c) gift_card_order_expired(p_session_id) — see the header.
-- ---------------------------------------------------------------------------
create function public.gift_card_order_expired(p_session_id text) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_order   public.gift_card_orders;
  v_changed boolean := false;
begin
  if p_session_id is null or p_session_id !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'invalid Checkout Session id' using errcode = '22023';
  end if;
  select * into v_order from public.gift_card_orders o where o.stripe_checkout_session_id = p_session_id for update;
  if not found then
    raise exception 'gift card order not found' using errcode = 'P0002';
  end if;
  if v_order.status = 'pending' then
    update public.gift_card_orders o set status = 'expired' where o.id = v_order.id
    returning * into v_order;
    v_changed := true;
  end if;
  return jsonb_build_object('order_id', v_order.id, 'status', v_order.status, 'changed', v_changed);
end
$$;

comment on function public.gift_card_order_expired(text) is
  'service_role (stripe-webhook checkout.session.expired): the pending gift card order of the session becomes expired. Idempotent. {order_id, status, changed}.';

-- ---------------------------------------------------------------------------
-- (d) distinct refusals (HINT), same SQLSTATE / message
-- ---------------------------------------------------------------------------
-- membership_join_prepare (0069)
create or replace function public.membership_join_prepare(
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
    insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, source,
                                  lifecycle, phone_unverified)
    values (v_shop.id, v_first, v_last, v_email::extensions.citext, v_phone, v_sms and v_phone is not null, v_email_opt,
            'online_booking', 'customer', v_phone is not null)
    returning id into v_customer;
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
                            'email', v_email);
end
$$;

-- gift_card_order_prepare (0066)
create or replace function public.gift_card_order_prepare(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now        timestamptz := public.effective_now(p_now);
  v_shop       public.shops;
  v_gs         public.gift_card_settings;
  v_index      integer;
  v_amount     integer;
  v_value      bigint;
  v_price      bigint;
  v_buyer      jsonb;
  v_to         jsonb;
  v_b_name     text;
  v_b_email    text;
  v_r_name     text;
  v_r_email    text;
  v_message    text;
  v_order      public.gift_card_orders;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_gs from public.gift_card_settings g where g.shop_id = v_shop.id;
  if not coalesce(v_gs.online_enabled, false) then
    raise exception 'online gift card sales are not enabled for this shop' using errcode = '55000';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'order details must be a JSON object' using errcode = '22023';
  end if;
  v_index := public.payload_int(p_payload, 'offer_index', 'offer', 0, 7);
  v_amount := public.payload_int(p_payload, 'amount_cents', 'amount', 1, 100000000);
  if (v_index is null) = (v_amount is null) then
    raise exception 'choose one of the offers or an amount' using errcode = '22023';
  end if;
  if v_index is not null then
    if v_index >= jsonb_array_length(v_gs.offers) then
      raise exception 'that offer is no longer available' using errcode = '22023';
    end if;
    v_value := (v_gs.offers -> v_index ->> 'value_cents')::bigint;
    v_price := (v_gs.offers -> v_index ->> 'price_cents')::bigint;
  else
    if not v_gs.allow_custom_amount then
      raise exception 'custom amounts are not available' using errcode = '22023';
    end if;
    if v_amount < v_gs.min_custom_cents or v_amount > v_gs.max_custom_cents then
      raise exception 'amount out of range: choose between % and %',
        public.format_money(v_gs.min_custom_cents, v_shop.currency), public.format_money(v_gs.max_custom_cents, v_shop.currency)
        using errcode = '22023', hint = 'amount_out_of_range';
    end if;
    v_value := v_amount;
    v_price := v_amount;
  end if;

  v_buyer := p_payload -> 'purchaser';
  v_to := p_payload -> 'recipient';
  if coalesce(jsonb_typeof(v_buyer), 'null') <> 'object' then
    raise exception 'purchaser details are required' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(v_to), 'null') <> 'object' then
    raise exception 'recipient details are required' using errcode = '22023';
  end if;
  v_b_name := public.payload_text(v_buyer, 'name', 120, 'your name', true);
  v_b_email := lower(public.payload_text(v_buyer, 'email', 254, 'your email', true));
  v_r_name := public.payload_text(v_to, 'name', 120, 'recipient name');
  v_r_email := lower(public.payload_text(v_to, 'email', 254, 'recipient email', true));
  v_message := public.payload_text(v_to, 'message', 500, 'message');
  if not public.is_valid_email(v_b_email) then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  if not public.is_valid_email(v_r_email) then
    raise exception 'enter a valid recipient email address' using errcode = '22023';
  end if;

  -- abuse limit (wall clock, independent of p_now)
  if (select count(*) from public.gift_card_orders o
       where o.shop_id = v_shop.id and lower(o.purchaser_email::text) = v_b_email
         and o.created_at > now() - interval '24 hours') >= 5 then
    raise exception 'too many gift card orders for this email today; please contact the shop' using errcode = 'PT429';
  end if;

  insert into public.gift_card_orders (shop_id, value_cents, price_cents, purchaser_name, purchaser_email,
                                       recipient_name, recipient_email, message, signer_ip, created_at)
  values (v_shop.id, v_value, v_price, v_b_name, v_b_email::extensions.citext, v_r_name,
          v_r_email::extensions.citext, v_message, public.form_signer_ip(), v_now)
  returning * into v_order;
  return jsonb_build_object(
    'order_id', v_order.id,
    'token', v_order.token,
    'shop_id', v_shop.id,
    'value_cents', v_value,
    'price_cents', v_price,
    'currency', v_shop.currency,
    'purchaser_email', v_b_email);
end
$$;

-- ---------------------------------------------------------------------------
-- (e) add_fee_line + p_request_nonce (0068's rules otherwise)
-- ---------------------------------------------------------------------------
drop function public.add_fee_line(text, uuid, uuid);

create function public.add_fee_line(
  p_doc_kind       text,
  p_doc_id         uuid,
  p_fee_id         uuid,
  p_request_nonce  text default null
) returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_kind    text := lower(btrim(coalesce(p_doc_kind, '')));
  v_shop    uuid;
  v_status  text;
  v_job     uuid;
  v_fee     public.shop_fees;
  v_id      uuid;
  v_req     uuid;
  v_prior   jsonb;
begin
  if v_kind not in ('job', 'quote', 'invoice') then
    raise exception 'document kind must be job, quote or invoice' using errcode = '22023';
  end if;
  if v_kind = 'job' then
    select j.shop_id into v_shop from public.jobs j where j.id = p_doc_id for no key update;
  elsif v_kind = 'quote' then
    select q.shop_id, q.status::text into v_shop, v_status from public.quotes q where q.id = p_doc_id for no key update;
  else
    select i.shop_id, i.status::text, i.job_id into v_shop, v_status, v_job from public.invoices i where i.id = p_doc_id;
  end if;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception '% not found', v_kind using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can add fees' using errcode = '42501';
  end if;
  -- a retry of a request that already added its line returns that line
  if p_request_nonce is not null then
    select c.request_id, c.result into v_req, v_prior
      from public.client_request_claim(v_shop, 'add_fee_line', p_request_nonce,
                                       md5(concat_ws(':', v_kind, p_doc_id::text, p_fee_id::text))) c;
    if v_prior is not null then
      return (v_prior ->> 'line_id')::uuid;
    end if;
  end if;
  select * into v_fee from public.shop_fees f
   where f.id = p_fee_id and f.shop_id = v_shop and f.active and f.archived_at is null;
  if not found then
    raise exception 'this fee is not available' using errcode = '22023';
  end if;

  if v_kind = 'job' then
    insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, taxable, duration_minutes,
                                       fee_id, sort)
    values (v_shop, p_doc_id, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, 0, v_fee.id,
            coalesce((select max(li.sort) from public.job_line_items li where li.job_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  elsif v_kind = 'quote' then
    if v_status not in ('draft', 'sent', 'viewed') then
      raise exception 'line items of a % quote cannot be changed; revise it back to draft first', v_status
        using errcode = '22023';
    end if;
    insert into public.quote_line_items (shop_id, quote_id, name, quantity, unit_price_cents, taxable, fee_id, sort)
    values (v_shop, p_doc_id, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, v_fee.id,
            coalesce((select max(li.sort) from public.quote_line_items li where li.quote_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  else
    -- the invoice line guard (every context) refuses void invoices, money
    -- received and payments in flight
    insert into public.invoice_line_items (shop_id, invoice_id, job_id, name, quantity, unit_price_cents, taxable,
                                           fee_id, sort)
    values (v_shop, p_doc_id, v_job, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, v_fee.id,
            coalesce((select max(li.sort) from public.invoice_line_items li where li.invoice_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  end if;
  if v_req is not null then
    perform public.client_request_finish(v_req, jsonb_build_object('line_id', v_id));
  end if;
  return v_id;
end
$$;

comment on function public.add_fee_line(text, uuid, uuid, text) is
  'Adds a preset fee as a line on a job, quote or invoice (managers+; each document''s edit rules apply). Returns the line id. p_request_nonce (0095): a retry returns the same line.';

-- ---------------------------------------------------------------------------
-- (f) import_customers / import_services + p_request_nonce (0087's bodies)
-- ---------------------------------------------------------------------------
drop function public.import_customers(uuid, jsonb, boolean, uuid, text);
drop function public.import_services(uuid, jsonb, boolean, uuid, text);

create function public.import_customers(
  p_shop_id    uuid,
  p_rows       jsonb,
  p_dry_run    boolean default true,
  p_batch_id   uuid default null,
  p_file_name  text default null,
  p_request_nonce  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['first_name', 'last_name', 'company', 'email', 'phone', 'address_line1',
                                  'address_line2', 'city', 'region', 'postal_code', 'country', 'notes', 'tags',
                                  'lifecycle', 'sms_opt_in', 'email_opt_in', 'vehicle'];
  c_vkeys constant text[] := array['year', 'make', 'model', 'trim', 'color', 'license_plate', 'vin', 'category'];
  v_shop     public.shops;
  v_results  jsonb := '[]';
  v_errors   jsonb := '[]';
  v_created  integer := 0;
  v_updated  integer := 0;
  v_skipped  integer := 0;
  v_row      jsonb;
  v_n        integer;
  v_unknown  text;
  v_first    text;
  v_last     text;
  v_company  text;
  v_email    text;
  v_phone    text;
  v_raw      text;
  v_line1    text;
  v_line2    text;
  v_city     text;
  v_region   text;
  v_postal   text;
  v_country  text;
  v_notes    text;
  v_tags     text[];
  v_life     public.customer_lifecycle;
  v_sms_yes  boolean;
  v_mail_yes boolean;
  v_sms_ok   boolean;
  v_mail_ok  boolean;
  v_note     text;
  v_veh      jsonb;
  v_year     integer;
  v_make     text;
  v_model    text;
  v_trim     text;
  v_color    text;
  v_plate    text;
  v_vin      text;
  v_cat      uuid;
  v_cust     public.customers;
  v_before   jsonb;
  v_vehicle  public.vehicles;
  v_vaction  text;
  v_action   text;
  v_message  text;
  v_batch    uuid := p_batch_id;
  v_req      uuid;
  v_prior    jsonb;
begin
  v_shop := public.comms_import_begin(p_shop_id, 'customers', p_rows, p_dry_run, p_batch_id, p_file_name);
  -- a committed chunk retried with the same nonce (0095) returns the first
  -- call's result and imports nothing again (dry runs ignore the nonce)
  if p_request_nonce is not null and not p_dry_run then
    select c.request_id, c.result into v_req, v_prior
      from public.client_request_claim(p_shop_id, 'import_customers', p_request_nonce,
                                       md5(p_rows::text || '|' || coalesce(p_batch_id::text, '-') || '|'
                                           || coalesce(p_file_name, '-'))) c;
    if v_prior is not null then
      return v_prior || jsonb_build_object('replayed', true);
    end if;
  end if;

  begin
    for v_row, v_n in select e, o::integer from jsonb_array_elements(p_rows) with ordinality as x(e, o) loop
      v_action := null; v_message := null; v_note := null; v_vaction := 'none'; v_cust := null; v_vehicle := null;
      begin
        if jsonb_typeof(v_row) <> 'object' then
          raise exception 'each row must be an object' using errcode = '22023';
        end if;
        select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_row) k where k <> all (c_keys);
        if v_unknown is not null then
          raise exception 'unknown column(s): %', v_unknown using errcode = '22023';
        end if;
        v_first := public.payload_text(v_row, 'first_name', 100, 'first name');
        v_last := public.payload_text(v_row, 'last_name', 100, 'last name');
        v_company := public.payload_text(v_row, 'company', 200, 'company');
        v_email := lower(public.payload_text(v_row, 'email', 320, 'email'));
        if v_email is not null and not public.is_valid_email(v_email) then
          raise exception 'email "%" is not a valid address', left(v_email, 80) using errcode = '22023';
        end if;
        v_raw := public.payload_text(v_row, 'phone', 40, 'phone');
        v_phone := public.normalize_phone_e164(v_raw, v_shop.country);
        if v_raw is not null and v_phone is null then
          raise exception 'phone "%" is not a valid number', v_raw using errcode = '22023';
        end if;
        v_line1 := public.payload_text(v_row, 'address_line1', 200, 'address line 1');
        v_line2 := public.payload_text(v_row, 'address_line2', 200, 'address line 2');
        v_city := public.payload_text(v_row, 'city', 100, 'city');
        v_region := public.payload_text(v_row, 'region', 100, 'state / region');
        v_postal := public.payload_text(v_row, 'postal_code', 20, 'postal code');
        v_country := upper(public.payload_text(v_row, 'country', 2, 'country'));
        if v_country is not null and v_country !~ '^[A-Z]{2}$' then
          raise exception 'country must be a 2-letter code' using errcode = '22023';
        end if;
        v_notes := public.payload_text(v_row, 'notes', 20000, 'notes');
        v_tags := public.comms_import_tags(v_row -> 'tags');
        if cardinality(v_tags) > 50 then
          raise exception 'at most 50 tags' using errcode = '22023';
        end if;
        v_raw := lower(public.payload_text(v_row, 'lifecycle', 20, 'lifecycle'));
        if v_raw is not null and v_raw not in ('lead', 'customer') then
          raise exception 'lifecycle must be lead or customer' using errcode = '22023';
        end if;
        -- only an explicit value: a matched lead is promoted when the row
        -- says 'customer'; a new customer defaults to 'customer' below
        v_life := v_raw::public.customer_lifecycle;
        v_sms_yes := public.comms_import_yes(v_row, 'sms_opt_in');
        v_mail_yes := public.comms_import_yes(v_row, 'email_opt_in');

        -- vehicle
        v_veh := v_row -> 'vehicle';
        v_year := null; v_make := null; v_model := null; v_trim := null; v_color := null; v_plate := null;
        v_vin := null; v_cat := null;
        if v_veh is not null and jsonb_typeof(v_veh) <> 'null' then
          if jsonb_typeof(v_veh) <> 'object' then
            raise exception 'vehicle must be an object' using errcode = '22023';
          end if;
          select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_veh) k where k <> all (c_vkeys);
          if v_unknown is not null then
            raise exception 'unknown vehicle column(s): %', v_unknown using errcode = '22023';
          end if;
          v_year := public.payload_int(v_veh, 'year', 'vehicle year', 1886, 2100);
          v_make := public.payload_text(v_veh, 'make', 60, 'vehicle make');
          v_model := public.payload_text(v_veh, 'model', 60, 'vehicle model');
          v_trim := public.payload_text(v_veh, 'trim', 60, 'vehicle trim');
          v_color := public.payload_text(v_veh, 'color', 40, 'vehicle color');
          v_plate := upper(public.payload_text(v_veh, 'license_plate', 15, 'license plate'));
          v_vin := nullif(upper(regexp_replace(coalesce(public.payload_text(v_veh, 'vin', 40, 'VIN'), ''),
                                               '[[:space:]-]', '', 'g')), '');
          if v_vin is not null and v_vin !~ '^[A-Z0-9]{5,17}$' then
            raise exception 'VIN "%" is not valid', v_vin using errcode = '22023';
          end if;
          v_raw := public.payload_text(v_veh, 'category', 60, 'vehicle size');
          if v_raw is not null then
            select vc.id into v_cat from public.vehicle_categories vc
             where vc.shop_id = p_shop_id and lower(vc.name) = lower(v_raw);
            if v_cat is null then
              raise exception 'unknown vehicle size "%"', v_raw using errcode = '22023';
            end if;
          end if;
        end if;

        -- match
        if v_email is not null then
          select * into v_cust from public.customers c
           where c.shop_id = p_shop_id and c.archived_at is null and c.email is not null
             and lower(c.email::text) = v_email
           order by c.created_at desc, c.id limit 1;
        end if;
        if v_cust.id is null and v_phone is not null then
          select * into v_cust from public.customers c
           where c.shop_id = p_shop_id and c.archived_at is null and c.email is null and c.phone = v_phone
           order by c.created_at desc, c.id limit 1;
        end if;

        -- consent applies to the address the row gives, and only when that
        -- is the address the customer has (or will have) on file
        v_sms_ok := v_phone is not null and (v_cust.id is null or coalesce(v_cust.phone, v_phone) = v_phone);
        v_mail_ok := v_email is not null
                     and (v_cust.id is null or lower(coalesce(v_cust.email::text, v_email)) = v_email);
        if v_sms_yes and not v_sms_ok then
          v_note := case when v_phone is null then 'text consent not applied: the row has no phone'
                         else 'text consent not applied: the row''s phone is not the one on file' end;
        end if;
        if v_mail_yes and not v_mail_ok then
          v_note := concat_ws('; ', v_note,
                              case when v_email is null then 'email consent not applied: the row has no email'
                                   else 'email consent not applied: the row''s email is not the one on file' end);
        end if;
        v_sms_yes := v_sms_yes and v_sms_ok;
        v_mail_yes := v_mail_yes and v_mail_ok;

        if v_cust.id is null then
          if coalesce(v_first, v_last, v_company) is null then
            raise exception 'a first name, last name or company is required' using errcode = '22023';
          end if;
          insert into public.customers (shop_id, first_name, last_name, company, email, phone, address_line1,
                                        address_line2, city, region, postal_code, country, notes, tags, lifecycle,
                                        source, sms_opt_in, email_opt_in)
          values (p_shop_id, v_first, v_last, v_company, v_email::extensions.citext, v_phone, v_line1, v_line2, v_city,
                  v_region, v_postal, v_country, v_notes, v_tags,
                  coalesce(v_life, 'customer'::public.customer_lifecycle), 'import', v_sms_yes, v_mail_yes)
          returning * into v_cust;
          v_action := 'create';
        else
          v_before := to_jsonb(v_cust);
          update public.customers c
             set first_name = coalesce(nullif(btrim(c.first_name), ''), v_first),
                 last_name = coalesce(nullif(btrim(c.last_name), ''), v_last),
                 company = coalesce(nullif(btrim(c.company), ''), v_company),
                 email = coalesce(c.email, v_email::extensions.citext),
                 phone = coalesce(c.phone, v_phone),
                 address_line1 = coalesce(c.address_line1, v_line1),
                 address_line2 = coalesce(c.address_line2, v_line2),
                 city = coalesce(c.city, v_city),
                 region = coalesce(c.region, v_region),
                 postal_code = coalesce(c.postal_code, v_postal),
                 country = coalesce(c.country, v_country),
                 notes = case when v_notes is null then c.notes
                              when c.notes is null or btrim(c.notes) = '' then v_notes
                              when strpos(c.notes, v_notes) > 0 then c.notes
                              when char_length(c.notes) + 2 + char_length(v_notes) > 20000 then c.notes
                              else c.notes || E'\n\n' || v_notes end,
                 tags = (select coalesce(array_agg(t order by o), '{}')
                           from (select t, o from unnest(c.tags || array(select x from unnest(v_tags) x
                                                                           where x <> all (c.tags)))
                                   with ordinality as u(t, o)
                                  order by o limit 50) y),
                 lifecycle = case when c.lifecycle = 'lead' and v_life is not distinct from 'customer'
                                  then 'customer'::public.customer_lifecycle
                                  else c.lifecycle end,
                 sms_opt_in = c.sms_opt_in or (v_sms_yes and c.sms_opted_out_at is null),
                 email_opt_in = c.email_opt_in or (v_mail_yes and c.email_opted_out_at is null)
           where c.id = v_cust.id and c.shop_id = p_shop_id
          returning * into v_cust;
          v_action := case when (to_jsonb(v_cust) - 'updated_at') = (v_before - 'updated_at') then 'skip'
                           else 'update' end;
        end if;

        -- vehicle
        if coalesce(v_make, v_model, v_vin) is not null then
          if v_vin is not null then
            select * into v_vehicle from public.vehicles v
             where v.shop_id = p_shop_id and v.customer_id = v_cust.id and v.archived_at is null and v.vin = v_vin
             order by v.created_at desc, v.id limit 1;
          end if;
          if v_vehicle.id is null then
            select * into v_vehicle from public.vehicles v
             where v.shop_id = p_shop_id and v.customer_id = v_cust.id and v.archived_at is null
               and lower(btrim(coalesce(v.make, ''))) = lower(coalesce(v_make, ''))
               and lower(btrim(coalesce(v.model, ''))) = lower(coalesce(v_model, ''))
               and v.year is not distinct from v_year
               and (v_vin is null or v.vin is null)
             order by v.created_at desc, v.id limit 1;
          end if;
          if v_vehicle.id is null then
            insert into public.vehicles (shop_id, customer_id, year, make, model, trim, color, license_plate, vin,
                                         category_id)
            values (p_shop_id, v_cust.id, v_year, v_make, v_model, v_trim, v_color, v_plate, v_vin, v_cat)
            returning * into v_vehicle;
            v_vaction := 'create';
            if v_action = 'skip' then
              v_action := 'update';
            end if;
          else
            v_before := to_jsonb(v_vehicle);
            update public.vehicles v
               set year = coalesce(v.year, v_year),
                   trim = coalesce(v.trim, v_trim),
                   color = coalesce(v.color, v_color),
                   license_plate = coalesce(v.license_plate, v_plate),
                   vin = coalesce(v.vin, v_vin),
                   category_id = coalesce(v.category_id, v_cat)
             where v.id = v_vehicle.id and v.shop_id = p_shop_id
            returning * into v_vehicle;
            v_vaction := 'match';
            if v_action = 'skip' and (to_jsonb(v_vehicle) - 'updated_at') <> (v_before - 'updated_at') then
              v_action := 'update';
            end if;
          end if;
        end if;

        if v_action = 'skip' then
          v_message := 'already up to date';
        end if;
        v_message := nullif(concat_ws('; ', v_message, v_note), '');
      exception when others then
        v_action := 'error';
        v_message := sqlerrm;
        v_cust := null;
        v_vaction := 'none';
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', v_n, 'message', left(sqlerrm, 500)));
      end;
      if v_action = 'create' then v_created := v_created + 1;
      elsif v_action = 'update' then v_updated := v_updated + 1;
      elsif v_action = 'skip' then v_skipped := v_skipped + 1;
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_n,
        'action', v_action,
        'customer_id', case when p_dry_run and v_action = 'create' then null else v_cust.id end,
        'vehicle_action', v_vaction,
        'message', v_message));
    end loop;

    if p_dry_run then
      raise exception using errcode = 'P0001', message = 'comms_import_dry_run';
    end if;
  exception when sqlstate 'P0001' then
    if sqlerrm is distinct from 'comms_import_dry_run' then
      raise;
    end if;
  end;

  if not p_dry_run then
    v_batch := public.comms_import_record(p_shop_id, 'customers', p_batch_id, p_file_name,
                                          jsonb_array_length(p_rows), v_created, v_updated, v_skipped, v_errors);
  end if;

  v_prior := jsonb_build_object(
    'batch_id', v_batch,
    'dry_run', p_dry_run,
    'counts', jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped,
                                 'errors', jsonb_array_length(v_errors)),
    'rows', v_results);
  if v_req is not null then
    perform public.client_request_finish(v_req, v_prior);
  end if;
  return v_prior;
end
$$;

create function public.import_services(
  p_shop_id    uuid,
  p_rows       jsonb,
  p_dry_run    boolean default true,
  p_batch_id   uuid default null,
  p_file_name  text default null,
  p_request_nonce  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['name', 'category', 'kind', 'description', 'duration_minutes', 'taxable',
                                  'online_bookable', 'prices'];
  v_shop      public.shops;
  v_results   jsonb := '[]';
  v_errors    jsonb := '[]';
  v_created   integer := 0;
  v_updated   integer := 0;
  v_skipped   integer := 0;
  v_row       jsonb;
  v_n         integer;
  v_unknown   text;
  v_name      text;
  v_catname   text;
  v_cat       uuid;
  v_raw       text;
  v_kind      public.service_kind;
  v_desc      text;
  v_duration  integer;
  v_taxable   boolean;
  v_bookable  boolean;
  v_prices    jsonb;
  v_pkey      text;
  v_pval      jsonb;
  v_vcat      uuid;
  v_cents     bigint;
  v_price_rows jsonb;
  v_svc       public.services;
  v_before    jsonb;
  v_added     integer;
  v_kept      text[];
  v_action    text;
  v_message   text;
  v_batch     uuid := p_batch_id;
  v_req      uuid;
  v_prior    jsonb;
begin
  v_shop := public.comms_import_begin(p_shop_id, 'services', p_rows, p_dry_run, p_batch_id, p_file_name);
  -- a committed chunk retried with the same nonce (0095) returns the first
  -- call's result and imports nothing again (dry runs ignore the nonce)
  if p_request_nonce is not null and not p_dry_run then
    select c.request_id, c.result into v_req, v_prior
      from public.client_request_claim(p_shop_id, 'import_services', p_request_nonce,
                                       md5(p_rows::text || '|' || coalesce(p_batch_id::text, '-') || '|'
                                           || coalesce(p_file_name, '-'))) c;
    if v_prior is not null then
      return v_prior || jsonb_build_object('replayed', true);
    end if;
  end if;

  begin
    for v_row, v_n in select e, o::integer from jsonb_array_elements(p_rows) with ordinality as x(e, o) loop
      v_action := null; v_message := null; v_svc := null; v_added := 0; v_kept := '{}';
      begin
        if jsonb_typeof(v_row) <> 'object' then
          raise exception 'each row must be an object' using errcode = '22023';
        end if;
        select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_row) k where k <> all (c_keys);
        if v_unknown is not null then
          raise exception 'unknown column(s): %', v_unknown using errcode = '22023';
        end if;
        v_name := public.payload_text(v_row, 'name', 120, 'name', true);
        v_catname := public.payload_text(v_row, 'category', 80, 'category');
        v_raw := lower(public.payload_text(v_row, 'kind', 20, 'kind'));
        if v_raw is not null and v_raw not in ('service', 'package', 'addon', 'product') then
          raise exception 'kind must be service, package, addon or product' using errcode = '22023';
        end if;
        v_kind := coalesce(v_raw, 'service')::public.service_kind;
        v_desc := public.payload_text(v_row, 'description', 10000, 'description');
        v_duration := public.payload_int(v_row, 'duration_minutes', 'duration (minutes)', 0, 1440);
        v_taxable := public.comms_import_flag(v_row, 'taxable', 'taxable', true);
        v_bookable := public.comms_import_flag(v_row, 'online_bookable', 'online bookable', false);

        -- prices: validated completely before anything is written
        v_prices := v_row -> 'prices';
        v_price_rows := '[]';
        if v_prices is not null and jsonb_typeof(v_prices) <> 'null' then
          if jsonb_typeof(v_prices) <> 'object' then
            raise exception 'prices must be an object {"base" or vehicle size: cents}' using errcode = '22023';
          end if;
          for v_pkey, v_pval in select k, v from jsonb_each(v_prices) as p(k, v) order by k loop
            continue when jsonb_typeof(v_pval) = 'null' or (jsonb_typeof(v_pval) = 'string' and btrim(v_pval #>> '{}') = '');
            if jsonb_typeof(v_pval) not in ('number', 'string') or btrim(v_pval #>> '{}') !~ '^[0-9]{1,9}$' then
              raise exception 'price for "%" must be whole cents', v_pkey using errcode = '22023';
            end if;
            v_cents := btrim(v_pval #>> '{}')::bigint;
            if v_cents > 100000000 then
              raise exception 'price for "%" is too large', v_pkey using errcode = '22023';
            end if;
            v_vcat := null;
            if lower(btrim(v_pkey)) <> 'base' then
              select vc.id into v_vcat from public.vehicle_categories vc
               where vc.shop_id = p_shop_id and lower(vc.name) = lower(btrim(v_pkey));
              if v_vcat is null then
                raise exception 'unknown vehicle size "%"', v_pkey using errcode = '22023';
              end if;
            end if;
            v_price_rows := v_price_rows || jsonb_build_array(jsonb_build_object('label', v_pkey, 'category_id', v_vcat,
                                                                                 'cents', v_cents));
          end loop;
        end if;

        -- category (created when missing)
        v_cat := null;
        if v_catname is not null then
          select sc.id into v_cat from public.service_categories sc
           where sc.shop_id = p_shop_id and lower(btrim(sc.name)) = lower(v_catname);
          if v_cat is null then
            insert into public.service_categories (shop_id, name) values (p_shop_id, v_catname) returning id into v_cat;
          end if;
        end if;

        select * into v_svc from public.services s
         where s.shop_id = p_shop_id and s.archived_at is null and lower(btrim(s.name)) = lower(v_name)
         order by s.created_at, s.id limit 1;
        if v_svc.id is null then
          insert into public.services (shop_id, category_id, name, description, kind, duration_minutes, taxable,
                                       online_bookable)
          values (p_shop_id, v_cat, v_name, v_desc, v_kind, coalesce(v_duration, 60), v_taxable, v_bookable)
          returning * into v_svc;
          v_action := 'create';
        else
          v_before := to_jsonb(v_svc);
          update public.services s
             set description = coalesce(s.description, v_desc),
                 category_id = coalesce(s.category_id, v_cat)
           where s.id = v_svc.id and s.shop_id = p_shop_id
          returning * into v_svc;
          v_action := case when (to_jsonb(v_svc) - 'updated_at') = (v_before - 'updated_at') then 'skip'
                           else 'update' end;
        end if;

        -- prices: only where the service has none for that size
        for v_pval in select e from jsonb_array_elements(v_price_rows) e loop
          if exists (select 1 from public.service_prices sp
                      where sp.shop_id = p_shop_id and sp.service_id = v_svc.id
                        and sp.vehicle_category_id is not distinct from (v_pval ->> 'category_id')::uuid) then
            v_kept := v_kept || (v_pval ->> 'label');
          else
            insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
            values (p_shop_id, v_svc.id, (v_pval ->> 'category_id')::uuid, (v_pval ->> 'cents')::bigint);
            v_added := v_added + 1;
          end if;
        end loop;
        if v_added > 0 and v_action = 'skip' then
          v_action := 'update';
        end if;
        if cardinality(v_kept) > 0 then
          v_message := 'existing price kept for: ' || array_to_string(v_kept, ', ');
        elsif v_action = 'skip' then
          v_message := 'already up to date';
        end if;
      exception when others then
        v_action := 'error';
        v_message := sqlerrm;
        v_svc := null;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', v_n, 'message', left(sqlerrm, 500)));
      end;
      if v_action = 'create' then v_created := v_created + 1;
      elsif v_action = 'update' then v_updated := v_updated + 1;
      elsif v_action = 'skip' then v_skipped := v_skipped + 1;
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_n,
        'action', v_action,
        'service_id', case when p_dry_run and v_action = 'create' then null else v_svc.id end,
        'message', v_message));
    end loop;

    if p_dry_run then
      raise exception using errcode = 'P0001', message = 'comms_import_dry_run';
    end if;
  exception when sqlstate 'P0001' then
    if sqlerrm is distinct from 'comms_import_dry_run' then
      raise;
    end if;
  end;

  if not p_dry_run then
    v_batch := public.comms_import_record(p_shop_id, 'services', p_batch_id, p_file_name,
                                          jsonb_array_length(p_rows), v_created, v_updated, v_skipped, v_errors);
  end if;

  v_prior := jsonb_build_object(
    'batch_id', v_batch,
    'dry_run', p_dry_run,
    'counts', jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped,
                                 'errors', jsonb_array_length(v_errors)),
    'rows', v_results);
  if v_req is not null then
    perform public.client_request_finish(v_req, v_prior);
  end if;
  return v_prior;
end
$$;

-- ---------------------------------------------------------------------------
-- (g) shop timezone / slug / currency for the portal and the report page
-- ---------------------------------------------------------------------------
-- job_report_public_json (0072): shop.timezone
create or replace function public.job_report_public_json(p_report_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', jsonb_build_object(
      'name', s.name,
      'logo_path', s.logo_path,
      'brand_color', s.brand_color,
      'phone', s.phone,
      'email', s.email,
      'review_url', s.review_url,
      'timezone', s.timezone),
    'job', jsonb_build_object(
      'number', j.number,
      'status', j.status,
      'completed_at', j.completed_at,
      'local_date', (coalesce(j.completed_at, j.scheduled_start, j.created_at) at time zone s.timezone)::date),
    'vehicle', case when v.id is null then null else jsonb_build_object(
      'year', v.year, 'make', v.make, 'model', v.model, 'color', v.color) end,
    'services', coalesce((
      select jsonb_agg(li.name order by li.sort, li.created_at, li.id)
        from public.job_line_items li
       where li.job_id = j.id and li.shop_id = j.shop_id and li.fee_id is null), '[]'::jsonb),
    'message', r.message,
    'published_at', r.published_at,
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'kind', p.kind,
               'caption', p.caption,
               'media_type', p.media_type,
               'duration_seconds', p.duration_seconds,
               'has_poster', p.poster_path is not null,
               'created_at', p.created_at) order by p.created_at, p.id)
        from public.job_photos p
       where p.job_id = j.id and p.shop_id = j.shop_id
         and p.customer_visible and p.kind = any (r.photo_kinds)), '[]'::jsonb),
    'inspections', case when r.include_inspections then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id,
               'kind', i.kind,
               'mileage', i.mileage,
               'fuel_level', i.fuel_level,
               'marks', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', m.id,
                          'view', m.view,
                          'x', m.x,
                          'y', m.y,
                          'damage', m.damage,
                          'note', m.note,
                          'has_photo', m.photo_path is not null) order by m.created_at, m.id)
                   from public.inspection_marks m
                  where m.inspection_id = i.id and m.shop_id = i.shop_id), '[]'::jsonb),
               'signed_at', i.signed_at,
               'signed_by_name', i.signed_by_name,
               'signed_remotely', i.signed_remotely,
               'can_acknowledge', i.kind = 'pre' and i.signed_at is null
                                  and j.status not in ('cancelled', 'no_show'))
             order by i.kind, i.created_at, i.id)
        from public.inspections i
       where i.job_id = j.id and i.shop_id = j.shop_id), '[]'::jsonb)
      else '[]'::jsonb end,
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id,
               'file_name', d.file_name,
               'content_type', d.content_type,
               'size_bytes', d.size_bytes) order by d.created_at, d.id)
        from public.documents d
       where d.job_id = j.id and d.shop_id = j.shop_id and d.customer_visible), '[]'::jsonb),
    'signature_upload_prefix',
      case when r.include_inspections and j.status not in ('cancelled', 'no_show')
                and exists (select 1 from public.inspections i
                             where i.job_id = j.id and i.shop_id = j.shop_id and i.kind = 'pre' and i.signed_at is null)
           then r.shop_id::text || '/reports/' || r.token::text || '/' end)
  from public.job_reports r
  join public.shops s on s.id = r.shop_id
  join public.jobs j on j.id = r.job_id and j.shop_id = r.shop_id
  left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
  where r.id = p_report_id
$$;

-- portal_documents (0075)
create or replace function public.portal_documents() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', d.id,
             'shop_name', s.name,
             'shop_slug', s.slug,
             'timezone', s.timezone,
             'currency', s.currency,
             'file_name', d.file_name,
             'content_type', d.content_type,
             'size_bytes', d.size_bytes,
             'job_number', j.number,
             'created_at', d.created_at) order by d.created_at desc, d.id)
      from public.customers c
      join public.documents d on d.customer_id = c.id and d.shop_id = c.shop_id
      join public.shops s on s.id = d.shop_id
      left join public.jobs j on j.id = d.job_id and j.shop_id = d.shop_id
     where c.portal_user_id = v_uid and c.archived_at is null and d.customer_visible), '[]'::jsonb);
end
$$;

-- portal_job_reports (0075)
create or replace function public.portal_job_reports() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'shop_name', s.name,
             'shop_slug', s.slug,
             'timezone', s.timezone,
             'currency', s.currency,
             'job_number', j.number,
             'completed_at', j.completed_at,
             'published_at', r.published_at,
             'report_path', '/r/' || r.token::text) order by r.published_at desc, r.id)
      from public.customers c
      join public.jobs j on j.customer_id = c.id and j.shop_id = c.shop_id
      join public.job_reports r on r.job_id = j.id and r.shop_id = j.shop_id and r.revoked_at is null
      join public.shops s on s.id = j.shop_id
     where c.portal_user_id = v_uid and c.archived_at is null), '[]'::jsonb);
end
$$;

-- portal_referrals (0069)
create or replace function public.portal_referrals() returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_out  jsonb := '[]'::jsonb;
  r      record;
  v_code jsonb;
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  for r in
    select c.id, c.shop_id, s.name as shop_name, s.slug as shop_slug, s.timezone as shop_timezone,
           s.currency as shop_currency
      from public.customers c
      join public.shops s on s.id = c.shop_id
      join public.referral_settings rs on rs.shop_id = c.shop_id and rs.enabled
     where c.portal_user_id = v_uid and c.archived_at is null
     order by s.name, c.created_at, c.id
  loop
    v_code := public.referral_code_core(r.id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'shop_name', r.shop_name,
      'shop_slug', r.shop_slug,
      'timezone', r.shop_timezone,
      'currency', r.shop_currency,
      'code', v_code ->> 'code',
      'share_url', v_code ->> 'share_url',
      'credits_earned_cents', (select coalesce(sum(rc.amount_cents), 0) from public.referral_credits rc
                                where rc.shop_id = r.shop_id and rc.referrer_customer_id = r.id and rc.status = 'issued'),
      'credit_balance_cents', (select coalesce(sum(g.balance_cents), 0) from public.gift_cards g
                                where g.shop_id = r.shop_id and g.owner_customer_id = r.id and g.kind = 'credit'
                                  and g.status = 'active' and (g.expires_at is null or g.expires_at > now()))));
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.client_request_claim(uuid, text, text, text),
  public.client_request_finish(uuid, jsonb),
  public.gift_card_order_expired(text)
from public, anon, authenticated;
grant execute on function
  public.client_request_claim(uuid, text, text, text),
  public.client_request_finish(uuid, jsonb),
  public.gift_card_order_expired(text)
to service_role;

revoke execute on function public.add_fee_line(text, uuid, uuid, text) from public, anon;
grant execute on function public.add_fee_line(text, uuid, uuid, text) to authenticated, service_role;

revoke execute on function
  public.import_customers(uuid, jsonb, boolean, uuid, text, text),
  public.import_services(uuid, jsonb, boolean, uuid, text, text)
from public, anon;
grant execute on function
  public.import_customers(uuid, jsonb, boolean, uuid, text, text),
  public.import_services(uuid, jsonb, boolean, uuid, text, text)
to authenticated, service_role;
