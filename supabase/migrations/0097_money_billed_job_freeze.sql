-- ============================================================================
-- 0097 — A billed job's price is frozen (money 0062 / 0063).
--
-- A job with a live invoice — a single-job invoice (invoices.job_id) or a
-- grouped one (a live invoice_jobs row), any status but void — was billed
-- from the lines and discount it had then: create_invoice_from_job(s) copied
-- them, and the invoice's lines lock once money is on it. 0062 already froze
-- the job's coupon and its lines' discount eligibility for that reason ("the
-- job's total must keep matching what it was billed"), but the lines
-- themselves and the manual discount stayed editable, so the job total and
-- the invoice drifted apart silently: work added after invoicing was never
-- billed (job_payment_summary shows the invoice's balance, e.g. 0 on a paid
-- invoice, and unbilled_jobs no longer lists the job), and report_team /
-- report_member_earnings paid commission on the job's lines and total, not
-- on what was billed.
--
-- Now, while the job has a live invoice (every writer — staff through
-- PostgREST, add_fee_line and other RPCs, server code; 23514):
--   * job_line_items: no new line, no deleted line, and no change to a
--     line's quantity, unit_price_cents, discount_cents, taxable or job
--     (moving it onto or off a billed job). Its name, description, duration,
--     sort order, vehicle, service / fee / membership links stay editable
--     (they do not change what was billed; a deleted service, vehicle, fee
--     or membership still clears its link). Deleting the lines together with
--     their job or shop (cascades) is not refused here.
--   * jobs: no change to discount_kind, discount_value or tax_rate_bps.
-- Message: 'this job is billed on invoice #N; its services, prices and
-- discount can''t change (void that invoice first, or bill extra work on a
-- new invoice)'. A draft invoice can be deleted instead of voided. Voiding
-- (or deleting) the invoice releases the job, exactly as for its coupon.
-- ============================================================================

-- The number of the job's live (not void) invoice, single-job or grouped;
-- null when it has none. Internal.
create function public.job_live_invoice_number(p_shop_id uuid, p_job_id uuid) returns bigint
language sql stable security definer
set search_path = ''
as $$
  select i.number
    from public.invoices i
   where i.shop_id = p_shop_id and i.status <> 'void'
     and (i.job_id = p_job_id
          or exists (select 1 from public.invoice_jobs ij
                      where ij.shop_id = p_shop_id and ij.invoice_id = i.id and ij.job_id = p_job_id
                        and not ij.voided))
   order by i.created_at desc, i.id
   limit 1
$$;

comment on function public.job_live_invoice_number(uuid, uuid) is
  'Internal (0097): number of the job''s live (non-void) invoice, single-job or grouped; null when the job is not billed.';

create function public.money_billed_job_message(p_number bigint) returns text
language sql immutable
set search_path = ''
as $$
  select format('this job is billed on invoice #%s; its services, prices and discount can''t change '
                '(void that invoice first, or bill extra work on a new invoice)', p_number)
$$;

-- ---------------------------------------------------------------------------
-- job_line_items_97_billed_guard — AFTER (sees the final row, whatever the
-- BEFORE triggers did).
-- ---------------------------------------------------------------------------
create function public.job_line_items_money_billed_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_number bigint;
begin
  if tg_op = 'DELETE' then
    -- deleted with its job or shop (cascade): nothing is left to drift
    if not exists (select 1 from public.jobs j where j.id = old.job_id and j.shop_id = old.shop_id)
       or not exists (select 1 from public.shops s where s.id = old.shop_id) then
      return null;
    end if;
    v_number := public.job_live_invoice_number(old.shop_id, old.job_id);
  elsif tg_op = 'INSERT' then
    v_number := public.job_live_invoice_number(new.shop_id, new.job_id);
  else
    if (new.quantity, new.unit_price_cents, new.discount_cents, new.taxable, new.job_id)
       is not distinct from (old.quantity, old.unit_price_cents, old.discount_cents, old.taxable, old.job_id) then
      return null;
    end if;
    v_number := coalesce(public.job_live_invoice_number(old.shop_id, old.job_id),
                         public.job_live_invoice_number(new.shop_id, new.job_id));
  end if;
  if v_number is not null then
    raise exception '%', public.money_billed_job_message(v_number) using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger job_line_items_97_billed_guard after insert or update or delete on public.job_line_items
  for each row execute function public.job_line_items_money_billed_guard();

-- ---------------------------------------------------------------------------
-- jobs_97_billed_guard — the document discount and tax rate of a billed job.
-- ---------------------------------------------------------------------------
create function public.jobs_money_billed_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_number bigint;
begin
  v_number := public.job_live_invoice_number(new.shop_id, new.id);
  if v_number is not null then
    raise exception '%', public.money_billed_job_message(v_number) using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger jobs_97_billed_guard after update on public.jobs
  for each row
  when ((old.discount_kind, old.discount_value, old.tax_rate_bps)
        is distinct from (new.discount_kind, new.discount_value, new.tax_rate_bps))
  execute function public.jobs_money_billed_guard();

revoke execute on function
  public.job_live_invoice_number(uuid, uuid),
  public.money_billed_job_message(bigint),
  public.job_line_items_money_billed_guard(),
  public.jobs_money_billed_guard()
from public, anon, authenticated;
grant execute on function
  public.job_live_invoice_number(uuid, uuid),
  public.money_billed_job_message(bigint)
to service_role;
