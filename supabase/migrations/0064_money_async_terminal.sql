-- ============================================================================
-- 0064 — Asynchronous Stripe payments (P-31: ACH debit, buy-now-pay-later)
-- and Stripe Terminal / Tap to Pay rows (P-6).
--
-- Payment methods written by Stripe (service_role only, 0061 CHECKs):
--   card, card_present (Terminal / Tap to Pay), ach_debit (us_bank_account),
--   bnpl (affirm, klarna, afterpay_clearpay, zip, ...). The webhook also
--   records Stripe's own payment_method type (stripe_method_type).
-- State machine of a Stripe payment row (upsert_stripe_payment):
--   pending -> processing -> succeeded | failed
--   pending -> succeeded | failed | cancelled
--   * processing (an ACH debit clearing, which takes days) is always money
--     in flight (payment_in_flight) and counts 0 toward balances until it
--     succeeds; a late 'pending' report never moves it back
--   * failed after processing (an ACH return before the money settled) is
--     final for that intent: nothing was received, so balances need no
--     correction
--   * received states (succeeded / refunded) are never downgraded; refunds
--     only through apply_stripe_refund / set_stripe_refund_total
-- Terminal (P-6): a card_present intent created by the payments edge
-- function is recorded 'pending' (method card_present) and settles exactly
-- like a PaymentSheet payment; while pending it is in flight (manual
-- payments, voids and line edits wait). shop_terminal_locations (0061)
-- holds the shop's Terminal location.
-- Public pages (outside this file, recorded here): a deposit whose payment
-- is 'processing' is money on its way, so booking_public_json (0042,
-- redefined below) reports deposit.payment_pending = true for it, and
-- money_public_quote_json (0067) has self_schedule.payment_pending — the
-- payments edge refuses a second deposit Checkout while it is true.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- payment_in_flight — 'processing' is always in flight; 'pending' for an
-- hour after it started (0012).
-- ---------------------------------------------------------------------------
create or replace function public.payment_in_flight(
  p_status      public.payment_status,
  p_created_at  timestamptz,
  p_now         timestamptz default now()
) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_status = 'processing'
      or (p_status = 'pending' and p_created_at > p_now - interval '1 hour')
$$;

