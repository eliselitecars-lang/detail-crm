-- ============================================================================
-- 0013 — Money RPCs (SPEC §4.5): invoices (create_invoice_from_job,
-- create_invoice, mark_invoice_sent, void_invoice), manual payments
-- (record_manual_payment, refund_manual_payment, apply_payment_to_invoice),
-- Stripe webhook helpers
-- (upsert_stripe_payment, apply_stripe_refund — service_role only) and
-- job_payment_summary.
--
-- Permission shorthand:
--   collector = owner/admin/manager, or a technician assigned to the job when
--               shops.techs_can_collect_payments (public.can_collect_for_job)
--   admin     = owner/admin (refunds, voids — SPEC §3)
-- Callers who are not members of the document's shop get "not found"
-- (P0002) so ids of other shops are not confirmed; members lacking the role
-- get 42501. The invoice rows these RPCs return carry public_token = null:
-- the token is the customer's credential, which owners/admins/managers read
-- with invoice_link_token (0015) and collecting technicians never see.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- create_invoice_from_job(job_id) — collector. Copies the job's lines,
-- discount and tax rate, attaches the job's earlier payments that have no
-- invoice (deposits), and issues the invoice (open; due per
-- shops.invoice_due_days). Fails if the job already has a non-void invoice.
-- ---------------------------------------------------------------------------
create function public.create_invoice_from_job(p_job_id uuid) returns public.invoices
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job       public.jobs;
  v_inv       public.invoices;
  v_existing  bigint;
begin
  select * into v_job from public.jobs j where j.id = p_job_id for update;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_job(v_job.shop_id, v_job.id) then
    raise exception 'you cannot invoice this job' using errcode = '42501';
  end if;
  select i.number into v_existing from public.invoices i
   where i.shop_id = v_job.shop_id and i.job_id = v_job.id and i.status <> 'void';
  if found then
    raise exception 'this job already has invoice #%', v_existing using errcode = '23505';
  end if;
  if not exists (select 1 from public.job_line_items li where li.job_id = v_job.id and li.shop_id = v_job.shop_id) then
    raise exception 'the job has no line items to invoice' using errcode = '22023';
  end if;

  insert into public.invoices (shop_id, job_id, customer_id, status, discount_kind, discount_value, tax_rate_bps)
  values (v_job.shop_id, v_job.id, v_job.customer_id, 'draft', v_job.discount_kind, v_job.discount_value, v_job.tax_rate_bps)
  returning * into v_inv;

  insert into public.invoice_line_items (shop_id, invoice_id, service_id, vehicle_id, name, description, quantity,
                                         unit_price_cents, discount_cents, taxable, sort)
  select v_job.shop_id, v_inv.id, li.service_id, li.vehicle_id, li.name, li.description, li.quantity,
         li.unit_price_cents, li.discount_cents, li.taxable,
         row_number() over (order by li.sort, li.created_at, li.id)::integer
  from public.job_line_items li
  where li.job_id = v_job.id and li.shop_id = v_job.shop_id;

  update public.payments p
     set invoice_id = v_inv.id
   where p.shop_id = v_job.shop_id and p.job_id = v_job.id and p.invoice_id is null;

  update public.invoices i
     set status = case when i.status = 'draft' then 'open'::public.invoice_status else i.status end
   where i.id = v_inv.id
  returning * into v_inv;
  v_inv.public_token := null;  -- the customer's credential: invoice_link_token (0015)
  return v_inv;
end
$$;

-- Raises 22023 from inside an expression (used to validate JSON input).
-- VOLATILE on purpose: an immutable call with constant arguments could be
-- folded (and raise) at plan time even in an untaken CASE branch.
create function public.money_raise_invalid(p_message text) returns jsonb
language plpgsql volatile
set search_path = ''
as $$
begin
  raise exception '%', p_message using errcode = '22023';
end
$$;

-- ---------------------------------------------------------------------------
-- create_invoice(customer, lines, notes, internal_notes) — manager+, ad-hoc
-- draft invoice (no job). p_lines: [{service_id?, vehicle_id?, name?,
-- description?, quantity?, unit_price_cents?, discount_cents?, taxable?}];
-- a line with a service and no price is priced from the catalog for the
-- line's vehicle category; taxable defaults to the service's flag (else true).
-- ---------------------------------------------------------------------------
create function public.create_invoice(
  p_customer_id     uuid,
  p_lines           jsonb default '[]'::jsonb,
  p_notes           text default null,
  p_internal_notes  text default null
) returns public.invoices
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust  public.customers;
  v_inv   public.invoices;
  v_line  record;
  v_price bigint;
  v_tax   boolean;
  v_name  text;
