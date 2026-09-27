-- ============================================================================
-- 0045 — Reports foundation (SPEC §4.8): shared helpers for the dashboard,
-- report and search RPCs (0046-0049) plus their supporting indexes.
--
-- Conventions shared by every report RPC:
--   * SECURITY DEFINER, search_path = '', role-checked with
--     report_caller_role(): owner/admin/manager get shop-wide data;
--     technicians only where a report has an explicit "own numbers" variant
--     (dashboard_summary, report_team, search_shop); everyone else —
--     clients, other shops' staff, anon — gets 42501.
--   * Date ranges are inclusive local calendar dates [p_from, p_to] in the
--     SHOP's time zone: [p_from 00:00 local, p_to + 1 00:00 local). Weeks
--     start on Monday (ISO, date_trunc('week')). DST is handled by
--     converting local midnights with `at time zone`, never fixed offsets.
--   * Money bases:
--       cash    — payments by paid_at: net = amount − refunded part of the
--                 amount; tips are reported separately (net of tip refunds)
--                 and never counted as revenue. Payments carry only a
--                 cumulative refunded_cents (no refund timestamp), so a
--                 refund is reported in the period of the original payment.
--       accrual — completed jobs by completed_at: pre-tax revenue =
--                 subtotal − document discount (used by sales-by-service,
--                 team attribution and customer tickets).
--   * Time-dependent functions take p_now timestamptz default now().
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Caller check. Returns the caller's active role in the shop or raises
-- 42501 (not a member / technician where not allowed). SECURITY INVOKER: it
-- only calls the definer role helpers; it runs inside the definer RPCs.
-- ---------------------------------------------------------------------------
create function public.report_caller_role(p_shop_id uuid, p_allow_technician boolean default false)
returns public.shop_role
language plpgsql stable
set search_path = ''
as $$
declare
  v_role public.shop_role;
begin
  v_role := public.shop_role_of(p_shop_id);
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if v_role = 'technician' and not coalesce(p_allow_technician, false) then
    raise exception 'this report is available to owners, admins and managers' using errcode = '42501';
  end if;
  return v_role;
end
$$;

-- The caller's own active membership id in the shop (null when none).
create function public.report_caller_member(p_shop_id uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
  select m.id from public.shop_members m
  where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active
$$;

-- Inclusive local date range validation (max ~10 years so a day-bucketed
-- report stays bounded).
create function public.report_check_range(p_from date, p_to date) returns void
language plpgsql immutable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null then
    raise exception 'from and to dates are required' using errcode = '22023';
  end if;
  if p_to < p_from then
    raise exception 'the end date must not be before the start date' using errcode = '22023';
  end if;
  if p_to - p_from > 3660 then
    raise exception 'report ranges are limited to 10 years' using errcode = '22023';
  end if;
end
$$;

-- First instant of a local calendar date in a time zone.
create function public.report_local_start(p_date date, p_timezone text) returns timestamptz
language sql stable
set search_path = ''
as $$ select (p_date::timestamp at time zone p_timezone) $$;

-- Display helpers (pure).
create function public.report_customer_label(p_first text, p_last text, p_company text) returns text
language sql immutable
set search_path = ''
as $$
  select coalesce(nullif(btrim(concat_ws(' ', btrim(p_first), btrim(p_last))), ''), nullif(btrim(p_company), ''))
$$;

create function public.report_vehicle_label(p_year smallint, p_make text, p_model text) returns text
language sql immutable
set search_path = ''
as $$
  select nullif(btrim(concat_ws(' ', p_year::text, nullif(btrim(p_make), ''), nullif(btrim(p_model), ''))), '')
$$;

-- LIKE pattern for a literal substring: escapes the escape character and
-- both wildcards so user input can never widen a match. Use with
-- `LIKE ... ESCAPE '\'`.
create function public.like_escape(p_text text) returns text
language sql immutable
set search_path = ''
as $$ select replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_') $$;

-- ---------------------------------------------------------------------------
-- Supporting indexes
-- ---------------------------------------------------------------------------
-- (accrual reports find completed jobs by date through 0034's
--  jobs_shop_completed_idx (shop_id, completed_at) where completed_at is not null)
-- per-customer completion history (new vs returning, lifetime jobs)
create index jobs_shop_customer_completed_idx on public.jobs (shop_id, customer_id, completed_at)
  where status = 'completed';
-- dashboard: who is on the clock
create index time_entries_shop_open_idx on public.time_entries (shop_id, member_id) where clock_out is null;
-- (open receivables use invoices_shop_status_idx (shop_id, status, due_at);
--  received payments by date use payments_shop_paid_at_idx (shop_id, paid_at))
-- report_customers: new customer records per period
create index customers_shop_created_idx on public.customers (shop_id, created_at);

-- ---------------------------------------------------------------------------
-- Grants: internal helpers are not API surface. The pure display / escape
-- helpers stay callable by staff (harmless) but not by anon.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.report_caller_role(uuid, boolean),
  public.report_caller_member(uuid),
  public.report_check_range(date, date),
  public.report_local_start(date, text)
from public, anon, authenticated;
grant execute on function
  public.report_caller_role(uuid, boolean),
  public.report_caller_member(uuid),
  public.report_check_range(date, date),
  public.report_local_start(date, text)
to service_role;

revoke execute on function
  public.report_customer_label(text, text, text),
  public.report_vehicle_label(smallint, text, text),
  public.like_escape(text)
from public, anon;
grant execute on function
  public.report_customer_label(text, text, text),
  public.report_vehicle_label(smallint, text, text),
  public.like_escape(text)
to authenticated, service_role;
