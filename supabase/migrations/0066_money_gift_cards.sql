-- ============================================================================
-- 0066 — Gift cards and store credit (P-13b). Tender, not discount:
--   * a SALE (online order or staff issue) creates a gift_cards row and an
--     'issue' transaction — a liability, never a payments row, so revenue
--     reports are unchanged;
--   * a REDEMPTION is a payments row (method gift_card, succeeded, no tip,
--     no Stripe data) on an invoice plus a 'redeem' transaction, written
--     atomically under the card's row lock — revenue when redeemed;
--   * refunding such a payment (refund_manual_payment) credits the card
--     back ('refund' transaction) instead of handing out cash.
-- Store credit = gift_cards kind 'credit' owned by a customer (referral
-- rewards, 0069): staff apply it to that customer's invoices without a code
-- (redeem_customer_credit). Gift cards (kind 'gift') always need the code.
--
-- Codes: 16 characters of Crockford base32 from gen_random_bytes, shown as
-- XXXX-XXXX-XXXX-XXXX (80 random bits). Only sha256(shop_id || ':' ||
-- normalised code) is stored; normalising upper-cases, drops spaces and
-- dashes and reads O as 0 and I / L as 1 (Crockford). The plain code is
-- returned once (issue_gift_card) or delivered in the gift_card_delivery /
-- referral_reward message — messages are readable by managers, who may
-- issue cards anyway (accepted trade-off). The comms range writes the
-- wording of those templates (0083); until then enqueueing is a no-op.
--
-- Brute force: code lookups are logged in gift_card_attempts (misses are
-- recorded without raising, so the log survives). Staff: PT429 after 10
-- misses per user per hour (lookup_gift_card / redeem_gift_card together);
-- the public /i page: PT429 after 5 misses per invoice or 20 per client IP
-- per hour. A wrong code returns null (staff) or gift_card_result.redeemed
-- = false (public) instead of an error.
--
-- Expiry: expires_at (gift cards bought or issued while the shop sets
-- gift_card_settings.expires_months, >= 60 months) is enforced when
-- redeeming; the status column is not swept.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Code helpers (internal)
-- ---------------------------------------------------------------------------
create function public.gift_card_normalize_code(p_code text) returns text
language sql immutable
set search_path = ''
as $$
  select nullif(translate(upper(regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g')), 'OIL', '011'), '')
$$;

create function public.gift_card_code_hash(p_shop_id uuid, p_code text) returns text
language sql immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_shop_id::text || ':' || coalesce(public.gift_card_normalize_code(p_code), ''), 'UTF8')), 'hex')
$$;

create function public.gen_gift_card_code() returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  c_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_bytes bytea := extensions.gen_random_bytes(16);
  v_out   text := '';
begin
  for i in 0..15 loop
    v_out := v_out || substr(c_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
    if i in (3, 7, 11) then
      v_out := v_out || '-';
    end if;
  end loop;
  return v_out;
end
$$;

-- Records one code attempt (and prunes this key's rows older than a day).
create function public.gift_card_log_attempt(p_shop_id uuid, p_key text, p_succeeded boolean) returns void
language sql volatile
set search_path = ''
as $$
  delete from public.gift_card_attempts a
   where a.shop_id = p_shop_id and a.attempt_key = p_key and a.created_at < now() - interval '1 day';
  insert into public.gift_card_attempts (shop_id, attempt_key, succeeded) values (p_shop_id, p_key, p_succeeded);
$$;

-- Misses in the last hour for a key.
create function public.gift_card_recent_misses(p_shop_id uuid, p_key text) returns bigint
language sql stable
set search_path = ''
as $$
  select count(*) from public.gift_card_attempts a
   where a.shop_id = p_shop_id and a.attempt_key = p_key and not a.succeeded
     and a.created_at > now() - interval '1 hour'
$$;

-- A customer of the shop by email (most recent non-archived one), else a
-- new lead with that email: never overwrites a matched customer, never
-- turns any consent on.
create function public.gift_card_match_customer(
  p_shop_id  uuid,
  p_email    text,
  p_name     text,
  p_source   public.customer_source
) returns uuid
language plpgsql volatile
set search_path = ''
as $$
declare
  v_id    uuid;
  v_email text := lower(nullif(btrim(p_email), ''));
  v_name  text := nullif(btrim(p_name), '');
begin
  if v_email is null then
    return null;
  end if;
  select c.id into v_id from public.customers c
   where c.shop_id = p_shop_id and c.archived_at is null and c.email is not null and lower(c.email::text) = v_email
   order by c.created_at desc, c.id limit 1;
  if v_id is not null then
    return v_id;
  end if;
  insert into public.customers (shop_id, first_name, last_name, email, lifecycle, source)
  values (p_shop_id,
          left(coalesce(split_part(v_name, ' ', 1), split_part(v_email, '@', 1)), 100),
          left(nullif(btrim(substr(v_name, char_length(split_part(v_name, ' ', 1)) + 1)), ''), 100),
          v_email::extensions.citext, 'lead', p_source)
  returning id into v_id;
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- gift_card_issue_core — INTERNAL: creates the card with a fresh code and
-- its 'issue' transaction. Returns {gift_card_id, code, last4}.
-- ---------------------------------------------------------------------------
create function public.gift_card_issue_core(
  p_shop_id          uuid,
  p_kind             text,
  p_amount_cents     bigint,
  p_sold_price_cents bigint,
  p_issued_via       text,
  p_purchaser_id     uuid,
  p_owner_id         uuid,
  p_recipient_name   text,
  p_recipient_email  text,
  p_message          text,
  p_payment_intent   text,
  p_expires_at       timestamptz,
  p_note             text
) returns jsonb
language plpgsql volatile
set search_path = ''
as $$
declare
  v_code  text;
  v_id    uuid;
  v_try   integer := 0;
begin
  loop
    v_try := v_try + 1;
    v_code := public.gen_gift_card_code();
    begin
      insert into public.gift_cards (shop_id, kind, code_hash, code_last4, initial_cents, balance_cents,
                                     sold_price_cents, purchaser_customer_id, owner_customer_id, recipient_name,
                                     recipient_email, message, issued_via, stripe_payment_intent_id, expires_at,
                                     issued_by)
      values (p_shop_id, p_kind, public.gift_card_code_hash(p_shop_id, v_code),
              right(public.gift_card_normalize_code(v_code), 4), p_amount_cents, p_amount_cents,
              p_sold_price_cents, p_purchaser_id, p_owner_id, nullif(btrim(p_recipient_name), ''),
              lower(nullif(btrim(p_recipient_email), ''))::extensions.citext, nullif(btrim(p_message), ''),
              p_issued_via, p_payment_intent, p_expires_at, auth.uid())
      returning id into v_id;
      exit;
    exception when unique_violation then
      -- a code collision (80 random bits: practically never) or a replayed
      -- payment intent, which the caller checks first
      if v_try >= 5 or p_payment_intent is not null
         and exists (select 1 from public.gift_cards g where g.stripe_payment_intent_id = p_payment_intent) then
        raise;
      end if;
    end;
  end loop;
  insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents, note,
                                             created_by)
  values (p_shop_id, v_id, 'issue', p_amount_cents, p_amount_cents, left(p_note, 500), auth.uid());
  return jsonb_build_object('gift_card_id', v_id, 'code', v_code,
                            'last4', right(public.gift_card_normalize_code(v_code), 4));
end
$$;

-- Delivery message variables (gift_card_delivery).
create function public.gift_card_delivery_vars(
  p_shop_id uuid, p_code text, p_amount bigint, p_sender text, p_recipient text, p_message text
) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'gift_card_code', p_code,
    'gift_card_amount', public.format_money(p_amount, s.currency),
    'sender_name', coalesce(nullif(btrim(p_sender), ''), s.name),
    'recipient_name', nullif(btrim(p_recipient), ''),
    'gift_message', nullif(btrim(p_message), ''))
  from public.shops s where s.id = p_shop_id
