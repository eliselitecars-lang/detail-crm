-- ============================================================================
-- 0105 — Public abuse limits count an IPv6 client by its /64, and signed-in
-- clients book from their own daily allowance.
--
-- The per-connection limits of the anonymous public forms compared the exact
-- address from form_signer_ip(). An IPv6 client picks its own interface id
-- and normally holds a whole /64, so every request could come from a fresh
-- address with its full allowance: one machine made the shop's 100 online
-- bookings of the day (and 200 submissions of a lead form) in minutes, which
-- closed online booking — and the lead form — for everyone for 24 hours,
-- after putting 100 requested jobs on the calendar and 100 new customers in
-- the shop.
--
--   * client_ip_scope(ip) — the unit a per-connection limit counts: an IPv4
--     address as is, an IPv4-mapped IPv6 address (::ffff:a.b.c.d) as that
--     IPv4 address, any other IPv6 address as its /64 network.
--   * create_online_booking (0104): 10 bookings per connection per shop (an
--     IPv6 /64); lead forms (public_submit_lead, 0088): 10 per connection
--     per form; gift card codes on the /i page (public_redeem_gift_card,
--     0066): 20 wrong codes per connection per shop an hour ('ip:' key, now
--     the scope; unchanged for IPv4). Addresses are still recorded exactly
--     (lead_submissions.signer_ip is audit evidence).
--   * The 100-a-day shop cap on online bookings counted every caller, so
--     callers who proved nothing (10 IPv4 addresses are enough) could still
--     lock out the shop's real clients. A booking by a signed-in client with
--     a confirmed email (portal_confirmed_email()) now draws on its own
--     allowance: 10 per account per shop and 100 per shop a day for signed-in
--     bookings, next to the 100 per shop for anonymous ones — anonymous
--     traffic can no longer close online booking for signed-in clients. The
--     per-connection limit still counts both. online_booking_log.user_id
--     records the account (null = anonymous).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- client_ip_scope — the unit per-connection abuse limits count
-- ---------------------------------------------------------------------------
create function public.client_ip_scope(p_ip inet) returns inet
language sql immutable
set search_path = ''
as $$
  select case
    when p_ip is null then null
    when pg_catalog.family(p_ip) = 4 then pg_catalog.host(p_ip)::inet
    -- an IPv4 client seen through an IPv6 socket (::ffff:a.b.c.d)
    when p_ip <<= '::ffff:0.0.0.0/96'::inet then '0.0.0.0'::inet + (p_ip - '::ffff:0.0.0.0'::inet)
    else pg_catalog.network(pg_catalog.set_masklen(p_ip, 64))::inet
  end
$$;

comment on function public.client_ip_scope(inet) is
  'Internal (0105): the unit a per-connection abuse limit counts — an IPv4 address as is (/32), an IPv4-mapped IPv6 address as its IPv4 address, any other IPv6 address as its /64 (a client chooses its own interface id). Null for null.';
revoke execute on function public.client_ip_scope(inet) from public, anon, authenticated;
grant execute on function public.client_ip_scope(inet) to service_role;

-- ---------------------------------------------------------------------------
-- online_booking_log: + user_id; the per-connection index counts scopes
-- ---------------------------------------------------------------------------
alter table public.online_booking_log add column user_id uuid;
comment on column public.online_booking_log.user_id is
  'The signed-in client (auth user with a confirmed email) who booked, or null for an anonymous booking (0105: separate daily allowances).';
comment on table public.online_booking_log is
  'Internal (0104; 0105): one row per accepted online booking — its shop, the client IP (form_signer_ip; null when unknown), the signed-in client with a confirmed email (null = anonymous) and when. Only create_online_booking reads and writes it (abuse limits, rolling 24 h: 10 per connection — an IPv6 /64 — per shop; 10 per signed-in account per shop; 100 anonymous and 100 signed-in bookings per shop). No client access.';

drop index public.online_booking_log_shop_ip_idx;
create index online_booking_log_shop_scope_idx on public.online_booking_log
  (shop_id, public.client_ip_scope(client_ip), created_at) where client_ip is not null;
create index online_booking_log_shop_user_idx on public.online_booking_log (shop_id, user_id, created_at)
  where user_id is not null;

-- ---------------------------------------------------------------------------
-- create_online_booking (0104) — connection = client_ip_scope; separate
-- allowances for signed-in clients. The booking itself is unchanged
-- (create_online_booking_core, 0054 / 0102).
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

  v_result := public.create_online_booking_core(p_slug, p_payload, p_now);

  delete from public.online_booking_log l
   where l.shop_id = v_shop and l.created_at < now() - interval '2 days';
  insert into public.online_booking_log (shop_id, client_ip, user_id) values (v_shop, v_ip, v_user);
  return v_result;
end
$$;

comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap; 0102: a lapsed shop answers 55000; 0104/0105: PT429 past 10 bookings per connection — an IPv6 /64 — per shop, 10 per signed-in account per shop, 100 anonymous and 100 signed-in bookings per shop, in any rolling 24 hours).';

-- ---------------------------------------------------------------------------
-- public_submit_lead (0088; same signature, grants) — the per-connection
-- limit counts the client's scope (an IPv6 /64). signer_ip stays the exact
-- address.
-- ---------------------------------------------------------------------------
create or replace function public.public_submit_lead(
  p_token    uuid,
  p_payload  jsonb,
  p_now      timestamptz default now()
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_default_message constant text := 'Thanks! We received your request and will be in touch soon.';
  v_now      timestamptz := public.effective_now(p_now);
  v_form     public.lead_forms;
  v_shop     public.shops;
  v_first    text;
  v_last     text;
  v_email    text;
  v_raw      text;
  v_phone    text;
  v_sms      boolean;
  v_mail     boolean;
  v_veh_in   jsonb;
  v_year     integer;
  v_make     text;
  v_model    text;
  v_vinfo    jsonb;
  v_message  text;
  v_answers  jsonb := '{}';
  v_field    public.custom_fields;
  v_val      jsonb;
  v_err      text;
  v_key      text;
  v_recent   integer;
  v_cust     public.customers;
  v_matched  boolean := false;
  v_vehicle  uuid;
  v_who      text;
  v_ip       inet := public.form_signer_ip();
  v_scope    inet := public.client_ip_scope(v_ip);   -- 0105: an IPv6 client's /64
  -- the auto-reply's variables: nothing the visitor typed (see the header)
  v_reply    constant jsonb := jsonb_build_object('customer_first_name', 'there', 'customer_name', null);
begin
  v_form := public.comms_live_lead_form(p_token);
  if jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'the submission must be an object' using errcode = '22023';
  end if;
  -- honeypot: bots fill every field; people never see this one
  if nullif(btrim(coalesce(p_payload ->> 'website', '')), '') is not null then
    return jsonb_build_object('ok', true, 'message', coalesce(v_form.success_message, c_default_message));
  end if;
  select * into v_shop from public.shops s where s.id = v_form.shop_id;

  v_first := public.payload_text(p_payload, 'first_name', 100, 'first name', true);
  v_last := public.payload_text(p_payload, 'last_name', 100, 'last name');
  v_email := lower(public.payload_text(p_payload, 'email', 320, 'email'));
  if v_email is not null and not public.is_valid_email(v_email) then
    raise exception 'please enter a valid email address' using errcode = '22023';
  end if;
  v_raw := public.payload_text(p_payload, 'phone', 40, 'phone');
  v_phone := public.normalize_phone_e164(v_raw, v_shop.country);
  if v_raw is not null and v_phone is null then
    raise exception 'please enter a valid phone number' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'an email address or phone number is required' using errcode = '22023';
  end if;
  v_sms := public.payload_bool(p_payload, 'sms_opt_in', 'text message consent') and v_phone is not null;
  v_mail := public.payload_bool(p_payload, 'email_opt_in', 'email consent') and v_email is not null;

  if v_form.ask_vehicle then
    v_veh_in := p_payload -> 'vehicle';
    if v_veh_in is not null and jsonb_typeof(v_veh_in) not in ('object', 'null') then
      raise exception 'vehicle must be an object' using errcode = '22023';
    end if;
    v_year := public.payload_int(v_veh_in, 'year', 'vehicle year', 1886, 2100);
    v_make := public.payload_text(v_veh_in, 'make', 60, 'vehicle make');
    v_model := public.payload_text(v_veh_in, 'model', 60, 'vehicle model');
    if coalesce(v_year::text, v_make, v_model) is not null then
      v_vinfo := jsonb_strip_nulls(jsonb_build_object('year', v_year, 'make', v_make, 'model', v_model));
    end if;
  end if;
  if v_form.ask_message then
    v_message := public.payload_text(p_payload, 'message', 5000, 'message');
  end if;

  -- answers: only the form's (live) questions, each valid; required ones answered
  if p_payload -> 'answers' is not null and jsonb_typeof(p_payload -> 'answers') <> 'null' then
    if jsonb_typeof(p_payload -> 'answers') <> 'object' then
      raise exception 'answers must be an object' using errcode = '22023';
    end if;
    select k into v_key from jsonb_object_keys(p_payload -> 'answers') k
     where k not in (select f.key from public.comms_lead_form_fields(v_form) f)
     order by k limit 1;
    if v_key is not null then
      raise exception 'unknown question "%"', left(v_key, 40) using errcode = '22023';
    end if;
  end if;
  for v_field in select * from public.comms_lead_form_fields(v_form) loop
    v_val := p_payload -> 'answers' -> v_field.key;
    if v_val is null or jsonb_typeof(v_val) = 'null'
       or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '')
       or (jsonb_typeof(v_val) = 'array' and jsonb_array_length(v_val) = 0) then
      if v_field.required then
        raise exception '% is required', v_field.label using errcode = '22023';
      end if;
      continue;
    end if;
    if jsonb_typeof(v_val) = 'string' and v_field.type in ('text', 'textarea', 'select', 'date') then
      v_val := to_jsonb(btrim(v_val #>> '{}', E' \t\r\n'));
    end if;
    v_err := public.comms_custom_value_error(v_field.type, v_field.options, v_val);
    if v_err is not null then
      raise exception '% %', v_field.label, v_err using errcode = '22023';
    end if;
    v_answers := v_answers || jsonb_build_object(v_field.key, v_val);
  end loop;

  -- abuse limits (per form, serialised)
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.lead_form:' || v_form.id::text, 0));
  -- one client (IP; 0105: an IPv6 client's whole /64) cannot use up the
  -- form's daily allowance on its own
  if v_scope is not null then
    select count(*) into v_recent from public.lead_submissions ls
     where ls.shop_id = v_form.shop_id and ls.lead_form_id = v_form.id and ls.created_at > v_now - interval '24 hours'
       and public.client_ip_scope(ls.signer_ip) = v_scope;
    if v_recent >= 10 then
      raise exception 'too many requests from this connection; please try again later or call the shop'
        using errcode = 'PT429';
    end if;
  end if;
  select count(*) into v_recent from public.lead_submissions ls
   where ls.shop_id = v_form.shop_id and ls.lead_form_id = v_form.id and ls.created_at > v_now - interval '24 hours';
  if v_recent >= 200 then
    raise exception 'this form is receiving too many requests; please try again later or call the shop'
      using errcode = 'PT429';
  end if;
  select count(*) into v_recent
    from public.lead_submissions ls
    join public.customers c on c.id = ls.customer_id and c.shop_id = ls.shop_id
   where ls.shop_id = v_form.shop_id and ls.lead_form_id = v_form.id and ls.created_at > v_now - interval '24 hours'
     and ((v_email is not null and lower(c.email::text) = v_email) or (v_phone is not null and c.phone = v_phone));
  if v_recent >= 3 then
    raise exception 'we already received your request; please call the shop if you need anything else'
      using errcode = 'PT429';
  end if;

  -- customer: match (never modified) or create a lead
  if v_email is not null then
    -- as online booking (0042 / 0054): never a record whose phone came from
    -- someone else's unverified public form, unless this lead gives that
    -- same phone. A form proves neither the email nor the phone, and the
    -- auto-reply (and staff's follow-up) would reach that stranger's phone.
    select * into v_cust from public.customers c
     where c.shop_id = v_form.shop_id and c.archived_at is null and c.email is not null
       and lower(c.email::text) = v_email
       and (not c.phone_unverified or c.phone is null or c.phone = v_phone)
     order by coalesce(c.phone = v_phone, false) desc, c.created_at desc, c.id limit 1;
  end if;
  if v_cust.id is null and v_phone is not null then
    select * into v_cust from public.customers c
     where c.shop_id = v_form.shop_id and c.archived_at is null and c.email is null and c.phone = v_phone
     order by c.created_at desc, c.id limit 1;
  end if;
  if v_cust.id is not null then
    v_matched := true;
  else
    insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, lifecycle,
                                  source, custom_data, phone_unverified)
    values (v_form.shop_id, v_first, v_last, v_email::extensions.citext, v_phone, v_sms, v_mail, 'lead',
            v_form.default_source, v_answers, v_phone is not null)
    returning * into v_cust;
    if coalesce(v_make, v_model) is not null then
      insert into public.vehicles (shop_id, customer_id, year, make, model)
      values (v_form.shop_id, v_cust.id, v_year, v_make, v_model)
      returning id into v_vehicle;
    end if;
  end if;

  insert into public.lead_submissions (shop_id, lead_form_id, customer_id, vehicle_id, vehicle_info, answers, message,
                                       matched_existing, signer_ip, created_at)
  values (v_form.shop_id, v_form.id, v_cust.id, v_vehicle, v_vinfo, v_answers, v_message, v_matched,
          v_ip, v_now);

  begin
    if v_form.notify_staff then
      v_who := coalesce(nullif(btrim(concat_ws(' ', v_first, v_last)), ''), 'a new contact');
      perform public.notify_shop_staff(
        v_form.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'new_lead',
        'New lead: ' || v_who,
        concat_ws(' · ', v_form.name, left(v_message, 200)),
        null, null, p_customer_id => v_cust.id);
    end if;
    if v_form.auto_reply then
      -- emailed; texted only to a phone the shop verified (see the header)
      perform public.enqueue_customer_template(v_form.shop_id, v_cust.id, 'lead_received', 'email', null, v_reply);
      if v_cust.phone is not null and not v_cust.phone_unverified then
        perform public.enqueue_customer_template(v_form.shop_id, v_cust.id, 'lead_received', 'sms', null, v_reply);
      end if;
    end if;
  exception when others then
    raise warning 'lead side effects failed for form %: % (%)', v_form.id, sqlerrm, sqlstate;
  end;

  return jsonb_build_object('ok', true, 'message', coalesce(v_form.success_message, c_default_message));
end
$$;

comment on function public.public_submit_lead(uuid, jsonb, timestamptz) is
  'Public lead form submission by form token (0088: matching, required questions, honeypot, auto-reply without visitor text). PT429 past 3 submissions per email / phone per form, 10 per connection (0105: an IPv6 /64) per form, 200 per form, in any rolling 24 hours.';

-- ---------------------------------------------------------------------------
-- public_redeem_gift_card (0066; same signature, grants) — the per-client
-- wrong-code limit ('ip:' key) counts the client's scope (an IPv6 /64).
-- ---------------------------------------------------------------------------
create or replace function public.public_redeem_gift_card(p_token uuid, p_code text, p_amount_cents bigint default null)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_inv     public.invoices;
  v_card    public.gift_cards;
  v_ip      inet := public.client_ip_scope(public.form_signer_ip());   -- 0105: an IPv6 client's /64
  v_pay     public.payments;
  v_reason  text;
begin
  select * into v_inv from public.invoices i where i.public_token = p_token for update;
  if not found or v_inv.status = 'draft' then
    raise exception 'invoice not found' using errcode = 'PT404';
  end if;
  if public.gift_card_recent_misses(v_inv.shop_id, 'invoice:' || v_inv.id::text) >= 5
     or (v_ip is not null and public.gift_card_recent_misses(v_inv.shop_id, 'ip:' || pg_catalog.abbrev(v_ip)) >= 20) then
    raise exception 'too many gift card attempts; try again later' using errcode = 'PT429';
  end if;
  if v_inv.status not in ('open', 'partially_paid') or v_inv.balance_cents <= 0 then
    raise exception 'this invoice has nothing left to pay' using errcode = '22023';
  end if;

  select * into v_card from public.gift_cards g
   where g.shop_id = v_inv.shop_id
     and g.code_hash = public.gift_card_code_hash(v_inv.shop_id, p_code)
     for update;
  if v_card.id is null then
    perform public.gift_card_log_attempt(v_inv.shop_id, 'invoice:' || v_inv.id::text, false);
    if v_ip is not null then
      perform public.gift_card_log_attempt(v_inv.shop_id, 'ip:' || pg_catalog.abbrev(v_ip), false);
    end if;
    return public.money_public_invoice_json(v_inv.id)
           || jsonb_build_object('gift_card_result', jsonb_build_object(
                'redeemed', false, 'message', 'this gift card code is not valid',
                'amount_cents', 0, 'remaining_cents', null, 'last4', null));
  end if;
  perform public.gift_card_log_attempt(v_inv.shop_id, 'invoice:' || v_inv.id::text, true);

  v_reason := case
    when v_card.kind = 'credit' and v_card.owner_customer_id is distinct from v_inv.customer_id
      then 'this store credit belongs to another customer'
    when v_card.status = 'void' then 'this gift card has been voided'
    when v_card.expires_at is not null and v_card.expires_at <= now() then 'this gift card has expired'
    when v_card.balance_cents <= 0 then 'this gift card has no balance left'
  end;
  if v_reason is not null then
    return public.money_public_invoice_json(v_inv.id)
           || jsonb_build_object('gift_card_result', jsonb_build_object(
                'redeemed', false, 'message', v_reason, 'amount_cents', 0,
                'remaining_cents', v_card.balance_cents, 'last4', v_card.code_last4));
  end if;

  v_pay := public.gift_card_redeem_core(v_inv, v_card, p_amount_cents, 'Gift card …' || v_card.code_last4 || ' (online)');
  return public.money_public_invoice_json(v_inv.id)
         || jsonb_build_object('gift_card_result', jsonb_build_object(
              'redeemed', true, 'message', null, 'amount_cents', v_pay.amount_cents,
              'remaining_cents', v_card.balance_cents - v_pay.amount_cents, 'last4', v_card.code_last4));
end
$$;

comment on function public.public_redeem_gift_card(uuid, text, bigint) is
  'Pays the invoice of a /i link (invoices.public_token) from a gift card or the customer''s store credit (0066). A wrong or unusable code is an answer (gift_card_result.redeemed = false); PT429 after 5 wrong codes per invoice or 20 per connection (0105: an IPv6 /64) per shop in an hour.';