-- ---------------------------------------------------------------------------
-- booking_public_json (integration 0042, owner sched) — deposit.payment_pending
-- also covers a payment still 'processing' (ACH / pay-later). Redefined here
-- (fix forward) instead of editing the committed 0042: a database that
-- already applied 0042 only receives the change through a later file. The
-- rest of the builder is 0042's, unchanged except for grouped invoices
-- (P-7, 0063; sched's fix, made in this redefinition because it is the one
-- that is live): the job's live invoice is found through invoice_jobs, so a
-- job on a grouped invoice (invoices.job_id null, whole-invoice payments
-- without job_id) shows the invoice's paid / balance, a payment in flight
-- on that invoice counts as pending, and a deposit is never due beyond what
-- the invoice still owes. Grants stay as 0042 set them (service_role only;
-- CREATE OR REPLACE keeps them).
-- ---------------------------------------------------------------------------
create or replace function public.booking_public_json(p_job_id uuid, p_now timestamptz) returns jsonb
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
  -- the job's live invoice, single-job or grouped (a job has at most one
  -- live invoice: invoice_jobs_one_live_invoice, 0061/0063)
  select i.* into v_inv
    from public.invoice_jobs ij
    join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
   where ij.shop_id = v_job.shop_id and ij.job_id = v_job.id and not ij.voided and i.status <> 'void'
   order by i.created_at desc
   limit 1;
  select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                    filter (where p.kind = 'deposit'), 0),
         -- money on its way: a card attempt still pending, or an ACH / pay-later
         -- payment clearing ('processing' — in flight for days,
         -- payment_in_flight). payment_net_amount counts neither, so without
         -- this flag the page would ask for (and the payments edge would
         -- charge) the deposit twice.
         coalesce(bool_or(p.status = 'pending' or public.payment_in_flight(p.status, p.created_at, p_now)), false)
    into v_paid, v_dep_paid, v_pending
    from public.payments p
   where p.shop_id = v_job.shop_id and p.job_id = v_job.id;
  -- same rule as job_payment_summary (0013): the deposit is capped by what
  -- is actually owed, i.e. the invoice total once there is one (a discount
  -- or edited lines at invoicing can bring it below the job's total)
  v_dep_due := greatest(least(v_job.deposit_required_cents, coalesce(v_inv.total_cents, v_job.total_cents)) - v_paid, 0);
  -- a grouped invoice's own payments have no job_id (they pay the whole
  -- invoice): what was paid and what is left come from the invoice, and
  -- one of its payments in flight counts as pending
  if v_inv.id is not null and v_inv.job_id is null then
    v_paid := v_inv.amount_paid_cents;
    v_pending := v_pending or exists (
      select 1 from public.payments p
       where p.shop_id = v_inv.shop_id and p.invoice_id = v_inv.id
         and (p.status = 'pending' or public.payment_in_flight(p.status, p.created_at, p_now)));
  end if;
  -- never ask for a deposit beyond what the invoice still owes
  if v_inv.id is not null then
    v_dep_due := least(v_dep_due, greatest(v_inv.balance_cents, 0));
  end if;

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
-- upsert_stripe_payment (service_role; webhook / payments edge function) —
-- 0013 plus p_stripe_method_type, the 'processing' state and the ACH / BNPL
-- methods. See 0013 for linkage, idempotency and out-of-order rules; new:
--   * p_status may be 'processing'; processing never returns to pending,
--     and failed after processing is final
--   * p_method: card | card_present | ach_debit | bnpl. The method (and
--     stripe_method_type) follow Stripe's latest report while the payment
--     has not been received — a Checkout Session's method is only known
--     once the customer chose it — and are fixed once it is
-- ---------------------------------------------------------------------------
drop function public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                                           public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text,
                                           timestamptz);

