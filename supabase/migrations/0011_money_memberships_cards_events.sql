-- ============================================================================
-- 0011 — Money (SPEC §4.5): membership_plans, memberships,
-- customer_payment_methods (saved cards), stripe_events (webhook
-- idempotency), create_membership (staff) and the service_role helpers the
-- Stripe webhook uses for these tables.
--
-- Access (SPEC §3): owner/admin/manager manage plans and memberships and read
-- saved cards; technicians have no access to any of these tables. Stripe-driven
-- columns (subscription ids, statuses, periods, card rows) are written only by
-- service_role (edge functions / webhook).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- membership_plans
-- ---------------------------------------------------------------------------
create table public.membership_plans (
  id                    uuid primary key default gen_random_uuid(),
  shop_id               uuid not null references public.shops (id) on delete cascade,
  name                  text not null check (char_length(btrim(name)) between 1 and 120),
  description           text check (description is null or char_length(description) <= 5000),
  price_cents           bigint not null check (price_cents > 0),
  interval              public.membership_interval not null default 'month',
  interval_count        integer not null default 1,
  included_service_ids  uuid[] not null default '{}'
                          check (array_position(included_service_ids, null) is null
                                 and cardinality(included_service_ids) <= 100),
  discount_bps          integer not null default 0 check (discount_bps between 0 and 10000),
  active                boolean not null default true,
  sort                  integer not null default 0,
  stripe_product_id     text check (stripe_product_id is null or stripe_product_id ~ '^prod_[A-Za-z0-9]+$'),
  stripe_price_id       text check (stripe_price_id is null or stripe_price_id ~ '^price_[A-Za-z0-9]+$'),
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint membership_plans_shop_id_id_key unique (shop_id, id),
  -- Stripe recurring prices bill at most once a year
  constraint membership_plans_interval_count check (
    (interval = 'month' and interval_count between 1 and 12)
    or (interval = 'year' and interval_count = 1))
);
create unique index membership_plans_shop_stripe_price_key on public.membership_plans (shop_id, stripe_price_id)
  where stripe_price_id is not null;
create index membership_plans_shop_sort_idx on public.membership_plans (shop_id, sort, name);

-- Direct writes cannot set Stripe ids; changing the billing terms detaches the
-- (immutable) Stripe price so the next checkout creates a new one — existing
-- subscribers keep the price they signed up with.
create function public.membership_plans_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.stripe_product_id is not null or new.stripe_price_id is not null then
      raise exception 'Stripe product/price ids are managed by the payments service' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.stripe_product_id is distinct from old.stripe_product_id
     or (new.stripe_price_id is distinct from old.stripe_price_id and new.stripe_price_id is not null) then
    raise exception 'Stripe product/price ids are managed by the payments service' using errcode = '42501';
  end if;
  if (new.price_cents, new.interval, new.interval_count) is distinct from (old.price_cents, old.interval, old.interval_count) then
    new.stripe_price_id := null;
  end if;
  return new;
end
$$;

-- Included services must be this shop's services (arrays cannot carry FKs).
-- Only ids being added are validated; ids already on the plan whose service
-- has since been deleted are dropped (membership_plans_drop_deleted_service
-- normally removes them at delete time), so a deleted service never freezes
-- the plan — renames, deactivation and the payments service's Stripe id sync
-- keep working.
-- SECURITY INVOKER: client writes only see their own shop's services, so the
-- check never reveals anything about another shop's catalog.
create function public.membership_plans_before_write() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old uuid[] := case when tg_op = 'UPDATE' then old.included_service_ids else '{}'::uuid[] end;
begin
  if exists (select 1 from unnest(new.included_service_ids) as x
             where x is not null and x <> all (v_old)
               and not exists (select 1 from public.services s where s.id = x and s.shop_id = new.shop_id)) then
    raise exception 'included services must belong to this shop' using errcode = '23503';
  end if;
  new.included_service_ids := coalesce(
    array(select distinct x from unnest(new.included_service_ids) as x
          where x is not null
            and exists (select 1 from public.services s where s.id = x and s.shop_id = new.shop_id)
          order by 1), '{}');
  new.name := btrim(new.name);
  return new;
