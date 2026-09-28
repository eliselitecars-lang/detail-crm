-- ============================================================================
-- 0062 — Coupon restrictions (P-13a) and discount-eligible totals.
--
-- Totals (SPEC §4.5, the one implementation is compute_document_totals):
-- each line may be discount-eligible or not (default: eligible).
--   E  = Σ line_total of eligible lines, ET = Σ taxable line_total of them
--   discount         = percent: round(E × bps / 10000) | fixed: value; ≤ E
--   taxable_discount = E > 0 ? round(discount × ET / E) : 0
--   tax              = round((taxable_subtotal − taxable_discount) × rate / 10000)
--   total            = subtotal − discount + tax
-- With every line eligible E = subtotal and ET = taxable subtotal, so the
-- result is exactly the previous formula (00_totals.sql).
--
-- Coupon rules:
--   * service_ids: a job line is discount-eligible when the job's coupon has
--     no service list or lists the line's service (job_line_items_60_money,
--     re-stamped when the job's coupon changes, jobs_zz_money_coupon_lines,
--     or the coupon's list changes on open jobs — not billed, closed or
--     paid, coupons_zz_money_restamp). Eligibility is frozen once the job
--     is billed, and referential actions (a deleted coupon, service or
--     vehicle) never re-derive it, so a billed or settled job's total keeps
--     matching what it was billed / paid at. A job
--     whose coupon discounts none of its lines is refused, and so is one
--     whose eligible subtotal is below min_subtotal_cents — checked when the
--     transaction commits (DEFERRABLE jobs_zz_money_coupon_check), because
--     create_online_booking inserts the lines after the job.
--   * customer_id / once_per_customer / new_customers_only: checked when a
--     coupon is attached or the job moves to another customer, in EVERY
--     context (online bookings included): jobs_61_money_coupon_rules.
--     An online booking made through the API by someone NOT proven to be
--     the matched customer (anyone may type any email or phone, and a
--     referral code is shared publicly) must not learn whether that contact
--     is a returning customer, has redeemed the coupon or owns it: its
--     customer rules are checked when the transaction commits instead
--     (DEFERRABLE jobs_zzz_money_coupon_booking, after every other check,
--     jobs_zz_money_coupon_check included, so the validation order and the
--     other errors never depend on the match) and every failure there reads
--     the same neutral message (coupon_booking_refused_message). A
--     customer-specific coupon is refused there even with its owner's
--     contact details (typing them proves nothing, and success would name
--     the owner; public_validate_coupon already calls it not valid for an
--     anonymous visitor): its owner signs in to use it. Proven =
--     the customer is linked to the signed-in caller (portal_user_id =
--     auth.uid()) or the caller is a manager+ of the shop; service_role and
--     direct sessions keep the immediate, specific reason
--     (coupon_rules_masked).
--   * one coupon_redemptions row per job carrying a coupon (every context,
--     jobs_zz_money_coupon_redemption); removed with the coupon or the job.
--     The redemption counter on coupons works as before (jobs_apply_coupon /
--     create_online_booking), so coupon_release_for_job needs no change.
--   * referrer_customer_id (referral coupons, 0069) is server-set only, and
--     a referral coupon's code (= the customer's referral code) is fixed.
-- Customer merge (P-20): while merge_customers runs (GUC
-- detailcrm.customer_merge = 'on', trusted context) moving a job to the
-- surviving customer neither re-checks its coupon nor moves its redemption
-- row (merge_customers moves coupon_redemptions itself).
-- Also here:
--   * jobs_apply_coupon (0012, redefined): the billed-job coupon freeze
--     covers grouped invoices (invoice_jobs), not only invoices.job_id.
--   * job lines of a job WITHOUT a coupon keep the discount_eligible server
--     code gives them (quote conversions, 0067); client writes still cannot
--     change it (job_line_items_60_money).
--   * a referee with a referral credit (0069) is no longer a new customer
--     (coupon_customer_reason), even after the rewarded job was deleted.
--   * public_validate_coupon prices the booking's auto-applied fees (0068)
--     for p_location_type, so its preview equals the booked job.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- compute_document_totals — same signature; lines may carry
-- discount_eligible (default true).
-- ---------------------------------------------------------------------------
create or replace function public.compute_document_totals(
  p_lines          jsonb,
  p_discount_kind  public.discount_kind default 'none',
  p_discount_value bigint default 0,
  p_tax_rate_bps   integer default 0
) returns public.document_totals
language plpgsql immutable
set search_path = ''
as $$
declare
  v_line        jsonb;
  v_qty         numeric;
  v_price       bigint;
  v_line_disc   bigint;
  v_taxable     boolean;
  v_eligible    boolean;
  v_line_total  bigint;
  v_e           bigint := 0;
  v_et          bigint := 0;
  r             public.document_totals;
