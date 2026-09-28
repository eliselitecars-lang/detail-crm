-- ============================================================================
-- 0109 — Cancelled appointments stop asking for money and give their coupon
-- back; cash, checks and gift cards wait for open card pay pages.
--
-- 1. The invoice of a cancelled appointment
--    public_cancel_booking (0106) and set_job_status(..., 'cancelled') left
--    the job's live invoice as it was, so the follow-ups (0085) kept
--    queueing invoice_reminder / invoice_overdue for a booking the customer
--    cancelled, and /i kept offering to pay it.
--    invoice_bills_only_cancelled_jobs(invoice): the invoice bills at least
--    one job (invoices.job_id or a live invoice_jobs row) and every one of
--    them is cancelled (a no-show is not: shops bill no-shows).
--      * comms_followup_candidates (0085 body): no invoice follow-ups for
--        such an invoice; comms_withdraw_reason (0085 body) withdraws a
--        queued one at send time ('the appointment was cancelled').
--      * money_public_invoice_json (0066 body): payable and
--        gift_card_redeemable are false for it (the /i page stops offering
--        Pay and gift cards; the invoice is still shown).
--      * payments_hold_invoice_checkout (below) refuses it (55000 HINT
--        booking_cancelled), so the edge does not hand out a pay link.
--      * jobs_zz_money_cancelled_invoice (new): cancelling a job that is on
--        a draft / open / partially paid invoice notifies managers
--        ('booking_cancelled': void or delete the invoice, or refund / keep
--        what was paid). The invoice itself is not voided automatically
--        (voiding is an owner/admin decision and money may be on it).
--
-- 2. Manual money and open Stripe pay pages
--    record_manual_payment, redeem_gift_card, redeem_customer_credit and
--    public_redeem_gift_card subtracted only payment rows in flight; an open
--    Checkout Session has none, so staff could take cash for the whole
--    balance while the customer's /i (or deposit) page stayed payable for
--    32-42 minutes and the webhook then recorded the card payment on the
--    paid invoice (overpaid by the full amount).
--      * invoice_checkout_holds (internal, service_role): one row per open
--        Checkout Session of an INVOICE (pay links of completed jobs and of
--        grouped invoices are held here too, which job_checkout_holds does
--        not cover), until Stripe expires it or it is released.
--      * payments_hold_invoice_checkout(shop, invoice, session, expires_at,
--        amount?) service_role: called right after the session is created
--        and BEFORE its URL is handed out. Locks the invoice (the lock every
--        manual payment takes) and refuses (55000, the edge then expires the
--        session) an invoice that can no longer take this payment: HINT
--        invoice_closed (not open / partially paid, or nothing left to pay —
--        e.g. cash recorded meanwhile), balance_changed (p_amount_cents, the
--        session's amount without tip, exceeds what is still to pay),
--        booking_cancelled (see 1).
--      * payments_release_invoice_checkouts(shop, invoice, sessions?)
--        service_role: forget the invoice's holds once the edge expired them.
--        payments_release_job_checkouts (0106 body) also forgets the invoice
--        holds of the sessions it is given, and a completed session
--        (processing / received payment row) releases both kinds
--        (payments_release_checkout_hold, 0106 body).
--      * money_refuse_open_checkout(invoice): while the invoice or any job it
--        bills has a live hold (invoice_checkout_holds / job_checkout_holds,
--        expires_at > now()), record_manual_payment (0064 body) and
--        gift_card_redeem_core (0066 body: every gift card / store credit
--        redemption, staff and public) fail with
--          55000 'a card payment page for this invoice is still open (until
--                 <time>); cancel the open payments first, or wait until then'
--          HINT  'checkout_open'
--        Staff apps call the payments edge cancel_open_payments (invoice_id)
--        — it expires the sessions and releases the holds — then retry.
--
-- 3. A cancelled booking gives its coupon redemption back
--    coupons.redemptions counted every job that ever took the coupon, so a
--    booking cancelled online (or by staff, or a no-show) used up a limited
--    coupon for good; anyone could drain a "first N customers" promo by
--    booking and cancelling. Now (every context) a job holds a redemption
--    only while it is not cancelled / no-show:
--      * jobs_zz_money_coupon_status (new): a job keeping its coupon that
--        moves to cancelled / no-show releases the redemption; reopening it
--        takes one again (even past max_redemptions: staff reopening an
--        existing booking honour it).
--      * jobs_apply_coupon (0062 body): changing the coupon of a cancelled /
--        no-show job validates the new coupon but holds no redemption.
--      * jobs_release_coupon_on_delete (0012 body): deleting a cancelled /
--        no-show job releases nothing (it already did).
--    once_per_customer (coupon_redemptions rows) is unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- invoice_bills_only_cancelled_jobs — internal
-- ---------------------------------------------------------------------------
create function public.invoice_bills_only_cancelled_jobs(p_invoice_id uuid) returns boolean
language sql stable
set search_path = ''
as $$
  with billed as (
    select j.status
      from public.invoices i
      join public.jobs j on j.shop_id = i.shop_id
                        and (j.id = i.job_id
                             or j.id in (select ij.job_id from public.invoice_jobs ij
                                          where ij.shop_id = i.shop_id and ij.invoice_id = i.id and not ij.voided))
     where i.id = p_invoice_id
  )
  select exists (select 1 from billed) and not exists (select 1 from billed b where b.status <> 'cancelled')
