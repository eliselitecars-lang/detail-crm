-- ============================================================================
-- 0063 — Multi-job invoices (P-7) and the money guards' customer-merge
-- bypasses (P-20 contract).
--
-- invoice_jobs (0061) lists the jobs an invoice bills. A single-job invoice
-- keeps invoices.job_id (its row is maintained by invoices_zz_money_invoice_jobs);
-- a grouped invoice (create_invoice_from_jobs, fleet / dealer work) has
-- job_id null and one row per job. A job has at most one live invoice,
-- single or grouped (unique index invoice_jobs_one_live_invoice); voiding
-- the invoice releases its jobs (voided = true) and hands each job's
-- payments back to the job.
--
-- Grouped invoice lines carry job_id (and each job's vehicle); each job's
-- document discount is carried as line discounts (see
-- create_invoice_from_jobs), so the grouped invoice itself has no document
-- discount. Its total equals the sum of the job totals except for tax
-- rounding: tax is rounded once on the invoice instead of once per job
-- (at most half a cent per job).
--
-- Technicians: a grouped invoice has no job_id, so can_collect_for_invoice
-- (and the invoices / lines / payments policies) give technicians nothing
-- of it; job_payment_summary shows them the job as billed (no invoice
-- details, balance 0 — managers collect grouped invoices).
--
-- Customer merge (P-20): while merge_customers runs (GUC
-- detailcrm.customer_merge = 'on', trusted context) jobs_money_guard,
-- jobs_quote_validate, invoice_jobs' customer guard and jobs_customer_change
-- skip ONLY their customer-ownership check (a merged job keeps its booking
-- link: the customer is the same person).
--
-- Plan note: invoice_line_items_guard (0012) is also redefined here (not in
-- the plan's list; money owns it, redefined once): the ON DELETE SET NULL of
-- the new fee / membership / job link columns must not count as a line edit
-- on an invoice with money. The coupon freeze of a grouped-billed job is in
-- jobs_apply_coupon (0062).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- invoices -> invoice_jobs for single-job invoices; void releases every job.
-- ---------------------------------------------------------------------------
create function public.invoices_money_invoice_jobs() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.job_id is not null and new.job_id is distinct from old.job_id then
    delete from public.invoice_jobs ij where ij.invoice_id = new.id and ij.job_id = old.job_id;
  end if;
  if new.job_id is not null then
    insert into public.invoice_jobs as ij (shop_id, invoice_id, job_id, voided)
    values (new.shop_id, new.id, new.job_id, new.status = 'void')
    on conflict (invoice_id, job_id) do update
      set voided = excluded.voided
      where ij.voided is distinct from excluded.voided;
  end if;
  if new.status = 'void' and (tg_op = 'INSERT' or old.status <> 'void') then
    update public.invoice_jobs ij set voided = true where ij.invoice_id = new.id and not ij.voided;
  end if;
  return null;
end
$$;

create trigger invoices_zz_money_invoice_jobs after insert or update of status, job_id on public.invoices
  for each row execute function public.invoices_money_invoice_jobs();

-- invoice_jobs: a billed job belongs to the invoice's customer.
create function public.invoice_jobs_money_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust uuid;
begin
  if tg_op = 'UPDATE' and new.job_id is not distinct from old.job_id and new.invoice_id is not distinct from old.invoice_id then
    return new;
  end if;
  if coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
    return new;
  end if;
  select i.customer_id into v_cust from public.invoices i where i.id = new.invoice_id and i.shop_id = new.shop_id;
  if found and not exists (select 1 from public.jobs j
                           where j.id = new.job_id and j.shop_id = new.shop_id and j.customer_id = v_cust) then
    raise exception 'the invoice customer must be the job''s customer' using errcode = '23514';
  end if;
  return new;
end
$$;

create trigger invoice_jobs_60_money_validate before insert or update on public.invoice_jobs
  for each row execute function public.invoice_jobs_money_validate();

-- ---------------------------------------------------------------------------
-- invoices_validate — a job invoice belongs to the job's customer, and so do
-- all jobs of a grouped invoice.
-- ---------------------------------------------------------------------------
create or replace function public.invoices_validate() returns trigger
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
  if tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id
     and exists (select 1 from public.invoice_jobs ij
                 join public.jobs j on j.id = ij.job_id and j.shop_id = ij.shop_id
                 where ij.invoice_id = new.id and ij.shop_id = new.shop_id and j.customer_id <> new.customer_id) then
    raise exception 'jobs on this invoice belong to another customer' using errcode = '23514';
  end if;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- invoice lines: a line's job is one of the invoice's jobs; its vehicle
-- belongs to the invoice's customer.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_line_items_validate() returns trigger
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
  if new.job_id is not null
     and (tg_op = 'INSERT' or new.job_id is distinct from old.job_id)
     and not exists (select 1 from public.invoice_jobs ij
                     where ij.invoice_id = new.invoice_id and ij.shop_id = new.shop_id and ij.job_id = new.job_id) then
    raise exception 'the line''s job is not one of this invoice''s jobs' using errcode = '23514';
  end if;
  return null;
end
$$;

-- The line guard (0012) with the range's new link columns: the ON DELETE
-- SET NULL of a deleted fee / membership / job (trusted context, only the
-- link cleared) must not count as a line change on an invoice with money.
create or replace function public.invoice_line_items_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_inv   record;
  v_id    uuid;
  c_links constant text[] := array['service_id', 'vehicle_id', 'job_id', 'fee_id', 'membership_id',
                                   'updated_at', 'total_cents'];
begin
  if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then
    raise exception 'line items cannot move between invoices' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and not public.is_client_context()
     and (new.service_id is null or new.service_id = old.service_id)
     and (new.vehicle_id is null or new.vehicle_id = old.vehicle_id)
     and (new.job_id is null or new.job_id = old.job_id)
     and (new.fee_id is null or new.fee_id = old.fee_id)
     and (new.membership_id is null or new.membership_id = old.membership_id)
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

-- ---------------------------------------------------------------------------
-- payments_before_write — as 0012, with invoice_jobs:
--   * a job payment without an invoice attaches to the job's live invoice,
--     single or grouped
--   * a payment on a grouped invoice keeps its job (one of the invoice's
--     jobs) or has none; on a single-job invoice it takes the invoice's job
--   * money arriving for a void grouped invoice goes back to its own job
--     (then to that job's live invoice), else to the customer, unapplied
--   * gift card payments are recorded against an invoice
-- ---------------------------------------------------------------------------
create or replace function public.payments_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job       uuid;
  v_cust      uuid;
  v_status    public.invoice_status;
  v_number    bigint;
  v_target    uuid;
  v_job_cust  uuid;
begin
  if tg_op = 'INSERT' and new.method = 'gift_card' and new.invoice_id is null then
    raise exception 'gift card payments are recorded against an invoice' using errcode = '23514';
  end if;

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
      if new.job_id is not null and new.job_id is distinct from v_job
         and not exists (select 1 from public.invoice_jobs ij
                         where ij.invoice_id = new.invoice_id and ij.shop_id = new.shop_id and ij.job_id = new.job_id) then
        raise exception 'payment job does not match the invoice''s job' using errcode = '23514';
      end if;
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the invoice''s customer' using errcode = '23514';
      end if;
      v_target := coalesce(new.job_id, v_job);
      if v_target is not null then
        select j.customer_id into v_job_cust from public.jobs j where j.id = v_target and j.shop_id = new.shop_id;
      end if;
      new.invoice_id := null;
      new.customer_id := v_cust;
      if v_target is not null and v_job_cust = v_cust then
        new.job_id := v_target;
      else
        new.job_id := null;
        new.note := coalesce(new.note,
          format('Received for void invoice #%s: apply it to another invoice or refund it', v_number));
      end if;
    end if;
  end if;

  if new.invoice_id is null and new.job_id is not null then
    perform 1 from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id for no key update;
    select ij.invoice_id into new.invoice_id
      from public.invoice_jobs ij
      join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
     where ij.shop_id = new.shop_id and ij.job_id = new.job_id and not ij.voided and i.status <> 'void';
  end if;

  if new.invoice_id is not null then
    select i.job_id, i.customer_id into v_job, v_cust
      from public.invoices i where i.id = new.invoice_id and i.shop_id = new.shop_id
       for no key update;
    if found then
      if v_job is not null then
        if new.job_id is not null and new.job_id is distinct from v_job then
          raise exception 'payment job does not match the invoice''s job' using errcode = '23514';
        end if;
        new.job_id := v_job;
      elsif new.job_id is not null
            and not exists (select 1 from public.invoice_jobs ij
                            where ij.invoice_id = new.invoice_id and ij.shop_id = new.shop_id and ij.job_id = new.job_id) then
        raise exception 'payment job is not one of the invoice''s jobs' using errcode = '23514';
      end if;
      if new.customer_id is not null and new.customer_id <> v_cust then
        raise exception 'payment customer does not match the invoice''s customer' using errcode = '23514';
      end if;
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

-- ---------------------------------------------------------------------------
-- jobs: money keeps the customer (0012) — any live invoice (single or
-- grouped), or real money. A VOID grouped invoice pins it too, exactly as
-- a void single-job invoice does (jobs_customer_records_guard, 0023/0074,
-- which only sees invoices.job_id): the void invoice keeps its invoice_jobs
-- rows, so its /i page lists the job — it must stay the invoice customer's
-- (invoice_jobs_money_validate's invariant). Merge bypass (see header).
-- ---------------------------------------------------------------------------
create or replace function public.jobs_money_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_number bigint;
begin
  if new.customer_id is distinct from old.customer_id
     and not (coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context()) then
    if exists (select 1 from public.invoices i
               where i.job_id = new.id and i.shop_id = new.shop_id and i.status <> 'void')
       or exists (select 1 from public.invoice_jobs ij
                  where ij.job_id = new.id and ij.shop_id = new.shop_id and not ij.voided)
       or exists (select 1 from public.payments p
                  where p.job_id = new.id and p.shop_id = new.shop_id
                    and (p.status in ('succeeded', 'partially_refunded', 'refunded')
                         or public.payment_in_flight(p.status, p.created_at))) then
      raise exception 'this job has an invoice or payments; its customer cannot change' using errcode = '23514';
    end if;
    select i.number into v_number
      from public.invoice_jobs ij
      join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
     where ij.job_id = new.id and ij.shop_id = new.shop_id
     order by i.created_at desc, i.id
     limit 1;
    if found then
      raise exception 'this job is on invoice #% (void) issued to its customer; its customer cannot change (book a new job instead)',
        v_number using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

-- a job's quote is a quote of the job's customer (0010); merge bypass
create or replace function public.jobs_quote_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_number    bigint;
  v_customer  uuid;
begin
  if new.quote_id is null
     or (tg_op = 'UPDATE' and new.quote_id is not distinct from old.quote_id
         and new.customer_id is not distinct from old.customer_id) then
    return null;
  end if;
  if tg_op = 'UPDATE' and new.quote_id is not distinct from old.quote_id
     and coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
    return null;   -- merge_customers moves the quote to the same customer next
  end if;
  select q.number, q.customer_id into v_number, v_customer
    from public.quotes q where q.id = new.quote_id and q.shop_id = new.shop_id;
  if found and v_customer <> new.customer_id then
    if tg_op = 'UPDATE' and new.quote_id is not distinct from old.quote_id then
      raise exception 'this job is linked to quote #% of its previous customer; unlink the quote to move the job to another customer',
        v_number using errcode = '23514';
    end if;
    raise exception 'quote #% belongs to another customer', v_number using errcode = '23514';
  end if;
  return null;
end
$$;

-- a different customer never inherits the previous customer's /booking
-- link (0012) — except a merge: the surviving record is the same person
create or replace function public.jobs_customer_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.customer_id is distinct from old.customer_id
     and not (coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context()) then
    new.public_token := gen_random_uuid();
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- create_invoice_from_job(job) — collector (0013), now invoice_jobs aware:
-- refuses a job on any live invoice (single or grouped), and copies each
-- line's job, discount eligibility, fee and membership.
-- ---------------------------------------------------------------------------
create or replace function public.create_invoice_from_job(p_job_id uuid) returns public.invoices
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
  select i.number into v_existing
    from public.invoice_jobs ij
    join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
   where ij.shop_id = v_job.shop_id and ij.job_id = v_job.id and not ij.voided;
  if found then
    raise exception 'this job already has invoice #%', v_existing using errcode = '23505';
  end if;
  if not exists (select 1 from public.job_line_items li where li.job_id = v_job.id and li.shop_id = v_job.shop_id) then
    raise exception 'the job has no line items to invoice' using errcode = '22023';
  end if;

  insert into public.invoices (shop_id, job_id, customer_id, status, discount_kind, discount_value, tax_rate_bps)
  values (v_job.shop_id, v_job.id, v_job.customer_id, 'draft', v_job.discount_kind, v_job.discount_value, v_job.tax_rate_bps)
  returning * into v_inv;

  insert into public.invoice_line_items (shop_id, invoice_id, job_id, service_id, vehicle_id, name, description,
                                         quantity, unit_price_cents, discount_cents, taxable, discount_eligible,
                                         fee_id, membership_id, sort)
  select v_job.shop_id, v_inv.id, v_job.id, li.service_id, li.vehicle_id, li.name, li.description, li.quantity,
         li.unit_price_cents, li.discount_cents, li.taxable, li.discount_eligible, li.fee_id, li.membership_id,
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

-- ---------------------------------------------------------------------------
-- create_invoice_from_jobs(customer, jobs, notes, internal_notes) —
-- owner/admin/manager. One invoice for 2..100 jobs of one customer (fleet /
-- dealer billing). The jobs are locked in id order; none may be cancelled /
-- no-show or already on a live invoice. Lines are copied in (job
-- scheduled_start, job number, line sort) order with their job and vehicle
-- (the line's, else the job's), discount eligibility, fee and membership.
-- Each job's document discount D becomes line discounts on that job's
-- discount-eligible lines: its taxable share TD = round(D × ET / E) (the
-- canonical formula) over the taxable eligible lines and D − TD over the
-- others, each split in proportion to the line totals by largest remainder
-- (never more than a line's total), so every job's taxable base is exactly
-- what the job had. The invoice therefore has no document discount and the
-- jobs' tax rate (they must share one: 22023 otherwise), and its total
-- differs from the sum of the job totals only by tax rounding (tax is
-- rounded once on the invoice, not per job). Each job's unapplied payments
-- (deposits) are attached, and the invoice is issued (open, due per
-- shops.invoice_due_days). Returns the invoice with public_token = null.
-- ---------------------------------------------------------------------------
create function public.create_invoice_from_jobs(
  p_customer_id     uuid,
  p_job_ids         uuid[],
  p_notes           text default null,
  p_internal_notes  text default null
) returns public.invoices
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust    public.customers;
  v_ids     uuid[];
  v_n       integer;
  v_inv     public.invoices;
  v_bad     record;
  v_rate    integer;
  v_rates   bigint;
begin
  select * into v_cust from public.customers c where c.id = p_customer_id;
  if not found or not public.is_shop_member(v_cust.shop_id) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_cust.shop_id) then
    raise exception 'only owners, admins and managers can invoice several jobs together' using errcode = '42501';
  end if;
  v_ids := array(select distinct x from unnest(coalesce(p_job_ids, '{}'::uuid[])) as x where x is not null order by 1);
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n < 2 or v_n > 100 then
    raise exception 'choose between 2 and 100 jobs for one invoice' using errcode = '22023';
  end if;
  if char_length(p_notes) > 20000 or char_length(p_internal_notes) > 20000 then
    raise exception 'notes are too long (max 20000 characters)' using errcode = '22023';
  end if;

  perform 1 from public.jobs j where j.shop_id = v_cust.shop_id and j.id = any (v_ids) order by j.id for update;
  if (select count(*) from public.jobs j where j.shop_id = v_cust.shop_id and j.id = any (v_ids)) <> v_n then
    raise exception 'one or more jobs were not found' using errcode = '22023';
  end if;
  select j.number into v_bad from public.jobs j
   where j.shop_id = v_cust.shop_id and j.id = any (v_ids) and j.customer_id <> v_cust.id
   order by j.number limit 1;
  if found then
    raise exception 'job #% belongs to another customer', v_bad.number using errcode = '22023';
  end if;
  select j.number, j.status into v_bad from public.jobs j
   where j.shop_id = v_cust.shop_id and j.id = any (v_ids) and j.status in ('cancelled', 'no_show')
   order by j.number limit 1;
  if found then
    raise exception 'job #% is % and cannot be invoiced', v_bad.number, replace(v_bad.status::text, '_', '-')
      using errcode = '22023';
  end if;
  select j.number, i.number as invoice_number into v_bad
    from public.invoice_jobs ij
    join public.jobs j on j.id = ij.job_id and j.shop_id = ij.shop_id
    join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
   where ij.shop_id = v_cust.shop_id and ij.job_id = any (v_ids) and not ij.voided
   order by j.number limit 1;
  if found then
    raise exception 'job #% is already billed on invoice #%', v_bad.number, v_bad.invoice_number using errcode = '22023';
  end if;
  if not exists (select 1 from public.job_line_items li where li.shop_id = v_cust.shop_id and li.job_id = any (v_ids)) then
    raise exception 'the jobs have no line items to invoice' using errcode = '22023';
  end if;
  -- one invoice has one tax rate: the jobs' (e.g. a tax-exempt fleet account)
  select min(j.tax_rate_bps), count(distinct j.tax_rate_bps) into v_rate, v_rates
    from public.jobs j where j.shop_id = v_cust.shop_id and j.id = any (v_ids);
  if v_rates > 1 then
    raise exception 'these jobs have different tax rates; invoice them separately or align their tax rates'
      using errcode = '22023';
  end if;

  insert into public.invoices (shop_id, customer_id, status, notes, internal_notes, tax_rate_bps)
  values (v_cust.shop_id, v_cust.id, 'draft', nullif(btrim(p_notes), ''), nullif(btrim(p_internal_notes), ''), v_rate)
  returning * into v_inv;

  insert into public.invoice_jobs (shop_id, invoice_id, job_id)
  select v_cust.shop_id, v_inv.id, x from unnest(v_ids) as x;

  insert into public.invoice_line_items (shop_id, invoice_id, job_id, service_id, vehicle_id, name, description,
                                         quantity, unit_price_cents, discount_cents, taxable, discount_eligible,
                                         fee_id, membership_id, sort)
  with lines as (
    select li.id, li.job_id, li.service_id, coalesce(li.vehicle_id, j.vehicle_id) as vehicle_id, li.name,
           li.description, li.quantity, li.unit_price_cents, li.discount_cents, li.taxable, li.discount_eligible,
           li.fee_id, li.membership_id, li.total_cents as t, li.sort, li.created_at,
           j.discount_cents as d, j.scheduled_start, j.number as job_number
      from public.job_line_items li
      join public.jobs j on j.id = li.job_id and j.shop_id = li.shop_id
     where li.shop_id = v_cust.shop_id and li.job_id = any (v_ids)
  ), job_base as (
    select l.job_id,
           max(l.d) as d,
           coalesce(sum(l.t) filter (where l.discount_eligible), 0) as e,
           coalesce(sum(l.t) filter (where l.discount_eligible and l.taxable), 0) as et
      from lines l group by l.job_id
  ), job_target as (
    select b.job_id, b.d,
           case when b.e > 0 then round(b.d::numeric * b.et / b.e)::bigint else 0 end as td
      from job_base b
  ), grouped as (
    select l.*,
           case when not l.discount_eligible then 0
                when l.taxable then jt.td
                else jt.d - jt.td end as g_target,
           (sum(l.t) over (partition by l.job_id, l.discount_eligible, l.taxable))::bigint as g_total
      from lines l join job_target jt on jt.job_id = l.job_id
  ), floored as (
    select g.*,
           case when g.g_total > 0 then (g.g_target * g.t) / g.g_total else 0 end as base,
           case when g.g_total > 0 then (g.g_target * g.t) % g.g_total else 0 end as rem
      from grouped g
  ), ranked as (
    select f.*,
           f.g_target - sum(f.base) over (partition by f.job_id, f.discount_eligible, f.taxable) as leftover,
           row_number() over (partition by f.job_id, f.discount_eligible, f.taxable
                              order by f.rem desc, f.sort, f.created_at, f.id) as rn
      from floored f
  )
  select v_cust.shop_id, v_inv.id, r.job_id, r.service_id, r.vehicle_id, r.name, r.description, r.quantity,
         r.unit_price_cents,
         r.discount_cents + r.base + case when r.rn <= r.leftover then 1 else 0 end,
         r.taxable, r.discount_eligible, r.fee_id, r.membership_id,
         row_number() over (order by r.scheduled_start nulls last, r.job_number, r.sort, r.created_at, r.id)::integer
    from ranked r;

  update public.payments p
     set invoice_id = v_inv.id
   where p.shop_id = v_cust.shop_id and p.job_id = any (v_ids) and p.invoice_id is null;

  update public.invoices i
     set status = case when i.status = 'draft' then 'open'::public.invoice_status else i.status end
   where i.id = v_inv.id
  returning * into v_inv;
  v_inv.public_token := null;  -- the customer's credential: invoice_link_token (0015)
  return v_inv;
end
$$;

comment on function public.create_invoice_from_jobs(uuid, uuid[], text, text) is
  'Grouped invoice (P-7) for 2..100 jobs of one customer: lines per job with job and vehicle, job discounts carried as line discounts, deposits attached, issued. Managers+.';

-- ---------------------------------------------------------------------------
-- unbilled_jobs(customer) — owner/admin/manager: the customer's jobs that
-- are not cancelled / no-show and not on a live invoice (candidates for a
-- grouped invoice), oldest first. paid_cents = net received on the job.
-- ---------------------------------------------------------------------------
create function public.unbilled_jobs(p_customer_id uuid)
returns table (
  job_id           uuid,
  number           bigint,
  status           public.job_status,
  scheduled_start  timestamptz,
  completed_at     timestamptz,
  vehicle_label    text,
  total_cents      bigint,
  paid_cents       bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_shop uuid;
begin
  select c.shop_id into v_shop from public.customers c where c.id = p_customer_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can see unbilled jobs' using errcode = '42501';
  end if;
  return query
  select j.id, j.number, j.status, j.scheduled_start, j.completed_at,
         public.money_vehicle_label(j.shop_id, j.vehicle_id),
         j.total_cents,
         coalesce((select sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                     from public.payments p where p.shop_id = j.shop_id and p.job_id = j.id), 0)::bigint
    from public.jobs j
   where j.shop_id = v_shop and j.customer_id = p_customer_id
     and j.status not in ('cancelled', 'no_show')
     and not exists (select 1 from public.invoice_jobs ij where ij.job_id = j.id and ij.shop_id = j.shop_id and not ij.voided)
   order by j.scheduled_start nulls last, j.number;
end
$$;

comment on function public.unbilled_jobs(uuid) is
  'Jobs of a customer with no live invoice (not cancelled / no-show), for grouped invoicing. Managers+. @nullable: scheduled_start, completed_at, vehicle_label';

-- ---------------------------------------------------------------------------
-- void_invoice(invoice, reason) — owner/admin (0013). Grouped invoices: every
-- job is locked first (id order, before the invoice — the order payments
-- use), each job payment goes back to its job, and the jobs are released
-- (invoice_jobs.voided, by trigger).
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
-- job_payment_summary(job) — collector (0013) with invoice_job_count:
-- 0 = no live invoice, 1 = a single-job invoice, n = a grouped invoice of n
-- jobs. total / balance come from the live invoice (for a grouped invoice:
-- the whole invoice's). Technicians see a job on a grouped invoice as billed
-- without its details (invoice fields null, total = the job's total, balance
-- 0): grouped invoices are collected by managers.
-- deposit_due_cents = the required deposit (capped at the total) minus what
-- was received on the job — and, once the job is on a live invoice, never
-- more than the balance reported here: a grouped invoice's own payments
-- carry no job_id, so without the cap every job of a paid fleet invoice
-- would still show its deposit due. Same rule as the /booking page
-- (booking_public_json, 0064) and the deposit reminders
-- (comms_deposit_due_cents, 0085).
-- ---------------------------------------------------------------------------
drop function public.job_payment_summary(uuid);

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
  balance_cents           bigint,
  invoice_job_count       integer
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job     public.jobs;
  v_inv     public.invoices;
  v_count   integer := 0;
  v_paid    bigint;
  v_dep     bigint;
  v_tip     bigint;
  v_ref     bigint;
  v_pend    bigint;
  v_total   bigint;
  v_balance bigint;
  v_dep_due bigint;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.can_collect_for_job(v_job.shop_id, v_job.id) then
    raise exception 'you cannot view payments for this job' using errcode = '42501';
  end if;

  select i.* into v_inv
    from public.invoice_jobs ij
    join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
   where ij.shop_id = v_job.shop_id and ij.job_id = v_job.id and not ij.voided and i.status <> 'void'
   limit 1;
  if v_inv.id is not null then
    select count(*)::integer into v_count from public.invoice_jobs ij
     where ij.invoice_id = v_inv.id and ij.shop_id = v_inv.shop_id;
  end if;

  select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                    filter (where p.kind = 'deposit'), 0),
         coalesce(sum(public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0),
         coalesce(sum(p.refunded_cents), 0),
         coalesce(sum(p.amount_cents + p.tip_cents) filter (where public.payment_in_flight(p.status, p.created_at)), 0)
    into v_paid, v_dep, v_tip, v_ref, v_pend
    from public.payments p
   where p.shop_id = v_job.shop_id and p.job_id = v_job.id;

  if v_inv.id is not null and v_inv.job_id is null and not public.is_shop_manager(v_job.shop_id) then
    -- a technician: the grouped invoice is not theirs to see or collect
    v_inv := null;
    v_total := v_job.total_cents;
    v_balance := 0;
    v_dep_due := 0;
  else
    v_total := coalesce(v_inv.total_cents, v_job.total_cents);
    v_balance := coalesce(v_inv.balance_cents, v_total - v_paid);
    v_dep_due := greatest(least(v_job.deposit_required_cents, v_total) - v_paid, 0);
    if v_inv.id is not null then
      -- never a deposit beyond what the job's invoice still owes
      v_dep_due := least(v_dep_due, greatest(v_inv.balance_cents, 0));
    end if;
  end if;
  return query select
    v_job.id,
    v_inv.id,
    v_inv.number,
    v_inv.status,
    v_total,
    v_job.deposit_required_cents,
    v_dep,
    v_dep_due,
    v_paid,
    v_tip,
    v_ref,
    v_pend,
    v_balance,
    v_count;
end
$$;

-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.job_payment_summary(uuid) is '@nullable: invoice_id, invoice_number, invoice_status';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.invoices_money_invoice_jobs(),
  public.invoice_jobs_money_validate()
from public, anon, authenticated;

revoke execute on function
  public.create_invoice_from_jobs(uuid, uuid[], text, text),
  public.unbilled_jobs(uuid),
  public.job_payment_summary(uuid)
from public, anon;
grant execute on function
  public.create_invoice_from_jobs(uuid, uuid[], text, text),
  public.unbilled_jobs(uuid),
  public.job_payment_summary(uuid)
to authenticated, service_role;
