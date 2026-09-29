-- ============================================================================
-- 0118 — A job's price and deposit wait for its open deposit pages; a
-- deposit page is held only while the deposit is still due; an invoice
-- line's discount eligibility waits like its price (0106 / 0109 / 0116).
--
-- 1. Job price cuts and deposit waivers wait for open card pay pages
--    An open deposit Checkout page (booking or quote deposit) is held in
--    job_checkout_holds (0106), but only the customer's online cancel and
--    manual money on an invoice (money_refuse_open_checkout, 0109) looked
--    at it; 0116 guarded invoice price cuts only. Before a job is invoiced
--    — exactly when deposit pages are open — staff could lower the job's
--    total (a line's price / quantity / discount, a deleted line, a coupon
--    or discount, a lower tax rate) or lower / waive deposit_required_cents
--    while the customer's page for the old deposit could still be paid for
--    32-42 minutes. The page charges what it was opened for, so the job
--    (and the invoice made from it) ended with a negative balance — the
--    whole price correction overpaid for a shop taking full prepayment.
--    Now jobs_98_open_checkout (new, AFTER UPDATE, every context, SECURITY
--    DEFINER: the holds are service_role only) refuses, while the job has a
--    live hold (expires_at > now()), any update that LOWERS the job's
--    total_cents or deposit_required_cents:
--        55000 'a card payment page for this job is still open (until
--               <time>); cancel the open payments first, or wait until then'
--        HINT  'checkout_open'
--    The job's total is recomputed on every line write (the line's
--    touch-job update), so this covers every way a total goes down (lines,
--    coupon, discount, tax rate, membership lines) at the one place the
--    total lands. What cannot lower it stays allowed: adding a line,
--    raising a price (a membership that stops covering a visit reprices it
--    up, 0108), notes, schedule, assignees. The staff apps call the
--    payments edge cancel_open_payments (job_id) — which expires the job's
--    open sessions and releases these holds — then retry.
--    job_open_checkout_until(shop, job) (internal): the latest expiry of the
--    job's live holds, null when none.
--
-- 2. payments_hold_job_checkout re-checks the deposit under the locks
--    The edge reads the deposit still due, then creates the Stripe session,
--    and only then holds it. The hold (0106) locked the job and refused
--    only a closed job, so cash / a check / a gift card recorded on the
--    job's invoice in between (record_manual_payment takes the INVOICE
--    lock; no hold existed yet) was followed by an accepted hold, and the
--    page then overpaid the invoice by the deposit. The invoice pay link
--    hold (payments_hold_invoice_checkout, 0109) already re-checks under
--    the invoice lock. Now (same name; the old 4-argument signature is
--    replaced by one with an optional 5th argument, so existing callers
--    are unchanged):
--      payments_hold_job_checkout(shop, job, session, expires_at,
--                                 p_amount_cents bigint default null)
--    for a DEPOSIT page (a session that is not also held for an invoice —
--    an /i pay link is held on its invoice first, which checked the
--    balance) locks the job's live invoice(s) after the job (the lock every
--    manual payment and gift card redemption takes: one either sees this
--    hold or is already in the amount read below) and refuses (55000; the
--    edge then expires the session instead of returning its URL):
--      HINT deposit_not_due  nothing is due any more
--                            (comms_deposit_due_cents: least(deposit
--                            required, total) - money received / in flight,
--                            capped at what the job's live invoice still
--                            owes);
--      HINT balance_changed  p_amount_cents (the session's amount) exceeds
--                            what is still due.
--    A repeat call for a session already held only extends it (idempotent).
--
-- 3. An invoice line's discount eligibility waits like its price
--    invoice_line_items_open_checkout_guard (0116 body) also refuses a
--    change of discount_eligible while a pay page is open: with a document
--    discount, making a line eligible lowers the total below what the page
--    charges.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- job_open_checkout_until — the latest expiry of the job's live holds
-- ---------------------------------------------------------------------------
create function public.job_open_checkout_until(p_shop_id uuid, p_job_id uuid) returns timestamptz
language sql stable security definer
set search_path = ''
as $$
  select max(h.expires_at)
    from public.job_checkout_holds h
   where h.shop_id = p_shop_id and h.job_id = p_job_id and h.expires_at > now()
$$;

comment on function public.job_open_checkout_until(uuid, uuid) is
  'Internal (0118): the latest expires_at of the job''s live Checkout Session holds (job_checkout_holds, expires_at > now()); null when no card pay page of the job can still be paid.';
revoke execute on function public.job_open_checkout_until(uuid, uuid) from public, anon, authenticated;
grant execute on function public.job_open_checkout_until(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- jobs_98_open_checkout — no lower total / deposit while a page is open
-- ---------------------------------------------------------------------------
create function public.jobs_open_checkout_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_until  timestamptz;
  v_tz     text;
begin
  v_until := public.job_open_checkout_until(new.shop_id, new.id);
  if v_until is not null then
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    raise exception 'a card payment page for this job is still open (until %); cancel the open payments first, or wait until then',
      to_char(v_until at time zone coalesce(v_tz, 'UTC'), 'FMHH12:MI AM')
      using errcode = '55000', hint = 'checkout_open';
  end if;
  return null;
end
$$;

comment on function public.jobs_open_checkout_guard() is
  'Internal (0118): a job''s total_cents or deposit_required_cents cannot go down (line price / quantity / discount edits, deleted lines, coupon, discount, tax rate, a lower or waived deposit) while a card pay page of the job (a deposit page, job_checkout_holds) can still be paid: 55000 HINT checkout_open.';
revoke execute on function public.jobs_open_checkout_guard() from public, anon, authenticated;

create trigger jobs_98_open_checkout after update on public.jobs
  for each row
  when (new.total_cents < old.total_cents or new.deposit_required_cents < old.deposit_required_cents)
  execute function public.jobs_open_checkout_guard();

-- ---------------------------------------------------------------------------
-- payments_hold_job_checkout — 0106 body + the deposit re-check (2)
-- ---------------------------------------------------------------------------
drop function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz);

create function public.payments_hold_job_checkout(
  p_shop_id       uuid,
  p_job_id        uuid,
  p_session_id    text,
  p_expires_at    timestamptz,
  p_amount_cents  bigint default null
) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_due  bigint;
begin
  if p_shop_id is null or p_job_id is null or p_session_id is null or p_expires_at is null then
    raise exception 'shop, job, session and expiry are required' using errcode = '22023';
  end if;
  if p_session_id !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'invalid Checkout Session id' using errcode = '22023';
  end if;
  if p_amount_cents is not null and p_amount_cents <= 0 then
    raise exception 'amount must be greater than zero' using errcode = '22023';
  end if;
  -- the row lock public_cancel_booking takes: a cancel either sees this hold
  -- or has already closed the job (and the hold is refused)
  select * into v_job from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id for update;
  if not found then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if v_job.status in ('cancelled', 'no_show', 'completed') then
    raise exception 'this booking is no longer taking payments' using errcode = '55000', hint = 'booking_closed';
  end if;
  -- 0118: a deposit page (an /i pay link was held on its invoice first, which
  -- re-checked the balance; a session already held here is only extended)
  if not exists (select 1 from public.invoice_checkout_holds ih
                  where ih.stripe_checkout_session_id = p_session_id and ih.shop_id = p_shop_id)
     and not exists (select 1 from public.job_checkout_holds h
                      where h.stripe_checkout_session_id = p_session_id
                        and h.shop_id = p_shop_id and h.job_id = p_job_id) then
    -- the lock record_manual_payment / gift card redemptions take: a manual
    -- payment either sees this hold (money_refuse_open_checkout) or is
    -- already in the amount read below
    perform 1 from public.invoices i
     where i.shop_id = p_shop_id and i.status <> 'void'
       and (i.job_id = p_job_id
            or exists (select 1 from public.invoice_jobs ij
                        where ij.shop_id = p_shop_id and ij.invoice_id = i.id and ij.job_id = p_job_id
                          and not ij.voided))
     order by i.id
       for update;
    v_due := coalesce(public.comms_deposit_due_cents(p_job_id), 0);
    if v_due <= 0 then
      raise exception 'no deposit is due for this booking any more' using errcode = '55000', hint = 'deposit_not_due';
    end if;
    if p_amount_cents is not null and p_amount_cents > v_due then
      raise exception 'this booking''s deposit changed; reload it and try again' using errcode = '55000', hint = 'balance_changed';
    end if;
  end if;
  delete from public.job_checkout_holds h
   where h.shop_id = p_shop_id and h.job_id = p_job_id and h.expires_at <= now();
  insert into public.job_checkout_holds (stripe_checkout_session_id, shop_id, job_id, expires_at)
  values (p_session_id, p_shop_id, p_job_id, p_expires_at)
  on conflict (stripe_checkout_session_id) do update
     set expires_at = greatest(public.job_checkout_holds.expires_at, excluded.expires_at)
   where public.job_checkout_holds.shop_id = excluded.shop_id
     and public.job_checkout_holds.job_id = excluded.job_id;
  if not found then
    raise exception 'Checkout Session % is held for another job', p_session_id using errcode = '22023';
  end if;
end
$$;

comment on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz, bigint) is
  'service_role (payments edge, 0106 / 0118): record an open Checkout Session of a job until p_expires_at, before handing out its URL. Locks the job; 55000 HINT booking_closed when the job is cancelled / no-show / completed. For a deposit page (a session not held for an invoice) it also locks the job''s live invoice(s) and refuses 55000 HINT deposit_not_due (nothing is due any more: comms_deposit_due_cents) or balance_changed (p_amount_cents, the session''s amount, exceeds what is due) — the edge then expires the session. Idempotent per session (a repeat only extends the hold).';