begin
  select * into v_cust from public.customers c where c.id = p_customer_id;
  if not found or not public.is_shop_member(v_cust.shop_id) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_cust.shop_id) then
    raise exception 'only owners, admins and managers can create invoices' using errcode = '42501';
  end if;
  p_lines := coalesce(p_lines, '[]'::jsonb);
  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_lines) > 200 then
    raise exception 'an invoice can have at most 200 lines' using errcode = '22023';
  end if;

  insert into public.invoices (shop_id, customer_id, status, notes, internal_notes)
  values (v_cust.shop_id, v_cust.id, 'draft', nullif(btrim(p_notes), ''), nullif(btrim(p_internal_notes), ''))
  returning * into v_inv;

  for v_line in
    select x.*, t.ord
    from jsonb_array_elements(p_lines) with ordinality as t(elem, ord)
    cross join lateral jsonb_to_record(
      case when jsonb_typeof(t.elem) = 'object' then t.elem
           else public.money_raise_invalid('each line must be a JSON object') end)
      as x(service_id uuid, vehicle_id uuid, name text, description text, quantity numeric,
           unit_price_cents bigint, discount_cents bigint, taxable boolean)
    order by t.ord
  loop
    v_price := v_line.unit_price_cents;
    v_tax := v_line.taxable;
    v_name := nullif(btrim(v_line.name), '');
    if v_line.service_id is not null then
      if not exists (select 1 from public.services s where s.id = v_line.service_id and s.shop_id = v_cust.shop_id) then
        raise exception 'service not found' using errcode = '22023';
      end if;
      if v_price is null then
        select sp.price_cents into v_price
          from public.service_price_for(
                 v_line.service_id,
                 (select v.category_id from public.vehicles v
                   where v.id = v_line.vehicle_id and v.shop_id = v_cust.shop_id)) sp;
      end if;
      if v_tax is null then
        select s.taxable into v_tax from public.services s where s.id = v_line.service_id;
      end if;
    end if;
    if v_price is null then
      raise exception 'line % needs a unit price', v_line.ord using errcode = '22023';
    end if;
    if v_name is null and v_line.service_id is null then
      raise exception 'line % needs a name', v_line.ord using errcode = '22023';
    end if;
    insert into public.invoice_line_items (shop_id, invoice_id, service_id, vehicle_id, name, description,
                                           quantity, unit_price_cents, discount_cents, taxable, sort)
    values (v_cust.shop_id, v_inv.id, v_line.service_id, v_line.vehicle_id, v_name,
            nullif(btrim(v_line.description), ''), coalesce(v_line.quantity, 1), v_price,
            coalesce(v_line.discount_cents, 0), coalesce(v_tax, true), v_line.ord::integer);
  end loop;

  select * into v_inv from public.invoices i where i.id = v_inv.id;
  v_inv.public_token := null;  -- the customer's credential: invoice_link_token (0015)
  return v_inv;
end
$$;

-- ---------------------------------------------------------------------------
-- mark_invoice_sent(invoice) — collector (job invoices) / manager+ (all).
-- Issues a draft (needs at least one line) and stamps sent_at; re-sending an
-- issued invoice re-stamps sent_at. Void invoices cannot be sent.
-- ---------------------------------------------------------------------------
create function public.mark_invoice_sent(p_invoice_id uuid) returns public.invoices
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id for update;
  if not found or not public.is_shop_member(v_inv.shop_id) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_invoice(v_inv.shop_id, v_inv.id) then
    raise exception 'you cannot send this invoice' using errcode = '42501';
  end if;
  if v_inv.status = 'void' then
    raise exception 'a void invoice cannot be sent' using errcode = '22023';
  end if;
  if v_inv.status = 'draft' then
    if not exists (select 1 from public.invoice_line_items li where li.invoice_id = v_inv.id and li.shop_id = v_inv.shop_id) then
      raise exception 'add at least one line item before sending the invoice' using errcode = '22023';
    end if;
    if v_inv.due_at is not null and v_inv.due_at < now() then
      raise exception 'the due date is in the past; change it before sending' using errcode = '22023';
    end if;
    update public.invoices i set status = 'open', sent_at = now() where i.id = v_inv.id returning * into v_inv;
  else
    update public.invoices i set sent_at = now() where i.id = v_inv.id returning * into v_inv;
  end if;
  v_inv.public_token := null;  -- the customer's credential: invoice_link_token (0015)
  return v_inv;