$$;

comment on function public.invoice_bills_only_cancelled_jobs(uuid) is
  'Internal (0109): the invoice bills at least one job and every job it bills is cancelled (no follow-ups, not payable online).';

create or replace function public.comms_followup_candidates(p_now timestamptz, p_doc_kind text default null, p_doc_id uuid default null)
returns table (
  doc_kind      text,
  doc_id        uuid,
  shop_id       uuid,
  customer_id   uuid,
  job_id        uuid,
  quote_id      uuid,
  invoice_id    uuid,
  key           public.message_template_key,
  timezone      text,
  base_at       timestamptz,
  first_after   interval,
  repeat_every  interval,
  in_days       boolean,
  max_attempts  integer
)
language sql stable
rows 20
set search_path = ''
as $$
  -- quotes awaiting an answer
  select 'quote', q.id, q.shop_id, q.customer_id, null::uuid, q.id, null::uuid,
         'quote_reminder'::public.message_template_key, s.timezone, q.sent_at,
         make_interval(hours => f.quote_first_after_hours), make_interval(hours => f.quote_repeat_every_hours),
         false, f.quote_max_attempts::integer
    from public.quotes q
    join public.followup_settings f on f.shop_id = q.shop_id
    join public.shops s on s.id = q.shop_id
   where f.quote_enabled and not q.followups_paused
     and q.status in ('sent', 'viewed') and q.sent_at is not null
     and exists (select 1 from public.message_templates t
                  where t.shop_id = q.shop_id and t.key = 'quote_reminder' and t.enabled)
     and (q.valid_until is null or public.quote_validity_end(q.valid_until, s.timezone) > p_now)
     and (p_doc_kind is null or p_doc_kind = 'quote')
     and (p_doc_id is null or q.id = p_doc_id)
  union all
  -- deposits still due for an upcoming appointment
  select 'deposit', j.id, j.shop_id, j.customer_id, j.id, null::uuid, null::uuid,
         'deposit_reminder'::public.message_template_key, s.timezone, greatest(j.created_at, j.appointment_set_at),
         make_interval(hours => f.deposit_first_after_hours), make_interval(hours => f.deposit_repeat_every_hours),
         false, f.deposit_max_attempts::integer
    from public.jobs j
    join public.followup_settings f on f.shop_id = j.shop_id
    join public.shops s on s.id = j.shop_id
   where f.deposit_enabled and not j.deposit_followups_paused
     and j.deposit_required_cents > 0
     and exists (select 1 from public.message_templates t
                  where t.shop_id = j.shop_id and t.key = 'deposit_reminder' and t.enabled)
     and j.status in ('requested', 'scheduled', 'confirmed')
     and (j.scheduled_start > p_now or (j.scheduled_start is null and j.status = 'requested'))
     and (p_doc_kind is null or p_doc_kind = 'deposit')
     and (p_doc_id is null or j.id = p_doc_id)
     and public.comms_deposit_due_cents(j.id) > 0
  union all
  -- sent invoices with a balance: reminders before, overdue notices after the due date
  select case when i.due_at is not null and i.due_at <= p_now then 'invoice_overdue' else 'invoice' end,
         i.id, i.shop_id, i.customer_id,
         (select j.id from public.jobs j where j.id = i.job_id and j.shop_id = i.shop_id and j.customer_id = i.customer_id),
         null::uuid, i.id,
         case when i.due_at is not null and i.due_at <= p_now then 'invoice_overdue' else 'invoice_reminder' end
           ::public.message_template_key,
         s.timezone,
         case when i.due_at is not null and i.due_at <= p_now then i.due_at else i.sent_at end,
         case when i.due_at is not null and i.due_at <= p_now then make_interval(days => f.overdue_first_after_days)
              else make_interval(hours => f.invoice_first_after_hours) end,
         case when i.due_at is not null and i.due_at <= p_now then make_interval(days => f.overdue_repeat_every_days)
              else make_interval(hours => f.invoice_repeat_every_hours) end,
         i.due_at is not null and i.due_at <= p_now,
         case when i.due_at is not null and i.due_at <= p_now then f.overdue_max_attempts
              else f.invoice_max_attempts end::integer
    from public.invoices i
    join public.followup_settings f on f.shop_id = i.shop_id
    join public.shops s on s.id = i.shop_id
   where not i.followups_paused
     and i.status in ('open', 'partially_paid') and i.balance_cents > 0 and i.sent_at is not null
     -- money still to pay: a payment clearing for the balance is not chased
     and public.comms_invoice_due_cents(i.id, p_now) > 0
     -- 0109: not for an invoice whose every billed appointment was cancelled
     and not public.invoice_bills_only_cancelled_jobs(i.id)
     and case when i.due_at is not null and i.due_at <= p_now then f.overdue_enabled else f.invoice_enabled end
     and exists (select 1 from public.message_templates t
                  where t.shop_id = i.shop_id and t.enabled
                    and t.key = case when i.due_at is not null and i.due_at <= p_now then 'invoice_overdue'
                                     else 'invoice_reminder' end::public.message_template_key)
     and (p_doc_kind is null or p_doc_kind = 'invoice')
     and (p_doc_id is null or i.id = p_doc_id)
