-- ============================================================================
-- 0012 — Money (SPEC §4.5): invoices, invoice_line_items, payments and the
-- server-maintained invoice balance / status.
--
-- Invoice amounts (all server-maintained; client writes are ignored):
--   subtotal/discount/tax/total   canonical totals over the invoice's lines
--   amount_paid_cents             Σ net amount of payments in status
--                                 succeeded / partially_refunded / refunded
--   tip_cents                     Σ net tip of the same payments
--   balance_cents                 total − amount_paid (tips never count;
--                                 negative = customer credit / overpayment)
-- A payment's refunded_cents is the refunded part of its whole charge
-- (amount + tip) and is applied to the amount first, then to the tip:
--   net amount = amount − least(refunded, amount)
--   net tip    = tip − greatest(refunded − amount, 0)
--
-- Invoice status:
--   draft  → not issued; editable; not payable. Receiving money auto-issues it.
--   open / partially_paid / paid — derived from the amounts whenever anything
--          changes: balance ≤ 0 → paid (so an issued zero-total invoice is
--          paid), paid > 0 → partially_paid, else open. Refunds reopen.
--   void   → terminal (void_invoice, owner/admin). Never reissued.
-- Lines and pricing are editable only while no money has been received
-- (draft, open, or a zero-total paid invoice) and no payment is in flight;
-- never on void invoices or invoices with money on them. Line guards lock the
-- invoice row first, so they serialize with payments (which lock it too).
--
-- In flight = a 'pending' payment started less than an hour ago
-- (public.payment_in_flight). A declined PaymentSheet attempt stays 'pending'
-- (upsert_stripe_payment): the sheet can still confirm it with another card,
-- so cash cannot cover the same balance meanwhile. Older pending rows are
-- abandoned intents (a dismissed PaymentSheet stays requires_payment_method
-- forever and Stripe sends no event; the stale-sheet sweep cancels it): they
-- stop blocking edits / voids / manual payments. If
-- one still completes later, the webhook records the money like any other
-- late payment (see "void invoices" below).
--
-- Payments never land on a void invoice: money that arrives for one (a
-- Checkout Session opened before the void, a stale intent) is re-routed when
-- it is recorded, becomes received, or is received again after a refund
-- failed at Stripe — a job payment to the job's current
-- invoice (or to the job, for the next create_invoice_from_job), anything
-- else to the customer as an unapplied payment flagged in its note.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- invoices
-- ---------------------------------------------------------------------------
create table public.invoices (
  id                 uuid primary key default gen_random_uuid(),
  shop_id            uuid not null references public.shops (id) on delete cascade,
  number             bigint not null,
  job_id             uuid,
  customer_id        uuid not null,
  status             public.invoice_status not null default 'draft',
  issued_at          timestamptz,
  due_at             timestamptz,
  sent_at            timestamptz,
  paid_at            timestamptz,
  voided_at          timestamptz,
  void_reason        text check (void_reason is null or char_length(void_reason) <= 1000),
  notes              text check (notes is null or char_length(notes) <= 20000),
  terms              text check (terms is null or char_length(terms) <= 20000),
  internal_notes     text check (internal_notes is null or char_length(internal_notes) <= 20000),
  discount_kind      public.discount_kind not null default 'none',
  discount_value     bigint not null default 0,
  tax_rate_bps       integer not null check (tax_rate_bps between 0 and 10000),
  subtotal_cents     bigint not null default 0 check (subtotal_cents >= 0),
  discount_cents     bigint not null default 0 check (discount_cents >= 0),
  tax_cents          bigint not null default 0 check (tax_cents >= 0),
  total_cents        bigint not null default 0 check (total_cents >= 0),
  amount_paid_cents  bigint not null default 0 check (amount_paid_cents >= 0),
  balance_cents      bigint not null default 0,
  tip_cents          bigint not null default 0 check (tip_cents >= 0),
  public_token       uuid not null default gen_random_uuid() unique,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint invoices_shop_id_id_key unique (shop_id, id),
  constraint invoices_shop_number_key unique (shop_id, number),
  -- invoices are financial records: a job / customer with invoices cannot be deleted
  constraint invoices_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete restrict,
  constraint invoices_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete restrict,
  constraint invoices_discount_value check (
    discount_value >= 0
    and (discount_kind <> 'none' or discount_value = 0)
    and (discount_kind <> 'percent' or discount_value <= 10000)),
  constraint invoices_totals_consistent check (total_cents = subtotal_cents - discount_cents + tax_cents),
  constraint invoices_balance_consistent check (balance_cents = total_cents - amount_paid_cents),
  constraint invoices_issued check (status in ('draft', 'void') or issued_at is not null),
  constraint invoices_void_stamp check ((status = 'void') = (voided_at is not null)),
  constraint invoices_paid_stamp check (status <> 'paid' or paid_at is not null),
  constraint invoices_due_after_issue check (due_at is null or issued_at is null or due_at >= issued_at)
);
-- SPEC §4.5: at most one non-void invoice per job
create unique index invoices_one_per_job_key on public.invoices (shop_id, job_id)
  where job_id is not null and status <> 'void';
create index invoices_shop_job_idx on public.invoices (shop_id, job_id);
create index invoices_shop_customer_idx on public.invoices (shop_id, customer_id);
create index invoices_shop_status_idx on public.invoices (shop_id, status, due_at);
create index invoices_created_by_idx on public.invoices (created_by);
comment on column public.invoices.number is 'Human invoice number per shop, assigned by invoices_integrity. @insert-optional';
comment on column public.invoices.tax_rate_bps is 'Defaults to the shop''s tax rate when omitted (invoices_integrity). @insert-optional';

