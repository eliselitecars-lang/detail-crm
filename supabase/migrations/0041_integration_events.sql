-- ============================================================================
-- 0041 — Cross-domain side effects (SPEC §4.7 notifications, §4.9 booking):
-- staff notifications and customer messages that follow business events in
-- other domains.
--
--   event                                    staff notification (owner/admin/manager)   customer message (every enabled channel)
--   online booking created (0042 RPC)        new_booking                                booking_request_received | booking_confirmed
--   job requested -> scheduled/confirmed     -                                          booking_confirmed
--   job -> en_route                          -                                          on_the_way (only if its template is enabled)
--   job -> completed                         -                                          job_completed
--   quote -> approved / declined             quote_approved / quote_declined            -
--   payment succeeded (card or manual)       payment_received                           payment_receipt (deposits/payments, not memberships)
--   form signed                              form_signed                                -
--   membership -> active                     -                                          membership_welcome
--   inbound SMS                              inbound_message — already created by record_inbound_sms (0033); not repeated here
--   booking cancelled by the customer        booking_cancelled — created by public_cancel_booking (0042)
--
-- Exactly once. Every event except quote responses is claimed in the
-- integration_events ledger (UNIQUE (event, subject)) before anything is
-- sent, so repeated updates, backward-then-forward status moves, webhook
-- replays and concurrent writers never repeat a side effect. Quote
-- notifications fire on the status TRANSITION itself (a revised quote that is
-- approved again is a new response and notifies again). Job-scoped customer
-- messages are additionally skipped per channel when the job already has a
-- live (not failed/cancelled) message of that template — e.g. a technician's
-- manual "on my way" (enqueue_template_message).
--
-- Robustness. Side effects run in the same transaction as the business write
-- (so they commit or roll back with it) but inside their own subtransaction:
-- an unexpected failure is reported as a WARNING and never blocks the booking
-- / status change / payment / signature that caused it. Missing contact
-- details, opt-outs, disabled templates or an unconfigured SMS number are
-- normal no-ops (enqueue_customer_template returns null).
-- ============================================================================

create table public.integration_events (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops (id) on delete cascade,
  event               text not null check (event in ('booking_created', 'booking_confirmed', 'on_the_way', 'job_completed',
                                                     'payment_succeeded', 'form_signed', 'membership_activated')),
  job_id              uuid,
  payment_id          uuid,
  form_submission_id  uuid,
  membership_id       uuid,
  subject_id          uuid generated always as (coalesce(job_id, payment_id, form_submission_id, membership_id)) stored,
  created_at          timestamptz not null default now(),
  constraint integration_events_shop_id_id_key unique (shop_id, id),
  constraint integration_events_once unique (event, subject_id),
  constraint integration_events_one_subject check (num_nonnulls(job_id, payment_id, form_submission_id, membership_id) = 1),
  constraint integration_events_subject_kind check (
    case event
      when 'payment_succeeded' then payment_id is not null
      when 'form_signed' then form_submission_id is not null
      when 'membership_activated' then membership_id is not null
      else job_id is not null
    end),
  constraint integration_events_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint integration_events_payment_fk foreign key (shop_id, payment_id)
    references public.payments (shop_id, id) on delete cascade,
  constraint integration_events_form_submission_fk foreign key (shop_id, form_submission_id)
    references public.form_submissions (shop_id, id) on delete cascade,
  constraint integration_events_membership_fk foreign key (shop_id, membership_id)
    references public.memberships (shop_id, id) on delete cascade
);
create index integration_events_shop_job_idx on public.integration_events (shop_id, job_id);
create index integration_events_shop_payment_idx on public.integration_events (shop_id, payment_id);
create index integration_events_shop_form_idx on public.integration_events (shop_id, form_submission_id);
create index integration_events_shop_membership_idx on public.integration_events (shop_id, membership_id);

comment on table public.integration_events is
  'Idempotency ledger for cross-domain side effects (0041). Written only by definer code; managers+ may read it.';