begin
  if p_lines is null then
    p_lines := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;
  if p_tax_rate_bps is null or p_tax_rate_bps < 0 or p_tax_rate_bps > 10000 then
    raise exception 'tax_rate_bps must be between 0 and 10000' using errcode = '22023';
  end if;
  p_discount_kind := coalesce(p_discount_kind, 'none');
  p_discount_value := coalesce(p_discount_value, 0);
  if p_discount_value < 0 then
    raise exception 'discount value cannot be negative' using errcode = '22023';
  end if;
  if p_discount_kind = 'percent' and p_discount_value > 10000 then
    raise exception 'percent discount cannot exceed 10000 bps' using errcode = '22023';
  end if;

  r.subtotal_cents := 0;
  r.taxable_subtotal_cents := 0;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'each line must be a JSON object' using errcode = '22023';
    end if;
    if coalesce(jsonb_typeof(v_line -> 'discount_eligible'), 'null') not in ('boolean', 'null') then
      raise exception 'discount_eligible must be true or false' using errcode = '22023';
    end if;
    v_qty       := coalesce((v_line ->> 'quantity')::numeric, 1);
    v_price     := (v_line ->> 'unit_price_cents')::bigint;
    v_line_disc := coalesce((v_line ->> 'discount_cents')::bigint, 0);
    v_taxable   := coalesce((v_line ->> 'taxable')::boolean, true);
    v_eligible  := coalesce((v_line ->> 'discount_eligible')::boolean, true);
    if v_price is null or v_price < 0 then
      raise exception 'unit_price_cents must be a non-negative integer' using errcode = '22023';
    end if;
    if v_qty <= 0 then
      raise exception 'quantity must be positive' using errcode = '22023';
    end if;
    if v_line_disc < 0 then
      raise exception 'line discount cannot be negative' using errcode = '22023';
    end if;
    v_line_total := public.line_total_cents(v_qty, v_price, v_line_disc);
    r.subtotal_cents := r.subtotal_cents + v_line_total;
    if v_taxable then
      r.taxable_subtotal_cents := r.taxable_subtotal_cents + v_line_total;
    end if;
    if v_eligible then
      v_e := v_e + v_line_total;
      if v_taxable then
        v_et := v_et + v_line_total;
      end if;
    end if;
  end loop;

  r.discount_cents := case p_discount_kind
    when 'percent' then round(v_e::numeric * p_discount_value / 10000)::bigint
    when 'fixed'   then p_discount_value
    else 0
  end;
  r.discount_cents := least(r.discount_cents, v_e);

  r.taxable_discount_cents := case
    when v_e > 0 then round(r.discount_cents::numeric * v_et / v_e)::bigint
    else 0
  end;

  r.tax_cents := round((r.taxable_subtotal_cents - r.taxable_discount_cents)::numeric
                       * p_tax_rate_bps / 10000)::bigint;
  r.total_cents := r.subtotal_cents - r.discount_cents + r.tax_cents;
  return r;
end
$$;

comment on function public.compute_document_totals(jsonb, public.discount_kind, bigint, integer) is
  'Canonical SPEC §4.5 totals. Pure; reused by jobs, quotes and invoices. The document discount applies to discount-eligible lines only (discount_eligible, default true).';

-- ---------------------------------------------------------------------------
-- jobs_compute_totals / invoices_compute — pass discount_eligible.
-- ---------------------------------------------------------------------------
create or replace function public.jobs_compute_totals() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t public.document_totals;
begin
  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(jsonb_build_object(
                             'quantity', li.quantity,
                             'unit_price_cents', li.unit_price_cents,
                             'discount_cents', li.discount_cents,
                             'taxable', li.taxable,
                             'discount_eligible', li.discount_eligible)), '[]'::jsonb)
              from public.job_line_items li
             where li.job_id = new.id and li.shop_id = new.shop_id),
           new.discount_kind, new.discount_value, new.tax_rate_bps);

  new.subtotal_cents := v_t.subtotal_cents;
  new.discount_cents := v_t.discount_cents;
  new.tax_cents := v_t.tax_cents;
  new.total_cents := v_t.total_cents;
  return new;
end
$$;

create or replace function public.invoices_compute() returns trigger
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
                             'taxable', li.taxable,
                             'discount_eligible', li.discount_eligible)), '[]'::jsonb)
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

-- ---------------------------------------------------------------------------
-- coupons: redemptions and referral links are server-maintained.
-- ---------------------------------------------------------------------------
create or replace function public.coupons_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    if tg_op = 'INSERT' then
      new.redemptions := 0;
      new.referrer_customer_id := null;
    else
      new.redemptions := old.redemptions;
      new.referrer_customer_id := old.referrer_customer_id;
      -- a referral coupon's code is its customer's referral code (share links)
      if old.referrer_customer_id is not null and new.code is distinct from old.code then
        raise exception 'the code of a referral coupon cannot be changed' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end
$$;