$$;

create or replace function public.comms_withdraw_reason(p_msg public.messages, p_now timestamptz default now())
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_now      timestamptz := coalesce(p_now, now());
  v_cust     public.customers;
  v_job      public.jobs;
  v_campaign text;
  v_at_start boolean;
  v_quote    public.quotes;
  v_inv      public.invoices;
  v_tz       text;
begin
  if p_msg.id is null or p_msg.direction <> 'outbound' then
    return null;
  end if;

  if p_msg.customer_id is not null then
    select * into v_cust from public.customers c where c.id = p_msg.customer_id and c.shop_id = p_msg.shop_id;
  end if;
  if (p_msg.channel = 'sms' and v_cust.sms_opted_out_at is not null)
     or (p_msg.channel = 'email' and v_cust.email_opted_out_at is not null)
     or public.comms_is_suppressed(p_msg.shop_id, p_msg.channel, p_msg.to_address) then
    return 'the recipient opted out before sending';
  end if;
  if v_cust.id is not null
     and public.comms_address_key(p_msg.channel, p_msg.to_address)
         is distinct from public.comms_address_key(p_msg.channel, case p_msg.channel when 'sms' then v_cust.phone
                                                                                     else v_cust.email::text end) then
    return 'the customer''s contact details changed before sending';
  end if;

  if p_msg.campaign_id is not null then
    execute 'select c.status::text from public.campaigns c where c.id = $1 and c.shop_id = $2'
      into v_campaign using p_msg.campaign_id, p_msg.shop_id;
    if v_campaign = 'cancelled' then
      return 'the campaign was cancelled';
    end if;
  end if;
  if p_msg.campaign_id is not null or public.comms_is_marketing_key(p_msg.template_key) then
    if v_cust.id is null
       or not (case p_msg.channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end) then
      return 'the recipient withdrew marketing consent before sending';
    elsif v_cust.archived_at is not null then
      -- archived = soft-deleted (SPEC §2): no promotions, as campaigns and
      -- enqueue_message_core already exclude them when queueing
      return 'the customer was archived before sending';
    end if;
  end if;

  if p_msg.job_id is null and public.comms_is_appointment_key(p_msg.template_key) then
    return 'the appointment was deleted';
  end if;
  if p_msg.job_id is not null then
    select * into v_job from public.jobs j where j.id = p_msg.job_id and j.shop_id = p_msg.shop_id;
    if v_job.id is not null and public.comms_is_appointment_key(p_msg.template_key) then
      if v_job.status = 'cancelled' then
        return 'the appointment was cancelled';
      elsif v_job.status = 'no_show' then
        return 'the appointment was marked as a no-show';
      elsif v_job.customer_id is distinct from p_msg.customer_id then
        return 'the appointment now belongs to another customer';
      elsif p_msg.template_key = 'appointment_reminder'
            and (v_job.status in ('in_progress', 'completed') or v_job.scheduled_start is null
                 or v_job.scheduled_start <= v_now - interval '15 minutes') then
        return 'the appointment has already started';
      elsif p_msg.template_key = 'appointment_reminder' and v_job.scheduled_start <= v_now then
        -- the 15 minutes of grace are only for a reminder that was due at the
        -- start itself (offset 0): the automation log row it was queued
        -- under is for this start and due at it (0034). Any earlier reminder
        -- (1 hour, 24 hours, sent by hand …) is withdrawn once it started.
        v_at_start := false;
        if to_regclass('public.job_automation_log') is not null then
          execute 'select exists (select 1 from public.job_automation_log l
                                   where l.shop_id = $1 and l.job_id = $2 and l.key = ''appointment_reminder''
                                     and $3 = any (l.message_ids) and l.scheduled_for = $4
                                     and l.due_at >= l.scheduled_for)'
            into v_at_start using p_msg.shop_id, p_msg.job_id, p_msg.id, v_job.scheduled_start;
        end if;
        if not v_at_start then
          return 'the appointment has already started';
        end if;
      end if;
    end if;
  end if;

  -- document follow-ups (0085): only while the document still needs them
  if p_msg.template_key = 'quote_reminder' then
    if p_msg.quote_id is not null then
      select * into v_quote from public.quotes q where q.id = p_msg.quote_id and q.shop_id = p_msg.shop_id;
    end if;
    if v_quote.id is null then
      return 'the quote was deleted';
    elsif v_quote.status not in ('sent', 'viewed') then
      return 'the quote was already answered';
    elsif v_quote.customer_id is distinct from p_msg.customer_id then
      return 'the quote now belongs to another customer';
    end if;
    select s.timezone into v_tz from public.shops s where s.id = p_msg.shop_id;
    if v_quote.valid_until is not null and public.quote_validity_end(v_quote.valid_until, v_tz) <= v_now then
      return 'the quote has expired';
    elsif v_quote.followups_paused then
      return 'follow-ups were paused for this quote';
    end if;
  elsif p_msg.template_key = 'deposit_reminder' then
    if v_job.id is null then
      return 'the appointment was deleted';
    elsif v_job.status in ('cancelled', 'no_show') then
      return 'the appointment was cancelled';
    elsif v_job.status not in ('requested', 'scheduled', 'confirmed') then
      return 'the appointment has already started';
    elsif v_job.customer_id is distinct from p_msg.customer_id then
      -- the reminder carries the job's /booking link (read + cancel): never
      -- to whoever the appointment belonged to before
      return 'the appointment now belongs to another customer';
    elsif v_job.deposit_followups_paused then
      return 'follow-ups were paused for this appointment';
    elsif public.comms_deposit_due_cents(v_job.id) <= 0 then
      return 'the deposit was paid';
    end if;
  elsif p_msg.template_key in ('invoice_reminder', 'invoice_overdue') then
    if p_msg.invoice_id is not null then
      select * into v_inv from public.invoices i where i.id = p_msg.invoice_id and i.shop_id = p_msg.shop_id;
    end if;
    if v_inv.id is null then
      return 'the invoice was deleted';
    elsif v_inv.status = 'void' then
      return 'the invoice was voided';
    elsif v_inv.status not in ('open', 'partially_paid') or v_inv.balance_cents <= 0 then
      return 'the invoice was paid';
    elsif public.comms_invoice_due_cents(v_inv.id, v_now) <= 0 then
      return 'a payment for the invoice balance is on its way';
    elsif v_inv.customer_id is distinct from p_msg.customer_id then
      return 'the invoice now belongs to another customer';
    elsif public.invoice_bills_only_cancelled_jobs(v_inv.id) then
      return 'the appointment was cancelled';
    elsif v_inv.followups_paused then
      return 'follow-ups were paused for this invoice';
    end if;
  end if;

  if p_msg.job_id is not null and p_msg.template_key in ('on_the_way', 'job_started')
     and p_msg.send_after < v_now - interval '2 hours' then
    return 'the message is too old to send';
  end if;
  if (p_msg.campaign_id is not null
      or p_msg.template_key in ('quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue',
                                'service_followup')
      or (p_msg.job_id is not null
          and (p_msg.template_key is null or p_msg.template_key not in ('quote_sent', 'invoice_sent', 'payment_receipt'))))
     and p_msg.send_after < v_now - interval '24 hours' then
    return 'the message is too old to send';
  end if;
  return null;
