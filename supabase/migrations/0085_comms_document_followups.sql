-- ============================================================================
-- 0085 — Automatic follow-ups for unapproved quotes, unpaid deposits and
-- unpaid / past-due invoices (P-3).
--
-- Schedule (followup_settings, one row per shop, all off by default):
--   quote            quote_reminder    quotes sent / viewed, not expired, not paused;
--                                      attempt n due at sent_at + first + (n-1) * repeat (hours)
--   deposit          deposit_reminder  jobs requested / scheduled / confirmed whose deposit is
--                                      still due (deposit_required − received − in flight > 0,
--                                      and never more than the job's live invoice — single or
--                                      grouped — still needs, comms_deposit_due_cents),
--                                      not started, appointment still ahead (a requested job
--                                      without a time counts too), not paused; attempt n due at
--                                      greatest(created_at, appointment_set_at) + first + (n-1) * repeat
--   invoice          invoice_reminder  invoices open / partially paid, sent, with money still
--                                      to pay (balance − payments in flight > 0: a clearing
--                                      ACH debit or pay-later payment is not chased), not
--                                      paused, not yet due (due_at null or in the future);
--                                      attempt n due at sent_at + first + (n-1) * repeat (hours)
--   invoice_overdue  invoice_overdue   the same invoices once due_at has passed; attempt n due
--                                      at 10:00 shop-local time on the local date of due_at
--                                      + first + (n-1) * repeat DAYS (calendar days, so a DST
--                                      change never moves it). due_at is the END of the local
--                                      due date (0093), so a day schedule kept at due_at's time
--                                      of day would text customers around midnight; when that
--                                      10:00 is not after due_at (first = 0, or a due time set
--                                      after 10:00) every attempt moves one day later.
-- Waking hours: hour schedules are elapsed time, but an attempt that would
-- fall due outside 08:00-21:00 shop-local time is due when that window next
-- opens (08:00 the same morning, or the next morning from 21:00) — deposit
-- reminders count from the moment of an online booking, and quote / invoice
-- reminders from the moment staff pressed Send, both at any hour; the
-- 10:00 day schedules are always inside it. The run itself only queues
-- inside the window (a late run at night waits for the morning), so no
-- automatic follow-up is ever queued for the middle of the night, and the
-- message is rendered when it is queued (current amounts, times and links).
-- A document is only processed while at least one channel template of its
-- key is enabled (enabling one later still catches attempts due within the
-- last 24 hours).
-- Exactly once: every attempt is claimed in document_followup_log (UNIQUE
-- (doc_kind, doc_id, attempt)) before anything is queued. Only the latest
-- due attempt of a document is sent in a run (earlier unsent ones are
-- logged 'skipped', so enabling follow-ups or a scheduler outage never sends
-- a burst), and an attempt that became due more than 24 hours ago is
-- skipped. Each attempt goes out on every ENABLED channel template of its
-- key the customer can receive; 'skipped' when none could be queued.
-- Transactional: no marketing opt-in needed, but opt-outs and suppressions
-- apply. Messages carry messages.quote_id / invoice_id / job_id, and a
-- queued follow-up is withdrawn at send time once its document no longer
-- needs it (comms_withdraw_reason: quote answered / expired, deposit paid,
-- invoice paid, voided or covered by a payment still clearing, appointment
-- cancelled or started, follow-ups paused).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Variables (internal, service_role)
-- ---------------------------------------------------------------------------

-- {quote_number, quote_link (null while draft), quote_total, valid_until
-- (null when the quote does not expire)}. Null for an unknown quote.
create function public.comms_quote_vars(p_quote_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'quote_number', q.number::text,
    'quote_link', case when q.status <> 'draft' then public.app_url('/q/' || q.public_token::text) end,
    'quote_total', public.format_money(q.total_cents, s.currency),
    'valid_until', to_char(q.valid_until, 'FMMonth FMDD, YYYY'))
  from public.quotes q join public.shops s on s.id = q.shop_id
  where q.id = p_quote_id
$$;

