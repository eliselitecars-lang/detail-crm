-- ============================================================================
-- 0092 — Cross-surface CRM operations (integration phase).
--
--   customer_summary           money / visit overview of one customer (manager+)
--   replace_business_hours     atomic save of a shop's weekly hours (admin+)
--   reorder_job_line_items     atomic reorder of a job's lines (manager+)
--   account_deletion_blockers  what stops the caller deleting their account
--                              (App Store 5.1.1(v): shops they own)
--
-- Access errors follow the house style: a record of a shop the caller does
-- not belong to (or an unknown id) is "not found" (P0002); a member whose
-- role may not do it gets 42501.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- customer_summary — exactly one row for the customer:
--   lifetime_paid_cents    Σ net amount of the customer's payments (refunds
--                          deducted, tips excluded; payment_net_amount)
--   tips_cents             Σ net tips (payment_net_tip)
--   refunded_cents         Σ refunded_cents of received payments
--   open_balance_cents     Σ balance of open / partially paid invoices
--   overdue_balance_cents  the same, only invoices past their due time
--   completed_jobs         jobs completed
--   upcoming_jobs          jobs requested / scheduled / confirmed that start
--   next_job_at            now or later (count, earliest start)
--   first_visit_at         first / last completion of a completed job
--   last_visit_at
--   open_quotes            quotes sent / viewed / approved
--   active_memberships     memberships active / past due
-- ---------------------------------------------------------------------------
create function public.customer_summary(p_customer_id uuid)
returns table (
  customer_id            uuid,
  lifetime_paid_cents    bigint,
  tips_cents             bigint,
  refunded_cents         bigint,
  open_balance_cents     bigint,
  overdue_balance_cents  bigint,
  completed_jobs         integer,
  upcoming_jobs          integer,
  first_visit_at         timestamptz,
  last_visit_at          timestamptz,
  next_job_at            timestamptz,
  open_quotes            integer,
  active_memberships     integer
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
    raise exception 'only owners, admins and managers can see customer totals' using errcode = '42501';
  end if;
  return query
  select p_customer_id,
         (select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0)::bigint
            from public.payments p where p.shop_id = v_shop and p.customer_id = p_customer_id),
         (select coalesce(sum(public.payment_net_tip(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0)::bigint
            from public.payments p where p.shop_id = v_shop and p.customer_id = p_customer_id),
         (select coalesce(sum(p.refunded_cents), 0)::bigint
            from public.payments p
           where p.shop_id = v_shop and p.customer_id = p_customer_id
             and p.status in ('succeeded', 'partially_refunded', 'refunded')),
         (select coalesce(sum(i.balance_cents), 0)::bigint
            from public.invoices i
           where i.shop_id = v_shop and i.customer_id = p_customer_id and i.status in ('open', 'partially_paid')),
         (select coalesce(sum(i.balance_cents), 0)::bigint
            from public.invoices i
           where i.shop_id = v_shop and i.customer_id = p_customer_id and i.status in ('open', 'partially_paid')
             and i.due_at < now()),
         (select count(*)::integer from public.jobs j
           where j.shop_id = v_shop and j.customer_id = p_customer_id and j.status = 'completed'),
         (select count(*)::integer from public.jobs j
           where j.shop_id = v_shop and j.customer_id = p_customer_id
             and j.status in ('requested', 'scheduled', 'confirmed') and j.scheduled_start >= now()),
         (select min(j.completed_at) from public.jobs j
           where j.shop_id = v_shop and j.customer_id = p_customer_id and j.status = 'completed'),
         (select max(j.completed_at) from public.jobs j
           where j.shop_id = v_shop and j.customer_id = p_customer_id and j.status = 'completed'),
         (select min(j.scheduled_start) from public.jobs j
           where j.shop_id = v_shop and j.customer_id = p_customer_id
             and j.status in ('requested', 'scheduled', 'confirmed') and j.scheduled_start >= now()),
         (select count(*)::integer from public.quotes q
           where q.shop_id = v_shop and q.customer_id = p_customer_id and q.status in ('sent', 'viewed', 'approved')),
         (select count(*)::integer from public.memberships m
           where m.shop_id = v_shop and m.customer_id = p_customer_id and m.status in ('active', 'past_due'));
end
$$;

comment on function public.customer_summary(uuid) is
  'Money and visit overview of one customer (owner/admin/manager). @nullable: first_visit_at, last_visit_at, next_job_at';

-- ---------------------------------------------------------------------------
-- replace_business_hours — replaces all of a shop's business hours in one
-- statement block (owner/admin). p_rows: a JSON array (at most 50) of
-- {"weekday": 0-6 (0 = Sunday), "opens_at": "HH:MM[:SS]",
--  "closes_at": "HH:MM[:SS]" (24:00 allowed)}; [] = closed all week.
-- Overlapping intervals (23P01) or closes_at <= opens_at (23514) fail the
-- whole call, so the previous hours stay. Concurrent saves of one shop are
-- serialized by an advisory lock. Returns the stored rows by weekday, time.
-- ---------------------------------------------------------------------------
create function public.replace_business_hours(p_shop_id uuid, p_rows jsonb)
returns setof public.business_hours
language plpgsql security definer
set search_path = ''
as $$
declare
  c_time constant text := '^(([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?|24:00(:00)?)$';
  v_row  jsonb;
  v_n    bigint;
begin
  if p_shop_id is null or not public.is_shop_admin(p_shop_id) then
    raise exception 'only owners and admins can change business hours' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'business hours must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 50 then
    raise exception 'at most 50 business hour intervals' using errcode = '22023';
  end if;
  for v_row, v_n in select e.value, e.ord from jsonb_array_elements(p_rows) with ordinality as e(value, ord) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'business hours row % must be an object', v_n using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_object_keys(v_row) k where k not in ('weekday', 'opens_at', 'closes_at')) then
      raise exception 'business hours row % may only have weekday, opens_at and closes_at', v_n using errcode = '22023';
    end if;
    if jsonb_typeof(v_row -> 'weekday') is distinct from 'number'
       or (v_row ->> 'weekday') !~ '^[0-6]$' then
      raise exception 'business hours row %: weekday must be a whole number from 0 (Sunday) to 6 (Saturday)', v_n
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_row -> 'opens_at') is distinct from 'string' or (v_row ->> 'opens_at') !~ c_time then
      raise exception 'business hours row %: opens_at must be a time like 09:00', v_n using errcode = '22023';
    end if;
    if jsonb_typeof(v_row -> 'closes_at') is distinct from 'string' or (v_row ->> 'closes_at') !~ c_time then
      raise exception 'business hours row %: closes_at must be a time like 17:00 (24:00 allowed)', v_n
        using errcode = '22023';
    end if;
  end loop;

  perform pg_advisory_xact_lock(hashtext('business_hours:' || p_shop_id::text));
  delete from public.business_hours h where h.shop_id = p_shop_id;
  insert into public.business_hours (shop_id, weekday, opens_at, closes_at)
  select p_shop_id, (e.value ->> 'weekday')::smallint, (e.value ->> 'opens_at')::time, (e.value ->> 'closes_at')::time
    from jsonb_array_elements(p_rows) as e(value);

  return query
  select h.* from public.business_hours h where h.shop_id = p_shop_id order by h.weekday, h.opens_at;