end
$$;

-- ---------------------------------------------------------------------------
-- void_invoice(invoice, reason) — owner/admin.
-- Payments that belong to the invoice's job are detached back to the job, so
-- a replacement invoice (create_invoice_from_job) picks them up again. It is
-- refused while a payment is in flight (public.payment_in_flight), and when
-- money that is not tied to a job is still on the invoice (refund it first).
-- Money that still arrives for the void invoice later is re-routed by
-- payments_before_write. Locks the job before the invoice (payments take
-- them in that order too).
-- ---------------------------------------------------------------------------
create function public.void_invoice(p_invoice_id uuid, p_reason text default null) returns public.invoices
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id;
  if not found or not public.is_shop_member(v_inv.shop_id) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if v_inv.job_id is not null then
    perform 1 from public.jobs j where j.id = v_inv.job_id and j.shop_id = v_inv.shop_id for no key update;
  end if;
  select * into v_inv from public.invoices i where i.id = p_invoice_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_inv.shop_id) then
    raise exception 'only owners and admins can void invoices' using errcode = '42501';
  end if;
  if v_inv.status = 'void' then
    raise exception 'this invoice is already void' using errcode = '22023';
  end if;
  if char_length(p_reason) > 1000 then
    raise exception 'void reason is too long (max 1000 characters)' using errcode = '22023';
  end if;
  if exists (select 1 from public.payments p
             where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id
               and public.payment_in_flight(p.status, p.created_at)) then
    raise exception 'a payment is in progress on this invoice; wait for it to finish' using errcode = '22023';
  end if;
  if exists (select 1 from public.payments p
             where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id and p.job_id is null
               and public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)
                 + public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) > 0) then
    raise exception 'refund the payments on this invoice before voiding it' using errcode = '22023';
  end if;

  update public.invoices i
     set status = 'void', voided_at = now(), void_reason = nullif(btrim(p_reason), '')
   where i.id = v_inv.id;
  update public.payments p
     set invoice_id = null
   where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id and p.job_id is not null;

  select * into v_inv from public.invoices i where i.id = p_invoice_id;
  v_inv.public_token := null;  -- the customer's credential: invoice_link_token (0015)
  return v_inv;
end
$$;

-- ---------------------------------------------------------------------------
-- record_manual_payment — collector. Cash / check / bank transfer / other.
-- 0 < amount ≤ current balance minus card payments in flight on the invoice
-- (no overpayment, and no double payment while a card is being confirmed);
-- tip ≥ 0 never counts toward the balance. The invoice must be issued and
-- not fully paid.
-- ---------------------------------------------------------------------------
create function public.record_manual_payment(
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
-- refund_manual_payment — owner/admin. Records money handed back for a
-- cash/check/bank/other payment (or corrects a mistaken entry). Card refunds
-- go through Stripe (payments edge function) and arrive via
-- apply_stripe_refund. p_amount_cents is refunded from amount first, then tip.
-- ---------------------------------------------------------------------------
create function public.refund_manual_payment(p_payment_id uuid, p_amount_cents bigint) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
  v_new bigint;
begin
  select * into v_pay from public.payments p where p.id = p_payment_id for update;
  if not found or not public.is_shop_member(v_pay.shop_id) then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_pay.shop_id) then
    raise exception 'only owners and admins can refund payments' using errcode = '42501';
  end if;
  if v_pay.method in ('card', 'card_present') then
    raise exception 'card payments are refunded through Stripe' using errcode = '22023';
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
  update public.payments p
     set refunded_cents = v_new,
         status = public.payment_refund_status(p.amount_cents, p.tip_cents, v_new)
   where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- apply_payment_to_invoice(payment, invoice) — manager+. Puts received money