-- ---------------------------------------------------------------------------
-- invoice_line_items
-- ---------------------------------------------------------------------------
create table public.invoice_line_items (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  invoice_id        uuid not null,
  service_id        uuid,
  vehicle_id        uuid,
  name              text not null check (char_length(btrim(name)) between 1 and 200),
  description       text check (description is null or char_length(description) <= 5000),
  quantity          numeric(10, 2) not null default 1 check (quantity > 0),
  unit_price_cents  bigint not null check (unit_price_cents >= 0),
  discount_cents    bigint not null default 0 check (discount_cents >= 0),
  taxable           boolean not null default true,
  sort              integer not null default 0,
  total_cents       bigint generated always as
                      (public.line_total_cents(quantity, unit_price_cents, discount_cents)) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint invoice_line_items_shop_id_id_key unique (shop_id, id),
  constraint invoice_line_items_invoice_fk foreign key (shop_id, invoice_id)
    references public.invoices (shop_id, id) on delete cascade,
  constraint invoice_line_items_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete set null (service_id),
  constraint invoice_line_items_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id)
);
create index invoice_line_items_shop_invoice_idx on public.invoice_line_items (shop_id, invoice_id, sort);
create index invoice_line_items_shop_service_idx on public.invoice_line_items (shop_id, service_id);
create index invoice_line_items_shop_vehicle_idx on public.invoice_line_items (shop_id, vehicle_id);

-- ---------------------------------------------------------------------------
-- payments — card rows are written only by service_role (webhook helpers in
-- 0013); manual rows only through record_manual_payment. No client role can
-- insert/update/delete directly.
-- ---------------------------------------------------------------------------
create table public.payments (
  id                          uuid primary key default gen_random_uuid(),
  shop_id                     uuid not null references public.shops (id) on delete cascade,
  invoice_id                  uuid,
  job_id                      uuid,
  customer_id                 uuid not null,
  membership_id               uuid,
  kind                        public.payment_kind not null default 'payment',
  method                      public.payment_method not null,
  status                      public.payment_status not null default 'pending',
  amount_cents                bigint not null check (amount_cents >= 0),
  tip_cents                   bigint not null default 0 check (tip_cents >= 0),
  refunded_cents              bigint not null default 0 check (refunded_cents >= 0),
  -- money taken back by a lost card dispute (chargeback), maintained by the
  -- webhook through apply_stripe_dispute (0093). Informational: it does not
  -- change the net amount, invoice balances or reports' revenue — staff
  -- decide whether to bill the customer again (SPEC §4.5).
  disputed_cents              bigint not null default 0,
  stripe_payment_intent_id    text unique check (stripe_payment_intent_id is null
                                                 or stripe_payment_intent_id ~ '^pi_[A-Za-z0-9]+$'),
  stripe_charge_id            text check (stripe_charge_id is null or stripe_charge_id ~ '^(ch|py)_[A-Za-z0-9]+$'),
  stripe_checkout_session_id  text check (stripe_checkout_session_id is null
                                          or stripe_checkout_session_id ~ '^cs_[A-Za-z0-9_]+$'),
  card_brand                  text check (card_brand is null or char_length(card_brand) between 1 and 30),
  card_last4                  text check (card_last4 is null or card_last4 ~ '^[0-9]{4}$'),
  note                        text check (note is null or char_length(note) <= 1000),
  recorded_by                 uuid references auth.users (id) on delete set null,
  paid_at                     timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint payments_shop_id_id_key unique (shop_id, id),
  -- money records survive: parents with payments cannot be deleted
  constraint payments_invoice_fk foreign key (shop_id, invoice_id)
    references public.invoices (shop_id, id) on delete restrict,
  constraint payments_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete restrict,
  constraint payments_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete restrict,
  constraint payments_membership_fk foreign key (shop_id, membership_id)
    references public.memberships (shop_id, id) on delete restrict,
  constraint payments_positive check (amount_cents + tip_cents > 0),
  constraint payments_refund_bound check (refunded_cents <= amount_cents + tip_cents),
  constraint payments_disputed_bound check (disputed_cents >= 0 and disputed_cents <= amount_cents + tip_cents),
  constraint payments_refund_status check (
    case status
      when 'refunded' then refunded_cents = amount_cents + tip_cents
      when 'partially_refunded' then refunded_cents > 0 and refunded_cents < amount_cents + tip_cents
      else refunded_cents = 0
    end),
  constraint payments_paid_stamp check (status not in ('succeeded', 'partially_refunded', 'refunded') or paid_at is not null),
  -- card / card_present rows always come from Stripe; manual rows never carry Stripe/card data
  constraint payments_card_via_stripe check ((method in ('card', 'card_present')) = (stripe_payment_intent_id is not null)),
  constraint payments_manual_no_card_data check (
    method in ('card', 'card_present')
    or (card_brand is null and card_last4 is null and stripe_charge_id is null and stripe_checkout_session_id is null)),
  constraint payments_membership_kind check ((membership_id is not null) = (kind = 'membership'))
);
create unique index payments_checkout_session_key on public.payments (stripe_checkout_session_id)
  where stripe_checkout_session_id is not null;