-- What the customer still has to pay on an invoice, in cents: its balance
-- minus the payments on it that are still in flight at p_now (an ACH debit
-- or pay-later payment 'processing' for days, a card attempt pending for
-- under an hour — payment_in_flight), never negative. The /i page treats
-- clearing money the same way (money_public_invoice_json.payable), so a
-- follow-up never asks for money the customer already sent. Null for an
-- unknown invoice.
create function public.comms_invoice_due_cents(p_invoice_id uuid, p_now timestamptz default now()) returns bigint
language sql stable
set search_path = ''
as $$
  select greatest(
           i.balance_cents
           - coalesce((select sum(p.amount_cents)
                         from public.payments p
                        where p.shop_id = i.shop_id and p.invoice_id = i.id
                          and public.payment_in_flight(p.status, p.created_at, coalesce(p_now, now()))), 0),
           0)::bigint
  from public.invoices i
  where i.id = p_invoice_id
$$;

-- {invoice_number, invoice_link (null for draft / void), amount (total),
-- balance (what is still to pay: the balance minus payments in flight,
-- never negative — comms_invoice_due_cents), due_date (shop-local date;
-- null without a due date), days_overdue (whole shop-local days past the
-- due date at p_now; null while not due)}. Null for an unknown invoice.
create function public.comms_invoice_vars(p_invoice_id uuid, p_now timestamptz default now()) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'invoice_number', i.number::text,
    'invoice_link', case when i.status not in ('draft', 'void') then public.app_url('/i/' || i.public_token::text) end,
    'amount', public.format_money(i.total_cents, s.currency),
    'balance', public.format_money(public.comms_invoice_due_cents(i.id, p_now), s.currency),
    'due_date', to_char(i.due_at at time zone s.timezone, 'FMMonth FMDD, YYYY'),
    'days_overdue', case when i.due_at is not null and i.due_at <= coalesce(p_now, now())
                         then ((coalesce(p_now, now()) at time zone s.timezone)::date
                               - (i.due_at at time zone s.timezone)::date)::text end)
  from public.invoices i join public.shops s on s.id = i.shop_id
  where i.id = p_invoice_id
$$;

-- The deposit a job still needs, in cents: the required deposit (capped at
-- the total: the invoice's once the job has one) minus what was received on
-- the job and what is still in flight (a processing ACH debit is not
-- chased) — and, once the job is billed on a live invoice (single-job or
-- grouped, found through invoice_jobs), never more than that invoice still
-- needs (comms_invoice_due_cents). A grouped (fleet) invoice's payments
-- carry no job_id, so without that cap every job of a fully paid grouped
-- invoice would still be asked for its deposit. Same basis as the /booking
-- page's deposit.due_cents (booking_public_json, 0064), with money in
-- flight counted as paid.
create function public.comms_deposit_due_cents(p_job_id uuid) returns bigint
language sql stable
set search_path = ''
as $$
  select greatest(
           case when inv.id is null then d.job_due
                else least(d.job_due, public.comms_invoice_due_cents(inv.id)) end,
           0)::bigint
  from public.jobs j
  left join lateral (
    select i.id, i.total_cents
      from public.invoice_jobs ij
      join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
     where ij.shop_id = j.shop_id and ij.job_id = j.id and not ij.voided and i.status <> 'void'
     order by i.created_at desc
     limit 1) inv on true
  cross join lateral (
    select least(j.deposit_required_cents, coalesce(inv.total_cents, j.total_cents))
           - coalesce((select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents,
                                                                     p.refunded_cents)), 0)
                            + coalesce(sum(p.amount_cents) filter (where public.payment_in_flight(p.status, p.created_at)), 0)
                         from public.payments p where p.shop_id = j.shop_id and p.job_id = j.id), 0)
             as job_due) d
  where j.id = p_job_id
$$;

-- ---------------------------------------------------------------------------
-- The documents that follow-ups currently apply to, with their schedule
-- (internal). One row per (doc_kind, doc_id); p_doc_id narrows to one
-- document (status RPCs).
-- ---------------------------------------------------------------------------
create function public.comms_followup_candidates(p_now timestamptz, p_doc_kind text default null, p_doc_id uuid default null)
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
     and case when i.due_at is not null and i.due_at <= p_now then f.overdue_enabled else f.invoice_enabled end
     and exists (select 1 from public.message_templates t
                  where t.shop_id = i.shop_id and t.enabled
                    and t.key = case when i.due_at is not null and i.due_at <= p_now then 'invoice_overdue'
                                     else 'invoice_reminder' end::public.message_template_key)
     and (p_doc_kind is null or p_doc_kind = 'invoice')
     and (p_doc_id is null or i.id = p_doc_id)
$$;

-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.comms_followup_candidates(timestamptz, text, uuid) is
  'Internal: documents follow-ups apply to, with their schedule. @nullable: job_id, quote_id, invoice_id';