alter table public.integration_events enable row level security;
create policy integration_events_select on public.integration_events for select to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.integration_events from anon;
revoke insert, update, delete, truncate, references, trigger on public.integration_events from authenticated;

-- ---------------------------------------------------------------------------
-- Internal helpers (definer code only)
-- ---------------------------------------------------------------------------

-- Claims an event for a subject; true exactly once per (event, subject).
create function public.integration_claim_event(
  p_shop_id             uuid,
  p_event               text,
  p_job_id              uuid default null,
  p_payment_id          uuid default null,
  p_form_submission_id  uuid default null,
  p_membership_id       uuid default null
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.integration_events (shop_id, event, job_id, payment_id, form_submission_id, membership_id)
  values (p_shop_id, p_event, p_job_id, p_payment_id, p_form_submission_id, p_membership_id)
  on conflict (event, subject_id) do nothing
  returning id into v_id;
  return v_id is not null;
end
$$;

-- Customer display name for staff notifications.
create function public.integration_customer_label(p_shop_id uuid, p_customer_id uuid) returns text
language sql stable
set search_path = ''
as $$
  select coalesce(
           (select coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(c.first_name), ''), nullif(btrim(c.last_name), ''))), ''),
                            nullif(btrim(c.company), ''))
              from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id),
           'a customer')
$$;

-- Queues template p_key for a customer on every channel (sms, email).
-- p_dedupe_job: skip a channel when job p_job_id already has a live
-- (not failed / cancelled) outbound message of this template on it.
-- Returns the number of messages queued.
create function public.integration_send_customer_template(
  p_shop_id      uuid,
  p_customer_id  uuid,
  p_key          public.message_template_key,
  p_job_id       uuid default null,
  p_extra_vars   jsonb default null,
  p_dedupe_job   boolean default true
) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ch    public.message_channel;
  v_count integer := 0;
begin
  foreach v_ch in array enum_range(null::public.message_channel) loop
    if p_dedupe_job and p_job_id is not null and exists (
         select 1 from public.messages m
          where m.shop_id = p_shop_id and m.job_id = p_job_id and m.direction = 'outbound'
            and m.template_key = p_key and m.channel = v_ch
            and m.status not in ('failed', 'cancelled')) then
      continue;
    end if;
    if public.enqueue_customer_template(p_shop_id, p_customer_id, p_key, v_ch, p_job_id, p_extra_vars, null, null)
       is not null then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- Online booking created — called by create_online_booking (0042) after the
