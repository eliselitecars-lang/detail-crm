-- ============================================================================
-- 0121 — Money round 9: applied payments wait for open pay pages; a
-- cancelled booking gives its once-per-customer coupon use back; a coupon's
-- service list edit skips jobs with an open deposit page.
--
-- 1. apply_payment_to_invoice waits for open card pay pages
--    0109 / 0116 / 0118 made every way of lowering an invoice's balance wait
--    for its open Stripe pay pages (money_refuse_open_checkout: 55000 HINT
--    checkout_open) — cash, checks, gift cards, store credit, void, line /
--    discount / tax edits — but apply_payment_to_invoice (0013) was missed.
--    It subtracts only payment rows in flight, and an open Checkout Session
--    has no payment row, so staff could move an unapplied payment onto an
--    invoice whose /i page (or a deposit page of a job it bills) the
--    customer could still pay: the card payment then landed on a paid
--    invoice (paid / -balance, an overpayment of the whole amount).
--    Now (0013 body) the target invoice is checked with
--    money_refuse_open_checkout after it is locked; the staff apps offer
--    "cancel open payments" on HINT checkout_open as for cash, then retry.
--    The source invoice needs no check: only an overpayment leaves it, and
--    its balance stays <= 0 (no page can be open for it).
--
-- 2. A cancelled / no-show job gives its once-per-customer coupon use back
--    0109 gave the redemption COUNT back when a job carrying a coupon is
--    cancelled or marked no-show, but once_per_customer still saw the
--    job's coupon_redemptions row: a customer who booked with a "first
--    visit" code or a friend's referral code (referral coupons are once per
--    customer, 0069) and cancelled could never book with it again (online:
--    the masked 'this coupon cannot be used for this booking ...'), and the
--    referrer could never earn the credit. Now a job holds its customer's
--    once-per-customer use only while it is not cancelled / no-show:
--      * coupon_customer_reason (0062 body): the once-per-customer rule
--        ignores redemptions of cancelled / no-show jobs;
--      * coupon_redemptions.once_per_customer (the flag the unique index
--        coupon_redemptions_once_key enforces under concurrency) is cleared
--        when the job is cancelled / no-show (jobs_money_coupon_status_count,
--        0109 body) and when a cancelled job's coupon is set
--        (jobs_money_coupon_redemption, 0062 body); reopening the job takes
--        the use again (copied from the coupon, as a new redemption) unless
--        another job of the customer holds it by then — the reopened booking
--        is honoured, like 0109's redemption count;
--      * backfill: the flag is cleared on the rows of jobs already
--        cancelled / no-show.
--
-- 3. A coupon's service list edit skips jobs with an open deposit page
--    coupons_zz_money_restamp (0062) re-stamps discount_eligible on the
--    open, unpaid, unbilled jobs carrying the coupon when its service_ids
--    change. Widening (or clearing) the list lowers those jobs' totals, and
--    0118's jobs_98_open_checkout refuses that while a job has a live
--    deposit page hold — so the owner's whole coupon UPDATE failed with a
--    message about "this job" that Settings → Coupons cannot act on,
--    whenever any customer had a deposit page open. Now (0062 body) a job
--    whose deposit page can still be paid (job_open_checkout_until, 0118)
--    keeps its eligibility, as a paid job already does; staff can re-apply
--    the coupon on that job later to re-stamp it.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. apply_payment_to_invoice — 0013 body + money_refuse_open_checkout
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice(
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
  -- 0121: like cash, checks and gift cards (0109), applied money waits for
  -- the invoice's open card pay pages (and its jobs' deposit pages)
  perform public.money_refuse_open_checkout(v_inv);
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
comment on function public.money_refuse_open_checkout(public.invoices) is
  'Internal (0109): raises 55000 HINT checkout_open while the invoice or a job it bills has a live Checkout Session hold (invoice_checkout_holds / job_checkout_holds). Callers: record_manual_payment, gift_card_redeem_core (0109); void_invoice, invoice line (incl. discount eligibility, 0118) and invoice discount / tax edits (0116); apply_payment_to_invoice (0121). A job''s own price cuts: jobs_open_checkout_guard (0118).';

-- ---------------------------------------------------------------------------
-- 2. once-per-customer coupons: cancelled / no-show jobs hold no use
-- ---------------------------------------------------------------------------
create or replace function public.coupon_customer_reason(p_coupon public.coupons, p_customer_id uuid, p_job_id uuid default null)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when p_coupon.customer_id is not null and p_coupon.customer_id is distinct from p_customer_id
      then 'this coupon is not valid for this customer'
    when p_customer_id is null then null
    -- 0121: a cancelled / no-show job's redemption is not a use
    when p_coupon.once_per_customer
         and exists (select 1 from public.coupon_redemptions r
                       join public.jobs j on j.id = r.job_id and j.shop_id = r.shop_id
                      where r.shop_id = p_coupon.shop_id and r.coupon_id = p_coupon.id
                        and r.customer_id = p_customer_id and r.job_id is distinct from p_job_id
                        and j.status not in ('cancelled', 'no_show'))
      then 'this coupon can only be used once per customer'
    when p_coupon.new_customers_only
         and (exists (select 1 from public.jobs j
                       where j.shop_id = p_coupon.shop_id and j.customer_id = p_customer_id
                         and j.status = 'completed' and j.id is distinct from p_job_id)
              or exists (select 1 from public.payments p
                          where p.shop_id = p_coupon.shop_id and p.customer_id = p_customer_id
                            and p.status in ('succeeded', 'partially_refunded', 'refunded'))
              -- a referee whose referred job was completed (0069) stays a
              -- returning customer even after that job is deleted
              or exists (select 1 from public.referral_credits rc
                          where rc.shop_id = p_coupon.shop_id and rc.referee_customer_id = p_customer_id
                            and (rc.job_id is null or p_job_id is null or rc.job_id <> p_job_id)))
      then 'this coupon is for new customers'
  end