create index payments_shop_invoice_idx on public.payments (shop_id, invoice_id);
create index payments_shop_job_idx on public.payments (shop_id, job_id);
create index payments_shop_customer_idx on public.payments (shop_id, customer_id);
create index payments_shop_membership_idx on public.payments (shop_id, membership_id);
create index payments_shop_paid_at_idx on public.payments (shop_id, paid_at);
create index payments_recorded_by_idx on public.payments (recorded_by);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Net contribution of a payment (see header). Rows in other statuses count 0.
create function public.payment_net_amount(p_status public.payment_status, p_amount bigint, p_tip bigint, p_refunded bigint)
returns bigint
language sql immutable
set search_path = ''
as $$
  select case when p_status in ('succeeded', 'partially_refunded', 'refunded')
              then p_amount - least(p_refunded, p_amount) else 0 end
$$;

create function public.payment_net_tip(p_status public.payment_status, p_amount bigint, p_tip bigint, p_refunded bigint)
returns bigint
language sql immutable
set search_path = ''
as $$
  select case when p_status in ('succeeded', 'partially_refunded', 'refunded')
              then p_tip - greatest(p_refunded - p_amount, 0) else 0 end
$$;

-- Is a payment money in flight at p_now? (see header: pending and started
-- within the last hour)
create function public.payment_in_flight(
  p_status      public.payment_status,
  p_created_at  timestamptz,
  p_now         timestamptz default now()
) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_status = 'pending' and p_created_at > p_now - interval '1 hour'
$$;

-- Status implied by a cumulative refund on a received payment.
create function public.payment_refund_status(p_amount bigint, p_tip bigint, p_refunded bigint)
returns public.payment_status
language sql immutable
set search_path = ''
as $$
  select case when p_refunded <= 0 then 'succeeded'
              when p_refunded >= p_amount + p_tip then 'refunded'
              else 'partially_refunded' end::public.payment_status
$$;