end
$$;

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
      'payable', i.status in ('open', 'partially_paid') and i.balance_cents - pr.processing > 0
                 and not public.invoice_bills_only_cancelled_jobs(i.id),
      'gift_card_redeemable', i.status in ('open', 'partially_paid') and i.balance_cents - pr.processing > 0
                              and not public.invoice_bills_only_cancelled_jobs(i.id)
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
-- jobs_zz_money_cancelled_invoice — managers hear about the live invoice of a
-- cancelled job (every context; a failure never blocks the cancel).
-- ---------------------------------------------------------------------------
create function public.jobs_money_cancelled_invoice_notice() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv       public.invoices;
  v_currency  text;
  v_others    boolean;
begin
  select i.* into v_inv
    from public.invoices i
   where i.shop_id = new.shop_id and i.status in ('draft', 'open', 'partially_paid')
     and (i.job_id = new.id
          or exists (select 1 from public.invoice_jobs ij
                      where ij.shop_id = new.shop_id and ij.invoice_id = i.id and ij.job_id = new.id and not ij.voided))
   order by i.created_at desc, i.id
   limit 1;
  if not found then
    return null;
  end if;
  begin
    select s.currency into v_currency from public.shops s where s.id = new.shop_id;
    v_others := not public.invoice_bills_only_cancelled_jobs(v_inv.id);
    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'booking_cancelled',
      format('Job #%s was cancelled; invoice #%s is still %s', new.number, v_inv.number,
             case v_inv.status when 'draft' then 'a draft' else 'open' end),
      case
        when v_others then
          format('The invoice also bills other jobs and still asks for %s: take the cancelled work off it (void and re-invoice) if it should not be paid.',
                 public.format_money(v_inv.balance_cents, v_currency))
        when v_inv.status = 'draft' then 'Delete the draft invoice if nothing is owed.'
        when v_inv.amount_paid_cents > 0 then
          format('%s was paid on it. Payment reminders and online payment have stopped; refund it or keep it as a cancellation fee, then void the invoice.',
                 public.format_money(v_inv.amount_paid_cents, v_currency))
        else 'Payment reminders and online payment have stopped. Void the invoice if nothing is owed.'
      end,
      new.id, null, p_customer_id => new.customer_id, p_invoice_id => v_inv.id);
  exception when others then
    raise warning 'cancelled-job invoice notification failed for job %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