$$;

create or replace function public.jobs_money_coupon_redemption() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.coupon_id is not distinct from old.coupon_id
     and new.customer_id is not distinct from old.customer_id then
    return null;
  end if;
  if new.coupon_id is null then
    delete from public.coupon_redemptions r where r.job_id = new.id;
    return null;
  end if;
  if tg_op = 'UPDATE' and new.coupon_id is not distinct from old.coupon_id
     and coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
    return null;  -- merge_customers moves coupon_redemptions itself
  end if;
  begin
    -- 0121: a cancelled / no-show job holds no once-per-customer use
    insert into public.coupon_redemptions as r (shop_id, coupon_id, customer_id, job_id, once_per_customer)
    select new.shop_id, c.id, new.customer_id, new.id,
           c.once_per_customer and new.status not in ('cancelled', 'no_show')
      from public.coupons c
     where c.id = new.coupon_id and c.shop_id = new.shop_id
    on conflict (job_id) do update
      set coupon_id = excluded.coupon_id,
          customer_id = excluded.customer_id,
          once_per_customer = case when r.coupon_id = excluded.coupon_id then r.once_per_customer
                                   else excluded.once_per_customer end;
  exception when unique_violation then
    -- an unproven online booking of a customer who already used the coupon
    -- (or lost a race for it): no row; jobs_zzz_money_coupon_booking refuses
    -- it at commit with the neutral message
    if tg_op = 'INSERT' and public.coupon_rules_masked(new.shop_id, new.customer_id, new.source) then
      return null;
    end if;
    -- a concurrent job of the same customer took the once-per-customer use
    raise exception 'this coupon can only be used once per customer' using errcode = '22023';
  end;
  return null;
end
$$;

create or replace function public.jobs_money_coupon_status_count() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status in ('cancelled', 'no_show') then
    update public.coupons c
       set redemptions = greatest(c.redemptions - 1, 0)
     where c.id = new.coupon_id and c.shop_id = new.shop_id;
    -- 0121: the customer's once-per-customer use is free again
    update public.coupon_redemptions r
       set once_per_customer = false
     where r.job_id = new.id and r.shop_id = new.shop_id and r.once_per_customer;
  else
    update public.coupons c
       set redemptions = c.redemptions + 1
     where c.id = new.coupon_id and c.shop_id = new.shop_id;
    -- 0121: reopened — takes the use again unless another job of the
    -- customer holds it by now (the reopened booking is honoured either way)
    begin
      update public.coupon_redemptions r
         set once_per_customer = true
        from public.coupons c
       where r.job_id = new.id and r.shop_id = new.shop_id and not r.once_per_customer
         and c.id = r.coupon_id and c.shop_id = r.shop_id and c.once_per_customer
         and not exists (select 1 from public.coupon_redemptions o
                          where o.coupon_id = r.coupon_id and o.customer_id = r.customer_id
                            and o.once_per_customer and o.id <> r.id);
    exception when unique_violation then
      null;   -- a concurrent job of the customer took it
    end;
  end if;
  return null;
end
$$;

comment on function public.jobs_money_coupon_status_count() is
  'Internal (0109; 0121): a job that keeps its coupon gives the redemption (and its customer''s once-per-customer use) back when it is cancelled / marked no-show and takes them again when reopened (the use only if no other job of the customer holds it).';

-- backfill: jobs already cancelled / no-show hold no once-per-customer use
update public.coupon_redemptions r
   set once_per_customer = false
  from public.jobs j
 where j.id = r.job_id and j.shop_id = r.shop_id
   and j.status in ('cancelled', 'no_show') and r.once_per_customer;

comment on table public.coupon_redemptions is
  'One row per job that carries a coupon (jobs_zz_money_coupon_redemption, every context). once_per_customer is copied from the coupon when redeemed and holds the customer''s single use (unique per coupon and customer); it is cleared while the job is cancelled / no-show (0121). Server-maintained; managers+ read.';

-- ---------------------------------------------------------------------------
-- 3. coupons_money_restamp_jobs — 0062 body + skip jobs with an open page
-- ---------------------------------------------------------------------------
create or replace function public.coupons_money_restamp_jobs() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.job_line_items li
     set discount_eligible = (new.service_ids is null or (li.service_id is not null and li.service_id = any (new.service_ids)))
    from public.jobs j
   where j.id = li.job_id and j.shop_id = li.shop_id
     and j.shop_id = new.shop_id and j.coupon_id = new.id
     and j.status not in ('completed', 'cancelled', 'no_show')
     and not exists (select 1 from public.invoice_jobs ij where ij.job_id = j.id and ij.shop_id = j.shop_id and not ij.voided)
     and not exists (select 1 from public.payments p
                      where p.shop_id = j.shop_id and p.job_id = j.id
                        and (p.status in ('succeeded', 'partially_refunded', 'refunded')
                             or public.payment_in_flight(p.status, p.created_at)))
     -- 0121: nor while a deposit page of the job can still be paid (0118)
     and public.job_open_checkout_until(j.shop_id, j.id) is null
     and li.discount_eligible is distinct from
         (new.service_ids is null or (li.service_id is not null and li.service_id = any (new.service_ids)));
  return null;
end
$$;