-- When attempt p_attempt of a schedule is due. Hour schedules are elapsed
-- time from p_base_at (p_base_at + p_first + (p_attempt - 1) * p_repeat),
-- moved into waking hours: a time before 08:00 shop-local becomes 08:00 that
-- morning, one from 21:00 on becomes 08:00 the next morning (attempts that
-- land in the same night fall due together, and the run sends only the
-- latest of them). Day schedules (p_first / p_repeat whole days) count
-- shop-local calendar days from the local date of p_base_at and are due at
-- 10:00 local time (a waking hour; a DST change never shifts it). When
-- attempt 1's 10:00 would not be after p_base_at (first = 0 days, or a base
-- time after 10:00 on that date), the whole schedule moves one day later,
-- so no attempt is due before the base (e.g. before the invoice is overdue)
-- and attempts stay p_repeat apart.
create function public.comms_followup_due_at(
  p_base_at timestamptz, p_first interval, p_repeat interval, p_in_days boolean, p_timezone text, p_attempt integer
) returns timestamptz
language sql immutable
set search_path = ''
as $$
  select case when p_in_days
              then (d.first_local
                    + case when d.first_local <= d.base_local then interval '1 day' else interval '0' end
                    + (p_attempt - 1) * p_repeat) at time zone p_timezone
              when h.raw_local::time >= time '08:00' and h.raw_local::time < time '21:00'
              then h.raw_at
              else ((h.raw_local::date + case when h.raw_local::time >= time '21:00' then 1 else 0 end)
                    + time '08:00') at time zone p_timezone end
    from (select p_base_at at time zone p_timezone as base_local,
                 ((p_base_at at time zone p_timezone)::date + time '10:00') + p_first as first_local) as d
   cross join lateral (select r.raw_at, r.raw_at at time zone p_timezone as raw_local
                         from (select p_base_at + p_first + (p_attempt - 1) * p_repeat as raw_at) as r) as h
$$;

-- ---------------------------------------------------------------------------
-- enqueue_document_followups (service_role; called by
-- enqueue_due_automations). Returns the number of messages queued.
-- ---------------------------------------------------------------------------
create function public.enqueue_document_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := coalesce(p_now, now());
  v_due    record;
  v_tpl    public.message_templates;
  v_log_id uuid;
  v_vars   jsonb;
  v_msg    uuid;
  v_ids    uuid[];
  v_total  integer := 0;
begin
  for v_due in
    with due as (
      select c.*, n.attempt,
             public.comms_followup_due_at(c.base_at, c.first_after, c.repeat_every, c.in_days, c.timezone, n.attempt)
               as due_at
        from public.comms_followup_candidates(v_now) c
        -- (max_attempts <= 10; a constant series keeps the row estimate small)
        cross join lateral (select g from generate_series(1, 10) as g where g <= c.max_attempts) as n(attempt)
       where not exists (select 1 from public.document_followup_log l
                          where l.doc_kind = c.doc_kind and l.doc_id = c.doc_id and l.attempt = n.attempt)
    )
    select d.*,
           row_number() over (partition by d.doc_kind, d.doc_id order by d.attempt desc) = 1 as latest
      from due d
     where d.due_at <= v_now
       -- only inside waking hours (08:00-21:00 shop time): a late run at
       -- night leaves the attempt for the morning run (still within 24 h)
       and (v_now at time zone d.timezone)::time >= time '08:00'
       and (v_now at time zone d.timezone)::time < time '21:00'
     order by d.due_at, d.doc_kind, d.doc_id, d.attempt
  loop
    insert into public.document_followup_log (shop_id, doc_kind, doc_id, attempt, due_at, processed_at, outcome)
    values (v_due.shop_id, v_due.doc_kind, v_due.doc_id, v_due.attempt, v_due.due_at, v_now, 'skipped')
    on conflict (doc_kind, doc_id, attempt) do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- processed by a concurrent run
    -- superseded by a later attempt, or stale: logged as skipped
    if not v_due.latest or v_due.due_at <= v_now - interval '24 hours' then
      v_log_id := null;
      continue;
    end if;

    v_vars := case v_due.doc_kind
      when 'quote' then public.comms_quote_vars(v_due.quote_id)
      when 'deposit' then jsonb_build_object(
        'deposit_link', (select public.app_url('/booking/' || j.public_token::text) from public.jobs j where j.id = v_due.job_id),
        'deposit_due', (select public.format_money(public.comms_deposit_due_cents(v_due.job_id), s.currency)
                          from public.shops s where s.id = v_due.shop_id))
      else public.comms_invoice_vars(v_due.invoice_id, v_now) end;

    v_ids := '{}';
    for v_tpl in
      select t.* from public.message_templates t
       where t.shop_id = v_due.shop_id and t.key = v_due.key and t.enabled
       order by t.channel
    loop
      v_msg := public.enqueue_message_core(v_due.shop_id, v_due.customer_id, v_due.key, v_tpl.channel,
                                           v_tpl.subject, v_tpl.body, v_due.job_id, v_vars, v_now, null, null,
                                           v_due.quote_id, v_due.invoice_id);
      if v_msg is not null then
        v_ids := v_ids || v_msg;
      end if;
    end loop;
    if cardinality(v_ids) > 0 then
      update public.document_followup_log l set outcome = 'queued', message_ids = v_ids where l.id = v_log_id;
      v_total := v_total + cardinality(v_ids);
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;