comment on function public.jobs_money_cancelled_invoice_notice() is
  'Internal (0109): notify managers when a job on a draft / open / partially paid invoice is cancelled.';
revoke execute on function public.jobs_money_cancelled_invoice_notice() from public, anon, authenticated;

create trigger jobs_zz_money_cancelled_invoice after update of status on public.jobs
  for each row when (new.status = 'cancelled' and old.status is distinct from 'cancelled')
  execute function public.jobs_money_cancelled_invoice_notice();

-- ---------------------------------------------------------------------------
-- invoice_checkout_holds — open Checkout Sessions of an invoice
-- ---------------------------------------------------------------------------
create table public.invoice_checkout_holds (
  stripe_checkout_session_id  text primary key
                              check (stripe_checkout_session_id ~ '^cs_[A-Za-z0-9_]+$'),
  shop_id                     uuid not null references public.shops (id) on delete cascade,
  invoice_id                  uuid not null,
  expires_at                  timestamptz not null,
  created_at                  timestamptz not null default now(),
  constraint invoice_checkout_holds_invoice_fk foreign key (shop_id, invoice_id)
    references public.invoices (shop_id, id) on delete cascade
);
create index invoice_checkout_holds_invoice_idx on public.invoice_checkout_holds (shop_id, invoice_id, expires_at);