-- service_ids: this shop's services, de-duplicated and sorted; an empty list
-- means "every service" (null). Only ids being added are validated, so a
-- service deleted since stays listed and simply matches nothing (the coupon
-- is never widened to every service). SECURITY DEFINER so trusted inserts
-- (referral coupons) work the same; another shop's service is "not found".
create function public.coupons_money_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_old uuid[] := case when tg_op = 'UPDATE' then coalesce(old.service_ids, '{}') else '{}'::uuid[] end;
begin
  if new.service_ids is not null then
    if exists (select 1 from unnest(new.service_ids) as x
               where x is not null and x <> all (v_old)
                 and not exists (select 1 from public.services s where s.id = x and s.shop_id = new.shop_id)) then
      raise exception 'coupon services must belong to this shop' using errcode = '23503';
    end if;
    new.service_ids := array(select distinct x from unnest(new.service_ids) as x where x is not null order by 1);
    if cardinality(new.service_ids) = 0 then
      new.service_ids := null;
    end if;
  end if;
  return new;
end
$$;

create trigger coupons_60_money_validate before insert or update on public.coupons
  for each row execute function public.coupons_money_validate();

-- ---------------------------------------------------------------------------
-- Rule helpers (internal: definer code and service_role only).
-- ---------------------------------------------------------------------------

-- Why p_customer_id may not use the coupon (null = allowed). p_job_id is the
-- job being written (its own redemption / completion does not count).
create function public.coupon_customer_reason(p_coupon public.coupons, p_customer_id uuid, p_job_id uuid default null)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when p_coupon.customer_id is not null and p_coupon.customer_id is distinct from p_customer_id
      then 'this coupon is not valid for this customer'
    when p_customer_id is null then null
    when p_coupon.once_per_customer
         and exists (select 1 from public.coupon_redemptions r
                      where r.shop_id = p_coupon.shop_id and r.coupon_id = p_coupon.id
                        and r.customer_id = p_customer_id and r.job_id is distinct from p_job_id)
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

-- First rule p_coupon fails for p_customer_id (null = unknown customer:
-- only a customer-specific coupon fails) and p_lines at p_now, or null.
-- p_lines: [{service_id?, quantity?, unit_price_cents, discount_cents?}].
create function public.coupon_restriction_reason(
  p_coupon       public.coupons,
  p_customer_id  uuid,
  p_lines        jsonb,
  p_now          timestamptz
) returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_reason    text;
  v_eligible  bigint := 0;
  v_any       boolean := false;
  v_currency  text;
  e           jsonb;
begin
  v_reason := public.coupon_unavailable_reason(p_coupon, coalesce(p_now, now()));
  if v_reason is not null then
    return v_reason;
  end if;
  v_reason := public.coupon_customer_reason(p_coupon, p_customer_id, null);
  if v_reason is not null then
    return v_reason;
  end if;
  for e in select value from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]' end) loop
    if p_coupon.service_ids is null
       or ((e ->> 'service_id') is not null and (e ->> 'service_id')::uuid = any (p_coupon.service_ids)) then
      v_any := true;
      v_eligible := v_eligible + public.line_total_cents(coalesce((e ->> 'quantity')::numeric, 1),
                                                         (e ->> 'unit_price_cents')::bigint,
                                                         coalesce((e ->> 'discount_cents')::bigint, 0));
    end if;
  end loop;
  if p_coupon.service_ids is not null and not v_any then
    return 'this coupon does not apply to the selected services';
  end if;
  if p_coupon.min_subtotal_cents is not null and v_eligible < p_coupon.min_subtotal_cents then
    select s.currency into v_currency from public.shops s where s.id = p_coupon.shop_id;
    return 'this coupon needs a subtotal of at least ' || public.format_money(p_coupon.min_subtotal_cents, v_currency);
  end if;
  return null;
end
$$;

-- Human summary of a coupon's restrictions (null when it has none).
create function public.coupon_restrictions_text(p_coupon public.coupons) returns text
language sql stable security definer
set search_path = ''
as $$
  select nullif(concat_ws(' ',
    case when p_coupon.service_ids is not null then
      'Applies to ' || coalesce((select string_agg(s.name, ', ' order by s.sort, s.name)
                                   from public.services s
                                  where s.shop_id = p_coupon.shop_id and s.id = any (p_coupon.service_ids)
                                    and s.archived_at is null), 'selected services') || '.' end,
    case when p_coupon.min_subtotal_cents is not null then
      'Minimum order ' || public.format_money(p_coupon.min_subtotal_cents,
                                              (select s.currency from public.shops s where s.id = p_coupon.shop_id)) || '.' end,
    case when p_coupon.new_customers_only then 'New customers only.' end,
    case when p_coupon.once_per_customer then 'One use per customer.' end,
    case when p_coupon.customer_id is not null then 'For one customer only.' end), '')
$$;