create function public.upsert_stripe_payment(
  p_shop_id              uuid,
  p_payment_intent_id    text,
  p_status               public.payment_status,
  p_amount_cents         bigint,
  p_tip_cents            bigint default 0,
  p_kind                 public.payment_kind default 'payment',
  p_method               public.payment_method default 'card',
  p_invoice_id           uuid default null,
  p_job_id               uuid default null,
  p_customer_id          uuid default null,
  p_membership_id        uuid default null,
  p_charge_id            text default null,
  p_checkout_session_id  text default null,
  p_card_brand           text default null,
  p_card_last4           text default null,
  p_paid_at              timestamptz default null,
  p_stripe_method_type   text default null
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay       public.payments;
  v_received  boolean;
  v_status    public.payment_status;
  v_method    public.payment_method := coalesce(p_method, 'card');
  v_type      text := lower(nullif(btrim(p_stripe_method_type), ''));
begin
  if p_shop_id is null or p_payment_intent_id is null or p_status is null then
    raise exception 'shop, payment intent and status are required' using errcode = '22023';
  end if;
  if p_status not in ('pending', 'processing', 'succeeded', 'failed', 'cancelled') then
    raise exception 'refund states are applied with apply_stripe_refund' using errcode = '22023';
  end if;
  if v_method not in ('card', 'card_present', 'ach_debit', 'bnpl') then
    raise exception 'Stripe payments are card, card_present, ach_debit or bnpl' using errcode = '22023';
  end if;
  if v_type is not null and v_type !~ '^[a-z][a-z0-9_]{0,39}$' then
    raise exception 'invalid Stripe payment method type' using errcode = '22023';
  end if;
  p_tip_cents := coalesce(p_tip_cents, 0);
  if p_amount_cents is null or p_amount_cents < 0 or p_tip_cents < 0 or p_amount_cents + p_tip_cents <= 0 then
    raise exception 'amount and tip must be non-negative and not both zero' using errcode = '22023';
  end if;
  if not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;

  select * into v_pay from public.payments p where p.stripe_payment_intent_id = p_payment_intent_id for update;
  if not found then
    if p_customer_id is null and p_invoice_id is null and p_job_id is null and p_membership_id is null then
      raise exception 'a payment needs an invoice, job, membership or customer' using errcode = '22023';
    end if;
    -- Stale links (the Stripe metadata names an invoice / job / membership /
    -- customer deleted since, or one of another shop) are dropped rather than
    -- failing the composite FK, so the money is still recorded against what
    -- remains. The payments trigger derives the customer from the rest.
    if p_invoice_id is not null
       and not exists (select 1 from public.invoices i where i.id = p_invoice_id and i.shop_id = p_shop_id) then
      p_invoice_id := null;
    end if;
    if p_job_id is not null
       and not exists (select 1 from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id) then
      p_job_id := null;
    end if;
    if p_membership_id is not null
       and not exists (select 1 from public.memberships m where m.id = p_membership_id and m.shop_id = p_shop_id) then
      p_membership_id := null;
      -- a membership charge whose membership is gone is an ordinary payment
      if p_kind = 'membership' then
        p_kind := 'payment';
      end if;
    end if;
    if p_customer_id is not null
       and not exists (select 1 from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id) then
      p_customer_id := null;
    end if;
    if p_customer_id is null and p_invoice_id is null and p_job_id is null and p_membership_id is null then
      raise exception 'none of the payment''s invoice, job, membership or customer exists in this shop'
        using errcode = 'P0002';
    end if;
    insert into public.payments (shop_id, invoice_id, job_id, customer_id, membership_id, kind, method, status,
                                 amount_cents, tip_cents, stripe_payment_intent_id, stripe_charge_id,
                                 stripe_checkout_session_id, card_brand, card_last4, paid_at, stripe_method_type)
    values (p_shop_id, p_invoice_id, p_job_id, p_customer_id, p_membership_id, coalesce(p_kind, 'payment'),
            v_method, p_status, p_amount_cents, p_tip_cents, p_payment_intent_id, p_charge_id,
            p_checkout_session_id, p_card_brand, p_card_last4,
            case when p_status = 'succeeded' then coalesce(p_paid_at, now()) end, v_type)
    on conflict (stripe_payment_intent_id) do nothing
    returning * into v_pay;
    if v_pay.id is not null then
      return v_pay;
    end if;
    -- a concurrent delivery inserted it first: fall through to the update path
    select * into v_pay from public.payments p where p.stripe_payment_intent_id = p_payment_intent_id for update;
  end if;

  if v_pay.shop_id <> p_shop_id then
    raise exception 'payment intent % belongs to another shop', p_payment_intent_id using errcode = '22023';
  end if;

  v_received := v_pay.status in ('succeeded', 'partially_refunded', 'refunded');
  v_status := case
    when v_received then v_pay.status
    when v_pay.status = 'cancelled' and p_status <> 'succeeded' then 'cancelled'
    -- a late pending / processing report never reopens a recorded decline
    -- (and an ACH return after processing is final)
    when v_pay.status = 'failed' and p_status in ('pending', 'processing') then 'failed'
    -- processing never regresses to pending
    when v_pay.status = 'processing' and p_status = 'pending' then 'processing'
    -- a declined PaymentSheet attempt stays open (see 0013)
    when p_status = 'failed' and v_pay.status = 'pending'
         and v_pay.kind <> 'membership'
         and v_pay.stripe_checkout_session_id is null and p_checkout_session_id is null
         and v_pay.card_last4 is null then 'pending'
    else p_status
  end;

  update public.payments p
     set status = v_status,
         amount_cents = case when v_received then p.amount_cents else p_amount_cents end,
         tip_cents = case when v_received then p.tip_cents else p_tip_cents end,
         method = case when v_received then p.method else v_method end,
         stripe_method_type = case when v_received then coalesce(p.stripe_method_type, v_type)
                                   else coalesce(v_type, p.stripe_method_type) end,
         stripe_charge_id = coalesce(p.stripe_charge_id, p_charge_id),
         stripe_checkout_session_id = coalesce(p.stripe_checkout_session_id, p_checkout_session_id),
         card_brand = coalesce(p.card_brand, p_card_brand),
         card_last4 = coalesce(p.card_last4, p_card_last4),
         paid_at = case when v_status = 'succeeded' and not v_received then coalesce(p_paid_at, now())
                        else p.paid_at end
   where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

comment on function public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                                                  public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text,
                                                  timestamptz, text) is
  'service_role: record / update the payment of a Stripe PaymentIntent (card, card_present, ach_debit, bnpl). pending -> processing -> succeeded | failed; received money is never downgraded.';