comment on table public.invoice_checkout_holds is
  'Internal (0109): the Stripe Checkout Sessions the payments edge opened for an invoice (/i pay links, incl. completed jobs and grouped invoices) that may still be paid — until expires_at, or until released (expired by the edge, or completed: a processing / received payment row with that session). While one is live (or one of the invoice''s jobs has a live job_checkout_holds row) manual payments and gift card redemptions on the invoice are refused (55000 HINT checkout_open). No client access.';
comment on column public.invoice_checkout_holds.expires_at is
  'When Stripe expires the session (Checkout Session expires_at): after that it can no longer be paid.';

alter table public.invoice_checkout_holds enable row level security;
revoke all on table public.invoice_checkout_holds from public, anon, authenticated;
grant select, insert, update, delete on table public.invoice_checkout_holds to service_role;

-- ---------------------------------------------------------------------------
-- payments_hold_invoice_checkout — the edge opened a pay link of the invoice
-- ---------------------------------------------------------------------------
create function public.payments_hold_invoice_checkout(
  p_shop_id       uuid,
  p_invoice_id    uuid,
  p_session_id    text,
  p_expires_at    timestamptz,
  p_amount_cents  bigint default null
) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_inv  public.invoices;
  v_due  bigint;
begin
  if p_shop_id is null or p_invoice_id is null or p_session_id is null or p_expires_at is null then
    raise exception 'shop, invoice, session and expiry are required' using errcode = '22023';
  end if;
  if p_session_id !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'invalid Checkout Session id' using errcode = '22023';
  end if;
  if p_amount_cents is not null and p_amount_cents <= 0 then
    raise exception 'amount must be greater than zero' using errcode = '22023';
  end if;
  -- the lock record_manual_payment / gift card redemptions take: a manual
  -- payment either sees this hold or is already in the balance read below
  select * into v_inv from public.invoices i where i.id = p_invoice_id and i.shop_id = p_shop_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  v_due := public.comms_invoice_due_cents(v_inv.id);
  if v_inv.status not in ('open', 'partially_paid') or coalesce(v_due, 0) <= 0 then
    raise exception 'this invoice is no longer taking this payment' using errcode = '55000', hint = 'invoice_closed';
  end if;
  if p_amount_cents is not null and p_amount_cents > v_due then
    raise exception 'this invoice''s balance changed; reload it and try again' using errcode = '55000', hint = 'balance_changed';
  end if;
  if public.invoice_bills_only_cancelled_jobs(v_inv.id) then
    raise exception 'the appointment on this invoice was cancelled' using errcode = '55000', hint = 'booking_cancelled';
  end if;
  delete from public.invoice_checkout_holds h
   where h.shop_id = p_shop_id and h.invoice_id = p_invoice_id and h.expires_at <= now();
  insert into public.invoice_checkout_holds (stripe_checkout_session_id, shop_id, invoice_id, expires_at)
  values (p_session_id, p_shop_id, p_invoice_id, p_expires_at)
  on conflict (stripe_checkout_session_id) do update
     set expires_at = greatest(public.invoice_checkout_holds.expires_at, excluded.expires_at)
   where public.invoice_checkout_holds.shop_id = excluded.shop_id
     and public.invoice_checkout_holds.invoice_id = excluded.invoice_id;
  if not found then
    raise exception 'Checkout Session % is held for another invoice', p_session_id using errcode = '22023';
  end if;