revoke execute on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz, bigint)
  from public, anon, authenticated;
grant execute on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz, bigint) to service_role;

-- ---------------------------------------------------------------------------
-- invoice_line_items_open_checkout_guard — 0116 body + discount_eligible (3)
-- ---------------------------------------------------------------------------
create or replace function public.invoice_line_items_open_checkout_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  if tg_op = 'UPDATE'
     and (new.quantity, new.unit_price_cents, new.discount_cents, new.taxable, new.discount_eligible)
         is not distinct from (old.quantity, old.unit_price_cents, old.discount_cents, old.taxable, old.discount_eligible) then
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
  'Internal (0116 / 0118): a line''s quantity / unit price / discount / taxable flag / discount eligibility cannot change, and a line cannot be deleted, while a card pay page of its invoice (or a deposit page of a job it bills) can still be paid: 55000 HINT checkout_open.';

comment on function public.money_refuse_open_checkout(public.invoices) is
  'Internal (0109): raises 55000 HINT checkout_open while the invoice or a job it bills has a live Checkout Session hold (invoice_checkout_holds / job_checkout_holds). Callers: record_manual_payment, gift_card_redeem_core (0109); void_invoice, invoice line (incl. discount eligibility, 0118) and invoice discount / tax edits (0116). A job''s own price cuts: jobs_open_checkout_guard (0118).';
