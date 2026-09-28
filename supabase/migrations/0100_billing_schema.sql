-- ============================================================================
-- 0100 — Shop subscription billing: schema (range 0100-0109; docs/BILLING.md).
--
-- The PLATFORM operator charges shops a recurring subscription through the
-- operator's own Stripe account (never a shop's Connect account). Plans and
-- prices live in Stripe and are mirrored here by the `billing` function;
-- nothing about a plan (name, price, seat limit, trial length) is written
-- in SQL. Billing is OFF until the operator turns it on
-- (set_billing_config, 0101): while off every shop is fully usable, exactly
-- as before this range.
--
--   0100  notification_kind 'billing_payment_failed' (the only enum change of
--         the range), platform_config billing keys, platform_plans,
--         shop_billing (+ a row per shop: seeding trigger and backfill), RLS
--   0101  billing_state / shop_can_write / shop_entitlement,
--         public_billing_plans, set_billing_config and the service-role
--         RPCs of the `billing` / `billing-webhook` functions
--   0102  enforcement: PT402 guards on new business records, seat limits,
--         online booking / automations / campaigns / follow-ups of lapsed
--         shops
--
-- platform_config keys (0030 key/value table; service_role / definer only):
--   billing_enabled     'true' | 'false'  (absent = false)
--   billing_trial_days  0 .. 730           (absent = 0 = no in-app trial)
--
-- platform_plans — one row per ACTIVE-or-retired recurring Stripe Price of a
-- plan Product (billing_upsert_plan / billing_deactivate_plans_except).
-- No client access at all (RLS on, no policies, no grants): Stripe ids stay
-- server-side and the plan list is read through public_billing_plans()
-- (anon + authenticated) or the `billing` function's `plans` action.
--
-- shop_billing — 1:1 with shops, written only by definer code / service_role
-- (the webhook through 0101's RPCs). Owners, admins and managers of the shop
-- may SELECT it directly, but never the Stripe ids: authenticated holds a
-- column-level SELECT grant without stripe_customer_id,
-- stripe_subscription_id, paid_through and last_event_at (select explicit
-- columns; shop_entitlement reports the access end;
-- `select *` is refused). Everyone else — technicians too — reads the
-- shop's standing through shop_entitlement(p_shop_id) (0101).
-- ============================================================================

alter type public.notification_kind add value if not exists 'billing_payment_failed';

-- ---------------------------------------------------------------------------
-- platform_config: the two billing keys hold only what set_billing_config
-- writes (a hand-edited typo must not read as "on" to one reader and "off"
-- to another).
-- ---------------------------------------------------------------------------
alter table public.platform_config
  add constraint platform_config_billing_enabled
    check (key <> 'billing_enabled' or value in ('true', 'false')),
  add constraint platform_config_billing_trial_days
    check (key <> 'billing_trial_days'
           or (case when value ~ '^[0-9]{1,3}$' then value::integer <= 730 else false end));

-- Billing switched on (platform_config.billing_enabled = 'true'). Internal:
-- definer code only (platform_config has no client grants).
create function public.billing_enabled() returns boolean
language sql stable security definer
set search_path = ''
as $$ select coalesce(public.platform_setting('billing_enabled') = 'true', false) $$;

-- The in-app trial length in days (0 = none). Internal.
create function public.billing_trial_days() returns integer
language sql stable security definer
set search_path = ''
as $$
  select case when v ~ '^[0-9]{1,3}$' then v::integer else 0 end
    from (select coalesce(public.platform_setting('billing_trial_days'), '0') as v) x
$$;

-- ---------------------------------------------------------------------------
-- platform_plans (platform-wide; no shop_id)
-- ---------------------------------------------------------------------------
create table public.platform_plans (
  id                 uuid primary key default gen_random_uuid(),
  stripe_price_id    text not null unique check (stripe_price_id ~ '^price_[A-Za-z0-9]+$'),
  stripe_product_id  text not null check (stripe_product_id ~ '^prod_[A-Za-z0-9]+$'),
  name               text not null check (char_length(btrim(name)) between 1 and 200),
  description        text check (description is null or char_length(description) <= 2000),
  amount_cents       integer not null check (amount_cents >= 0),
  currency           text not null check (currency ~ '^[a-z]{3}$'),
  interval           text not null check (interval in ('month', 'year')),
  interval_count     integer not null default 1 check (interval_count > 0),
  -- null = unlimited; counts active members + pending invites (0101)
  max_members        integer check (max_members is null or max_members > 0),
  features           text[] not null default '{}'
                       check (array_position(features, null) is null and cardinality(features) <= 50),
  sort               integer not null default 0,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index platform_plans_active_sort_idx on public.platform_plans (sort, amount_cents) where active;

comment on table public.platform_plans is
  'Shop subscription plans mirrored from the platform Stripe account (billing sync_plans). No client access: public_billing_plans() lists the active ones without Stripe ids.';
comment on column public.platform_plans.max_members is
  'Seat limit (active members + pending unexpired invites, owner included); null = unlimited.';

create trigger platform_plans_90_set_updated_at before update on public.platform_plans
  for each row execute function public.set_updated_at();

alter table public.platform_plans enable row level security;
-- No policies: only service_role (BYPASSRLS) and definer code read or write it.
revoke all on public.platform_plans from anon, authenticated;

-- ---------------------------------------------------------------------------
-- shop_billing (1:1 with shops)
-- ---------------------------------------------------------------------------
create table public.shop_billing (
  shop_id                 uuid primary key references public.shops (id) on delete cascade,
  stripe_customer_id      text unique check (stripe_customer_id is null or stripe_customer_id ~ '^cus_[A-Za-z0-9]+$'),
  stripe_subscription_id  text unique check (stripe_subscription_id is null
                                             or stripe_subscription_id ~ '^sub_[A-Za-z0-9]+$'),
  plan_id                 uuid references public.platform_plans (id) on delete set null,
  status                  text not null default 'none'
                            check (status in ('none', 'trialing', 'active', 'past_due', 'canceled', 'unpaid',
                                              'incomplete', 'incomplete_expired', 'paused')),
  trial_ends_at           timestamptz,
  trial_used              boolean not null default false,
  current_period_end      timestamptz,
  paid_through            timestamptz,
  cancel_at_period_end    boolean not null default false,
  comp_until              timestamptz,
  last_event_at           timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create index shop_billing_plan_idx on public.shop_billing (plan_id);

comment on table public.shop_billing is
  'A shop''s platform subscription (Stripe platform account). Written by definer code / service_role only (billing-webhook -> 0101 RPCs). Owners, admins and managers read the non-Stripe columns; everyone else uses shop_entitlement().';
comment on column public.shop_billing.status is
  'Stripe subscription status (none = never subscribed). The shop''s standing is derived by billing_state (0101).';
comment on column public.shop_billing.trial_ends_at is
  'End of the shop''s trial: the in-app trial (set_billing_config / new shops) or the Stripe subscription''s trial_end.';
comment on column public.shop_billing.trial_used is
  'A Stripe subscription of this shop had a trial: checkout no longer carries the in-app trial over.';
comment on column public.shop_billing.current_period_end is
  'Stripe''s current period end of the subscription. Stripe moves it on at renewal BEFORE the renewal is paid, so it is never what an ended subscription keeps access through (paid_through is).';
comment on column public.shop_billing.paid_through is
  'End of the last period the shop is in good standing for (billing_apply_subscription, 0101): the period end while the subscription is active / trialing; capped at the event time once it is past_due / unpaid / paused (the period Stripe moved on to was not paid). An ended subscription (canceled / unpaid / incomplete_expired / paused) keeps access until this time, never until current_period_end.';
comment on column public.shop_billing.comp_until is
  'Free until this time (''infinity'' = for good): billing_set_comp, the operator''s pilot-shop tool.';
comment on column public.shop_billing.last_event_at is
  'Created time of the newest Stripe event applied (older deliveries are ignored).';

create trigger shop_billing_90_set_updated_at before update on public.shop_billing
  for each row execute function public.set_updated_at();

alter table public.shop_billing enable row level security;

create policy shop_billing_select on public.shop_billing for select to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.shop_billing from anon, authenticated;
grant select (shop_id, plan_id, status, trial_ends_at, trial_used, current_period_end, cancel_at_period_end,
              comp_until, created_at, updated_at)
  on public.shop_billing to authenticated;

-- ---------------------------------------------------------------------------
-- Every shop has its row: new shops get one (with the in-app trial when
-- billing is on and the trial length is > 0), existing shops are backfilled.
-- ---------------------------------------------------------------------------
create function public.shops_seed_billing() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_days integer := public.billing_trial_days();
begin
  insert into public.shop_billing (shop_id, trial_ends_at)
  values (new.id, case when public.billing_enabled() and v_days > 0
                       then now() + make_interval(days => v_days) end)
  on conflict (shop_id) do nothing;
  return null;
end
$$;

create trigger shops_zz_billing_seed after insert on public.shops
  for each row execute function public.shops_seed_billing();

insert into public.shop_billing (shop_id, trial_ends_at)
select s.id, case when public.billing_enabled() and public.billing_trial_days() > 0
                  then now() + make_interval(days => public.billing_trial_days()) end
  from public.shops s
on conflict (shop_id) do nothing;

-- ---------------------------------------------------------------------------
-- Grants (functions)
-- ---------------------------------------------------------------------------
revoke execute on function public.shops_seed_billing() from public, anon, authenticated;
revoke execute on function public.billing_enabled(), public.billing_trial_days() from public, anon, authenticated;
grant execute on function public.billing_enabled(), public.billing_trial_days() to service_role;