end
$$;

create trigger membership_plans_05_prevent_shop_change before update on public.membership_plans
  for each row execute function public.prevent_shop_change();
create trigger membership_plans_10_client_guard before insert or update on public.membership_plans
  for each row execute function public.membership_plans_client_guard();
create trigger membership_plans_20_before_write before insert or update on public.membership_plans
  for each row execute function public.membership_plans_before_write();
create trigger membership_plans_90_set_updated_at before update on public.membership_plans
  for each row execute function public.set_updated_at();

-- A deleted service leaves every plan that included it (the array cannot
-- carry an ON DELETE rule). Runs as the owner: the service delete was already
-- authorized by the services policies.
create function public.membership_plans_drop_deleted_service() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.membership_plans p
     set included_service_ids = array_remove(p.included_service_ids, old.id)
   where p.shop_id = old.shop_id and old.id = any (p.included_service_ids);
  return null;
end
$$;

create trigger services_zz_membership_plans_drop after delete on public.services
  for each row execute function public.membership_plans_drop_deleted_service();

-- ---------------------------------------------------------------------------
-- memberships
-- Status machine: incomplete -> active | past_due | cancelled;
--                 active <-> past_due; active | past_due -> cancelled;
--                 cancelled is terminal.
-- Staff may only abandon an incomplete membership (-> cancelled) and change
-- the vehicle; everything else is Stripe-driven (service_role).
-- ---------------------------------------------------------------------------
create table public.memberships (
  id                      uuid primary key default gen_random_uuid(),
  shop_id                 uuid not null references public.shops (id) on delete cascade,
  plan_id                 uuid not null,
  customer_id             uuid not null,
  vehicle_id              uuid,
  status                  public.membership_status not null default 'incomplete',
  stripe_subscription_id  text unique check (stripe_subscription_id is null or stripe_subscription_id ~ '^sub_[A-Za-z0-9]+$'),
  current_period_end      timestamptz,
  cancel_at_period_end    boolean not null default false,
  started_at              timestamptz,
  cancelled_at            timestamptz,
  created_by              uuid references auth.users (id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint memberships_shop_id_id_key unique (shop_id, id),
  constraint memberships_plan_fk foreign key (shop_id, plan_id)
    references public.membership_plans (shop_id, id) on delete restrict,
  constraint memberships_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete restrict,
  -- RESTRICT, not SET NULL: a null vehicle means "covers every vehicle of the
  -- customer" (price_services), so deleting the covered vehicle must never
  -- widen the membership. Archive the vehicle, or move the membership to
  -- another vehicle first; membership history keeps its vehicle.
  constraint memberships_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete restrict,
  constraint memberships_cancelled_stamp check ((status = 'cancelled') = (cancelled_at is not null)),
  constraint memberships_started_stamp check (status not in ('active', 'past_due') or started_at is not null)
);
-- one open membership per plan + customer + vehicle
create unique index memberships_one_open_key on public.memberships (shop_id, plan_id, customer_id, vehicle_id)
  nulls not distinct where status <> 'cancelled';
create index memberships_shop_customer_idx on public.memberships (shop_id, customer_id);
create index memberships_shop_plan_idx on public.memberships (shop_id, plan_id);
create index memberships_shop_vehicle_idx on public.memberships (shop_id, vehicle_id);
create index memberships_shop_status_idx on public.memberships (shop_id, status);
create index memberships_created_by_idx on public.memberships (created_by);

create function public.memberships_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    raise exception 'use create_membership to add a membership' using errcode = '42501';
  end if;
  if (new.plan_id, new.customer_id, new.stripe_subscription_id, new.current_period_end,
      new.cancel_at_period_end, new.started_at, new.created_by)
     is distinct from
     (old.plan_id, old.customer_id, old.stripe_subscription_id, old.current_period_end,
      old.cancel_at_period_end, old.started_at, old.created_by) then
    raise exception 'only the vehicle can be edited; billing fields are managed by Stripe' using errcode = '42501';
  end if;
  if new.status is distinct from old.status
     and not (old.status = 'incomplete' and new.status = 'cancelled') then
    raise exception 'staff can only cancel incomplete memberships; cancel active ones through billing'
      using errcode = '42501';
  end if;
  new.cancelled_at := old.cancelled_at;
  return new;
end
$$;

create function public.memberships_status_machine() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status in ('active', 'past_due') then
      new.started_at := coalesce(new.started_at, now());
    end if;
    if new.status = 'cancelled' then
      new.cancelled_at := coalesce(new.cancelled_at, now());
    else
      new.cancelled_at := null;
    end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
    return new;
  end if;
  new.created_by := old.created_by;
  if new.status = old.status then
    return new;
  end if;
  if not ((old.status = 'incomplete' and new.status in ('active', 'past_due', 'cancelled'))
       or (old.status = 'active' and new.status in ('past_due', 'cancelled'))
       or (old.status = 'past_due' and new.status in ('active', 'cancelled'))) then
    raise exception 'invalid membership status transition: % -> %', old.status, new.status using errcode = '23514';
  end if;
  if new.status in ('active', 'past_due') then
    new.started_at := coalesce(new.started_at, now());
  end if;
  if new.status = 'cancelled' and new.cancelled_at is not distinct from old.cancelled_at then
    new.cancelled_at := now();
  end if;
  return new;
end
$$;

create function public.memberships_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id)
     and not exists (select 1 from public.vehicles v
                     where v.id = new.vehicle_id and v.shop_id = new.shop_id and v.customer_id = new.customer_id) then
    raise exception 'the vehicle does not belong to this membership''s customer' using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger memberships_05_prevent_shop_change before update on public.memberships
  for each row execute function public.prevent_shop_change();