$$;

-- ---------------------------------------------------------------------------
-- issue_gift_card — owner/admin/manager. p_recipient: {name?, email?,
-- message?, sender_name?}. kind 'gift' (default) or 'credit' (store credit,
-- p_owner_customer_id required). p_send queues gift_card_delivery (email)
-- to the recipient customer — matched by email or created as a lead (never
-- overwritten, no consent change) — who also becomes the card's owner when
-- none is given. The plain code is in the result ONCE; it is never stored.
-- Returns {gift_card_id, code, last4, balance_cents, delivery_queued}.
-- ---------------------------------------------------------------------------
create function public.issue_gift_card(
  p_shop_id            uuid,
  p_amount_cents       bigint,
  p_recipient          jsonb default '{}'::jsonb,
  p_sold_price_cents   bigint default null,
  p_kind               text default 'gift',
  p_owner_customer_id  uuid default null,
  p_send               boolean default false
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_rec       jsonb := coalesce(p_recipient, '{}'::jsonb);
  v_kind      text := lower(btrim(coalesce(p_kind, 'gift')));
  v_name      text;
  v_email     text;
  v_message   text;
  v_sender    text;
  v_owner     uuid := p_owner_customer_id;
  v_recipient uuid;
  v_expires   timestamptz;
  v_months    smallint;
  v_card      jsonb;
  v_msg       uuid;
begin
  if not public.is_shop_member(p_shop_id) then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can issue gift cards' using errcode = '42501';
  end if;
  if v_kind not in ('gift', 'credit') then
    raise exception 'kind must be gift or credit' using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > 1000000 then
    raise exception 'amount must be between 1 and 1000000 cents' using errcode = '22023';
  end if;
  if p_sold_price_cents is not null and (p_sold_price_cents < 0 or p_sold_price_cents > p_amount_cents) then
    raise exception 'the sold price must be between 0 and the card value' using errcode = '22023';
  end if;
  if jsonb_typeof(v_rec) <> 'object'
     or exists (select 1 from jsonb_object_keys(v_rec) k where k not in ('name', 'email', 'message', 'sender_name')) then
    raise exception 'recipient must be an object with name, email, message, sender_name' using errcode = '22023';
  end if;
  v_name := public.payload_text(v_rec, 'name', 120, 'recipient name');
  v_email := lower(public.payload_text(v_rec, 'email', 254, 'recipient email'));
  v_message := public.payload_text(v_rec, 'message', 500, 'message');
  v_sender := public.payload_text(v_rec, 'sender_name', 120, 'sender name');
  if v_email is not null and not public.is_valid_email(v_email) then
    raise exception 'enter a valid recipient email address' using errcode = '22023';
  end if;
  if v_owner is not null and not exists (select 1 from public.customers c
                                         where c.id = v_owner and c.shop_id = p_shop_id and c.archived_at is null) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if v_kind = 'credit' and v_owner is null then
    raise exception 'store credit needs the customer it belongs to' using errcode = '22023';
  end if;
  if coalesce(p_send, false) and v_email is null then
    raise exception 'a recipient email is needed to send the card' using errcode = '22023';
  end if;

  if coalesce(p_send, false) then
    v_recipient := public.gift_card_match_customer(p_shop_id, v_email, v_name, 'staff');
    v_owner := coalesce(v_owner, v_recipient);
  end if;
  if v_kind = 'gift' then
    select g.expires_months into v_months from public.gift_card_settings g where g.shop_id = p_shop_id;
    if v_months is not null then
      v_expires := now() + make_interval(months => v_months);
    end if;
  end if;

  v_card := public.gift_card_issue_core(p_shop_id, v_kind, p_amount_cents, p_sold_price_cents, 'staff', null, v_owner,
                                        v_name, v_email, v_message, null, v_expires, 'Issued by staff');
  if coalesce(p_send, false) then
    v_msg := public.enqueue_customer_template(
               p_shop_id, v_recipient, 'gift_card_delivery', 'email', null,
               public.gift_card_delivery_vars(p_shop_id, v_card ->> 'code', p_amount_cents, v_sender, v_name, v_message),
               null, auth.uid(), null);
  end if;
  return v_card || jsonb_build_object('balance_cents', p_amount_cents, 'delivery_queued', v_msg is not null);
end
$$;

-- ---------------------------------------------------------------------------
-- lookup_gift_card(shop, code) — owner/admin/manager, or a technician when
-- the shop lets technicians collect payments. null when no card has that
-- code (logged; PT429 after 10 misses per user per hour). Returns
-- {gift_card_id, kind, last4, balance_cents, status, expires_at}; status is
-- 'expired' once expires_at has passed.
-- ---------------------------------------------------------------------------
create function public.lookup_gift_card(p_shop_id uuid, p_code text) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_role  public.shop_role := public.shop_role_of(p_shop_id);
  v_key   text := 'user:' || coalesce(auth.uid()::text, 'service');
  v_card  public.gift_cards;
begin
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if v_role = 'technician'
     and not exists (select 1 from public.shops s where s.id = p_shop_id and s.techs_can_collect_payments) then
    raise exception 'you cannot look up gift cards' using errcode = '42501';
  end if;
  if public.gift_card_recent_misses(p_shop_id, v_key) >= 10 then
    raise exception 'too many gift card attempts; try again later' using errcode = 'PT429';
  end if;
  select * into v_card from public.gift_cards g
   where g.shop_id = p_shop_id and g.code_hash = public.gift_card_code_hash(p_shop_id, p_code);
  perform public.gift_card_log_attempt(p_shop_id, v_key, found);
  if v_card.id is null then
    return null;
  end if;
  return jsonb_build_object(
    'gift_card_id', v_card.id,
    'kind', v_card.kind,
    'last4', v_card.code_last4,
    'balance_cents', v_card.balance_cents,
    'status', case when v_card.status in ('active', 'depleted') and v_card.expires_at <= now() then 'expired'
                   else v_card.status::text end,
    'expires_at', v_card.expires_at);
end
$$;

-- ---------------------------------------------------------------------------
-- gift_card_redeem_core — INTERNAL. p_inv and p_card are locked by the
-- caller (invoice first, then card). Refuses void / expired / empty cards;
-- the amount is p_amount (must fit the card and the invoice balance less
-- payments in flight) or, when null, as much as both allow.
-- ---------------------------------------------------------------------------
create function public.gift_card_redeem_core(
  p_inv     public.invoices,
  p_card    public.gift_cards,
  p_amount  bigint,
  p_note    text
) returns public.payments
language plpgsql volatile
set search_path = ''
as $$
declare
  v_in_flight  bigint;
  v_max        bigint;
  v_amount     bigint;
  v_pay        public.payments;
  v_currency   text;
begin
  select s.currency into v_currency from public.shops s where s.id = p_inv.shop_id;
  if p_inv.status not in ('open', 'partially_paid') then
    raise exception 'this invoice is % and cannot take payments', p_inv.status using errcode = '22023';
  end if;
  if p_card.kind = 'credit' and p_card.owner_customer_id is distinct from p_inv.customer_id then
    raise exception 'this store credit belongs to another customer' using errcode = '22023';
  end if;
  if p_card.status = 'void' then
    raise exception 'this gift card has been voided' using errcode = '22023';
  end if;
  if p_card.expires_at is not null and p_card.expires_at <= now() then
    raise exception 'this gift card has expired' using errcode = '22023';
  end if;
  if p_card.balance_cents <= 0 then
    raise exception 'this gift card has no balance left' using errcode = '22023';
  end if;
  select coalesce(sum(p.amount_cents), 0) into v_in_flight
    from public.payments p
   where p.invoice_id = p_inv.id and p.shop_id = p_inv.shop_id
     and public.payment_in_flight(p.status, p.created_at);
  v_max := p_inv.balance_cents - v_in_flight;
  if v_max <= 0 then
    raise exception 'nothing is left to pay on this invoice' using errcode = '22023';
  end if;
  if p_amount is not null then
    if p_amount <= 0 then
      raise exception 'amount must be greater than zero' using errcode = '22023';
    end if;
    if p_amount > p_card.balance_cents then
      raise exception 'the gift card balance is only %', public.format_money(p_card.balance_cents, v_currency)
        using errcode = '22023';
    end if;
    if p_amount > v_max then
      raise exception 'amount exceeds the balance due (%)', public.format_money(v_max, v_currency) using errcode = '22023';
    end if;
    v_amount := p_amount;
  else
    v_amount := least(p_card.balance_cents, v_max);
  end if;

  insert into public.payments (shop_id, invoice_id, customer_id, kind, method, status, amount_cents, tip_cents,
                               note, recorded_by, paid_at)
  values (p_inv.shop_id, p_inv.id, p_inv.customer_id, 'payment', 'gift_card', 'succeeded', v_amount, 0,
          p_note, auth.uid(), now())
  returning * into v_pay;
  update public.gift_cards g
     set balance_cents = g.balance_cents - v_amount,
         status = case when g.balance_cents - v_amount = 0 then 'depleted'::public.gift_card_status else g.status end
   where g.id = p_card.id;
  insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents,
                                             payment_id, note, created_by)
  values (p_inv.shop_id, p_card.id, 'redeem', -v_amount, p_card.balance_cents - v_amount, v_pay.id,
          'Invoice #' || p_inv.number::text, auth.uid());
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- redeem_gift_card(invoice, code, amount) — collector
-- (can_collect_for_invoice). Pays the invoice from the card (see the core).
-- Returns the payment, or null when no card has that code (logged; PT429
-- after 10 misses per user per hour, shared with lookup_gift_card).
-- ---------------------------------------------------------------------------
create function public.redeem_gift_card(p_invoice_id uuid, p_code text, p_amount_cents bigint default null)
returns public.payments
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_inv   public.invoices;
  v_card  public.gift_cards;
  v_key   text := 'user:' || coalesce(auth.uid()::text, 'service');
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id for update;
  if not found or not public.is_shop_member(v_inv.shop_id) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_invoice(v_inv.shop_id, v_inv.id) then
    raise exception 'you cannot collect payments for this invoice' using errcode = '42501';
  end if;
  if public.gift_card_recent_misses(v_inv.shop_id, v_key) >= 10 then
    raise exception 'too many gift card attempts; try again later' using errcode = 'PT429';
  end if;
  select * into v_card from public.gift_cards g
   where g.shop_id = v_inv.shop_id and g.code_hash = public.gift_card_code_hash(v_inv.shop_id, p_code)
     for update;
  perform public.gift_card_log_attempt(v_inv.shop_id, v_key, found);
  if v_card.id is null then
    return null;
  end if;
  return public.gift_card_redeem_core(v_inv, v_card, p_amount_cents, 'Gift card …' || v_card.code_last4);