-- May the caller see / collect money for this job? Owner/admin/manager, or a
-- technician assigned to the job when the shop lets technicians collect.
create function public.can_collect_for_job(p_shop_id uuid, p_job_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_shop_manager(p_shop_id)
      or (p_job_id is not null
          and public.has_shop_role(p_shop_id, 'technician')
          and exists (select 1 from public.shops s where s.id = p_shop_id and s.techs_can_collect_payments)
          and exists (select 1 from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id)
          and public.is_assigned_to_job(p_job_id))
$$;

create function public.can_collect_for_invoice(p_shop_id uuid, p_invoice_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_shop_manager(p_shop_id)
      or exists (select 1 from public.invoices i
                 where i.id = p_invoice_id and i.shop_id = p_shop_id and i.job_id is not null
                   and public.can_collect_for_job(p_shop_id, i.job_id))
$$;

-- ---------------------------------------------------------------------------
-- invoices triggers
-- ---------------------------------------------------------------------------

-- 10: direct-write guard (staff via PostgREST). Creation, issuing and voiding
-- go through RPCs; amounts and stamps are server-maintained.
create function public.invoices_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    raise exception 'use create_invoice or create_invoice_from_job' using errcode = '42501';
  end if;
  if new.number <> old.number or new.public_token <> old.public_token
     or new.job_id is distinct from old.job_id or new.customer_id <> old.customer_id then
    raise exception 'invoice number, token, job and customer cannot be changed' using errcode = '42501';
  end if;
  if new.status <> old.status then
    raise exception 'invoice status is automatic; use mark_invoice_sent or void_invoice' using errcode = '42501';
  end if;
  -- server-maintained values: client values are ignored
  new.issued_at := old.issued_at;
  new.sent_at := old.sent_at;
  new.paid_at := old.paid_at;
  new.voided_at := old.voided_at;
  new.void_reason := old.void_reason;
  new.created_by := old.created_by;

  if old.status = 'void'
     and (new.notes, new.terms, new.due_at, new.discount_kind, new.discount_value, new.tax_rate_bps)
         is distinct from (old.notes, old.terms, old.due_at, old.discount_kind, old.discount_value, old.tax_rate_bps) then
    raise exception 'void invoices cannot be edited' using errcode = '23514';
  end if;
  if (new.discount_kind, new.discount_value, new.tax_rate_bps)
       is distinct from (old.discount_kind, old.discount_value, old.tax_rate_bps)
     and not (old.status in ('draft', 'open') or (old.status = 'paid' and old.amount_paid_cents = 0)) then
    raise exception 'pricing of a % invoice with payments cannot be changed', old.status using errcode = '23514';
  end if;
  if (new.discount_kind, new.discount_value, new.tax_rate_bps)
       is distinct from (old.discount_kind, old.discount_value, old.tax_rate_bps)
     and exists (select 1 from public.payments p
                 where p.invoice_id = old.id and p.shop_id = old.shop_id
                   and public.payment_in_flight(p.status, p.created_at)) then
    raise exception 'a payment is in progress on this invoice' using errcode = '23514';
  end if;
  return new;
end
$$;

-- 20: numbering and server defaults.
create function public.invoices_integrity() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.number := public.next_document_number(new.shop_id, 'invoice');
    if new.tax_rate_bps is null then
      select s.tax_rate_bps into new.tax_rate_bps from public.shops s where s.id = new.shop_id;
    end if;
    if new.terms is null then
      select s.invoice_terms into new.terms from public.shops s where s.id = new.shop_id;
    end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    new.number := old.number;
    new.created_by := public.audit_user_ref(new.created_by, old.created_by);
    new.public_token := old.public_token;
  end if;
  return new;
end
$$;

-- 40: totals, paid amounts, balance and derived status (the only place this
-- math lives; line and payment triggers just touch the invoice).
create function public.invoices_compute() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t         public.document_totals;
  v_paid      bigint;
  v_tip       bigint;
  v_last_paid timestamptz;
  v_due_days  integer;
  v_tz        text;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'void' and new.status <> 'void' then
      raise exception 'void invoices cannot be reopened' using errcode = '23514';
    end if;
    if old.status <> 'draft' and new.status = 'draft' then
      raise exception 'an issued invoice cannot return to draft' using errcode = '23514';
    end if;
  end if;

  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(jsonb_build_object(
                             'quantity', li.quantity,
                             'unit_price_cents', li.unit_price_cents,
                             'discount_cents', li.discount_cents,
                             'taxable', li.taxable)), '[]'::jsonb)
              from public.invoice_line_items li
             where li.invoice_id = new.id and li.shop_id = new.shop_id),
           new.discount_kind, new.discount_value, new.tax_rate_bps);
  new.subtotal_cents := v_t.subtotal_cents;
  new.discount_cents := v_t.discount_cents;
  new.tax_cents := v_t.tax_cents;
  new.total_cents := v_t.total_cents;

  select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         max(p.paid_at) filter (where public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents) > 0)
    into v_paid, v_tip, v_last_paid
    from public.payments p
   where p.invoice_id = new.id and p.shop_id = new.shop_id;
  new.amount_paid_cents := v_paid;
  new.tip_cents := v_tip;
  new.balance_cents := new.total_cents - v_paid;

  if new.status = 'draft' and v_paid > 0 then
    new.status := 'open';   -- money received: the invoice is real now
  end if;

  if new.status in ('open', 'partially_paid', 'paid') then
    if new.issued_at is null then
      new.issued_at := now();
    end if;
    if new.due_at is null then
      -- due at the END of the local due date (issue date + due days in the
      -- shop's timezone): 0 days = due on receipt, overdue from the next
      -- local midnight, so report_outstanding's days_past_due reads 1 on the
      -- first overdue day
      select s.invoice_due_days, s.timezone into v_due_days, v_tz from public.shops s where s.id = new.shop_id;
      v_tz := coalesce(v_tz, 'UTC');
      new.due_at := (((new.issued_at at time zone v_tz)::date + coalesce(v_due_days, 0))::timestamp
                     + time '23:59:59') at time zone v_tz;
    end if;
    new.status := case
      when new.balance_cents <= 0 then 'paid'
      when v_paid > 0 then 'partially_paid'
      else 'open'
    end;
    if new.status = 'paid' then
      if tg_op = 'INSERT' or old.status <> 'paid' or old.paid_at is null then
        -- the payment that settled it; a zero-total invoice is settled when issued
        new.paid_at := coalesce(v_last_paid, new.issued_at);
      else
        new.paid_at := old.paid_at;
      end if;
    else
      new.paid_at := null;
    end if;
  end if;
  return new;
end
$$;

-- AFTER: a job invoice belongs to the job's customer.
create function public.invoices_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.job_id is not null
     and (tg_op = 'INSERT' or new.job_id is distinct from old.job_id or new.customer_id is distinct from old.customer_id)
     and not exists (select 1 from public.jobs j
                     where j.id = new.job_id and j.shop_id = new.shop_id and j.customer_id = new.customer_id) then
    raise exception 'the invoice customer must be the job''s customer' using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger invoices_05_prevent_shop_change before update on public.invoices
  for each row execute function public.prevent_shop_change();
create trigger invoices_10_client_guard before insert or update on public.invoices
  for each row execute function public.invoices_client_guard();
create trigger invoices_20_integrity before insert or update on public.invoices
  for each row execute function public.invoices_integrity();
create trigger invoices_40_compute before insert or update on public.invoices
  for each row execute function public.invoices_compute();
create trigger invoices_90_set_updated_at before update on public.invoices
  for each row execute function public.set_updated_at();
create trigger invoices_validate after insert or update on public.invoices
  for each row execute function public.invoices_validate();

-- ---------------------------------------------------------------------------
-- invoice_line_items triggers
-- ---------------------------------------------------------------------------

-- In every context: lines change only while no money is on the invoice (see
-- header). Cascading deletes (invoice or shop being deleted) pass, and so do
-- the ON DELETE SET NULL updates Postgres issues when a referenced service or
-- vehicle is deleted (trusted context, only service_id / vehicle_id cleared:
-- the line keeps its name and price snapshot).
-- The invoice row is locked before it is checked: a line change waits for a
-- payment being recorded (record_manual_payment / payments_before_write lock
-- the invoice as well) and then sees the money.
-- SECURITY INVOKER on purpose: for direct (client) writes the invoice and
-- payment lookups go through RLS, so rows of other shops are simply not
-- found and the write is rejected by RLS/FKs without revealing their state.
create function public.invoice_line_items_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_inv   record;
  v_id    uuid;
  c_links constant text[] := array['service_id', 'vehicle_id', 'updated_at', 'total_cents'];
begin
  if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then
    raise exception 'line items cannot move between invoices' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and not public.is_client_context()
     and (new.service_id is null or new.service_id = old.service_id)
     and (new.vehicle_id is null or new.vehicle_id = old.vehicle_id)
     and (to_jsonb(new) - c_links) = (to_jsonb(old) - c_links) then
    return new;
  end if;
  v_id := case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end;
  -- named columns: SECURITY INVOKER, and authenticated may not read
  -- invoices.public_token (0015)
  select i.id, i.shop_id, i.status, i.amount_paid_cents into v_inv from public.invoices i
   where i.id = v_id and i.shop_id = case when tg_op = 'DELETE' then old.shop_id else new.shop_id end
     for no key update;
  if not found then
    -- insert: the composite FK rejects it; delete: the invoice is being deleted
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if v_inv.status = 'void' then
    raise exception 'line items of a void invoice cannot be changed' using errcode = '23514';
  end if;
  if v_inv.amount_paid_cents <> 0 or v_inv.status not in ('draft', 'open', 'paid') then
    raise exception 'line items cannot change once payments have been received (invoice is %)', v_inv.status
      using errcode = '23514';
  end if;
  if exists (select 1 from public.payments p
             where p.invoice_id = v_inv.id and p.shop_id = v_inv.shop_id
               and public.payment_in_flight(p.status, p.created_at)) then
    raise exception 'a payment is in progress on this invoice' using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

create function public.invoice_line_items_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.name is null and new.service_id is not null then
    select s.name into new.name from public.services s where s.id = new.service_id and s.shop_id = new.shop_id;
  end if;
  return new;
end
$$;

create function public.invoice_line_items_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id)
     and not exists (select 1
                     from public.invoices i
                     join public.vehicles v on v.customer_id = i.customer_id and v.shop_id = i.shop_id
                     where i.id = new.invoice_id and i.shop_id = new.shop_id and v.id = new.vehicle_id) then
    raise exception 'the vehicle does not belong to this invoice''s customer' using errcode = '23514';
  end if;
  return null;