create trigger memberships_10_client_guard before insert or update on public.memberships
  for each row execute function public.memberships_client_guard();
create trigger memberships_30_status_machine before insert or update on public.memberships
  for each row execute function public.memberships_status_machine();
create trigger memberships_90_set_updated_at before update on public.memberships
  for each row execute function public.set_updated_at();
create trigger memberships_validate after insert or update on public.memberships
  for each row execute function public.memberships_validate();

-- ---------------------------------------------------------------------------
-- customer_payment_methods — Stripe PaymentMethod references only (never
-- card numbers). At most one default per customer.
-- ---------------------------------------------------------------------------
create table public.customer_payment_methods (
  id                        uuid primary key default gen_random_uuid(),
  shop_id                   uuid not null references public.shops (id) on delete cascade,
  customer_id               uuid not null,
  stripe_payment_method_id  text not null check (stripe_payment_method_id ~ '^(pm|card|src)_[A-Za-z0-9]+$'),
  brand                     text check (brand is null or char_length(brand) between 1 and 30),
  last4                     text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  exp_month                 smallint check (exp_month is null or exp_month between 1 and 12),
  exp_year                  smallint check (exp_year is null or exp_year between 2000 and 2100),
  is_default                boolean not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint customer_payment_methods_shop_id_id_key unique (shop_id, id),
  constraint customer_payment_methods_shop_pm_key unique (shop_id, stripe_payment_method_id),
  constraint customer_payment_methods_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade
);
create unique index customer_payment_methods_one_default_key on public.customer_payment_methods (shop_id, customer_id)
  where is_default;
create index customer_payment_methods_shop_customer_idx on public.customer_payment_methods (shop_id, customer_id);

create trigger customer_payment_methods_05_prevent_shop_change before update on public.customer_payment_methods
  for each row execute function public.prevent_shop_change();
create trigger customer_payment_methods_90_set_updated_at before update on public.customer_payment_methods
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- stripe_events — webhook idempotency ledger (platform-level, no shop_id).
-- ---------------------------------------------------------------------------
create table public.stripe_events (
  id               text primary key check (id ~ '^evt_[A-Za-z0-9]+$'),
  type             text not null check (char_length(type) between 1 and 100),
  account          text check (account is null or account ~ '^acct_[A-Za-z0-9]+$'),
  received_at      timestamptz not null default now(),
  last_attempt_at  timestamptz not null default now(),
  attempts         integer not null default 1 check (attempts >= 1),
  processed_at     timestamptz,
  error            text check (error is null or char_length(error) <= 5000)
);
create index stripe_events_unprocessed_idx on public.stripe_events (received_at) where processed_at is null;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.membership_plans         enable row level security;
alter table public.memberships              enable row level security;
alter table public.customer_payment_methods enable row level security;
alter table public.stripe_events            enable row level security;