-- that is not paying anything onto one of the same customer's issued
-- invoices, so the customer never owes it twice:
--   * an unapplied payment: no invoice, job or membership. Money received
--     for a void invoice without a job, for a job / invoice / membership that
--     was deleted, or for a document that moved to another customer is kept
--     on the paying customer like this, with a note asking staff to apply it
--     or refund it (payments_before_write, stripe-webhook);
--   * an overpayment: a payment on another invoice that stays settled
--     without it (its balance + the payment's net amount ≤ 0), e.g. a second
--     payment link paid after the first one.
-- The whole payment row moves, so its Stripe intent, refunds and tip stay
-- together; its net amount (tips never count) must fit the target's balance
-- less the card payments in flight on it (no new overpayment). The target
-- must be open or partially paid. A job deposit still waiting for its job's
-- invoice is not unapplied (create_invoice_from_job attaches it), and a
-- membership payment belongs to its membership. A moved deposit becomes a
-- plain payment (it now pays an invoice, not a job's deposit); the payment's
-- job follows the target invoice. A line recording where it went is appended
-- to the payment's note. Locks jobs, then invoices, then the payment (the
-- order void_invoice and payments_before_write use).
-- ---------------------------------------------------------------------------
create function public.apply_payment_to_invoice(
  p_payment_id  uuid,
  p_invoice_id  uuid,
  p_now         timestamptz default now()
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now        timestamptz := public.effective_now(p_now);
  v_pay        public.payments;
  v_inv        public.invoices;
  v_src        public.invoices;
  v_src_id     uuid;
  v_net        bigint;
  v_in_flight  bigint;
  v_line       text;
begin
  select * into v_pay from public.payments p where p.id = p_payment_id;
  if not found or not public.is_shop_member(v_pay.shop_id) then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_pay.shop_id) then
    raise exception 'only owners, admins and managers can apply payments to invoices' using errcode = '42501';
  end if;
  select * into v_inv from public.invoices i where i.id = p_invoice_id and i.shop_id = v_pay.shop_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  v_src_id := v_pay.invoice_id;

  perform 1 from public.jobs j
   where j.shop_id = v_pay.shop_id and j.id in (v_inv.job_id, v_pay.job_id)
   order by j.id for no key update;
  perform 1 from public.invoices i
   where i.shop_id = v_pay.shop_id and i.id in (v_inv.id, v_src_id)
   order by i.id for update;
  select * into v_pay from public.payments p where p.id = p_payment_id for update;
  if v_pay.invoice_id is distinct from v_src_id then
    raise exception 'the payment changed while it was being applied; try again' using errcode = '40001';
  end if;
  select * into v_inv from public.invoices i where i.id = p_invoice_id;

  if v_pay.invoice_id = v_inv.id then
    raise exception 'the payment is already applied to invoice #%', v_inv.number using errcode = '22023';
  end if;
  if v_pay.membership_id is not null then
    raise exception 'membership payments belong to their membership' using errcode = '22023';
  end if;
  if v_pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'only received payments can be applied (this one is %)', v_pay.status using errcode = '22023';
  end if;
  v_net := public.payment_net_amount(v_pay.status, v_pay.amount_cents, v_pay.tip_cents, v_pay.refunded_cents);
  if v_net <= 0 then
    raise exception 'nothing of this payment is left to apply (tips never count toward invoices)' using errcode = '22023';
  end if;
  if v_pay.invoice_id is null and v_pay.job_id is not null then
    raise exception 'this payment belongs to job #%; it is applied when that job is invoiced',
      (select j.number from public.jobs j where j.id = v_pay.job_id and j.shop_id = v_pay.shop_id)
      using errcode = '22023';
  end if;
  if v_pay.invoice_id is not null then
    select * into v_src from public.invoices i where i.id = v_pay.invoice_id;
    if v_src.balance_cents + v_net > 0 then
      raise exception 'invoice #% needs this payment; only an overpayment can move to another invoice', v_src.number
        using errcode = '22023';
    end if;
  end if;
  if v_inv.customer_id <> v_pay.customer_id then
    raise exception 'invoice #% belongs to another customer', v_inv.number using errcode = '22023';
  end if;
  if v_inv.status not in ('open', 'partially_paid') then
    raise exception 'invoice #% is % and cannot take payments', v_inv.number, v_inv.status using errcode = '22023';
  end if;
  select coalesce(sum(p.amount_cents), 0) into v_in_flight
    from public.payments p
   where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id
     and public.payment_in_flight(p.status, p.created_at, v_now);
  if v_net > v_inv.balance_cents - v_in_flight then
    if v_in_flight > 0 then
      raise exception 'the payment (% cents) exceeds the balance due (% cents) less the card payments in progress (% cents)',
        v_net, v_inv.balance_cents, v_in_flight using errcode = '22023';
    end if;
    raise exception 'the payment (% cents) exceeds the balance due on invoice #% (% cents)',
      v_net, v_inv.number, v_inv.balance_cents using errcode = '22023';
  end if;

  v_line := format('Applied to invoice #%s', v_inv.number);
  update public.payments p
     set invoice_id = v_inv.id,
         job_id = null,   -- payments_before_write takes the invoice's job
         kind = case when p.kind = 'deposit' then 'payment'::public.payment_kind else p.kind end,
         note = case when p.note is null then v_line
                     else left(p.note, 1000 - char_length(v_line) - 1) || E'\n' || v_line end
   where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- upsert_stripe_payment (service_role; webhook / payments edge function).
-- Creates or updates the payment row for a PaymentIntent. Idempotent and
-- safe against out-of-order events:
--   * linkage (invoice / job / customer / membership / kind / method) is fixed
--     by the first call; later calls cannot move the money
--   * money already received (succeeded / refunded states) is never
--     downgraded; replays just fill missing charge/card details
--   * cancelled is terminal except for succeeded (money moved wins)
--   * a 'pending' report never reopens a row already recorded 'failed': it is
--     a late delivery (charge_saved_card records 'pending' for a 'processing'
--     intent after its Stripe call returns; the webhook's Checkout 'unpaid'
--     path records 'pending' too) that can land after payment_failed, and
--     reopening would count the decline as money in flight again, blocking
--     manual payments, applying credit, voiding and line edits. A failed row
--     moves on only to succeeded (money moved wins), failed or cancelled.
--   * amount / tip follow the latest pending/failed state until success
--   * a decline does not end an open PaymentSheet attempt: Stripe returns the
--     intent to requires_payment_method and the sheet still on the device
--     can confirm it with another card. So a 'failed' report for a pending
--     attempt whose card is not on record yet (the customer picks it in the
--     sheet) keeps it 'pending' — money in flight for every guard
--     (public.payment_in_flight) — until it succeeds or is cancelled
--     (superseded, cancel_open_payments, the stale-sheet sweep). Attempts
--     that cannot be confirmed again are recorded 'failed' as reported: a
--     saved-card charge (confirmed server-side only; its card is recorded
--     up front), a Checkout Session (Stripe cancels its intent when the
--     session expires), a membership invoice (Stripe Billing retries it),
--     or a decline recorded without an earlier pending row.
-- Refund states come only from apply_stripe_refund.
-- ---------------------------------------------------------------------------
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
  p_paid_at              timestamptz default null
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay       public.payments;
  v_received  boolean;
  v_status    public.payment_status;
begin
  if p_shop_id is null or p_payment_intent_id is null or p_status is null then
    raise exception 'shop, payment intent and status are required' using errcode = '22023';
  end if;
  if p_status not in ('pending', 'succeeded', 'failed', 'cancelled') then
    raise exception 'refund states are applied with apply_stripe_refund' using errcode = '22023';
  end if;
  if coalesce(p_method, 'card') not in ('card', 'card_present') then
    raise exception 'Stripe payments are card or card_present' using errcode = '22023';
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
    insert into public.payments (shop_id, invoice_id, job_id, customer_id, membership_id, kind, method, status,
                                 amount_cents, tip_cents, stripe_payment_intent_id, stripe_charge_id,
                                 stripe_checkout_session_id, card_brand, card_last4, paid_at)
    values (p_shop_id, p_invoice_id, p_job_id, p_customer_id, p_membership_id, coalesce(p_kind, 'payment'),
            coalesce(p_method, 'card'), p_status, p_amount_cents, p_tip_cents, p_payment_intent_id, p_charge_id,
            p_checkout_session_id, p_card_brand, p_card_last4,
            case when p_status = 'succeeded' then coalesce(p_paid_at, now()) end)
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
    -- a late pending report never reopens a recorded decline (see header)
    when v_pay.status = 'failed' and p_status = 'pending' then 'failed'
    -- a declined PaymentSheet attempt stays open (see header)
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

-- ---------------------------------------------------------------------------
-- apply_stripe_refund (service_role; charge.refunded). p_refunded_cents_total
-- is the charge's cumulative amount_refunded. The stored total only ever
-- grows, so replays and out-of-order deliveries are harmless.
-- ---------------------------------------------------------------------------
create function public.apply_stripe_refund(
  p_payment_intent_id      text,
  p_refunded_cents_total   bigint
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
  v_new bigint;
begin
  select * into v_pay from public.payments p where p.stripe_payment_intent_id = p_payment_intent_id for update;
  if not found then
    raise exception 'payment for intent % not found', p_payment_intent_id using errcode = 'P0002';
  end if;
  if p_refunded_cents_total is null or p_refunded_cents_total < 0
     or p_refunded_cents_total > v_pay.amount_cents + v_pay.tip_cents then
    raise exception 'refunded total must be between 0 and the charged amount (% cents)',
      v_pay.amount_cents + v_pay.tip_cents using errcode = '22023';
  end if;
  if v_pay.status not in ('succeeded', 'partially_refunded', 'refunded') then
    raise exception 'a % payment cannot be refunded', v_pay.status using errcode = '22023';
  end if;
  v_new := greatest(v_pay.refunded_cents, p_refunded_cents_total);
  if v_new = v_pay.refunded_cents then
    return v_pay;
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
-- job_payment_summary(job) — collector. Money picture of one job:
--   paid / deposit_paid / tip   net received (refunds subtracted)
--   refunded                    Σ refunded_cents
--   pending                     Σ amount + tip of in-flight payments
--                               (public.payment_in_flight)
--   total / balance             from the job's non-void invoice when there is
--                               one, else job total − paid
--   deposit_due                 what is still needed to cover the required
--                               deposit (any received money counts)
-- ---------------------------------------------------------------------------
create function public.job_payment_summary(p_job_id uuid)
returns table (
  job_id                  uuid,
  invoice_id              uuid,
  invoice_number          bigint,
  invoice_status          public.invoice_status,
  total_cents             bigint,
  deposit_required_cents  bigint,
  deposit_paid_cents      bigint,
  deposit_due_cents       bigint,
  paid_cents              bigint,
  tip_cents               bigint,
  refunded_cents          bigint,
  pending_cents           bigint,
  balance_cents           bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job   public.jobs;
  v_inv   public.invoices;
  v_paid  bigint;
  v_dep   bigint;
  v_tip   bigint;
  v_ref   bigint;
  v_pend  bigint;
  v_total bigint;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_job(v_job.shop_id, v_job.id) then
    raise exception 'you cannot view payments for this job' using errcode = '42501';
  end if;

  select * into v_inv from public.invoices i
   where i.shop_id = v_job.shop_id and i.job_id = v_job.id and i.status <> 'void';

  select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                    filter (where p.kind = 'deposit'), 0),
         coalesce(sum(public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(p.refunded_cents), 0),
         coalesce(sum(p.amount_cents + p.tip_cents) filter (where public.payment_in_flight(p.status, p.created_at)), 0)
    into v_paid, v_dep, v_tip, v_ref, v_pend
    from public.payments p
   where p.shop_id = v_job.shop_id and p.job_id = v_job.id;

  v_total := coalesce(v_inv.total_cents, v_job.total_cents);
  return query select
    v_job.id,
    v_inv.id,
    v_inv.number,
    v_inv.status,
    v_total,
    v_job.deposit_required_cents,
    v_dep,
    greatest(least(v_job.deposit_required_cents, v_total) - v_paid, 0),
    v_paid,
    v_tip,
    v_ref,
    v_pend,
    coalesce(v_inv.balance_cents, v_total - v_paid);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.money_raise_invalid(text) from public, anon, authenticated;

revoke execute on function
  public.create_invoice_from_job(uuid),
  public.create_invoice(uuid, jsonb, text, text),
  public.mark_invoice_sent(uuid),
  public.void_invoice(uuid, text),
  public.record_manual_payment(uuid, bigint, public.payment_method, bigint, text),
  public.refund_manual_payment(uuid, bigint),
  public.apply_payment_to_invoice(uuid, uuid, timestamptz),
  public.job_payment_summary(uuid)
from public, anon;
grant execute on function
  public.create_invoice_from_job(uuid),
  public.create_invoice(uuid, jsonb, text, text),
  public.mark_invoice_sent(uuid),
  public.void_invoice(uuid, text),
  public.record_manual_payment(uuid, bigint, public.payment_method, bigint, text),
  public.refund_manual_payment(uuid, bigint),
  public.apply_payment_to_invoice(uuid, uuid, timestamptz),
  public.job_payment_summary(uuid)
to authenticated, service_role;

revoke execute on function
  public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                               public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz),
  public.apply_stripe_refund(text, bigint)
from public, anon, authenticated;
grant execute on function
  public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind,
                               public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamptz),
  public.apply_stripe_refund(text, bigint)
to service_role;