end
$$;

-- ---------------------------------------------------------------------------
-- redeem_customer_credit(invoice, gift card, amount) — collector: applies
-- store credit (kind 'credit') owned by the invoice's customer, no code.
-- ---------------------------------------------------------------------------
create function public.redeem_customer_credit(p_invoice_id uuid, p_gift_card_id uuid, p_amount_cents bigint default null)
returns public.payments
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_inv   public.invoices;
  v_card  public.gift_cards;
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id for update;
  if not found or not public.is_shop_member(v_inv.shop_id) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_invoice(v_inv.shop_id, v_inv.id) then
    raise exception 'you cannot collect payments for this invoice' using errcode = '42501';
  end if;
  select * into v_card from public.gift_cards g
   where g.id = p_gift_card_id and g.shop_id = v_inv.shop_id for update;
  if not found then
    raise exception 'store credit not found' using errcode = 'P0002';
  end if;
  if v_card.kind <> 'credit' then
    raise exception 'gift cards are redeemed with their code' using errcode = '22023';
  end if;
  if v_card.owner_customer_id is distinct from v_inv.customer_id then
    raise exception 'this store credit belongs to another customer' using errcode = '22023';
  end if;
  return public.gift_card_redeem_core(v_inv, v_card, p_amount_cents, 'Store credit …' || v_card.code_last4);