-- Whether a job's coupon customer rules must not answer immediately and
-- specifically (see the header): an online booking made through the API by
-- a caller not proven to be the job's customer — neither a manager+ of the
-- shop nor the client whose portal account is linked to that customer.
create function public.coupon_rules_masked(p_shop_id uuid, p_customer_id uuid, p_source public.job_source)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_source = 'online_booking'
     and public.is_api_request()
     and not public.is_shop_manager(p_shop_id)
     and not coalesce(auth.uid() is not null
                      and exists (select 1 from public.customers c
                                   where c.id = p_customer_id and c.shop_id = p_shop_id
                                     and c.portal_user_id = auth.uid()), false)
$$;

-- The one answer an unproven online booker gets for any customer rule.
create function public.coupon_booking_refused_message() returns text
language sql immutable
set search_path = ''
as $$
  select 'this coupon cannot be used for this booking; remove it to book, or sign in to your account and try again'::text
$$;

-- ---------------------------------------------------------------------------
-- jobs: customer rules in every context (BEFORE; runs after
-- jobs_35_apply_coupon — any failure rolls the whole write back). An
-- unproven online booking is left to jobs_zzz_money_coupon_booking (commit).
-- ---------------------------------------------------------------------------
create function public.jobs_money_coupon_rules() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_c       public.coupons;
  v_reason  text;
begin
  if new.coupon_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.coupon_id is not distinct from old.coupon_id then
    if new.customer_id is not distinct from old.customer_id then
      return new;
    end if;
    -- customer merge: the job moves with its coupon (merge_customers)
    if coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
      return new;
    end if;
  end if;
  select * into v_c from public.coupons c where c.id = new.coupon_id and c.shop_id = new.shop_id;
  if not found then
    return new;   -- another shop's coupon: the composite FK rejects the write
  end if;
  v_reason := public.coupon_customer_reason(v_c, new.customer_id, new.id);
  if v_reason is not null then
    if tg_op = 'INSERT' and public.coupon_rules_masked(new.shop_id, new.customer_id, new.source) then
      return new;   -- refused at commit, with the neutral message, after every other check
    end if;
    raise exception '%', v_reason using errcode = '22023';
  end if;
  return new;
end
$$;

create trigger jobs_61_money_coupon_rules before insert or update on public.jobs
  for each row execute function public.jobs_money_coupon_rules();

-- ---------------------------------------------------------------------------
-- job_line_items: discount eligibility follows the job's coupon.
--   * job WITH a coupon: a new line is stamped from the coupon's service
--     list; an existing line is re-stamped only when its writer changes its
--     service, or when server code re-stamps it (jobs_money_coupon_lines /
--     coupons_money_restamp_jobs). Client writes of discount_eligible are
--     ignored, and every other edit keeps the line's value — including the
--     referential actions that edit lines behind the writer's back (a
--     deleted service clears service_id, a deleted vehicle clears
--     vehicle_id): the line keeps the eligibility it was priced with, even
--     when the coupon's list was edited since (a job the list edit did not
--     re-stamp, see coupons_money_restamp_jobs).
--   * job WITHOUT a coupon: server code keeps the value it supplies — a
--     quote conversion copies each quote line's discount_eligible
--     (convert_quote_to_job_core, 0067), so the job total equals the
--     approved quote; client (PostgREST) writes cannot change it: a new
--     line is eligible, an edited line keeps its value.
--   * a BILLED job (a live invoice_jobs row: single-job or grouped invoice)
--     never changes an existing line's eligibility: its invoice copied the
--     discount, so the job's total must keep matching what it was billed.
-- Removing a coupon re-stamps every line eligible (jobs_money_coupon_lines),
-- except when the coupon was deleted: the job keeps its discount
-- (jobs_apply_coupon leaves discount_kind / value outside client writes)
-- and its lines keep their eligibility, so the discount still covers what
-- it covered.
-- SECURITY INVOKER so is_client_context() sees who writes: a SECURITY
-- DEFINER RPC (or trigger) is server code, a PostgREST write is a client
-- write, and a referential action runs as the table owner. Client writers
-- are managers+ (job_line_items policies), who read the shop's jobs,
-- coupons, services and invoice_jobs.
-- ---------------------------------------------------------------------------
create function public.job_line_items_money_eligible() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_ids     uuid[];
  v_coupon  boolean;
