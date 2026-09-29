-- ============================================================================
-- 0116 — Voiding an invoice, or cutting its price, waits for its open card
-- pay pages (as cash, checks and gift cards do since 0109).
--
-- 0109 held every open /i pay link (invoice_checkout_holds) and deposit link
-- (job_checkout_holds), but only record_manual_payment and
-- gift_card_redeem_core looked at the holds (money_refuse_open_checkout).
-- An open Checkout Session has no payments row, so:
--   * void_invoice (0063 body), which refused only payment rows in flight,
--     voided an invoice whose page the customer could still pay for 30-40
--     minutes. The staff re-invoiced the job and took cash on the new
--     invoice (whose own holds do not include the void invoice's page); the
--     customer then paid the old page and payments_before_write moved that
--     payment onto the job's live invoice: paid twice. With no job (grouped
--     invoice) the money was kept as an unapplied customer payment.
--   * invoice line edits (invoice_line_items_guard, 0063 body) and invoice
--     discount / tax edits (invoices_client_guard, 0012) lowered the total
--     below the amount the open page charges: a negative balance
--     (overpayment) as soon as it was paid.
-- Now, while the invoice or a job it bills has a live hold (expires_at >
-- now()), each of these fails exactly like a manual payment does:
--     55000 'a card payment page for this invoice is still open (until
--            <time>); cancel the open payments first, or wait until then'
--     HINT  'checkout_open'
-- and the staff apps call the payments edge cancel_open_payments
-- (invoice_id) — which expires those sessions and releases exactly these
-- holds — then retry.
--   * void_invoice: money_refuse_open_checkout after the invoice is locked
--     (the lock payments_hold_invoice_checkout takes, so a pay link opened
--     meanwhile is either seen here or refused as invoice_closed).
--   * invoice_line_items_11_open_checkout (new, before update / delete,
--     SECURITY DEFINER: the holds are service_role only): changing a line's
--     quantity, unit price, discount or taxable flag, or deleting a line.
--     Adding a line (a fee, a forgotten service) can only raise the total and
--     stays allowed; so do edits that touch no money column (name,
--     description, sort, links) and the cascades of a deleted invoice or shop.
--   * invoices_15_open_checkout (new, before update of discount_kind,
--     discount_value, tax_rate_bps; SECURITY DEFINER): the invoice's
--     discount or tax rate.
-- With void refused while a hold is live, a void invoice never has a live
-- hold (payments_hold_invoice_checkout refuses a void invoice), so the
-- replacement invoice's holds are the only ones that matter.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- void_invoice — 0063 body + money_refuse_open_checkout.
-- ---------------------------------------------------------------------------
create or replace function public.void_invoice(p_invoice_id uuid, p_reason text default null) returns public.invoices
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
  perform 1 from public.jobs j
   where j.shop_id = v_inv.shop_id
     and (j.id = v_inv.job_id
          or j.id in (select ij.job_id from public.invoice_jobs ij
                       where ij.invoice_id = v_inv.id and ij.shop_id = v_inv.shop_id))
   order by j.id for no key update;
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
  -- 0116: an open pay page of the invoice (or a deposit page of one of its
  -- jobs) could still be paid after the void
  perform public.money_refuse_open_checkout(v_inv);
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

comment on function public.void_invoice(uuid, text) is
  'Owner/admin: void an invoice (reason optional, max 1000). Grouped invoices: every job is locked first (id order, before the invoice — the order payments use), each job payment goes back to its job, and the jobs are released (invoice_jobs.voided, by trigger). 22023 when already void, while a card payment is in progress, or while payments without a job are kept on it (refund them first); job payments go back to their job. 55000 HINT checkout_open while a card pay page of the invoice (or a deposit page of one of its jobs) can still be paid (0116; cancel_open_payments first).';

-- ---------------------------------------------------------------------------
-- invoice_line_items_11_open_checkout
-- ---------------------------------------------------------------------------
create function public.invoice_line_items_open_checkout_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  if tg_op = 'UPDATE'
     and (new.quantity, new.unit_price_cents, new.discount_cents, new.taxable)
         is not distinct from (old.quantity, old.unit_price_cents, old.discount_cents, old.taxable) then
    return new;
  end if;
  -- the cascade of a deleted shop or invoice: nothing is left to pay
  if not exists (select 1 from public.shops s where s.id = old.shop_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  select * into v_inv from public.invoices i where i.id = old.invoice_id and i.shop_id = old.shop_id;
  if found and v_inv.status <> 'void' then
    perform public.money_refuse_open_checkout(v_inv);
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

comment on function public.invoice_line_items_open_checkout_guard() is
  'Internal (0116): a line''s quantity / unit price / discount / taxable flag cannot change, and a line cannot be deleted, while a card pay page of its invoice (or a deposit page of a job it bills) can still be paid: 55000 HINT checkout_open.';
revoke execute on function public.invoice_line_items_open_checkout_guard() from public, anon, authenticated;

create trigger invoice_line_items_11_open_checkout before update or delete on public.invoice_line_items
  for each row execute function public.invoice_line_items_open_checkout_guard();

-- ---------------------------------------------------------------------------
-- invoices_15_open_checkout
-- ---------------------------------------------------------------------------
create function public.invoices_open_checkout_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if (new.discount_kind, new.discount_value, new.tax_rate_bps)
       is distinct from (old.discount_kind, old.discount_value, old.tax_rate_bps)
     and old.status <> 'void' then
    perform public.money_refuse_open_checkout(old);
  end if;
  return new;
end
$$;

comment on function public.invoices_open_checkout_guard() is
  'Internal (0116): an invoice''s discount or tax rate cannot change while a card pay page of it (or a deposit page of a job it bills) can still be paid: 55000 HINT checkout_open.';
revoke execute on function public.invoices_open_checkout_guard() from public, anon, authenticated;

create trigger invoices_15_open_checkout before update of discount_kind, discount_value, tax_rate_bps on public.invoices
  for each row execute function public.invoices_open_checkout_guard();

comment on function public.money_refuse_open_checkout(public.invoices) is
  'Internal (0109): raises 55000 HINT checkout_open while the invoice or a job it bills has a live Checkout Session hold (invoice_checkout_holds / job_checkout_holds). Callers: record_manual_payment, gift_card_redeem_core (0109); void_invoice, invoice line and invoice discount / tax edits (0116).';
