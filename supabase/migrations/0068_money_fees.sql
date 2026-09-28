-- ============================================================================
-- 0068 — Preset fees (P-21): fixed amounts the shop enters (nothing seeded;
-- no card surcharges). A fee on a document is an ordinary line (name, unit
-- price = amount, quantity 1, taxable per fee, fee_id), so totals, tax,
-- discounts and invoices treat it like any other line.
--
--   * auto-apply: a new job (every source except 'quote' — a quote's fee
--     lines are copied by the conversion) gets one line per active fee
--     whose auto_apply is 'both' or the job's location type (sort 1001+),
--     so online bookings include the fee before their deposit is computed.
--     Changing a job's location type (while it has no live invoice) removes
--     the auto-applied fee lines that no longer match and adds the missing
--     matching ones.
--   * add_fee_line(kind, document, fee) adds a fee by hand (managers+),
--     under each document's edit rules.
-- ============================================================================

create function public.shop_fees_before_write() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  return new;
end
$$;

create trigger shop_fees_20_before_write before insert or update on public.shop_fees
  for each row execute function public.shop_fees_before_write();

-- ---------------------------------------------------------------------------
-- jobs_zz_money_auto_fees — see the header (every context).
-- ---------------------------------------------------------------------------
create function public.jobs_money_auto_fees() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.source = 'quote' then
      return null;
    end if;
  else
    if new.location_type is not distinct from old.location_type then
      return null;
    end if;
    if exists (select 1 from public.invoice_jobs ij where ij.job_id = new.id and ij.shop_id = new.shop_id and not ij.voided) then
      return null;   -- billed: the invoice's lines are what counts now
    end if;
    delete from public.job_line_items li
     using public.shop_fees f
     where li.job_id = new.id and li.shop_id = new.shop_id
       and f.id = li.fee_id and f.shop_id = li.shop_id
       and f.auto_apply <> 'none'
       and not (f.auto_apply = 'both' or f.auto_apply::text = new.location_type::text);
  end if;
  insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, taxable, duration_minutes,
                                     fee_id, sort)
  select new.shop_id, new.id, f.name, 1, f.amount_cents, f.taxable, 0, f.id,
         1000 + row_number() over (order by f.sort, f.name, f.id)::integer
    from public.shop_fees f
   where f.shop_id = new.shop_id and f.active and f.archived_at is null
     and (f.auto_apply = 'both' or f.auto_apply::text = new.location_type::text)
     and not exists (select 1 from public.job_line_items li
                     where li.job_id = new.id and li.shop_id = new.shop_id and li.fee_id = f.id);
  return null;
end
$$;

create trigger jobs_zz_money_auto_fees after insert or update of location_type on public.jobs
  for each row execute function public.jobs_money_auto_fees();

-- ---------------------------------------------------------------------------
-- add_fee_line(doc kind, doc id, fee) — owner/admin/manager. p_doc_kind:
-- 'job' | 'quote' | 'invoice'. The fee must be an active, non-archived fee
-- of the document's shop. Quotes: only while draft / sent / viewed (a
-- shared line when the quote has options); invoices: only while no money is
-- on them and none is in flight (the invoice line guard). Returns the new
-- line's id.
-- ---------------------------------------------------------------------------
create function public.add_fee_line(p_doc_kind text, p_doc_id uuid, p_fee_id uuid) returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_kind    text := lower(btrim(coalesce(p_doc_kind, '')));
  v_shop    uuid;
  v_status  text;
  v_job     uuid;
  v_fee     public.shop_fees;
  v_id      uuid;
begin
  if v_kind not in ('job', 'quote', 'invoice') then
    raise exception 'document kind must be job, quote or invoice' using errcode = '22023';
  end if;
  if v_kind = 'job' then
    select j.shop_id into v_shop from public.jobs j where j.id = p_doc_id for no key update;
  elsif v_kind = 'quote' then
    select q.shop_id, q.status::text into v_shop, v_status from public.quotes q where q.id = p_doc_id for no key update;
  else
    select i.shop_id, i.status::text, i.job_id into v_shop, v_status, v_job from public.invoices i where i.id = p_doc_id;
  end if;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception '% not found', v_kind using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can add fees' using errcode = '42501';
  end if;
  select * into v_fee from public.shop_fees f
   where f.id = p_fee_id and f.shop_id = v_shop and f.active and f.archived_at is null;
  if not found then
    raise exception 'this fee is not available' using errcode = '22023';
  end if;

  if v_kind = 'job' then
    insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents, taxable, duration_minutes,
                                       fee_id, sort)
    values (v_shop, p_doc_id, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, 0, v_fee.id,
            coalesce((select max(li.sort) from public.job_line_items li where li.job_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  elsif v_kind = 'quote' then
    if v_status not in ('draft', 'sent', 'viewed') then
      raise exception 'line items of a % quote cannot be changed; revise it back to draft first', v_status
        using errcode = '22023';
    end if;
    insert into public.quote_line_items (shop_id, quote_id, name, quantity, unit_price_cents, taxable, fee_id, sort)
    values (v_shop, p_doc_id, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, v_fee.id,
            coalesce((select max(li.sort) from public.quote_line_items li where li.quote_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  else
    -- the invoice line guard (every context) refuses void invoices, money
    -- received and payments in flight
    insert into public.invoice_line_items (shop_id, invoice_id, job_id, name, quantity, unit_price_cents, taxable,
                                           fee_id, sort)
    values (v_shop, p_doc_id, v_job, v_fee.name, 1, v_fee.amount_cents, v_fee.taxable, v_fee.id,
            coalesce((select max(li.sort) from public.invoice_line_items li where li.invoice_id = p_doc_id and li.shop_id = v_shop), 0) + 1)
    returning id into v_id;
  end if;
  return v_id;
end
$$;

comment on function public.add_fee_line(text, uuid, uuid) is
  'Adds a preset fee as a line on a job, quote or invoice (managers+; each document''s edit rules apply). Returns the line id.';

revoke execute on function public.shop_fees_before_write(), public.jobs_money_auto_fees() from public, anon, authenticated;
revoke execute on function public.add_fee_line(text, uuid, uuid) from public, anon;
grant execute on function public.add_fee_line(text, uuid, uuid) to authenticated, service_role;