begin
  if tg_op = 'UPDATE'
     and exists (select 1 from public.invoice_jobs ij
                  where ij.shop_id = new.shop_id and ij.job_id = new.job_id and not ij.voided) then
    new.discount_eligible := old.discount_eligible;
    return new;
  end if;
  select true, c.service_ids into v_coupon, v_ids
    from public.jobs j
    join public.coupons c on c.id = j.coupon_id and c.shop_id = j.shop_id
   where j.id = new.job_id and j.shop_id = new.shop_id;
  if coalesce(v_coupon, false) then
    if tg_op = 'INSERT'
       or (new.service_id is distinct from old.service_id
           -- ON DELETE SET NULL of the line's service: not the writer's edit
           and not (new.service_id is null
                    and not exists (select 1 from public.services s
                                     where s.id = old.service_id and s.shop_id = old.shop_id)))
       or (new.discount_eligible is distinct from old.discount_eligible and not public.is_client_context()) then
      new.discount_eligible := v_ids is null or (new.service_id is not null and new.service_id = any (v_ids));
    else
      new.discount_eligible := old.discount_eligible;
    end if;
  elsif public.is_client_context() then
    new.discount_eligible := case when tg_op = 'INSERT' then true else old.discount_eligible end;
  else
    new.discount_eligible := coalesce(new.discount_eligible, true);
  end if;
  return new;
end
$$;

create trigger job_line_items_60_money before insert or update on public.job_line_items
  for each row execute function public.job_line_items_money_eligible();

-- A new / changed / removed coupon re-stamps the job's lines (each line
-- update recomputes the job's totals) — not on a billed job (its lines are
-- frozen, see above), and not when the coupon was DELETED (ON DELETE SET
-- NULL of jobs_coupon_fk: the coupon row is gone): the job keeps the
-- discount it received and the lines it covered.
create function public.jobs_money_coupon_lines() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if new.coupon_id is null and old.coupon_id is not null
     and not exists (select 1 from public.coupons c where c.id = old.coupon_id) then
    return null;
  end if;
  if exists (select 1 from public.invoice_jobs ij
              where ij.shop_id = new.shop_id and ij.job_id = new.id and not ij.voided) then
    return null;
  end if;
  select c.service_ids into v_ids from public.coupons c where c.id = new.coupon_id and c.shop_id = new.shop_id;
  update public.job_line_items li
     set discount_eligible = (v_ids is null or (li.service_id is not null and li.service_id = any (v_ids)))
   where li.job_id = new.id and li.shop_id = new.shop_id
     and li.discount_eligible is distinct from (v_ids is null or (li.service_id is not null and li.service_id = any (v_ids)));
  return null;
end
$$;

create trigger jobs_zz_money_coupon_lines after update of coupon_id on public.jobs
  for each row when (new.coupon_id is distinct from old.coupon_id)
  execute function public.jobs_money_coupon_lines();

-- Editing a coupon's service list re-stamps the lines of its OPEN jobs only:
-- a job whose price is settled keeps the eligibility it was priced with,
-- the same way the coupon's kind / value were snapshotted onto the job when
-- the coupon was attached (a value edit never changes existing jobs). A job
-- is settled when it is
--   * billed (a live invoice_jobs row: its invoice copied the discount),
--   * closed (completed, cancelled or no-show), or
--   * paid in part or in full: a payment of the job was received
--     (succeeded / partially_refunded / refunded) or is in flight
--     (payment_in_flight) — e.g. an online booking's deposit, computed
--     from and paid against the booked total.
-- Such a job only takes the new list when its coupon is attached again
-- (jobs_money_coupon_lines) or a line's service changes.
create function public.coupons_money_restamp_jobs() returns trigger
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
     and li.discount_eligible is distinct from
         (new.service_ids is null or (li.service_id is not null and li.service_id = any (new.service_ids)));
  return null;
end
$$;

create trigger coupons_zz_money_restamp after update of service_ids on public.coupons
  for each row when (new.service_ids is distinct from old.service_ids)
  execute function public.coupons_money_restamp_jobs();

-- ---------------------------------------------------------------------------
-- coupon_redemptions: one row per job with a coupon (every context).
-- ---------------------------------------------------------------------------
create function public.jobs_money_coupon_redemption() returns trigger
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
    insert into public.coupon_redemptions as r (shop_id, coupon_id, customer_id, job_id, once_per_customer)
    select new.shop_id, c.id, new.customer_id, new.id, c.once_per_customer
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

create trigger jobs_zz_money_coupon_redemption after insert or update of coupon_id, customer_id on public.jobs
  for each row execute function public.jobs_money_coupon_redemption();

-- ---------------------------------------------------------------------------
-- Service list / minimum subtotal: at commit (DEFERRABLE INITIALLY
-- DEFERRED), against the job's lines then. Tests force it with
--   set constraints jobs_zz_money_coupon_check immediate;
-- ---------------------------------------------------------------------------
create function public.jobs_money_coupon_check() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job       public.jobs;
  v_c         public.coupons;
  v_eligible  bigint;
  v_any       boolean;
  v_currency  text;