-- job's line items, totals and deposit exist, so messages list the services.
-- ---------------------------------------------------------------------------
create function public.integration_online_booking_created(p_job_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_vars jsonb;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    return;
  end if;
  begin
    if not public.integration_claim_event(v_job.shop_id, 'booking_created', p_job_id => v_job.id) then
      return;
    end if;
    v_vars := public.comms_job_vars(v_job.id);
    perform public.notify_shop_staff(
      v_job.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'new_booking',
      case when v_job.status = 'requested' then 'New booking request from ' else 'New booking from ' end
        || public.integration_customer_label(v_job.shop_id, v_job.customer_id),
      concat_ws(' · ', v_vars ->> 'services',
                nullif(concat_ws(' at ', v_vars ->> 'job_date', v_vars ->> 'job_time'), '')),
      v_job.id, null);
    if v_job.status = 'requested' then
      perform public.integration_send_customer_template(v_job.shop_id, v_job.customer_id, 'booking_request_received',
                                                        v_job.id);
    elsif public.integration_claim_event(v_job.shop_id, 'booking_confirmed', p_job_id => v_job.id) then
      perform public.integration_send_customer_template(v_job.shop_id, v_job.customer_id, 'booking_confirmed', v_job.id);
    end if;
  exception when others then
    raise warning 'online booking side effects failed for job %: % (%)', v_job.id, sqlerrm, sqlstate;
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- Jobs: status side effects.
-- ---------------------------------------------------------------------------
create function public.jobs_integration_status_events() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_event text;
  v_key   public.message_template_key;
begin
  if old.status = 'requested' and new.status in ('scheduled', 'confirmed') then
    v_event := 'booking_confirmed'; v_key := 'booking_confirmed';
  elsif new.status = 'en_route' then
    v_event := 'on_the_way'; v_key := 'on_the_way';
  elsif new.status = 'completed' then
    v_event := 'job_completed'; v_key := 'job_completed';
  else
    return null;
  end if;
  begin
    if public.integration_claim_event(new.shop_id, v_event, p_job_id => new.id) then
      perform public.integration_send_customer_template(new.shop_id, new.customer_id, v_key, new.id);
    end if;
  exception when others then
    raise warning 'job % side effects failed for job %: % (%)', v_event, new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger jobs_zz_integration_status_events after update of status on public.jobs
  for each row when (old.status is distinct from new.status)
  execute function public.jobs_integration_status_events();

-- ---------------------------------------------------------------------------
-- Quotes: approved / declined -> staff notification (not the staff member
-- who recorded the response themselves).
-- ---------------------------------------------------------------------------
create function public.quotes_integration_response() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_currency text;
begin
  begin
    select s.currency into v_currency from public.shops s where s.id = new.shop_id;
    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[],
      case new.status when 'approved' then 'quote_approved' else 'quote_declined' end::public.notification_kind,
      'Quote #' || new.number::text
        || case new.status when 'approved' then ' approved' || coalesce(' by ' || new.approved_by_name, '')
                           else ' declined' end,
      concat_ws(' · ', public.integration_customer_label(new.shop_id, new.customer_id),
                public.format_money(new.total_cents, v_currency),
                case when new.status = 'declined' then new.declined_reason end),
      null, auth.uid());
  exception when others then
    raise warning 'quote response side effects failed for quote %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger quotes_zz_integration_response after update of status on public.quotes
  for each row when (old.status is distinct from new.status and new.status in ('approved', 'declined'))
  execute function public.quotes_integration_response();

-- ---------------------------------------------------------------------------
-- Payments: succeeded (card via webhook, or manual) -> staff notification
-- (not the member who recorded it) + customer receipt for deposits and
-- payments. Runs after payments_touch_invoice, so the invoice balance in the
-- receipt already includes this payment.
-- ---------------------------------------------------------------------------
create function public.payments_integration_succeeded() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_currency  text;
  v_amount    bigint;
  v_what      text;
  v_extra     jsonb;
  v_inv       public.invoices;
  v_job_num   bigint;