create policy membership_plans_select on public.membership_plans for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy membership_plans_insert on public.membership_plans for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy membership_plans_update on public.membership_plans for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy membership_plans_delete on public.membership_plans for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy memberships_select on public.memberships for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy memberships_update on public.memberships for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
-- only never-billed rows can be removed; everything else is history
create policy memberships_delete on public.memberships for delete to authenticated
  using (public.is_shop_manager(shop_id) and status = 'incomplete' and stripe_subscription_id is null);

create policy customer_payment_methods_select on public.customer_payment_methods for select to authenticated
  using (public.is_shop_manager(shop_id));

-- stripe_events: no client policies at all (service_role only).

-- ---------------------------------------------------------------------------
-- RPC: create_membership (manager+) — an incomplete membership the payments
-- edge function turns into a Stripe subscription (membership_checkout).
-- ---------------------------------------------------------------------------
create function public.create_membership(
  p_plan_id      uuid,
  p_customer_id  uuid,
  p_vehicle_id   uuid default null
) returns public.memberships
language plpgsql security definer
set search_path = ''
as $$
declare
  v_plan  public.membership_plans;
  v_m     public.memberships;
begin
  select * into v_plan from public.membership_plans p where p.id = p_plan_id;
  if not found or not public.is_shop_member(v_plan.shop_id) then
    raise exception 'membership plan not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_plan.shop_id) then
    raise exception 'only owners, admins and managers can create memberships' using errcode = '42501';
  end if;
  if not v_plan.active or v_plan.archived_at is not null then
    raise exception 'this membership plan is not available' using errcode = '22023';
  end if;
  if not exists (select 1 from public.customers c
                 where c.id = p_customer_id and c.shop_id = v_plan.shop_id and c.archived_at is null) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if p_vehicle_id is not null and not exists (
       select 1 from public.vehicles v
       where v.id = p_vehicle_id and v.shop_id = v_plan.shop_id and v.customer_id = p_customer_id
         and v.archived_at is null) then
    raise exception 'the vehicle does not belong to this customer' using errcode = '22023';
  end if;
  if exists (select 1 from public.memberships m
             where m.shop_id = v_plan.shop_id and m.plan_id = v_plan.id and m.customer_id = p_customer_id
               and m.vehicle_id is not distinct from p_vehicle_id and m.status <> 'cancelled') then
    raise exception 'this customer already has an open membership on this plan%',
      case when p_vehicle_id is null then '' else ' for this vehicle' end using errcode = '23505';
  end if;

  insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status)
  values (v_plan.shop_id, v_plan.id, p_customer_id, p_vehicle_id, 'incomplete')
  returning * into v_m;
  return v_m;
end
$$;

-- ---------------------------------------------------------------------------
-- service_role: sync_stripe_subscription — apply a Stripe subscription state
-- (webhook customer.subscription.*). The row is found by subscription id, or
-- linked on first sight through p_membership_id (subscription metadata).
-- Out-of-order safe: a cancelled membership never revives and an
-- active/past_due one never regresses to incomplete (those updates only
-- refresh the period fields). Idempotent.
-- ---------------------------------------------------------------------------
create function public.sync_stripe_subscription(
  p_shop_id               uuid,
  p_subscription_id       text,
  p_status                public.membership_status,
  p_current_period_end    timestamptz default null,
  p_cancel_at_period_end  boolean default false,
  p_membership_id         uuid default null,
  p_now                   timestamptz default now()
) returns public.memberships
language plpgsql security definer
set search_path = ''
as $$
declare
  v_m       public.memberships;
  v_status  public.membership_status;