begin
  select * into v_job from public.jobs j where j.id = new.id;
  if not found or v_job.coupon_id is null then
    return null;
  end if;
  select * into v_c from public.coupons c where c.id = v_job.coupon_id and c.shop_id = v_job.shop_id;
  if not found or (v_c.service_ids is null and v_c.min_subtotal_cents is null) then
    return null;
  end if;
  select coalesce(sum(li.total_cents) filter (where li.discount_eligible), 0),
         coalesce(bool_or(li.discount_eligible), false)
    into v_eligible, v_any
    from public.job_line_items li
   where li.job_id = v_job.id and li.shop_id = v_job.shop_id;
  if v_c.service_ids is not null and not v_any then
    raise exception 'coupon %: this coupon does not apply to the selected services', v_c.code using errcode = '22023';
  end if;
  if v_c.min_subtotal_cents is not null and v_eligible < v_c.min_subtotal_cents then
    select s.currency into v_currency from public.shops s where s.id = v_job.shop_id;
    raise exception 'coupon %: this coupon needs a subtotal of at least %', v_c.code,
      public.format_money(v_c.min_subtotal_cents, v_currency) using errcode = '22023';
  end if;
  return null;
end
$$;

create constraint trigger jobs_zz_money_coupon_check after insert or update of coupon_id on public.jobs
  deferrable initially deferred
  for each row execute function public.jobs_money_coupon_check();

-- ---------------------------------------------------------------------------
-- Customer rules of an unproven online booking (see the header): at commit,
-- after jobs_zz_money_coupon_check (same event, trigger name order), so an
-- anonymous booker gets exactly the errors an unknown contact would get
-- until everything else has passed, and then one neutral message whatever
-- rule failed (a customer-specific coupon always fails here: see the header). A job that is not (or no longer) masked was checked by
-- jobs_61_money_coupon_rules already. The job must also carry its
-- redemption row (jobs_money_coupon_redemption leaves it out when the
-- customer's once-per-customer use is taken). Tests force it with
--   set constraints jobs_zzz_money_coupon_booking immediate;
-- ---------------------------------------------------------------------------
create function public.jobs_money_coupon_booking_check() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_c    public.coupons;
begin
  select * into v_job from public.jobs j where j.id = new.id;
  if not found or v_job.coupon_id is null
     or not public.coupon_rules_masked(v_job.shop_id, v_job.customer_id, v_job.source) then
    return null;
  end if;
  select * into v_c from public.coupons c where c.id = v_job.coupon_id and c.shop_id = v_job.shop_id;
  if not found then
    return null;
  end if;
  if v_c.customer_id is not null
     or public.coupon_customer_reason(v_c, v_job.customer_id, v_job.id) is not null
     or not exists (select 1 from public.coupon_redemptions r
                     where r.shop_id = v_job.shop_id and r.job_id = v_job.id and r.coupon_id = v_c.id) then
    raise exception '%', public.coupon_booking_refused_message() using errcode = '22023';
  end if;
  return null;
end
$$;

create constraint trigger jobs_zzz_money_coupon_booking after insert on public.jobs
  deferrable initially deferred
  for each row when (new.coupon_id is not null and new.source = 'online_booking')
  execute function public.jobs_money_coupon_booking_check();

-- ---------------------------------------------------------------------------
-- jobs_apply_coupon (0012) — the billed-job coupon freeze now sees every
-- live invoice of the job through invoice_jobs (0061): a single-job invoice
-- (invoices.job_id, mirrored by 0063's trigger) or a GROUPED one
-- (create_invoice_from_jobs, invoices.job_id null), which carries the job's
-- coupon discount as line discounts. Changing or removing the coupon of a
-- grouped-billed job would release a redemption the invoice billed (and
-- bypass max_redemptions / once_per_customer) while the invoice keeps the
-- discount. Everything else is 0012 unchanged (restriction checks run in
-- every context in jobs_61_money_coupon_rules; redemption rows in
-- jobs_zz_money_coupon_redemption). SECURITY INVOKER as before: client
-- writers are managers+, who read invoice_jobs and invoices.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- public_validate_coupon — discount preview for the booking wizard (0042),
-- now with coupon restrictions and private booking links:
--   p_link_token  a live booking link of the shop (sched 0053): its services
--                 are allowed instead of the online catalog (else PT404)
--   restrictions  services / minimum subtotal always; customer rules for the
--                 signed-in client linked to a customer of the shop (an
--                 anonymous visitor cannot use a customer-specific coupon;
--                 once-per-customer / new-customer rules are enforced when
--                 the booking is created)
--   p_location_type  'shop' | 'mobile' as the booking will be made (null =
--                 the booking's default: mobile for a mobile-only shop, else
--                 shop). The shop's auto-applied fees for it (0068
--                 jobs_zz_money_auto_fees: active, not archived, auto_apply
--                 'both' or this location type) are priced as lines exactly
--                 as the booked job will carry them — discount-eligible only
--                 under a coupon without a service list — so the preview's
--                 totals and the minimum-subtotal check match the job.
--   members       the signed-in client linked to a customer of the shop is
--                 priced as create_online_booking (sched 0054) prices them:
--                 membership-included services at 0 while the membership
--                 has uses left in the billing period of the booking's
--                 start (money 0069 price_services_core), so the totals and
--                 the minimum-subtotal check match the member's job.
--                 p_vehicle_id = the saved vehicle the booking names (only
--                 one of a customer linked to the signed-in client, else
--                 PT404 'vehicle not found', as the booking; its owner is
--                 the customer and its on-file category wins over
--                 p_vehicle_category_id); p_starts_at = the booking's
--                 starts_at, same format as the booking payload (local
--                 wall time in the shop's timezone, or ISO-8601 with an
--                 offset; null = now). Anonymous visitors: catalog prices.
--                 A member's plan discount (applied by the booking only
--                 without a coupon) is not part of the preview's discount.
-- Result keys: valid, message, code, kind, value, description,
-- subtotal_cents, discount_cents, tax_cents, total_cents (fees included),
-- eligible_service_ids (the chosen services the coupon discounts),
-- restrictions_text (human summary; null when none).
-- ---------------------------------------------------------------------------
drop function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz);