end
$$;

-- ---------------------------------------------------------------------------
-- adjust_gift_card / void_gift_card — owner/admin. Adjusting moves the
-- balance by p_delta_cents (never below 0; not on void cards); voiding takes
-- the remaining balance off the card for good. The returned rows carry
-- code_hash = null.
-- ---------------------------------------------------------------------------
create function public.adjust_gift_card(p_gift_card_id uuid, p_delta_cents bigint, p_note text default null)
returns public.gift_cards
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_card  public.gift_cards;
  v_new   bigint;
begin
  select * into v_card from public.gift_cards g where g.id = p_gift_card_id for update;
  if not found or not public.is_shop_member(v_card.shop_id) then
    raise exception 'gift card not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_card.shop_id) then
    raise exception 'only owners and admins can adjust gift cards' using errcode = '42501';
  end if;
  if v_card.status = 'void' then
    raise exception 'a void gift card cannot be adjusted' using errcode = '22023';
  end if;
  if p_delta_cents is null or p_delta_cents = 0 then
    raise exception 'the adjustment must not be zero' using errcode = '22023';
  end if;
  if char_length(p_note) > 500 then
    raise exception 'note is too long (max 500 characters)' using errcode = '22023';
  end if;
  v_new := v_card.balance_cents + p_delta_cents;
  if v_new < 0 then
    raise exception 'the balance cannot go below zero (it is % cents)', v_card.balance_cents using errcode = '22023';
  end if;
  if v_new > 1000000 then
    raise exception 'the balance cannot exceed 1000000 cents' using errcode = '22023';
  end if;
  update public.gift_cards g
     set balance_cents = v_new,
         status = case when v_new = 0 then 'depleted' else 'active' end::public.gift_card_status
   where g.id = v_card.id
  returning * into v_card;
  insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents, note,
                                             created_by)
  values (v_card.shop_id, v_card.id, 'adjust', p_delta_cents, v_new, nullif(btrim(p_note), ''), auth.uid());
  v_card.code_hash := null;
  return v_card;
end
$$;

create function public.void_gift_card(p_gift_card_id uuid, p_reason text default null)
returns public.gift_cards
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_card public.gift_cards;
begin
  select * into v_card from public.gift_cards g where g.id = p_gift_card_id for update;
  if not found or not public.is_shop_member(v_card.shop_id) then
    raise exception 'gift card not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_card.shop_id) then
    raise exception 'only owners and admins can void gift cards' using errcode = '42501';
  end if;
  if v_card.status = 'void' then
    raise exception 'this gift card is already void' using errcode = '22023';
  end if;
  if char_length(p_reason) > 500 then
    raise exception 'reason is too long (max 500 characters)' using errcode = '22023';
  end if;
  insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents, note,
                                             created_by)
  values (v_card.shop_id, v_card.id, 'void', -v_card.balance_cents, 0, nullif(btrim(p_reason), ''), auth.uid());
  update public.gift_cards g
     set status = 'void', balance_cents = 0, voided_at = now(), void_reason = nullif(btrim(p_reason), '')
   where g.id = v_card.id
  returning * into v_card;
  v_card.code_hash := null;
  return v_card;
end
$$;

-- ---------------------------------------------------------------------------
-- refund_manual_payment — owner/admin (0013). Stripe-backed methods (card,
-- card_present, ach_debit, bnpl) are refunded through Stripe; a gift card
-- payment's refund goes back onto its card ('refund' transaction). The
-- re-credit is refused (22023, nothing changes) when the card
--   * is void,
--   * was bought online and that purchase was refunded, in full or in part
--     (gift_card_orders.refunded_cents > 0): gift_card_order_refunded took
--     the refund off the unspent balance and reported what was already
--     spent as unrecovered, so crediting the spent value back would hand
--     the buyer that money twice (cash back from Stripe AND spendable
--     credit), or
--   * has expired (expires_at passed): the value would land on a card that
--     can never be redeemed.
-- The card row is locked before its order is read, the same order as
-- gift_card_order_refunded, so a purchase refund and a payment refund of
-- the same card serialize. p_amount_cents comes off the amount first, then
-- tip.
-- ---------------------------------------------------------------------------
create or replace function public.refund_manual_payment(p_payment_id uuid, p_amount_cents bigint) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay   public.payments;
  v_new   bigint;
  v_card  public.gift_cards;