-- ---------------------------------------------------------------------------
-- comms_withdraw_reason (replaced): the 0033 rules, plus
--   marketing          campaign messages and marketing keys (follow_up,
--                      service_followup) of a customer archived since
--                      they were queued
--   quote_reminder     the quote was deleted, answered (no longer sent /
--                      viewed), expired, or its follow-ups were paused
--   deposit_reminder   the appointment was deleted, cancelled, marked
--                      no-show or started, moved to another customer (the
--                      message carries its /booking link), the deposit is
--                      no longer due, or its follow-ups were paused
--   invoice_reminder / invoice_overdue
--                      the invoice was deleted, paid, voided (or is back in
--                      draft), has no balance, its balance is covered by a
--                      payment still in flight (a clearing ACH debit),
--                      belongs to another customer, or its follow-ups were
--                      paused
--   (quote_reminder is withdrawn too when the quote belongs to another
--   customer: every follow-up carries a public document link)
--   staleness          follow-ups (and per-service follow-ups) more than 24
--                      hours past their send time
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Staff view / pause of one document's follow-ups (owner/admin/manager).
--   p_kind 'quote' (quote id) | 'deposit' (job id) | 'invoice' (invoice id)
-- Result {kind, stage, enabled, paused, attempts_sent, max_attempts,
-- last_sent_at, next_at}: stage = the schedule in effect ('quote',
-- 'deposit', 'invoice' or — once the invoice is past due —
-- 'invoice_overdue'); enabled = the shop's setting is on and at least one
-- channel template of the key is enabled; attempts_sent / last_sent_at =
-- attempts that queued a message; next_at = when the next attempt is due
-- (null when none will be sent: off, paused, no attempts left, or the
-- document no longer qualifies). Unknown / other shop's document: P0002;
-- technicians: 42501.
-- ---------------------------------------------------------------------------
create function public.comms_followup_status_json(p_kind text, p_id uuid, p_now timestamptz) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_shop    uuid;
  v_paused  boolean;
  v_stage   text;
  v_key     public.message_template_key;
  v_setting boolean;
  v_max     integer;
  v_cand    record;
  v_sent    integer;
  v_last    timestamptz;
  v_next_n  integer;
  v_next_at timestamptz;
begin
  if p_kind = 'quote' then
    select q.shop_id, q.followups_paused into v_shop, v_paused from public.quotes q where q.id = p_id;
    v_stage := 'quote';
  elsif p_kind = 'deposit' then
    select j.shop_id, j.deposit_followups_paused into v_shop, v_paused from public.jobs j where j.id = p_id;
    v_stage := 'deposit';
  else
    select i.shop_id, i.followups_paused,
           case when i.due_at is not null and i.due_at <= p_now then 'invoice_overdue' else 'invoice' end
      into v_shop, v_paused, v_stage
      from public.invoices i where i.id = p_id;
  end if;
  v_key := case v_stage when 'quote' then 'quote_reminder' when 'deposit' then 'deposit_reminder'
                        when 'invoice' then 'invoice_reminder' else 'invoice_overdue' end;
  select case v_stage when 'quote' then f.quote_enabled when 'deposit' then f.deposit_enabled
                      when 'invoice' then f.invoice_enabled else f.overdue_enabled end,
         case v_stage when 'quote' then f.quote_max_attempts when 'deposit' then f.deposit_max_attempts
                      when 'invoice' then f.invoice_max_attempts else f.overdue_max_attempts end
    into v_setting, v_max
    from public.followup_settings f where f.shop_id = v_shop;
  v_setting := coalesce(v_setting, false)
               and exists (select 1 from public.message_templates t
                            where t.shop_id = v_shop and t.key = v_key and t.enabled);

  select count(*) filter (where l.outcome = 'queued'), max(l.processed_at) filter (where l.outcome = 'queued'),
         coalesce(max(l.attempt), 0) + 1
    into v_sent, v_last, v_next_n
    from public.document_followup_log l where l.doc_kind = v_stage and l.doc_id = p_id;

  select * into v_cand from public.comms_followup_candidates(p_now, p_kind, p_id) c where c.doc_kind = v_stage;
  if v_setting and not coalesce(v_paused, false) and v_cand.doc_id is not null and v_next_n <= coalesce(v_max, 0) then
    v_next_at := public.comms_followup_due_at(v_cand.base_at, v_cand.first_after, v_cand.repeat_every, v_cand.in_days,
                                             v_cand.timezone, v_next_n);
  end if;

  return jsonb_build_object(
    'kind', p_kind,
    'stage', v_stage,
    'enabled', v_setting,
    'paused', coalesce(v_paused, false),
    'attempts_sent', coalesce(v_sent, 0),
    'max_attempts', coalesce(v_max, 0),
    'last_sent_at', v_last,
    'next_at', v_next_at);