create function public.public_validate_coupon(
  p_slug                 text,
  p_code                 text,
  p_service_ids          uuid[],
  p_vehicle_category_id  uuid default null,
  p_now                  timestamptz default now(),
  p_link_token           uuid default null,
  p_location_type        public.location_type default null,
  p_vehicle_id           uuid default null,
  p_starts_at            text default null
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_now       timestamptz := public.effective_now(p_now);
  v_uid       uuid := auth.uid();
  v_shop      public.shops;
  v_enabled   boolean;
  v_code      text := nullif(btrim(p_code), '');
  v_ids       uuid[];
  v_link_ids  uuid[];
  v_pricing   jsonb;
  v_lines     jsonb;
  v_coupon    public.coupons;
  v_customer  uuid;
  v_reason    text;
  v_t         public.document_totals;
  v_base      public.document_totals;
  v_eligible  uuid[];
  v_loc       public.location_type;
  v_fees      jsonb;
  v_cat       uuid := p_vehicle_category_id;
  v_vehicle   uuid;
  v_start     timestamptz;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if p_vehicle_category_id is not null and not exists (
       select 1 from public.vehicle_categories vc where vc.id = p_vehicle_category_id and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  v_ids := array(select distinct x from unnest(p_service_ids) as x where x is not null);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 40 then
    raise exception 'too many services (max 40)' using errcode = '22023';
  end if;
  if p_link_token is not null then
    v_link_ids := public.booking_link_service_ids(v_shop.id, p_link_token);
    if v_link_ids is null then
      raise exception 'booking link not found' using errcode = 'PT404';
    end if;
    if exists (select 1 from unnest(v_ids) as x where not (x = any (v_link_ids))) then
      raise exception 'one or more services are not available for online booking' using errcode = '22023';
    end if;
  else
    perform public.booking_check_bookable(v_shop.id, v_ids, array['service', 'package', 'addon']::public.service_kind[],
                                          'services');
  end if;
  if p_starts_at is not null then
    v_start := public.booking_parse_start(p_starts_at, v_shop.timezone);
  end if;
  -- the signed-in client's own customer record in this shop, if any: the
  -- saved vehicle's owner (as the booking), else the newest linked record
  if p_vehicle_id is not null then
    select v.id, v.customer_id, coalesce(v.category_id, v_cat) into v_vehicle, v_customer, v_cat
      from public.vehicles v
      join public.customers c on c.id = v.customer_id and c.shop_id = v.shop_id
     where v.id = p_vehicle_id and v.shop_id = v_shop.id and v.archived_at is null and c.archived_at is null
       and v_uid is not null and c.portal_user_id = v_uid;
    if v_vehicle is null then
      raise exception 'vehicle not found' using errcode = 'PT404';
    end if;
  elsif v_uid is not null then
    select c.id into v_customer from public.customers c
     where c.shop_id = v_shop.id and c.portal_user_id = v_uid and c.archived_at is null
     order by c.created_at desc, c.id limit 1;
  end if;
  -- every chosen service has a catalog price for the category (as the booking)
  v_pricing := public.price_services_core(v_shop.id, null, v_cat, v_ids, null, false);
  if not (v_pricing ->> 'priced')::boolean then
    raise exception 'one or more services are not offered for this vehicle type' using errcode = '22023';
  end if;
  -- a member's included services, as the booking prices them (0069)
  if v_customer is not null then
    v_pricing := public.price_services_core(v_shop.id, v_customer, v_cat, v_ids, v_vehicle, true, v_start);
  end if;
  v_lines := coalesce((select jsonb_agg(jsonb_build_object(
                                'service_id', e ->> 'service_id',
                                'quantity', 1,
                                'unit_price_cents', (e ->> 'unit_price_cents')::bigint,
                                'taxable', (e ->> 'taxable')::boolean) order by o)
                         from jsonb_array_elements(v_pricing -> 'lines') with ordinality as t(e, o)), '[]'::jsonb);
  -- the booking's auto-applied fees (no service: eligible only under a
  -- coupon without a service list, as job_line_items_60_money stamps them)
  v_loc := coalesce(p_location_type,
                    case when v_shop.business_type = 'mobile' then 'mobile' else 'shop' end::public.location_type);
  v_fees := coalesce((select jsonb_agg(jsonb_build_object(
                               'service_id', null,
                               'quantity', 1,
                               'unit_price_cents', f.amount_cents,
                               'taxable', f.taxable) order by f.sort, f.name, f.id)
                        from public.shop_fees f
                       where f.shop_id = v_shop.id and f.active and f.archived_at is null
                         and (f.auto_apply = 'both' or f.auto_apply::text = v_loc::text)), '[]'::jsonb);
  v_lines := v_lines || v_fees;
  v_base := public.compute_document_totals(v_lines, 'none', 0, v_shop.tax_rate_bps);

  if v_code is null or char_length(v_code) > 40 or v_code !~ '^[A-Za-z0-9_-]+$' then
    v_reason := 'this coupon code is not valid';
  else
    select * into v_coupon from public.coupons c where c.shop_id = v_shop.id and lower(c.code::text) = lower(v_code);
    v_reason := public.coupon_unavailable_reason(v_coupon, v_now);
    if v_reason is null then
      v_reason := public.coupon_restriction_reason(v_coupon, v_customer, v_lines, v_now);
    end if;
  end if;

  if v_reason is not null then
    return jsonb_build_object(
      'valid', false,
      'message', v_reason,
      'code', left(v_code, 40),
      'kind', null,
      'value', null,
      'description', null,
      'subtotal_cents', v_base.subtotal_cents,
      'discount_cents', 0,
      'tax_cents', v_base.tax_cents,
      'total_cents', v_base.total_cents,
      'eligible_service_ids', '[]'::jsonb,
      'restrictions_text', case when v_coupon.id is not null
                                     and public.coupon_unavailable_reason(v_coupon, v_now) is null
                                then public.coupon_restrictions_text(v_coupon) end);
  end if;

  -- in the order the services were chosen
  v_eligible := array(select u.x from unnest(p_service_ids) with ordinality as u(x, o)
                       where u.x = any (v_ids) and (v_coupon.service_ids is null or u.x = any (v_coupon.service_ids))
                       group by u.x order by min(u.o));
  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(l || jsonb_build_object(
                                        'discount_eligible', v_coupon.service_ids is null
                                                             or coalesce((l ->> 'service_id')::uuid = any (v_coupon.service_ids),
                                                                         false))),
                            '[]'::jsonb)
              from jsonb_array_elements(v_lines) l),
           v_coupon.kind::text::public.discount_kind, v_coupon.value, v_shop.tax_rate_bps);
  return jsonb_build_object(
    'valid', true,
    'message', null,
    'code', v_coupon.code::text,
    'kind', v_coupon.kind,
    'value', v_coupon.value,
    'description', v_coupon.description,
    'subtotal_cents', v_t.subtotal_cents,
    'discount_cents', v_t.discount_cents,
    'tax_cents', v_t.tax_cents,
    'total_cents', v_t.total_cents,
    'eligible_service_ids', to_jsonb(v_eligible),
    'restrictions_text', public.coupon_restrictions_text(v_coupon));