begin
  select * into v_pay from public.payments p where p.id = p_payment_id for update;
  if not found or not public.is_shop_member(v_pay.shop_id) then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_pay.shop_id) then
    raise exception 'only owners and admins can refund payments' using errcode = '42501';
  end if;
  if v_pay.method in ('card', 'card_present', 'ach_debit', 'bnpl') then
    raise exception 'card, bank debit and pay-later payments are refunded through Stripe' using errcode = '22023';
  end if;
  if v_pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', v_pay.status using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'refund amount must be greater than zero' using errcode = '22023';
  end if;
  v_new := v_pay.refunded_cents + p_amount_cents;
  if v_new > v_pay.amount_cents + v_pay.tip_cents then
    raise exception 'refund exceeds the refundable amount (% cents)',
      v_pay.amount_cents + v_pay.tip_cents - v_pay.refunded_cents using errcode = '22023';
  end if;
  if v_pay.method = 'gift_card' then
    select g.* into v_card
      from public.gift_card_transactions t
      join public.gift_cards g on g.id = t.gift_card_id and g.shop_id = t.shop_id
     where t.shop_id = v_pay.shop_id and t.payment_id = v_pay.id and t.kind = 'redeem'
     limit 1;
    if v_card.id is null then
      raise exception 'the gift card of this payment was not found' using errcode = '22023';
    end if;
    select * into v_card from public.gift_cards g where g.id = v_card.id for update;
    if v_card.status = 'void' then
      raise exception 'the gift card of this payment is void; adjust another card or record the refund differently'
        using errcode = '22023';
    end if;
    if exists (select 1 from public.gift_card_orders o
                where o.shop_id = v_card.shop_id and o.gift_card_id = v_card.id
                  and (o.refunded_cents > 0 or o.status = 'refunded')) then
      raise exception 'the online purchase of the gift card of this payment was refunded; its value cannot be put back on the card'
        using errcode = '22023';
    end if;
    if v_card.expires_at is not null and v_card.expires_at <= now() then
      raise exception 'the gift card of this payment has expired; adjust another card or record the refund differently'
        using errcode = '22023';
    end if;
    update public.gift_cards g
       set balance_cents = g.balance_cents + p_amount_cents, status = 'active'
     where g.id = v_card.id;
    insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents,
                                               payment_id, note, created_by)
    values (v_pay.shop_id, v_card.id, 'refund', p_amount_cents, v_card.balance_cents + p_amount_cents, v_pay.id,
            'Payment refunded to the card', auth.uid());
  end if;
  update public.payments p
     set refunded_cents = v_new,
         status = public.payment_refund_status(p.amount_cents, p.tip_cents, v_new)
   where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- money_public_invoice_json — curated /i document (0014) plus:
--   invoice.processing_cents   bank payments still clearing (ACH)
--   invoice.payable            open / partially paid with a balance that
--                              clearing payments do not already cover
--   invoice.gift_card_redeemable  payable and the shop has live gift cards
--   jobs [{number, date, vehicle_label}]  every job the invoice bills
--                              (grouped invoices), line job_number
--   payments                   received ones plus 'processing' rows
--                              (processing: true)
-- ---------------------------------------------------------------------------
create or replace function public.money_public_invoice_json(p_invoice_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  with pr as (
    select coalesce(sum(p.amount_cents), 0)::bigint as processing
    from public.payments p
    where p.invoice_id = p_invoice_id and p.status = 'processing'
  )
  select jsonb_build_object(
    'shop', public.money_public_shop_json(i.shop_id),
    'invoice', jsonb_build_object(
      'number', i.number,
      'status', i.status,
      'issued_at', i.issued_at,
      'due_at', i.due_at,
      'paid_at', i.paid_at,
      'voided_at', i.voided_at,
      'notes', i.notes,
      'terms', i.terms,
      'subtotal_cents', i.subtotal_cents,
      'discount_cents', i.discount_cents,
      'tax_rate_bps', i.tax_rate_bps,
      'tax_cents', i.tax_cents,
      'total_cents', i.total_cents,
      'amount_paid_cents', i.amount_paid_cents,
      'balance_cents', i.balance_cents,
      'tip_cents', i.tip_cents,
      'processing_cents', pr.processing,
      'payable', i.status in ('open', 'partially_paid') and i.balance_cents - pr.processing > 0,
      'gift_card_redeemable', i.status in ('open', 'partially_paid') and i.balance_cents - pr.processing > 0
                              and exists (select 1 from public.gift_cards g
                                           where g.shop_id = i.shop_id and g.status = 'active'
                                             and (g.kind = 'gift' or g.owner_customer_id = i.customer_id)
                                             and g.balance_cents > 0 and (g.expires_at is null or g.expires_at > now())),
      'card_payments_enabled', coalesce((select a.charges_enabled from public.shop_stripe_accounts a
                                         where a.shop_id = i.shop_id), false)),
    'customer', jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'company', c.company),
    'job', (select jsonb_build_object('number', j.number, 'scheduled_start', j.scheduled_start,
                                      'scheduled_end', j.scheduled_end)
              from public.jobs j where j.id = i.job_id and j.shop_id = i.shop_id),
    'vehicle', (select public.money_public_vehicle_json(j.shop_id, j.vehicle_id)
                  from public.jobs j where j.id = i.job_id and j.shop_id = i.shop_id),
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number', j.number,
               'date', (coalesce(j.scheduled_start, j.completed_at) at time zone s.timezone)::date,
               'vehicle_label', public.money_vehicle_label(j.shop_id, j.vehicle_id))
             order by j.scheduled_start nulls last, j.number)
      from public.invoice_jobs ij
      join public.jobs j on j.id = ij.job_id and j.shop_id = ij.shop_id
      join public.shops s on s.id = ij.shop_id
      where ij.invoice_id = i.id and ij.shop_id = i.shop_id), '[]'::jsonb),
    'line_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', li.name,
               'description', li.description,
               'vehicle_label', public.money_vehicle_label(li.shop_id, li.vehicle_id),
               'job_number', (select j.number from public.jobs j where j.id = li.job_id and j.shop_id = li.shop_id),
               'quantity', li.quantity,
               'unit_price_cents', li.unit_price_cents,
               'discount_cents', li.discount_cents,
               'taxable', li.taxable,
               'total_cents', li.total_cents)
             order by li.sort, li.created_at, li.id)
      from public.invoice_line_items li
      where li.invoice_id = i.id and li.shop_id = i.shop_id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', p.kind,
               'method', p.method,
               'status', p.status,
               'processing', p.status = 'processing',
               'amount_cents', p.amount_cents,
               'tip_cents', p.tip_cents,
               'refunded_cents', p.refunded_cents,
               'card_brand', p.card_brand,
               'card_last4', p.card_last4,
               'paid_at', p.paid_at)
             order by p.paid_at nulls last, p.created_at, p.id)
      from public.payments p
      where p.invoice_id = i.id and p.shop_id = i.shop_id
        and p.status in ('succeeded', 'partially_refunded', 'refunded', 'processing')), '[]'::jsonb))
  from public.invoices i
  join public.customers c on c.id = i.customer_id and c.shop_id = i.shop_id
  cross join pr
  where i.id = p_invoice_id