end
$$;

comment on function public.payments_hold_invoice_checkout(uuid, uuid, text, timestamptz, bigint) is
  'service_role (payments edge, 0109): record an open Checkout Session of an invoice until p_expires_at, before handing out its URL. Locks the invoice; 55000 HINT invoice_closed (not open / nothing left to pay), balance_changed (p_amount_cents, without tip, exceeds what is still to pay) or booking_cancelled (every billed job cancelled) — the edge then expires the session. Idempotent per session.';
revoke execute on function public.payments_hold_invoice_checkout(uuid, uuid, text, timestamptz, bigint)
  from public, anon, authenticated;
grant execute on function public.payments_hold_invoice_checkout(uuid, uuid, text, timestamptz, bigint) to service_role;

create function public.payments_release_invoice_checkouts(
  p_shop_id      uuid,
  p_invoice_id   uuid,
  p_session_ids  text[] default null
) returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_shop_id is null or p_invoice_id is null then
    raise exception 'shop and invoice are required' using errcode = '22023';
  end if;
  delete from public.invoice_checkout_holds h
   where h.shop_id = p_shop_id and h.invoice_id = p_invoice_id
     and (p_session_ids is null or h.stripe_checkout_session_id = any (p_session_ids));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

comment on function public.payments_release_invoice_checkouts(uuid, uuid, text[]) is
  'service_role (payments edge, 0109): forget the invoice''s open Checkout Session holds — p_session_ids, or all of them when null — once the edge expired them. Returns how many were released.';
revoke execute on function public.payments_release_invoice_checkouts(uuid, uuid, text[]) from public, anon, authenticated;
grant execute on function public.payments_release_invoice_checkouts(uuid, uuid, text[]) to service_role;

-- ---------------------------------------------------------------------------
-- money_refuse_open_checkout — internal: 55000 HINT checkout_open while a pay
-- page of the invoice (or a deposit page of a job it bills) can still be paid
-- (wall clock: Stripe expires sessions in real time).
-- ---------------------------------------------------------------------------
create function public.money_refuse_open_checkout(p_inv public.invoices) returns void
language plpgsql stable
set search_path = ''
as $$
declare
  v_until  timestamptz;
  v_tz     text;
begin
  select max(h.expires_at) into v_until
    from (select ih.expires_at
            from public.invoice_checkout_holds ih
           where ih.shop_id = p_inv.shop_id and ih.invoice_id = p_inv.id and ih.expires_at > now()
          union all
          select jh.expires_at
            from public.job_checkout_holds jh
           where jh.shop_id = p_inv.shop_id and jh.expires_at > now()
             and (jh.job_id = p_inv.job_id
                  or jh.job_id in (select ij.job_id from public.invoice_jobs ij
                                    where ij.shop_id = p_inv.shop_id and ij.invoice_id = p_inv.id and not ij.voided))) h;
  if v_until is not null then
    select s.timezone into v_tz from public.shops s where s.id = p_inv.shop_id;
    raise exception 'a card payment page for this invoice is still open (until %); cancel the open payments first, or wait until then',
      to_char(v_until at time zone coalesce(v_tz, 'UTC'), 'FMHH12:MI AM')
      using errcode = '55000', hint = 'checkout_open';
  end if;
end
$$;

comment on function public.money_refuse_open_checkout(public.invoices) is
  'Internal (0109): raises 55000 HINT checkout_open while the invoice or a job it bills has a live Checkout Session hold (invoice_checkout_holds / job_checkout_holds).';
revoke execute on function public.money_refuse_open_checkout(public.invoices) from public, anon, authenticated;

create or replace function public.payments_release_job_checkouts(
  p_shop_id      uuid,
  p_job_id       uuid,
  p_session_ids  text[] default null
) returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_shop_id is null or p_job_id is null then
    raise exception 'shop and job are required' using errcode = '22023';
  end if;
  delete from public.job_checkout_holds h
   where h.shop_id = p_shop_id and h.job_id = p_job_id
     and (p_session_ids is null or h.stripe_checkout_session_id = any (p_session_ids));
  get diagnostics v_n = row_count;
  -- 0109: an expired session was also held for its invoice
  if p_session_ids is not null then
    delete from public.invoice_checkout_holds h
     where h.shop_id = p_shop_id and h.stripe_checkout_session_id = any (p_session_ids);
  end if;
  return v_n;