end
$$;

comment on function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text) is
  'Booking wizard coupon preview (anon): restrictions (services, minimum, customer rules for the signed-in linked client), optional private booking link, the auto-applied fees of the booking''s location type, a signed-in member''s included services (saved vehicle, booking start). Invalid codes answer valid=false.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.coupons_money_validate(),
  public.coupons_money_restamp_jobs(),
  public.jobs_money_coupon_rules(),
  public.job_line_items_money_eligible(),
  public.jobs_money_coupon_lines(),
  public.jobs_money_coupon_redemption(),
  public.jobs_money_coupon_check(),
  public.jobs_money_coupon_booking_check()
from public, anon, authenticated;

revoke execute on function
  public.coupon_rules_masked(uuid, uuid, public.job_source),
  public.coupon_booking_refused_message()
from public, anon, authenticated;
grant execute on function
  public.coupon_rules_masked(uuid, uuid, public.job_source),
  public.coupon_booking_refused_message()
to service_role;

revoke execute on function
  public.coupon_customer_reason(public.coupons, uuid, uuid),
  public.coupon_restriction_reason(public.coupons, uuid, jsonb, timestamptz),
  public.coupon_restrictions_text(public.coupons)
from public, anon, authenticated;
grant execute on function
  public.coupon_customer_reason(public.coupons, uuid, uuid),
  public.coupon_restriction_reason(public.coupons, uuid, jsonb, timestamptz),
  public.coupon_restrictions_text(public.coupons)
to service_role;

revoke execute on function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)
  from public;
grant execute on function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)
  to anon, authenticated, service_role;