$$;

-- ---------------------------------------------------------------------------
-- public_redeem_gift_card(token, code, amount) — anon / signed-in, on the
-- /i page (invoices.public_token). Pays the invoice from a gift card (or
-- from store credit of the invoice's customer, by its code). Returns money_public_invoice_json plus
--   gift_card_result {redeemed, message, amount_cents, remaining_cents, last4}
-- A wrong code or an unusable card is an answer (redeemed = false), not an
-- error; PT429 after 5 wrong codes per invoice or 20 per client IP per hour.
-- ---------------------------------------------------------------------------
create function public.public_redeem_gift_card(p_token uuid, p_code text, p_amount_cents bigint default null)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_inv     public.invoices;
  v_card    public.gift_cards;
  v_ip      inet := public.form_signer_ip();
  v_pay     public.payments;
  v_reason  text;
begin
  select * into v_inv from public.invoices i where i.public_token = p_token for update;
  if not found or v_inv.status = 'draft' then
    raise exception 'invoice not found' using errcode = 'PT404';
  end if;
  if public.gift_card_recent_misses(v_inv.shop_id, 'invoice:' || v_inv.id::text) >= 5
     or (v_ip is not null and public.gift_card_recent_misses(v_inv.shop_id, 'ip:' || host(v_ip)) >= 20) then
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
      perform public.gift_card_log_attempt(v_inv.shop_id, 'ip:' || host(v_ip), false);
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

-- ---------------------------------------------------------------------------
-- public_gift_card_offer(slug) — anon: what the shop sells online.
-- ---------------------------------------------------------------------------
create function public.public_gift_card_offer(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_gs   public.gift_card_settings;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_gs from public.gift_card_settings g where g.shop_id = v_shop.id;
  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'logo_path', v_shop.logo_path, 'brand_color', v_shop.brand_color),
    'enabled', coalesce(v_gs.online_enabled, false)
               and (jsonb_array_length(coalesce(v_gs.offers, '[]'::jsonb)) > 0 or coalesce(v_gs.allow_custom_amount, false)),
    'offers', coalesce(v_gs.offers, '[]'::jsonb),
    'allow_custom_amount', coalesce(v_gs.allow_custom_amount, false),
    'min_custom_cents', v_gs.min_custom_cents,
    'max_custom_cents', v_gs.max_custom_cents,
    'expires_months', v_gs.expires_months,
    'terms', v_gs.terms,
    'currency', v_shop.currency);
end
$$;