end
$$;

create function public.invoice_line_items_touch_invoice() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.invoices set updated_at = now()
   where id = case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end
     and shop_id = case when tg_op = 'DELETE' then old.shop_id else new.shop_id end;
  return null;
end
$$;

create trigger invoice_line_items_05_prevent_shop_change before update on public.invoice_line_items
  for each row execute function public.prevent_shop_change();
create trigger invoice_line_items_10_guard before insert or update or delete on public.invoice_line_items
  for each row execute function public.invoice_line_items_guard();
create trigger invoice_line_items_20_before_write before insert or update on public.invoice_line_items
  for each row execute function public.invoice_line_items_before_write();
create trigger invoice_line_items_90_set_updated_at before update on public.invoice_line_items
  for each row execute function public.set_updated_at();
create trigger invoice_line_items_touch_invoice after insert or update or delete on public.invoice_line_items
  for each row execute function public.invoice_line_items_touch_invoice();
create trigger invoice_line_items_validate after insert or update on public.invoice_line_items
  for each row execute function public.invoice_line_items_validate();

-- ---------------------------------------------------------------------------
-- payments triggers
-- ---------------------------------------------------------------------------

-- Linkage is derived, never trusted:
--   * a job payment without an invoice attaches to the job's non-void invoice
--   * an invoice payment takes the invoice's job and customer
--   * otherwise the customer comes from the job / membership
-- Supplied values that contradict the parent are rejected.
-- Money never lands on a void invoice (see header): when a payment is
-- recorded for one, moved onto one, or becomes received — or its net amount
-- rises again (a failed Stripe refund) — while still pointing at one, a job
-- payment goes back to its job (and so to the job's current
-- invoice, if any); a payment for an invoice without a job — or for a job
-- that has since changed customer — stays with the invoice's customer,
-- unapplied, with a note saying so.
-- Locks, always in the order job → invoice (as create_invoice_from_job and
-- void_invoice take them): looking up a job's invoice first locks the job,
-- so a payment recorded while create_invoice_from_job runs waits for it and
-- then attaches to the new invoice; the target invoice is locked so line /
-- pricing guards and manual payments serialize with the payment.
create function public.payments_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job     uuid;
  v_cust    uuid;
  v_status  public.invoice_status;
  v_number  bigint;
  v_job_cust uuid;
begin
  if new.invoice_id is not null
     and (tg_op = 'INSERT'
          or new.invoice_id is distinct from old.invoice_id
          or (new.status in ('succeeded', 'partially_refunded', 'refunded')
              and old.status not in ('succeeded', 'partially_refunded', 'refunded'))
          -- received again: a refund that failed at Stripe (refund.failed
          -- lowers refunded_cents, e.g. refunded -> succeeded) puts money
          -- back on the payment
          or public.payment_net_amount(new.status, new.amount_cents, new.tip_cents, new.refunded_cents)
             + public.payment_net_tip(new.status, new.amount_cents, new.tip_cents, new.refunded_cents)
             > public.payment_net_amount(old.status, old.amount_cents, old.tip_cents, old.refunded_cents)
             + public.payment_net_tip(old.status, old.amount_cents, old.tip_cents, old.refunded_cents)) then
    select i.status, i.job_id, i.customer_id, i.number into v_status, v_job, v_cust, v_number
      from public.invoices i where i.id = new.invoice_id and i.shop_id = new.shop_id;
    if found and v_status = 'void' then
      if new.job_id is not null and new.job_id is distinct from v_job then
        raise exception 'payment job does not match the invoice''s job' using errcode = '23514';
      end if;
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the invoice''s customer' using errcode = '23514';
      end if;
      if v_job is not null then
        select j.customer_id into v_job_cust from public.jobs j where j.id = v_job and j.shop_id = new.shop_id;
      end if;
      new.invoice_id := null;
      new.customer_id := v_cust;
      if v_job is not null and v_job_cust = v_cust then
        new.job_id := v_job;
      else
        new.job_id := null;
        new.note := coalesce(new.note,
          format('Received for void invoice #%s: apply it to another invoice or refund it', v_number));
      end if;
    end if;
  end if;

  if new.invoice_id is null and new.job_id is not null then
    perform 1 from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id for no key update;
    select i.id into new.invoice_id
      from public.invoices i
     where i.shop_id = new.shop_id and i.job_id = new.job_id and i.status <> 'void';
  end if;

  if new.invoice_id is not null then
    select i.job_id, i.customer_id into v_job, v_cust
      from public.invoices i where i.id = new.invoice_id and i.shop_id = new.shop_id
       for no key update;
    if found then
      if new.job_id is not null and new.job_id is distinct from v_job then
        raise exception 'payment job does not match the invoice''s job' using errcode = '23514';
      end if;
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the invoice''s customer' using errcode = '23514';
      end if;
      new.job_id := v_job;
      new.customer_id := v_cust;
    end if;
  elsif new.job_id is not null then
    select j.customer_id into v_cust from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
    if found then
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the job''s customer' using errcode = '23514';
      end if;
      new.customer_id := v_cust;
    end if;
  end if;

  if new.membership_id is not null then
    select m.customer_id into v_cust from public.memberships m where m.id = new.membership_id and m.shop_id = new.shop_id;
    if found then
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the membership''s customer' using errcode = '23514';
      end if;
      new.customer_id := v_cust;
    end if;
  end if;

  if new.status in ('succeeded', 'partially_refunded', 'refunded') and new.paid_at is null then
    new.paid_at := now();
  end if;
  new.card_brand := lower(nullif(btrim(new.card_brand), ''));
  new.note := nullif(btrim(new.note), '');
  if tg_op = 'UPDATE' then
    new.recorded_by := public.audit_user_ref(new.recorded_by, old.recorded_by);
  end if;
  return new;
