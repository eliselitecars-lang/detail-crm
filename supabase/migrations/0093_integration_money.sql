-- ============================================================================
-- 0093 — Cross-surface money operations (integration phase).
--
--   report_revenue_totals        one-row totals of report_revenue's range
--   sms_number_releases          Twilio numbers whose shop binding ended
--                                (operator worklist, service_role only)
--   set_stripe_refund_total      compare-and-set of a payment's refunded
--                                total (stripe-webhook: refund reversals)
--   apply_stripe_dispute         record a lost / reversed card dispute
--   staff_record_quote_response  staff record a customer's approval / decline
-- ============================================================================

-- ---------------------------------------------------------------------------
-- report_revenue_totals — the totals of report_revenue over [p_from, p_to]
-- in one row (same received-payment rules, shop time zone and caller check:
-- owner/admin/manager), so clients never sum buckets that may be capped.
-- ---------------------------------------------------------------------------
create function public.report_revenue_totals(p_shop_id uuid, p_from date, p_to date)
returns table (
  gross_cents     bigint,
  refunds_cents   bigint,
  net_cents       bigint,
  tips_cents      bigint,
  payments_count  bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tz text;
begin
  perform public.report_caller_role(p_shop_id, false);
  perform public.report_check_range(p_from, p_to);
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;

  return query
  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(least(p.refunded_cents, p.amount_cents)), 0)::bigint,
         coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0)::bigint,
         coalesce(sum(public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0)::bigint,
         count(p.id)
    from public.payments p
   where p.shop_id = p_shop_id
     and p.status in ('succeeded', 'partially_refunded', 'refunded')
     and p.paid_at >= public.report_local_start(p_from, v_tz)
     and p.paid_at < public.report_local_start(p_to + 1, v_tz);
end
$$;

comment on function public.report_revenue_totals(uuid, date, date) is
  'Cash revenue totals over a date range (shop time zone): gross, refunds, net (excl. tips), tips, count. One row.';

-- ---------------------------------------------------------------------------
-- sms_number_releases — when a number stops being bound to a shop (the
-- binding row is deleted, including by the cascade of a deleted shop), the
-- platform still rents it from Twilio. Each unbinding is logged here so the
-- operator knows which numbers to release (or re-assign). service_role only:
-- RLS on, no policies, no API grants. No FK: the shop is usually gone.
-- ---------------------------------------------------------------------------
create table public.sms_number_releases (
  id            uuid primary key default gen_random_uuid(),
  phone_number  text not null,
  shop_id       uuid not null,
  shop_name     text,
  released_at   timestamptz not null default now(),
  constraint sms_number_releases_shop_id_id_key unique (shop_id, id)
);
create index sms_number_releases_released_idx on public.sms_number_releases (released_at desc);

comment on table public.sms_number_releases is
  'Operator worklist: Twilio numbers unbound from their shop (shop deleted or number moved). service_role only.';

alter table public.sms_number_releases enable row level security;
revoke all on public.sms_number_releases from anon, authenticated;
grant select, insert, update, delete on public.sms_number_releases to service_role;

-- The shop's name while it is being deleted (the cascade that removes its
-- numbers no longer sees the shop row): remembered for this transaction.
create function public.shops_remember_name_on_delete() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('detail_crm.deleting_shop', old.id::text || ':' || old.name, true);
  return old;
end
$$;

create trigger shops_90_remember_name_on_delete before delete on public.shops
  for each row execute function public.shops_remember_name_on_delete();

create function public.shop_sms_numbers_log_release() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_name    text;
  v_pending text := current_setting('detail_crm.deleting_shop', true);
begin
  select s.name into v_name from public.shops s where s.id = old.shop_id;
  if v_name is null and v_pending like old.shop_id::text || ':%' then
    v_name := substr(v_pending, char_length(old.shop_id::text) + 2);
  end if;
  insert into public.sms_number_releases (phone_number, shop_id, shop_name)
  values (old.phone_number, old.shop_id, v_name);
  return null;
end
$$;