end
$$;

create or replace function public.payments_release_checkout_hold() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.job_checkout_holds h where h.stripe_checkout_session_id = new.stripe_checkout_session_id;
  delete from public.invoice_checkout_holds h where h.stripe_checkout_session_id = new.stripe_checkout_session_id;
  return null;
end
$$;

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
  perform public.money_refuse_open_checkout(v_inv);   -- 0109
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

create or replace function public.gift_card_redeem_core(
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
  perform public.money_refuse_open_checkout(p_inv);   -- 0109
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
-- jobs_zz_money_coupon_status — a job keeping its coupon holds a redemption
-- only while it is not cancelled / no-show (every context).
-- ---------------------------------------------------------------------------
create function public.jobs_money_coupon_status_count() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status in ('cancelled', 'no_show') then
    update public.coupons c
       set redemptions = greatest(c.redemptions - 1, 0)
     where c.id = new.coupon_id and c.shop_id = new.shop_id;
  else
    update public.coupons c
       set redemptions = c.redemptions + 1
     where c.id = new.coupon_id and c.shop_id = new.shop_id;
  end if;
  return null;
end
$$;

comment on function public.jobs_money_coupon_status_count() is
  'Internal (0109): a job that keeps its coupon gives the redemption back when it is cancelled / marked no-show and takes it again when reopened.';
revoke execute on function public.jobs_money_coupon_status_count() from public, anon, authenticated;

create trigger jobs_zz_money_coupon_status after update of status on public.jobs
  for each row
  when (new.coupon_id is not null and new.coupon_id is not distinct from old.coupon_id
        and (old.status in ('cancelled', 'no_show')) is distinct from (new.status in ('cancelled', 'no_show')))
  execute function public.jobs_money_coupon_status_count();

create or replace function public.jobs_apply_coupon() returns trigger
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
     where i.shop_id = old.shop_id and i.status <> 'void'
       and (i.job_id = old.id
            or exists (select 1 from public.invoice_jobs ij
                        where ij.shop_id = old.shop_id and ij.invoice_id = i.id and ij.job_id = old.id
                          and not ij.voided))
     order by i.created_at desc
     limit 1;
    if found then
      raise exception 'this job is billed on invoice #%; its coupon cannot change until that invoice is void', v_invoice
        using errcode = '23514';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.coupon_id is not null then
    -- 0109: a cancelled / no-show job already gave its redemption back
    if old.status not in ('cancelled', 'no_show') then
      perform public.coupon_release_for_job(old.shop_id, old.coupon_id);
    end if;
    if (new.discount_kind, new.discount_value) is not distinct from (old.discount_kind, old.discount_value) then
      new.discount_kind := 'none';
      new.discount_value := 0;
    end if;
  end if;
  if new.coupon_id is not null then
    v_c := public.coupon_redeem_for_job(new.shop_id, new.coupon_id);
    -- 0109: validated, but a cancelled / no-show job holds no redemption
    if v_c.id is not null and new.status in ('cancelled', 'no_show') then
      perform public.coupon_release_for_job(new.shop_id, new.coupon_id);
    end if;
    if v_c.id is not null then
      new.discount_kind := v_c.kind::text::public.discount_kind;
      new.discount_value := v_c.value;
    end if;
  end if;
  return new;
end
$$;

create or replace function public.jobs_release_coupon_on_delete() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.status in ('cancelled', 'no_show') then
    return null;   -- 0109: released when it was cancelled
  end if;
  update public.coupons c
     set redemptions = greatest(c.redemptions - 1, 0)
   where c.id = old.coupon_id and c.shop_id = old.shop_id;
  return null;
end
$$;

revoke execute on function public.invoice_bills_only_cancelled_jobs(uuid) from public, anon, authenticated;
grant execute on function public.invoice_bills_only_cancelled_jobs(uuid) to service_role;