end
$$;

-- Recompute every affected invoice.
create function public.payments_touch_invoice() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.invoice_id is not null
     and old.invoice_id::text = current_setting('detail_crm.deleting_invoice', true) then
    return null;   -- a dead attempt removed with its invoice (payments_delete_dead_for_parent)
  end if;
  if tg_op in ('UPDATE', 'DELETE') and old.invoice_id is not null then
    update public.invoices set updated_at = now() where id = old.invoice_id and shop_id = old.shop_id;
  end if;
  if tg_op = 'INSERT' and new.invoice_id is not null
     or tg_op = 'UPDATE' and new.invoice_id is not null
        and (new.invoice_id is distinct from old.invoice_id) then
    update public.invoices set updated_at = now() where id = new.invoice_id and shop_id = new.shop_id;
  end if;
  return null;
end
$$;

create trigger payments_05_prevent_shop_change before update on public.payments
  for each row execute function public.prevent_shop_change();
create trigger payments_20_before_write before insert or update on public.payments
  for each row execute function public.payments_before_write();
create trigger payments_90_set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();
create trigger payments_touch_invoice after insert or update or delete on public.payments
  for each row execute function public.payments_touch_invoice();

-- ---------------------------------------------------------------------------
-- jobs: a job with money on it keeps its customer (0006 cannot know about
-- invoices/payments). Only real money counts: received payments (even when
-- refunded since — the history stays with its customer) and payments in
-- flight. A failed / cancelled / abandoned attempt does not pin the customer.
-- ---------------------------------------------------------------------------
create function public.jobs_money_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.customer_id is distinct from old.customer_id
     and (exists (select 1 from public.invoices i
                  where i.job_id = new.id and i.shop_id = new.shop_id and i.status <> 'void')
          or exists (select 1 from public.payments p
                     where p.job_id = new.id and p.shop_id = new.shop_id
                       and (p.status in ('succeeded', 'partially_refunded', 'refunded')
                            or public.payment_in_flight(p.status, p.created_at)))) then
    raise exception 'this job has an invoice or payments; its customer cannot change' using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger jobs_money_guard after update of customer_id on public.jobs
  for each row execute function public.jobs_money_guard();

-- jobs: a different customer never inherits the previous customer's
-- /booking link (all contexts; runs after jobs_10_client_guard, which keeps
-- clients from choosing the token themselves).
create function public.jobs_customer_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.customer_id is distinct from old.customer_id then
    new.public_token := gen_random_uuid();
  end if;
  return new;
end
$$;

create trigger jobs_15_customer_change before update on public.jobs
  for each row execute function public.jobs_customer_change();

-- ---------------------------------------------------------------------------
-- jobs: coupons (SPEC §4.3 / §4.5 — the document discount is "coupon or
-- manual"). A staff write (client context) that attaches a coupon redeems it:
-- the coupon must be active, inside its window, under max_redemptions and not
-- online_only; redemptions is incremented under the coupon's row lock and the
-- job's discount is derived from the coupon (jobs_40_compute_totals then
-- applies it). Removing or replacing the coupon releases its redemption and,
-- unless a manual discount is set in the same write, removes its discount.
-- While a coupon is attached its discount cannot be edited by hand. Once the
-- job has a non-void invoice its coupon is frozen (the discount was billed).
-- Trusted code manages coupons itself (create_online_booking redeems and
-- sets the discount; ON DELETE SET NULL of a deleted coupon keeps the
-- discount the job already received).
-- The helpers run as the owner (coupon writes are admin-only under RLS) and
-- refuse to run outside a trigger, so they cannot be called as RPCs.
-- ---------------------------------------------------------------------------
create function public.coupon_redeem_for_job(p_shop_id uuid, p_coupon_id uuid) returns public.coupons
language plpgsql security definer
set search_path = ''
as $$
declare
  v_c public.coupons;