create trigger shop_sms_numbers_log_release after delete on public.shop_sms_numbers
  for each row execute function public.shop_sms_numbers_log_release();

-- ---------------------------------------------------------------------------
-- set_stripe_refund_total (service_role; stripe-webhook) — sets a received
-- card payment's cumulative refunded amount to p_refunded_cents_total when
-- it still equals p_expected_refunded_cents (compare-and-set: a concurrent
-- refund event changed it otherwise → 40001, Stripe redelivers). Unlike
-- apply_stripe_refund the total may go DOWN (a refund that failed or was
-- cancelled at Stripe gives the money back to the payment). The status
-- follows (payment_refund_status). Unknown intent / other shop: P0002.
-- ---------------------------------------------------------------------------
create function public.set_stripe_refund_total(
  p_shop_id                  uuid,
  p_payment_intent_id        text,
  p_expected_refunded_cents  bigint,
  p_refunded_cents_total     bigint
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments p where p.stripe_payment_intent_id = p_payment_intent_id for update;
  if not found or v_pay.shop_id is distinct from p_shop_id then
    raise exception 'payment for intent % not found', p_payment_intent_id using errcode = 'P0002';
  end if;
  if v_pay.status not in ('succeeded', 'partially_refunded', 'refunded') then
    raise exception 'a % payment has no refunds', v_pay.status using errcode = '22023';
  end if;
  if p_refunded_cents_total is null or p_refunded_cents_total < 0
     or p_refunded_cents_total > v_pay.amount_cents + v_pay.tip_cents then
    raise exception 'refunded total must be between 0 and the charged amount (% cents)',
      v_pay.amount_cents + v_pay.tip_cents using errcode = '22023';
  end if;
  if p_expected_refunded_cents is null then
    raise exception 'the expected refunded total is required' using errcode = '22023';
  end if;
  if v_pay.refunded_cents <> p_expected_refunded_cents then
    raise exception 'refund total changed concurrently' using errcode = '40001';
  end if;
  if v_pay.refunded_cents = p_refunded_cents_total then
    return v_pay;
  end if;
  update public.payments p
     set refunded_cents = p_refunded_cents_total,
         status = public.payment_refund_status(p.amount_cents, p.tip_cents, p_refunded_cents_total)
   where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- apply_stripe_dispute (service_role; stripe-webhook) — records the outcome
-- of a card dispute on the payment (payments.disputed_cents):
--   'lost'                                   → least(p_amount_cents, the
--                                              charge not yet refunded)
--   'won' / 'warning_closed' / 'funds_reinstated' → 0
--   anything else (needs_response, under_review, …) → unchanged
-- Balances, payment_net_amount and revenue are NOT changed: staff decide
-- whether to bill the customer again (SPEC §4.5). Unknown intent / other
-- shop: P0002. Idempotent.
-- ---------------------------------------------------------------------------
create function public.apply_stripe_dispute(
  p_shop_id            uuid,
  p_payment_intent_id  text,
  p_dispute_status     text,
  p_amount_cents       bigint
) returns public.payments
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pay    public.payments;
  v_status text := lower(btrim(p_dispute_status));
  v_new    bigint;
begin
  select * into v_pay from public.payments p where p.stripe_payment_intent_id = p_payment_intent_id for update;
  if not found or v_pay.shop_id is distinct from p_shop_id then
    raise exception 'payment for intent % not found', p_payment_intent_id using errcode = 'P0002';
  end if;
  if v_status is null or v_status = '' then
    raise exception 'dispute status is required' using errcode = '22023';
  end if;
  if v_status = 'lost' then
    if p_amount_cents is null or p_amount_cents < 0 then
      raise exception 'a lost dispute needs its amount' using errcode = '22023';
    end if;
    v_new := greatest(least(p_amount_cents, v_pay.amount_cents + v_pay.tip_cents - v_pay.refunded_cents), 0);
  elsif v_status in ('won', 'warning_closed', 'funds_reinstated') then
    v_new := 0;
  else
    return v_pay;
  end if;
  if v_new = v_pay.disputed_cents then
    return v_pay;
  end if;
  update public.payments p set disputed_cents = v_new where p.id = v_pay.id
  returning * into v_pay;
  return v_pay;
end
$$;

-- ---------------------------------------------------------------------------
-- staff_record_quote_response — staff record that the customer approved or
-- declined a sent quote (e.g. by phone), atomically with the optional lines
-- the customer chose. Owner/admin/manager. Same rules as the customer's own
-- public_respond_quote: only sent / viewed quotes inside their validity.
--   'approve'  p_selected_optional_line_ids (when not null) must be optional
--              lines of this quote and becomes exactly the selected set; null
--              keeps the current selections. approved_by_name = the name the
--              customer gave (optional, ≤ 200).
--   'decline'  declined_reason (optional, ≤ 1000).
-- Returns the updated quote.
-- ---------------------------------------------------------------------------
create function public.staff_record_quote_response(
  p_quote_id                    uuid,
  p_action                      text,
  p_selected_optional_line_ids  uuid[] default null,
  p_approved_by_name            text default null,
  p_declined_reason             text default null
) returns public.quotes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_q      public.quotes;
  v_tz     text;
  v_action text := lower(btrim(p_action));
  v_name   text := nullif(btrim(p_approved_by_name), '');
  v_reason text := nullif(btrim(p_declined_reason), '');
  v_ids    uuid[];
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found or not public.is_shop_member(v_q.shop_id) then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_q.shop_id) then
    raise exception 'only owners, admins and managers can record a quote response' using errcode = '42501';
  end if;
  if v_action is null or v_action not in ('approve', 'decline') then
    raise exception 'action must be approve or decline' using errcode = '22023';
  end if;
  if v_q.status not in ('sent', 'viewed') then
    raise exception 'this quote can no longer be answered (it is %)', v_q.status using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.valid_until is not null and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    raise exception 'this quote has expired' using errcode = '22023';
  end if;

  if v_action = 'approve' then
    if char_length(v_name) > 200 then
      raise exception 'the approver''s name is too long (max 200 characters)' using errcode = '22023';
    end if;
    if p_selected_optional_line_ids is not null then
      v_ids := array(select distinct x from unnest(p_selected_optional_line_ids) as x where x is not null);
      if exists (select 1 from unnest(v_ids) as x
                 where not exists (select 1 from public.quote_line_items li
                                   where li.id = x and li.quote_id = v_q.id and li.shop_id = v_q.shop_id
                                     and li.optional)) then
        raise exception 'selected items must be optional items of this quote' using errcode = '22023';
      end if;
      update public.quote_line_items li
         set selected = (li.id = any (v_ids))
       where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional
         and li.selected is distinct from (li.id = any (v_ids));
    end if;
    update public.quotes q set status = 'approved', approved_by_name = v_name where q.id = v_q.id
    returning * into v_q;
  else
    if char_length(v_reason) > 1000 then
      raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
    end if;
    update public.quotes q set status = 'declined', declined_reason = v_reason where q.id = v_q.id
    returning * into v_q;
  end if;
  return v_q;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.shops_remember_name_on_delete(),
  public.shop_sms_numbers_log_release()
from public, anon, authenticated;

revoke execute on function public.report_revenue_totals(uuid, date, date) from public, anon;
grant execute on function public.report_revenue_totals(uuid, date, date) to authenticated, service_role;

revoke execute on function
  public.set_stripe_refund_total(uuid, text, bigint, bigint),
  public.apply_stripe_dispute(uuid, text, text, bigint)
from public, anon, authenticated;
grant execute on function
  public.set_stripe_refund_total(uuid, text, bigint, bigint),
  public.apply_stripe_dispute(uuid, text, text, bigint)
to service_role;

revoke execute on function public.staff_record_quote_response(uuid, text, uuid[], text, text) from public, anon;
grant execute on function public.staff_record_quote_response(uuid, text, uuid[], text, text) to authenticated, service_role;