-- ---------------------------------------------------------------------------
-- record_manual_payment — collector (0013). Only cash / check /
-- bank_transfer / other: cards, ACH debits and pay-later go through Stripe,
-- and gift cards through redeem_gift_card / redeem_customer_credit. A
-- 'processing' (ACH) payment counts as in flight, so it is never paid twice.
-- ---------------------------------------------------------------------------
create or replace function public.record_manual_payment(
  p_invoice_id    uuid,
  p_amount_cents  bigint,
  p_method        public.payment_method,
  p_tip_cents     bigint default 0,
  p_note          text default null
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv        public.invoices;
  v_pay        public.payments;
  v_in_flight  bigint;
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id for update;
  if not found or not public.is_shop_member(v_inv.shop_id) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_invoice(v_inv.shop_id, v_inv.id) then
    raise exception 'you cannot collect payments for this invoice' using errcode = '42501';
  end if;
  if p_method = 'gift_card' then
    raise exception 'gift cards are redeemed with redeem_gift_card (or redeem_customer_credit for store credit)'
      using errcode = '22023';
  end if;
  if p_method in ('ach_debit', 'bnpl') then
    raise exception 'bank debits and pay-later payments are taken through Stripe' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('cash', 'check', 'bank_transfer', 'other') then
    raise exception 'manual payments must be cash, check, bank_transfer or other; cards are charged through Stripe'
      using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount must be greater than zero' using errcode = '22023';
  end if;
  p_tip_cents := coalesce(p_tip_cents, 0);
  if p_tip_cents < 0 then
    raise exception 'tip cannot be negative' using errcode = '22023';
  end if;
  if char_length(p_note) > 1000 then
    raise exception 'note is too long (max 1000 characters)' using errcode = '22023';
  end if;
  if v_inv.status not in ('open', 'partially_paid') then
    raise exception 'this invoice is % and cannot take payments', v_inv.status using errcode = '22023';
  end if;
  select coalesce(sum(p.amount_cents), 0) into v_in_flight
    from public.payments p
   where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id
     and public.payment_in_flight(p.status, p.created_at);
  if p_amount_cents > v_inv.balance_cents - v_in_flight then
    if v_in_flight > 0 then
      raise exception 'amount exceeds the balance due (% cents) less the card payments in progress (% cents)',
        v_inv.balance_cents, v_in_flight using errcode = '22023';
    end if;
    raise exception 'amount exceeds the balance due (% cents)', v_inv.balance_cents using errcode = '22023';
  end if;

  insert into public.payments (shop_id, invoice_id, customer_id, kind, method, status, amount_cents, tip_cents,
                               note, recorded_by, paid_at)
  values (v_inv.shop_id, v_inv.id, v_inv.customer_id, 'payment', p_method, 'succeeded', p_amount_cents, p_tip_cents,
          p_note, auth.uid(), now())
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants (upsert_stripe_payment: exactly as before — service_role only)
-- ---------------------------------------------------------------------------
revoke execute on function
  public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                               public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz, text)
from public, anon, authenticated;
grant execute on function
  public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                               public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz, text)
to service_role;