begin
  if pg_catalog.pg_trigger_depth() = 0 or not public.is_shop_manager(p_shop_id) then
    raise exception 'coupons are applied by setting the job''s coupon' using errcode = '42501';
  end if;
  select * into v_c from public.coupons c where c.id = p_coupon_id and c.shop_id = p_shop_id for update;
  if not found then
    return null;   -- another shop's coupon: the composite FK rejects the write
  end if;
  if not v_c.active then
    raise exception 'coupon % is no longer active', v_c.code using errcode = '23514';
  end if;
  if v_c.starts_at is not null and now() < v_c.starts_at then
    raise exception 'coupon % is not active yet', v_c.code using errcode = '23514';
  end if;
  if v_c.ends_at is not null and now() >= v_c.ends_at then
    raise exception 'coupon % has expired', v_c.code using errcode = '23514';
  end if;
  if v_c.online_only then
    raise exception 'coupon % can only be used for online bookings', v_c.code using errcode = '23514';
  end if;
  if v_c.max_redemptions is not null and v_c.redemptions >= v_c.max_redemptions then
    raise exception 'coupon % has been fully redeemed', v_c.code using errcode = '23514';
  end if;
  update public.coupons c set redemptions = c.redemptions + 1 where c.id = v_c.id returning * into v_c;
  return v_c;
end
$$;