end
$$;

-- Resolves the document's shop and checks the caller (manager+).
create function public.comms_followup_check(p_kind text, p_id uuid) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  if p_kind is null or p_kind not in ('quote', 'deposit', 'invoice') then
    raise exception 'kind must be quote, deposit or invoice' using errcode = '22023';
  end if;
  if p_kind = 'quote' then
    select q.shop_id into v_shop from public.quotes q where q.id = p_id;
  elsif p_kind = 'deposit' then
    select j.shop_id into v_shop from public.jobs j where j.id = p_id;
  else
    select i.shop_id into v_shop from public.invoices i where i.id = p_id;
  end if;
  if v_shop is null or (auth.uid() is not null and not public.is_shop_member(v_shop)) then
    raise exception '% not found', case p_kind when 'deposit' then 'job' else p_kind end using errcode = 'P0002';
  end if;
  if auth.uid() is not null and not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can manage follow-ups' using errcode = '42501';
  end if;
  return v_shop;
end
$$;

create function public.document_followup_status(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform public.comms_followup_check(p_kind, p_id);
  return public.comms_followup_status_json(p_kind, p_id, now());
end
$$;

create function public.set_document_followups_paused(p_kind text, p_id uuid, p_paused boolean) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.comms_followup_check(p_kind, p_id);
  if p_paused is null then
    raise exception 'paused must be true or false' using errcode = '22023';
  end if;
  if p_kind = 'quote' then
    update public.quotes q set followups_paused = p_paused where q.id = p_id;
  elsif p_kind = 'deposit' then
    update public.jobs j set deposit_followups_paused = p_paused where j.id = p_id;
  else
    update public.invoices i set followups_paused = p_paused where i.id = p_id;
  end if;
  return public.comms_followup_status_json(p_kind, p_id, now());
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.comms_quote_vars(uuid),
  public.comms_invoice_due_cents(uuid, timestamptz),
  public.comms_invoice_vars(uuid, timestamptz),
  public.comms_deposit_due_cents(uuid),
  public.comms_followup_candidates(timestamptz, text, uuid),
  public.comms_followup_due_at(timestamptz, interval, interval, boolean, text, integer),
  public.comms_followup_status_json(text, uuid, timestamptz),
  public.comms_followup_check(text, uuid),
  public.enqueue_document_followups(timestamptz)
from public, anon, authenticated;
grant execute on function
  public.comms_quote_vars(uuid),
  public.comms_invoice_due_cents(uuid, timestamptz),
  public.comms_invoice_vars(uuid, timestamptz),
  public.comms_deposit_due_cents(uuid),
  public.comms_followup_candidates(timestamptz, text, uuid),
  public.comms_followup_due_at(timestamptz, interval, interval, boolean, text, integer),
  public.comms_followup_status_json(text, uuid, timestamptz),
  public.comms_followup_check(text, uuid),
  public.enqueue_document_followups(timestamptz)
to service_role;

revoke execute on function
  public.document_followup_status(text, uuid),
  public.set_document_followups_paused(text, uuid, boolean)
from public, anon;
grant execute on function
  public.document_followup_status(text, uuid),
  public.set_document_followups_paused(text, uuid, boolean)
to authenticated, service_role;