-- ---------------------------------------------------------------------------
-- gift_card_order_prepare(slug, payload, now) — service_role (payments edge
-- gift_card_checkout). payload: {offer_index | amount_cents,
-- purchaser {name*, email*}, recipient {name, email*, message}}.
-- 55000 online sales off; 22023 invalid input (an amount outside the shop's
-- custom range says so); PT429 more than 5 orders per purchaser email per
-- shop in 24 hours; PT404 unknown shop. Returns {order_id, token, shop_id,
-- value_cents, price_cents, currency, purchaser_email}.
-- ---------------------------------------------------------------------------
create function public.gift_card_order_prepare(p_slug text, p_payload jsonb, p_now timestamptz default now())
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
        using errcode = '22023';
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
-- gift_card_order_paid(order, payment intent, amount received) —
-- service_role (stripe-webhook). Idempotent: a paid order (or an intent that
-- already issued a card) returns {first_time: false} and issues nothing.
-- The amount must be the order's price (22023). Issues the card (online,
-- expiry per settings), matches / creates the purchaser and the recipient
-- as customers (leads, no consent), queues gift_card_delivery to the
-- recipient (and a copy to the purchaser when their email differs) and
-- notifies managers (gift_card_purchased). Messaging failures never undo the
-- card. Returns {gift_card_id, last4, first_time}.
-- ---------------------------------------------------------------------------
create function public.gift_card_order_paid(p_order_id uuid, p_payment_intent_id text, p_amount_received_cents bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_order     public.gift_card_orders;
  v_card      public.gift_cards;
  v_months    smallint;
  v_expires   timestamptz;
  v_buyer     uuid;
  v_recipient uuid;
  v_new       jsonb;
  v_vars      jsonb;
  v_currency  text;
begin
  select * into v_order from public.gift_card_orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'gift card order not found' using errcode = 'P0002';
  end if;
  if v_order.gift_card_id is not null then
    select * into v_card from public.gift_cards g where g.id = v_order.gift_card_id;
    return jsonb_build_object('gift_card_id', v_card.id, 'last4', v_card.code_last4, 'first_time', false);
  end if;
  if p_payment_intent_id is null or p_payment_intent_id !~ '^pi_[A-Za-z0-9]+$' then
    raise exception 'invalid payment intent id' using errcode = '22023';
  end if;
  select * into v_card from public.gift_cards g where g.stripe_payment_intent_id = p_payment_intent_id;
  if found then
    if v_card.shop_id <> v_order.shop_id then
      raise exception 'payment intent belongs to another shop' using errcode = '22023';
    end if;
    return jsonb_build_object('gift_card_id', v_card.id, 'last4', v_card.code_last4, 'first_time', false);
  end if;
  if p_amount_received_cents is distinct from v_order.price_cents then
    raise exception 'the amount received (%) does not match the order price (%)', p_amount_received_cents,
      v_order.price_cents using errcode = '22023';
  end if;

  select g.expires_months into v_months from public.gift_card_settings g where g.shop_id = v_order.shop_id;
  if v_months is not null then
    v_expires := now() + make_interval(months => v_months);
  end if;
  v_buyer := public.gift_card_match_customer(v_order.shop_id, v_order.purchaser_email::text, v_order.purchaser_name,
                                             'other');
  v_recipient := public.gift_card_match_customer(v_order.shop_id, v_order.recipient_email::text,
                                                 coalesce(v_order.recipient_name, v_order.recipient_email::text), 'other');
  v_new := public.gift_card_issue_core(v_order.shop_id, 'gift', v_order.value_cents, v_order.price_cents, 'online',
                                       v_buyer, v_recipient, v_order.recipient_name, v_order.recipient_email::text,
                                       v_order.message, p_payment_intent_id, v_expires, 'Bought online');
  update public.gift_card_orders o
     set status = 'paid', gift_card_id = (v_new ->> 'gift_card_id')::uuid
   where o.id = v_order.id;

  begin
    v_vars := public.gift_card_delivery_vars(v_order.shop_id, v_new ->> 'code', v_order.value_cents,
                                             v_order.purchaser_name, v_order.recipient_name, v_order.message);
    perform public.enqueue_customer_template(v_order.shop_id, v_recipient, 'gift_card_delivery', 'email', null,
                                             v_vars, null, null, null);
    if v_buyer is distinct from v_recipient then
      perform public.enqueue_customer_template(v_order.shop_id, v_buyer, 'gift_card_delivery', 'email', null,
                                               v_vars, null, null, null);
    end if;
    select s.currency into v_currency from public.shops s where s.id = v_order.shop_id;
    perform public.notify_shop_staff(
      v_order.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'gift_card_purchased',
      'Gift card purchased: ' || public.format_money(v_order.value_cents, v_currency) || ' by ' || v_order.purchaser_name,
      'For ' || coalesce(v_order.recipient_name, v_order.recipient_email::text)
        || case when v_order.price_cents <> v_order.value_cents
                then ' · paid ' || public.format_money(v_order.price_cents, v_currency) else '' end,
      null, null, p_customer_id => v_buyer);
  exception when others then
    raise warning 'gift card delivery / notification failed for order %: % (%)', v_order.id, sqlerrm, sqlstate;
  end;
  return jsonb_build_object('gift_card_id', (v_new ->> 'gift_card_id')::uuid, 'last4', v_new ->> 'last4',
                            'first_time', true);
end
$$;

-- ---------------------------------------------------------------------------
-- gift_card_order_refunded(payment intent, refunded total) — service_role
-- (stripe-webhook charge.refunded on a gift card sale). p_refunded_total_cents
-- is the charge's cumulative refund (price terms); it only ever grows. The
-- matching card value (refund × value / price, cumulative rounding) comes
-- off the unspent balance — never below zero; what was already spent is
-- reported as unrecovered_cents. A fully refunded, never-used card is
-- voided. Returns {gift_card_id, refunded_total_cents, removed_cents,
-- unrecovered_cents, status}.
-- ---------------------------------------------------------------------------
create function public.gift_card_order_refunded(p_payment_intent_id text, p_refunded_total_cents bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_card     public.gift_cards;
  v_order    public.gift_card_orders;
  v_remove   bigint;
  v_take     bigint;
  v_used     boolean;
begin
  select * into v_card from public.gift_cards g where g.stripe_payment_intent_id = p_payment_intent_id for update;
  if not found then
    raise exception 'gift card for intent % not found', p_payment_intent_id using errcode = 'P0002';
  end if;
  select * into v_order from public.gift_card_orders o where o.gift_card_id = v_card.id and o.shop_id = v_card.shop_id
     for update;
  if not found then
    raise exception 'gift card order for intent % not found', p_payment_intent_id using errcode = 'P0002';
  end if;
  if p_refunded_total_cents is null or p_refunded_total_cents < 0 or p_refunded_total_cents > v_order.price_cents then
    raise exception 'refunded total must be between 0 and the order price (% cents)', v_order.price_cents
      using errcode = '22023';
  end if;
  if p_refunded_total_cents <= v_order.refunded_cents then
    return jsonb_build_object('gift_card_id', v_card.id, 'refunded_total_cents', v_order.refunded_cents,
                              'removed_cents', 0, 'unrecovered_cents', 0, 'status', v_card.status);
  end if;
  v_remove := round(p_refunded_total_cents::numeric * v_card.initial_cents / v_order.price_cents)::bigint
            - round(v_order.refunded_cents::numeric * v_card.initial_cents / v_order.price_cents)::bigint;
  v_take := least(v_remove, v_card.balance_cents);
  v_used := exists (select 1 from public.gift_card_transactions t
                     where t.gift_card_id = v_card.id and t.shop_id = v_card.shop_id and t.kind = 'redeem');
  if v_take > 0 then
    insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents, note)
    values (v_card.shop_id, v_card.id, 'refund', -v_take, v_card.balance_cents - v_take, 'Online purchase refunded');
    update public.gift_cards g
       set balance_cents = g.balance_cents - v_take,
           status = case when g.balance_cents - v_take = 0 then 'depleted'::public.gift_card_status else g.status end
     where g.id = v_card.id
    returning * into v_card;
  end if;
  if p_refunded_total_cents = v_order.price_cents and not v_used and v_card.status <> 'void' then
    insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents, note)
    values (v_card.shop_id, v_card.id, 'void', -v_card.balance_cents, 0, 'Purchase refunded in full');
    update public.gift_cards g
       set status = 'void', balance_cents = 0, voided_at = now(), void_reason = 'Purchase refunded in full'
     where g.id = v_card.id
    returning * into v_card;
  end if;
  update public.gift_card_orders o
     set refunded_cents = p_refunded_total_cents,
         status = case when p_refunded_total_cents = o.price_cents then 'refunded' else o.status end
   where o.id = v_order.id;
  return jsonb_build_object('gift_card_id', v_card.id, 'refunded_total_cents', p_refunded_total_cents,
                            'removed_cents', v_take, 'unrecovered_cents', v_remove - v_take,
                            'status', v_card.status);
end
$$;