begin
  if p_shop_id is null or p_subscription_id is null or p_status is null or p_now is null then
    raise exception 'shop, subscription id, status and now are required' using errcode = '22023';
  end if;
  select * into v_m from public.memberships m
   where m.stripe_subscription_id = p_subscription_id for update;
  if found and v_m.shop_id <> p_shop_id then
    raise exception 'subscription belongs to another shop' using errcode = '22023';
  end if;
  if not found and p_membership_id is not null then
    select * into v_m from public.memberships m
     where m.id = p_membership_id and m.shop_id = p_shop_id for update;
    if found and v_m.stripe_subscription_id is not null and v_m.stripe_subscription_id <> p_subscription_id then
      raise exception 'membership is already linked to another subscription' using errcode = '22023';
    end if;
  end if;
  if v_m.id is null then
    raise exception 'membership for subscription % not found', p_subscription_id using errcode = 'P0002';
  end if;

  v_status := case
    when v_m.status = 'cancelled' then 'cancelled'
    when p_status = 'incomplete' and v_m.status <> 'incomplete' then v_m.status
    else p_status
  end;

  update public.memberships m
     set stripe_subscription_id = p_subscription_id,
         status = v_status,
         current_period_end = coalesce(p_current_period_end, m.current_period_end),
         cancel_at_period_end = case when v_status = 'cancelled' then false else coalesce(p_cancel_at_period_end, false) end,
         started_at = case when v_status in ('active', 'past_due') then coalesce(m.started_at, p_now) else m.started_at end,
         cancelled_at = case when v_status = 'cancelled' then coalesce(m.cancelled_at, p_now) else null end
   where m.id = v_m.id
  returning * into v_m;
  return v_m;
end
$$;

-- ---------------------------------------------------------------------------
-- service_role: saved cards (setup_intent.succeeded / payment method detach).
-- ---------------------------------------------------------------------------
create function public.upsert_customer_payment_method(
  p_shop_id                   uuid,
  p_customer_id               uuid,
  p_stripe_payment_method_id  text,
  p_brand                     text default null,
  p_last4                     text default null,
  p_exp_month                 integer default null,
  p_exp_year                  integer default null,
  p_make_default              boolean default false
) returns public.customer_payment_methods
language plpgsql security definer
set search_path = ''
as $$
declare
  v_existing  public.customer_payment_methods;
  v_row       public.customer_payment_methods;
  v_default   boolean;
begin
  -- serializes default switching per customer
  perform 1 from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id for update;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  select * into v_existing from public.customer_payment_methods pm
   where pm.shop_id = p_shop_id and pm.stripe_payment_method_id = p_stripe_payment_method_id;
  if found and v_existing.customer_id <> p_customer_id then
    raise exception 'payment method belongs to another customer' using errcode = '22023';
  end if;

  v_default := coalesce(p_make_default, false)
            or coalesce(v_existing.is_default, false)
            or not exists (select 1 from public.customer_payment_methods pm
                           where pm.shop_id = p_shop_id and pm.customer_id = p_customer_id and pm.is_default);
  if v_default then
    update public.customer_payment_methods pm
       set is_default = false
     where pm.shop_id = p_shop_id and pm.customer_id = p_customer_id and pm.is_default
       and pm.stripe_payment_method_id <> p_stripe_payment_method_id;
  end if;

  insert into public.customer_payment_methods as pm
    (shop_id, customer_id, stripe_payment_method_id, brand, last4, exp_month, exp_year, is_default)
  values (p_shop_id, p_customer_id, p_stripe_payment_method_id, lower(nullif(btrim(p_brand), '')),
          p_last4, p_exp_month, p_exp_year, v_default)
  on conflict (shop_id, stripe_payment_method_id) do update
    set brand = coalesce(excluded.brand, pm.brand),
        last4 = coalesce(excluded.last4, pm.last4),
        exp_month = coalesce(excluded.exp_month, pm.exp_month),
        exp_year = coalesce(excluded.exp_year, pm.exp_year),
        is_default = excluded.is_default
  returning * into v_row;
  return v_row;
end
$$;