create function public.coupon_release_for_job(p_shop_id uuid, p_coupon_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if pg_catalog.pg_trigger_depth() = 0 or not public.is_shop_manager(p_shop_id) then
    raise exception 'coupons are released by removing the job''s coupon' using errcode = '42501';
  end if;
  update public.coupons c
     set redemptions = greatest(c.redemptions - 1, 0)
   where c.id = p_coupon_id and c.shop_id = p_shop_id;
end
$$;

-- SECURITY INVOKER so is_client_context() sees the caller (only managers+
-- reach the coupon logic: jobs_10_client_guard stops technicians, and
-- managers+ read every invoice of their shop).
-- The coupon of a job with a non-void invoice is frozen: the invoice copied
-- its discount (create_invoice_from_job), so the redemption was billed and is
-- never given back, and a coupon attached now would be used up without ever
-- reaching the invoice. Void the invoice (or delete a draft) first. The job
-- row is locked by this write, and create_invoice_from_job locks it too, so
-- an invoice cannot appear between the check and the release / redemption.
create function public.jobs_apply_coupon() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_c       public.coupons;
  v_invoice bigint;
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.coupon_id is not distinct from old.coupon_id then
    if new.coupon_id is not null
       and (new.discount_kind, new.discount_value) is distinct from (old.discount_kind, old.discount_value) then
      raise exception 'this job''s discount comes from its coupon; remove the coupon to set a manual discount'
        using errcode = '23514';
    end if;
    return new;
  end if;
  if tg_op = 'UPDATE' then
    select i.number into v_invoice
      from public.invoices i
     where i.shop_id = old.shop_id and i.job_id = old.id and i.status <> 'void'
     limit 1;
    if found then
      raise exception 'this job is billed on invoice #%; its coupon cannot change until that invoice is void', v_invoice
        using errcode = '23514';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.coupon_id is not null then
    perform public.coupon_release_for_job(old.shop_id, old.coupon_id);
    if (new.discount_kind, new.discount_value) is not distinct from (old.discount_kind, old.discount_value) then
      new.discount_kind := 'none';
      new.discount_value := 0;
    end if;
  end if;
  if new.coupon_id is not null then
    v_c := public.coupon_redeem_for_job(new.shop_id, new.coupon_id);
    if v_c.id is not null then
      new.discount_kind := v_c.kind::text::public.discount_kind;
      new.discount_value := v_c.value;
    end if;
  end if;
  return new;
end
$$;

create trigger jobs_35_apply_coupon before insert or update on public.jobs
  for each row execute function public.jobs_apply_coupon();

-- Deleting a job gives its coupon's redemption back, in every context: every
-- job that carries a coupon consumed one redemption (staff writes through
-- jobs_apply_coupon, online bookings in create_online_booking), and a job
-- deleted by mistake must not use up a limited coupon. Jobs with invoices or
-- payments cannot be deleted (RESTRICT), so a billed redemption is never
-- released. Runs as the owner (coupon writes are admin-only under RLS); the
-- delete itself was already authorized by the jobs policies. When the whole
-- shop is deleted the coupon may already be gone: nothing to update then.
create function public.jobs_release_coupon_on_delete() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.coupons c
     set redemptions = greatest(c.redemptions - 1, 0)
   where c.id = old.coupon_id and c.shop_id = old.shop_id;
  return null;
end
$$;

create trigger jobs_zz_release_coupon after delete on public.jobs
  for each row when (old.coupon_id is not null)
  execute function public.jobs_release_coupon_on_delete();

-- ---------------------------------------------------------------------------
-- Dead payment attempts never block deletes. payments RESTRICTs the deletion
-- of its job / invoice / customer so money records survive, but a failed or
-- cancelled attempt that never moved money (refunded_cents = 0, no paid_at)
-- is not a money record: it is removed with its parent (these triggers run
-- as the owner — authorization for the parent's delete was already checked
-- by its own policies). RESTRICT then protects only real or in-flight money.
-- A pending payment (in flight or abandoned) is kept: the sweep / webhook
-- resolves it first.
-- ---------------------------------------------------------------------------
create function public.payments_delete_dead_for_parent() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'invoices' then
    -- the invoice row itself is being deleted: payments_touch_invoice must
    -- not update it (a BEFORE DELETE trigger may not modify its own row)
    perform set_config('detail_crm.deleting_invoice', old.id::text, true);
    delete from public.payments p
     where p.shop_id = old.shop_id and p.invoice_id = old.id
       and p.status in ('failed', 'cancelled') and p.refunded_cents = 0 and p.paid_at is null;
    perform set_config('detail_crm.deleting_invoice', '', true);
  elsif tg_table_name = 'jobs' then
    delete from public.payments p
     where p.shop_id = old.shop_id and p.job_id = old.id
       and p.status in ('failed', 'cancelled') and p.refunded_cents = 0 and p.paid_at is null;
  elsif tg_table_name = 'customers' then
    delete from public.payments p
     where p.shop_id = old.shop_id and p.customer_id = old.id
       and p.status in ('failed', 'cancelled') and p.refunded_cents = 0 and p.paid_at is null;
  end if;
  return old;
end
$$;

create trigger jobs_07_delete_dead_payments before delete on public.jobs
  for each row execute function public.payments_delete_dead_for_parent();
create trigger invoices_07_delete_dead_payments before delete on public.invoices
  for each row execute function public.payments_delete_dead_for_parent();
create trigger customers_07_delete_dead_payments before delete on public.customers
  for each row execute function public.payments_delete_dead_for_parent();

-- ---------------------------------------------------------------------------
-- shops: deleting a shop cascades through its memberships and payments, but
-- the Stripe objects on its connected account live on. A subscription would
-- keep charging the customer every period while the webhook, which can no
-- longer find the shop or the membership, records nothing — and nobody can
-- cancel it from the CRM any more. So, in every context (the owner's
-- PostgREST DELETE, service_role, a direct database session), a shop cannot
-- be deleted while:
--   * any membership is not cancelled: an active / past_due one bills through
--     its subscription, and an incomplete one may have a payable
--     subscription-mode Checkout link (membership_checkout). Cancelling each
--     one through membership_cancel stops the subscription or expires the
--     links first;
--   * a card payment is in flight (public.payment_in_flight): a PaymentSheet
--     being confirmed would move money that is never recorded.
-- (Invoice / deposit Checkout links have no row until paid; they expire
-- within the hour and an orphaned one charges once at most.)
-- The row lock on the shop is taken by the DELETE itself, and new
-- memberships / payments need the shop row (FK key-share lock), so nothing
-- can be added between this check and the cascade.
-- ---------------------------------------------------------------------------
create function public.shops_money_delete_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_open bigint;
begin
  select count(*) into v_open
    from public.memberships m
   where m.shop_id = old.id and m.status <> 'cancelled';
  if v_open > 0 then
    raise exception 'this shop has % membership(s) that are not cancelled; cancel them first so their Stripe billing stops',
      v_open using errcode = '55000';
  end if;
  if exists (select 1 from public.payments p
             where p.shop_id = old.id and public.payment_in_flight(p.status, p.created_at)) then
    raise exception 'a card payment is in progress for this shop; wait for it to finish before deleting the shop'
      using errcode = '55000';
  end if;
  return old;
end
$$;

create trigger shops_20_money_delete_guard before delete on public.shops
  for each row execute function public.shops_money_delete_guard();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.invoices           enable row level security;
alter table public.invoice_line_items enable row level security;
alter table public.payments           enable row level security;

-- invoices: manager+ everything (inserts via RPCs); technicians read the
-- invoice of an assigned job when the shop lets them collect payments.
create policy invoices_select on public.invoices for select to authenticated
  using (public.is_shop_manager(shop_id)
         or (job_id is not null and public.can_collect_for_job(shop_id, job_id)));
create policy invoices_update on public.invoices for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy invoices_delete on public.invoices for delete to authenticated
  using (public.is_shop_manager(shop_id) and status = 'draft');

create policy invoice_line_items_select on public.invoice_line_items for select to authenticated
  using (public.can_collect_for_invoice(shop_id, invoice_id));
create policy invoice_line_items_insert on public.invoice_line_items for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy invoice_line_items_update on public.invoice_line_items for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy invoice_line_items_delete on public.invoice_line_items for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- payments: read-only for clients.
create policy payments_select on public.payments for select to authenticated
  using (public.is_shop_manager(shop_id)
         or (job_id is not null and public.can_collect_for_job(shop_id, job_id)));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.invoices, public.invoice_line_items, public.payments from anon;
revoke insert on public.invoices from authenticated;
revoke insert, update, delete on public.payments from authenticated;

revoke execute on function
  public.invoices_client_guard(),
  public.invoices_integrity(),
  public.invoices_compute(),
  public.invoices_validate(),
  public.invoice_line_items_guard(),
  public.invoice_line_items_before_write(),
  public.invoice_line_items_validate(),
  public.invoice_line_items_touch_invoice(),
  public.payments_before_write(),
  public.payments_touch_invoice(),
  public.jobs_money_guard(),
  public.jobs_customer_change(),
  public.jobs_apply_coupon(),
  public.jobs_release_coupon_on_delete(),
  public.payments_delete_dead_for_parent(),
  public.shops_money_delete_guard()
from public, anon, authenticated;

-- Called from the SECURITY INVOKER jobs_apply_coupon trigger, so staff need
-- EXECUTE; the functions themselves refuse to run outside a trigger.
revoke execute on function
  public.coupon_redeem_for_job(uuid, uuid),
  public.coupon_release_for_job(uuid, uuid)
from public, anon;
grant execute on function
  public.coupon_redeem_for_job(uuid, uuid),
  public.coupon_release_for_job(uuid, uuid)
to authenticated, service_role;

revoke execute on function
  public.can_collect_for_job(uuid, uuid),
  public.can_collect_for_invoice(uuid, uuid)
from public, anon;
grant execute on function
  public.can_collect_for_job(uuid, uuid),
  public.can_collect_for_invoice(uuid, uuid)
to authenticated, service_role;