begin
  if new.status <> 'succeeded'
     or (tg_op = 'UPDATE' and old.status in ('succeeded', 'partially_refunded', 'refunded')) then
    return null;
  end if;
  begin
    if not public.integration_claim_event(new.shop_id, 'payment_succeeded', p_payment_id => new.id) then
      return null;
    end if;
    select s.currency into v_currency from public.shops s where s.id = new.shop_id;
    v_amount := new.amount_cents + new.tip_cents;
    if new.invoice_id is not null then
      select * into v_inv from public.invoices i where i.id = new.invoice_id and i.shop_id = new.shop_id;
    end if;
    if new.job_id is not null then
      select j.number into v_job_num from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
    end if;
    v_what := case
      when new.kind = 'membership' then
        (select 'Membership: ' || p.name
           from public.memberships m join public.membership_plans p on p.id = m.plan_id and p.shop_id = m.shop_id
          where m.id = new.membership_id and m.shop_id = new.shop_id)
      when new.kind = 'deposit' and v_job_num is not null then 'Deposit for job #' || v_job_num::text
      when v_inv.id is not null then 'Invoice #' || v_inv.number::text
      when v_job_num is not null then 'Job #' || v_job_num::text
    end;

    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'payment_received',
      'Payment received: ' || public.format_money(v_amount, v_currency) || ' from '
        || public.integration_customer_label(new.shop_id, new.customer_id),
      concat_ws(' · ', v_what, replace(new.method::text, '_', ' '),
                case when new.tip_cents > 0 then 'includes ' || public.format_money(new.tip_cents, v_currency) || ' tip' end),
      new.job_id, new.recorded_by);

    if new.kind in ('deposit', 'payment') then
      v_extra := jsonb_build_object('amount', public.format_money(v_amount, v_currency));
      if v_inv.id is not null then
        v_extra := v_extra || jsonb_build_object(
          'balance', public.format_money(greatest(v_inv.balance_cents, 0), v_currency),
          'invoice_link', case when v_inv.status not in ('draft', 'void')
                               then public.app_url('/i/' || v_inv.public_token::text) end);
      end if;
      -- one receipt per payment (the ledger), so no per-job de-duplication
      perform public.integration_send_customer_template(new.shop_id, new.customer_id, 'payment_receipt', new.job_id,
                                                        v_extra, false);
    end if;
  exception when others then
    raise warning 'payment side effects failed for payment %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger payments_zz_integration_succeeded after insert or update of status on public.payments
  for each row execute function public.payments_integration_succeeded();

-- ---------------------------------------------------------------------------
-- Forms: signed -> staff notification (not the staff member who signed on
-- their device).
-- ---------------------------------------------------------------------------
create function public.form_submissions_integration_signed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job_num bigint;
begin
  begin
    if not public.integration_claim_event(new.shop_id, 'form_signed', p_form_submission_id => new.id) then
      return null;
    end if;
    select j.number into v_job_num from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
    perform public.notify_shop_staff(
      new.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'form_signed',
      'Form signed: ' || new.title,
      concat_ws(' · ', 'Signed by ' || new.signer_name, 'Job #' || v_job_num::text),
      new.job_id, new.signed_by);
  exception when others then
    raise warning 'form signed side effects failed for form %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger form_submissions_zz_integration_signed after update of signed_at on public.form_submissions
  for each row when (old.signed_at is null and new.signed_at is not null)
  execute function public.form_submissions_integration_signed();

-- ---------------------------------------------------------------------------
-- Memberships: first activation -> membership_welcome to the customer.
-- (past_due -> active is a recovery, not a new membership: the ledger keeps
-- it to one welcome per membership.)
-- ---------------------------------------------------------------------------
create function public.memberships_integration_activated() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then
    return null;
  end if;
  begin
    if public.integration_claim_event(new.shop_id, 'membership_activated', p_membership_id => new.id) then
      perform public.integration_send_customer_template(new.shop_id, new.customer_id, 'membership_welcome', null,
                                                        null, false);
    end if;
  exception when others then
    raise warning 'membership side effects failed for membership %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger memberships_zz_integration_activated after insert or update of status on public.memberships
  for each row execute function public.memberships_integration_activated();

-- ---------------------------------------------------------------------------
-- Grants: all internal.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.jobs_integration_status_events(),
  public.quotes_integration_response(),
  public.payments_integration_succeeded(),
  public.form_submissions_integration_signed(),
  public.memberships_integration_activated()
from public, anon, authenticated;

revoke execute on function
  public.integration_claim_event(uuid, text, uuid, uuid, uuid, uuid),
  public.integration_customer_label(uuid, uuid),
  public.integration_send_customer_template(uuid, uuid, public.message_template_key, uuid, jsonb, boolean),
  public.integration_online_booking_created(uuid)
from public, anon, authenticated;
grant execute on function
  public.integration_claim_event(uuid, text, uuid, uuid, uuid, uuid),
  public.integration_customer_label(uuid, uuid),
  public.integration_send_customer_template(uuid, uuid, public.message_template_key, uuid, jsonb, boolean),
  public.integration_online_booking_created(uuid)
to service_role;