-- ---------------------------------------------------------------------------
-- public_gift_card_order_status(token) — anon, the purchase success page
-- (gift_card_orders.token). Never the code.
-- ---------------------------------------------------------------------------
create function public.public_gift_card_order_status(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_order public.gift_card_orders;
begin
  select * into v_order from public.gift_card_orders o where o.token = p_token;
  if not found then
    raise exception 'gift card order not found' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'status', v_order.status,
    'value_cents', v_order.value_cents,
    'recipient_name', v_order.recipient_name,
    'last4', (select g.code_last4 from public.gift_cards g where g.id = v_order.gift_card_id and g.shop_id = v_order.shop_id));
end
$$;

-- ---------------------------------------------------------------------------
-- report_gift_cards(shop, from, to) — owner/admin/manager; local dates
-- [p_from, p_to] in the shop's time zone:
--   sold_count / sold_value_cents / sold_price_cents  gift cards (kind gift)
--                                  issued in the range (value / price paid)
--   redeemed_cents                 redemptions in the range minus refunds
--                                  credited back to cards in the range
--   outstanding_liability_cents    balances at the end of the range of
--                                  cards not expired by then (ledger-exact)
--   expired_cents                  balances left on cards that expired in
--                                  the range
--   credit_issued_cents            store credit issued in the range
-- ---------------------------------------------------------------------------
create function public.report_gift_cards(p_shop_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tz  text;
  v_s   timestamptz;
  v_e   timestamptz;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  v_s := public.report_local_start(p_from, v_tz);
  v_e := public.report_local_start(p_to + 1, v_tz);
  return jsonb_build_object(
    'sold_count', (select count(*) from public.gift_cards g
                    where g.shop_id = p_shop_id and g.kind = 'gift' and g.created_at >= v_s and g.created_at < v_e),
    'sold_value_cents', (select coalesce(sum(g.initial_cents), 0) from public.gift_cards g
                          where g.shop_id = p_shop_id and g.kind = 'gift' and g.created_at >= v_s and g.created_at < v_e),
    'sold_price_cents', (select coalesce(sum(g.sold_price_cents), 0) from public.gift_cards g
                          where g.shop_id = p_shop_id and g.kind = 'gift' and g.created_at >= v_s and g.created_at < v_e),
    'redeemed_cents', (select coalesce(sum(-t.amount_cents), 0)
                         from public.gift_card_transactions t
                        where t.shop_id = p_shop_id and t.created_at >= v_s and t.created_at < v_e
                          and (t.kind = 'redeem' or (t.kind = 'refund' and t.payment_id is not null))),
    'outstanding_liability_cents', (
      select coalesce(sum(t.amount_cents), 0)
        from public.gift_card_transactions t
        join public.gift_cards g on g.id = t.gift_card_id and g.shop_id = t.shop_id
       where t.shop_id = p_shop_id and t.created_at < v_e
         and (g.expires_at is null or g.expires_at > v_e)),
    'expired_cents', (
      select coalesce(sum(t.amount_cents), 0)
        from public.gift_cards g
        join public.gift_card_transactions t on t.gift_card_id = g.id and t.shop_id = g.shop_id
       where g.shop_id = p_shop_id and g.expires_at >= v_s and g.expires_at < v_e
         and t.created_at < g.expires_at),
    'credit_issued_cents', (select coalesce(sum(g.initial_cents), 0) from public.gift_cards g
                             where g.shop_id = p_shop_id and g.kind = 'credit' and g.created_at >= v_s and g.created_at < v_e));
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.gift_card_normalize_code(text),
  public.gift_card_code_hash(uuid, text),
  public.gen_gift_card_code(),
  public.gift_card_log_attempt(uuid, text, boolean),
  public.gift_card_recent_misses(uuid, text),
  public.gift_card_match_customer(uuid, text, text, public.customer_source),
  public.gift_card_issue_core(uuid, text, bigint, bigint, text, uuid, uuid, text, text, text, text, timestamptz, text),
  public.gift_card_delivery_vars(uuid, text, bigint, text, text, text),
  public.gift_card_redeem_core(public.invoices, public.gift_cards, bigint, text),
  public.gift_card_order_prepare(text, jsonb, timestamptz),
  public.gift_card_order_paid(uuid, text, bigint),
  public.gift_card_order_refunded(text, bigint)
from public, anon, authenticated;
grant execute on function
  public.gift_card_normalize_code(text),
  public.gift_card_code_hash(uuid, text),
  public.gen_gift_card_code(),
  public.gift_card_log_attempt(uuid, text, boolean),
  public.gift_card_recent_misses(uuid, text),
  public.gift_card_match_customer(uuid, text, text, public.customer_source),
  public.gift_card_issue_core(uuid, text, bigint, bigint, text, uuid, uuid, text, text, text, text, timestamptz, text),
  public.gift_card_delivery_vars(uuid, text, bigint, text, text, text),
  public.gift_card_redeem_core(public.invoices, public.gift_cards, bigint, text),
  public.gift_card_order_prepare(text, jsonb, timestamptz),
  public.gift_card_order_paid(uuid, text, bigint),
  public.gift_card_order_refunded(text, bigint)
to service_role;

revoke execute on function
  public.issue_gift_card(uuid, bigint, jsonb, bigint, text, uuid, boolean),
  public.lookup_gift_card(uuid, text),
  public.redeem_gift_card(uuid, text, bigint),
  public.redeem_customer_credit(uuid, uuid, bigint),
  public.adjust_gift_card(uuid, bigint, text),
  public.void_gift_card(uuid, text),
  public.report_gift_cards(uuid, date, date)
from public, anon;
grant execute on function
  public.issue_gift_card(uuid, bigint, jsonb, bigint, text, uuid, boolean),
  public.lookup_gift_card(uuid, text),
  public.redeem_gift_card(uuid, text, bigint),
  public.redeem_customer_credit(uuid, uuid, bigint),
  public.adjust_gift_card(uuid, bigint, text),
  public.void_gift_card(uuid, text),
  public.report_gift_cards(uuid, date, date)
to authenticated, service_role;

revoke execute on function
  public.public_redeem_gift_card(uuid, text, bigint),
  public.public_gift_card_offer(text),
  public.public_gift_card_order_status(uuid)
from public;
grant execute on function
  public.public_redeem_gift_card(uuid, text, bigint),
  public.public_gift_card_offer(text),
  public.public_gift_card_order_status(uuid)
to anon, authenticated, service_role;