-- Returns true when a row was removed. Removing the default promotes the
-- most recently added remaining card.
create function public.remove_customer_payment_method(
  p_shop_id                   uuid,
  p_stripe_payment_method_id  text
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_row public.customer_payment_methods;
begin
  select * into v_row from public.customer_payment_methods pm
   where pm.shop_id = p_shop_id and pm.stripe_payment_method_id = p_stripe_payment_method_id;
  if not found then
    return false;
  end if;
  perform 1 from public.customers c where c.id = v_row.customer_id and c.shop_id = p_shop_id for update;
  delete from public.customer_payment_methods pm where pm.id = v_row.id;
  if v_row.is_default then
    update public.customer_payment_methods pm
       set is_default = true
     where pm.id = (select x.id from public.customer_payment_methods x
                    where x.shop_id = p_shop_id and x.customer_id = v_row.customer_id
                    order by x.created_at desc, x.id desc limit 1);
  end if;
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- service_role: webhook idempotency.
-- record_stripe_event returns true when the caller should process the event:
-- it is new, or an earlier attempt failed (error recorded), or an earlier
-- attempt never finished within 5 minutes (crashed worker). Returns false for
-- processed events and for attempts still in flight — so the same event
-- delivered twice has one effect.
-- ---------------------------------------------------------------------------
create function public.record_stripe_event(
  p_event_id  text,
  p_type      text,
  p_account   text default null,
  p_now       timestamptz default now()
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_claimed boolean;
begin
  if p_event_id is null or p_type is null or p_now is null then
    raise exception 'event id, type and now are required' using errcode = '22023';
  end if;
  insert into public.stripe_events as e (id, type, account, received_at, last_attempt_at, attempts)
  values (p_event_id, p_type, p_account, p_now, p_now, 1)
  on conflict (id) do update
    set attempts = e.attempts + 1,
        last_attempt_at = p_now,
        error = null
    where e.processed_at is null
      and (e.error is not null or e.last_attempt_at <= p_now - interval '5 minutes')
  returning true into v_claimed;
  return coalesce(v_claimed, false);
end
$$;

-- p_error null = processed successfully; otherwise the failure is recorded so
-- the next delivery (Stripe retries non-2xx responses) re-processes it.
create function public.mark_stripe_event_processed(
  p_event_id  text,
  p_error     text default null,
  p_now       timestamptz default now()
) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.stripe_events e
     set processed_at = case when p_error is null then p_now end,
         error = left(p_error, 5000)
   where e.id = p_event_id;
  if not found then
    raise exception 'stripe event % not found', p_event_id using errcode = 'P0002';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.membership_plans, public.memberships, public.customer_payment_methods,
              public.stripe_events from anon;
revoke insert on public.memberships from authenticated;
revoke insert, update, delete on public.customer_payment_methods from authenticated;
revoke all on public.stripe_events from authenticated;

revoke execute on function
  public.membership_plans_client_guard(),
  public.membership_plans_before_write(),
  public.membership_plans_drop_deleted_service(),
  public.memberships_client_guard(),
  public.memberships_status_machine(),
  public.memberships_validate()
from public, anon, authenticated;

revoke execute on function public.create_membership(uuid, uuid, uuid) from public, anon;
grant execute on function public.create_membership(uuid, uuid, uuid) to authenticated, service_role;

revoke execute on function
  public.sync_stripe_subscription(uuid, text, public.membership_status, timestamptz, boolean, uuid, timestamptz),
  public.upsert_customer_payment_method(uuid, uuid, text, text, text, integer, integer, boolean),
  public.remove_customer_payment_method(uuid, text),
  public.record_stripe_event(text, text, text, timestamptz),
  public.mark_stripe_event_processed(text, text, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.sync_stripe_subscription(uuid, text, public.membership_status, timestamptz, boolean, uuid, timestamptz),
  public.upsert_customer_payment_method(uuid, uuid, text, text, text, integer, integer, boolean),
  public.remove_customer_payment_method(uuid, text),
  public.record_stripe_event(text, text, text, timestamptz),
  public.mark_stripe_event_processed(text, text, timestamptz)
to service_role;