end
$$;

-- ---------------------------------------------------------------------------
-- reorder_job_line_items — sets the order of a job's lines in one call
-- (owner/admin/manager). p_ids must list every line of the job exactly once
-- (22023 otherwise); sort becomes the position (0-based) and only rows whose
-- position changes are written. The job row is locked, so concurrent
-- reorders / line inserts of the job serialize.
-- ---------------------------------------------------------------------------
create function public.reorder_job_line_items(p_job_id uuid, p_ids uuid[]) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select j.shop_id into v_shop from public.jobs j where j.id = p_job_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can reorder line items' using errcode = '42501';
  end if;
  perform 1 from public.jobs j where j.id = p_job_id and j.shop_id = v_shop for no key update;

  if p_ids is null or array_position(p_ids, null) is not null
     or cardinality(p_ids) <> (select count(distinct x) from unnest(p_ids) x)
     or (select coalesce(array_agg(x order by x), '{}') from unnest(p_ids) x)
        is distinct from (select coalesce(array_agg(li.id order by li.id), '{}')
                            from public.job_line_items li where li.job_id = p_job_id and li.shop_id = v_shop) then
    raise exception 'the list must contain each line of this job exactly once' using errcode = '22023';
  end if;

  update public.job_line_items li
     set sort = (x.ord - 1)::integer
    from unnest(p_ids) with ordinality as x(id, ord)
   where li.id = x.id and li.job_id = p_job_id and li.shop_id = v_shop
     and li.sort is distinct from (x.ord - 1)::integer;
end
$$;

-- ---------------------------------------------------------------------------
-- account_deletion_blockers — for the signed-in caller: the shops they own.
-- An owner cannot delete their account (the owner membership blocks it,
-- 0002) until ownership is transferred or the shop is deleted; clients use
-- this to explain that before calling the account deletion function.
-- {"owned_shops": [{"shop_id", "name"}]} ordered by name.
-- ---------------------------------------------------------------------------
create function public.account_deletion_blockers() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  return jsonb_build_object('owned_shops', coalesce((
    select jsonb_agg(jsonb_build_object('shop_id', s.id, 'name', s.name) order by lower(s.name), s.id)
      from public.shop_members m
      join public.shops s on s.id = m.shop_id
     where m.user_id = auth.uid() and m.role = 'owner'), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.customer_summary(uuid),
  public.replace_business_hours(uuid, jsonb),
  public.reorder_job_line_items(uuid, uuid[]),
  public.account_deletion_blockers()
from public, anon;
grant execute on function
  public.customer_summary(uuid),
  public.replace_business_hours(uuid, jsonb),
  public.reorder_job_line_items(uuid, uuid[])
to authenticated, service_role;
-- only a signed-in user has a caller to check (the account edge function
-- calls it with the user's own JWT)
revoke execute on function public.account_deletion_blockers() from service_role;
grant execute on function public.account_deletion_blockers() to authenticated;
