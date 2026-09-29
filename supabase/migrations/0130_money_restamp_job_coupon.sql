-- ============================================================================
-- 0130 — "Refresh coupon": re-stamp a job's own coupon in place.
--
-- A job keeps the discount eligibility its lines were priced with when the
-- coupon's service list is edited later while the job is settled or its
-- deposit page is open (coupons_money_restamp_jobs, 0062 / 0121). 0121 and
-- 0123 told staff to re-apply the coupon on such a job to bring it up to
-- date — but re-applying redeems the coupon anew (coupon_redeem_for_job),
-- which refuses (23514) a coupon that has since expired, been deactivated
-- or been used up. The job already holds its redemption, so that advice
-- failed exactly for the coupons most likely to be stale.
--
--   restamp_job_coupon(p_job_id) -> {lines_changed, total_cents}
--     manager+ (technicians 42501; unknown job / another shop's P0002).
--     Re-stamps the job's lines' discount_eligible from its CURRENT
--     coupon's service list, keeping the coupon, its redemption and the
--     discount kind / value the job was given — no expiry, active or
--     max_redemptions check (nothing is redeemed). Refused:
--       22023 the job has no coupon;
--       23514 the job is billed on a live invoice (void it first; as
--             jobs_apply_coupon);
--       55000 HINT checkout_open when the refresh lowers the total while a
--             deposit page can still be paid (jobs_98_open_checkout, 0118).
--   job_coupon_eligibility_stale(p_job_id) -> boolean (manager+): true when
--     the job has a coupon, is not billed and a line's eligibility differs
--     from the coupon's current list — when the web / iOS job page shows
--     "Refresh coupon".
-- ============================================================================

-- What a line's eligibility is under a coupon's service list.
create function public.coupon_line_eligible(p_service_ids uuid[], p_service_id uuid) returns boolean
language sql immutable
set search_path = ''
as $$ select p_service_ids is null or (p_service_id is not null and p_service_id = any (p_service_ids)) $$;

comment on function public.coupon_line_eligible(uuid[], uuid) is
  'Internal (0130): whether a line of this service is discount-eligible under a coupon limited to p_service_ids (null = every line).';
revoke execute on function public.coupon_line_eligible(uuid[], uuid) from public, anon;
grant execute on function public.coupon_line_eligible(uuid[], uuid) to authenticated, service_role;

create function public.job_coupon_eligibility_stale(p_job_id uuid) returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
  v_ids uuid[];
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_job.shop_id) then
    raise exception 'only owners, admins and managers can manage a job''s coupon' using errcode = '42501';
  end if;
  if v_job.coupon_id is null or public.job_live_invoice_number(v_job.shop_id, v_job.id) is not null then
    return false;
  end if;
  select c.service_ids into v_ids from public.coupons c where c.id = v_job.coupon_id and c.shop_id = v_job.shop_id;
  return exists (select 1 from public.job_line_items li
                  where li.job_id = v_job.id and li.shop_id = v_job.shop_id
                    and li.discount_eligible is distinct from public.coupon_line_eligible(v_ids, li.service_id));
end
$$;

comment on function public.job_coupon_eligibility_stale(uuid) is
  'Manager+ (0130): the job''s coupon covers different lines than its current service list says (a list edit skipped the job while it was settled or its deposit page was open) and the job is not billed — restamp_job_coupon brings it up to date.';

create function public.restamp_job_coupon(p_job_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job     public.jobs;
  v_ids     uuid[];
  v_number  bigint;
  v_changed integer;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_job.shop_id) then
    raise exception 'only owners, admins and managers can refresh a job''s coupon' using errcode = '42501';
  end if;
  select * into v_job from public.jobs j where j.id = p_job_id for no key update;
  if v_job.coupon_id is null then
    raise exception 'this job has no coupon to refresh' using errcode = '22023';
  end if;
  v_number := public.job_live_invoice_number(v_job.shop_id, v_job.id);
  if v_number is not null then
    raise exception 'this job is billed on invoice #%; its coupon cannot change until that invoice is void', v_number
      using errcode = '23514';
  end if;
  select c.service_ids into v_ids from public.coupons c
   where c.id = v_job.coupon_id and c.shop_id = v_job.shop_id
  for share;

  -- server code re-stamps (job_line_items_money_eligible recomputes the same
  -- value from the coupon); each line update recomputes the job's totals,
  -- and jobs_98_open_checkout refuses a lower total while a page is open
  update public.job_line_items li
     set discount_eligible = public.coupon_line_eligible(v_ids, li.service_id)
   where li.job_id = v_job.id and li.shop_id = v_job.shop_id
     and li.discount_eligible is distinct from public.coupon_line_eligible(v_ids, li.service_id);
  get diagnostics v_changed = row_count;

  return jsonb_build_object(
    'lines_changed', v_changed,
    'total_cents', (select j.total_cents from public.jobs j where j.id = v_job.id));
end
$$;

comment on function public.restamp_job_coupon(uuid) is
  'Manager+ (0130): "Refresh coupon" — re-stamps the discount eligibility of the job''s lines from its current coupon''s service list without redeeming the coupon again (so an expired, deactivated or used-up coupon the job already holds can be refreshed). 22023 no coupon; 23514 billed; 55000 HINT checkout_open when a lower total meets an open deposit page. Returns {lines_changed, total_cents}.';

revoke execute on function public.restamp_job_coupon(uuid), public.job_coupon_eligibility_stale(uuid) from public, anon;
grant execute on function public.restamp_job_coupon(uuid), public.job_coupon_eligibility_stale(uuid)
  to authenticated, service_role;
