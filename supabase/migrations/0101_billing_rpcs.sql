-- ============================================================================
-- 0101 — Shop subscription billing: rules and RPCs (read 0100's header).
--
-- Standing (billing_state, the single place the rules live):
--   billing off                                   active    (reason billing_off)
--   comp_until > now                              comped    (comped)
--   status active                                 active    (subscribed)
--   status trialing                               trialing  (subscription_trial)
--   status past_due                               past_due  (past_due) — can still write:
--                                                 Stripe's retry schedule decides
--                                                 when it becomes unpaid / canceled
--   status none / incomplete, trial_ends_at > now trialing  (trial)
--   status none / incomplete otherwise            lapsed    (no_subscription | trial_ended
--                                                            | incomplete)
--   canceled / unpaid / incomplete_expired /
--   paused, paid_through > now                    active    (period_remaining)
--   the same otherwise                            lapsed    (the status itself)
-- An ended subscription keeps access through paid_through (0100: the end of
-- the last period the shop was in good standing for), NEVER through Stripe's
-- current_period_end: Stripe moves the period on at renewal before the
-- renewal is paid, so after failed retries (canceled / unpaid) that date is
-- the end of the period that was never paid — up to a year away on a yearly
-- plan. billing_apply_subscription keeps paid_through: the period end while
-- active / trialing, capped at the event time from past_due / unpaid /
-- paused on (so dunning that ends in canceled / unpaid lapses the shop at
-- once), unchanged by canceled / incomplete / incomplete_expired (a shop
-- that cancels while paid up keeps the rest of that period).
-- can_write = state <> 'lapsed' (shop_can_write). Billing state is judged on
-- the wall clock (now()), never on a caller's p_now.
--
-- Seats (billing_seats_used / billing_max_members): active members + pending
-- unexpired invites to addresses that are not already active members (the
-- owner counts). The limit is the plan's max_members while billing is on and
-- the shop is not comped; null = unlimited.
--
-- Client entry points:
--   shop_entitlement(p_shop_id) jsonb        any ACTIVE member (else P0002)
--   public_billing_plans() jsonb             anon + authenticated ([] while off)
-- service_role only (the `billing` / `billing-webhook` functions, the
-- deploy, the operator):
--   set_billing_config, billing_upsert_plan, billing_deactivate_plans_except,
--   billing_checkout_context, billing_link_customer,
--   billing_apply_subscription, billing_payment_failed, billing_set_comp
-- Internal (definer code): billing_state, shop_can_write,
--   billing_seats_used, billing_max_members.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- billing_state — the rules above (pure; p_now is required).
-- ---------------------------------------------------------------------------
create function public.billing_state(
  p_billing_enabled     boolean,
  p_status              text,
  p_trial_ends_at       timestamptz,
  p_paid_through        timestamptz,
  p_comp_until          timestamptz,
  p_now                 timestamptz,
  out state             text,
  out reason            text
)
language plpgsql immutable
set search_path = ''
as $$
begin
  if p_now is null then
    raise exception 'billing_state needs the time to judge at' using errcode = '22023';
  end if;
  if not coalesce(p_billing_enabled, false) then
    state := 'active'; reason := 'billing_off';
  elsif p_comp_until is not null and p_comp_until > p_now then
    state := 'comped'; reason := 'comped';
  else
    case coalesce(p_status, 'none')
      when 'active' then
        state := 'active'; reason := 'subscribed';
      when 'trialing' then
        state := 'trialing'; reason := 'subscription_trial';
      when 'past_due' then
        state := 'past_due'; reason := 'past_due';
      when 'none', 'incomplete' then
        if p_trial_ends_at is not null and p_trial_ends_at > p_now then
          state := 'trialing'; reason := 'trial';
        else
          state := 'lapsed';
          reason := case when p_status = 'incomplete' then 'incomplete'
                         when p_trial_ends_at is null then 'no_subscription'
                         else 'trial_ended' end;
        end if;
      when 'canceled', 'unpaid', 'incomplete_expired', 'paused' then
        if p_paid_through is not null and p_paid_through > p_now then
          state := 'active'; reason := 'period_remaining';
        else
          state := 'lapsed'; reason := p_status;
        end if;
      else
        state := 'lapsed'; reason := 'unknown_status';
    end case;
  end if;
end
$$;

comment on function public.billing_state(boolean, text, timestamptz, timestamptz, timestamptz, timestamptz) is
  'Internal, pure: a shop''s standing (state, reason) from its billing row at p_now. See the 0101 header.';

-- The shop's standing now (a missing row reads as never subscribed).
create function public.shop_billing_standing(p_shop_id uuid, out state text, out reason text)
language sql stable security definer
set search_path = ''
as $$
  select s.state, s.reason
    from (select 1) one
    left join public.shop_billing b on b.shop_id = p_shop_id
   cross join lateral public.billing_state(public.billing_enabled(), coalesce(b.status, 'none'), b.trial_ends_at,
                                           b.paid_through, b.comp_until, now()) s
$$;

-- May the shop create new business records right now? (Billing off: always.)
create function public.shop_can_write(p_shop_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select not public.billing_enabled()
      or (select s.state from public.shop_billing_standing(p_shop_id) s) <> 'lapsed'
$$;

comment on function public.shop_can_write(uuid) is
  'Internal: false while billing is on and the shop is lapsed (0101 rules). Not granted to API roles.';

-- ---------------------------------------------------------------------------
-- Seats
-- ---------------------------------------------------------------------------
-- Active members + pending unexpired invites to addresses that are not
-- active members yet. p_exclude_user leaves one member out (the one being
-- added); p_exclude_email leaves one address's invites out.
create function public.billing_seats_used(
  p_shop_id        uuid,
  p_exclude_user   uuid default null,
  p_exclude_email  text default null
) returns integer
language sql stable security definer
set search_path = ''
as $$
  select (select count(*) from public.shop_members m
           where m.shop_id = p_shop_id and m.active
             and (p_exclude_user is null or m.user_id <> p_exclude_user))::integer
       + (select count(distinct lower(i.email::text)) from public.shop_invites i
           where i.shop_id = p_shop_id and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()
             and (p_exclude_email is null or lower(i.email::text) <> lower(p_exclude_email))
             and not exists (select 1 from public.shop_members m join auth.users u on u.id = m.user_id
                              where m.shop_id = p_shop_id and m.active
                                and lower(u.email) = lower(i.email::text)))::integer
$$;

-- The seat limit in force: the plan's max_members while billing is on and
-- the shop is not comped; null = unlimited.
create function public.billing_max_members(p_shop_id uuid) returns integer
language sql stable security definer
set search_path = ''
as $$
  select case when not public.billing_enabled() then null
              when b.comp_until is not null and b.comp_until > now() then null
              else p.max_members end
    from (select 1) one
    left join public.shop_billing b on b.shop_id = p_shop_id
    left join public.platform_plans p on p.id = b.plan_id
$$;

-- ---------------------------------------------------------------------------
-- shop_entitlement(p_shop_id) — the caller's view of the shop's standing.
-- Any ACTIVE member; anyone else (and an unknown shop) P0002.
-- {billing_enabled, state, reason, plan_name, trial_ends_at,
--  current_period_end, cancel_at_period_end, max_members, members_used,
--  can_write, is_owner}. Billing details (plan_name, trial_ends_at,
-- current_period_end, cancel_at_period_end, max_members, members_used) are
-- for owners, admins and managers: technicians get null (false) there and
-- only the standing they need to explain a refusal. Never prices or Stripe
-- ids. current_period_end is the renewal / end date of a live subscription;
-- for an ended one (canceled / unpaid / incomplete_expired / paused) it is
-- when access ends or ended (paid_through), never the unpaid period's end.
-- ---------------------------------------------------------------------------
create function public.shop_entitlement(p_shop_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role    public.shop_role := public.shop_role_of(p_shop_id);
  v_enabled boolean := public.billing_enabled();
  v_b       public.shop_billing;
  v_plan    text;
  v_state   text;
  v_reason  text;
  v_details boolean;
begin
  if v_role is null then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_b from public.shop_billing b where b.shop_id = p_shop_id;
  select p.name into v_plan from public.platform_plans p where p.id = v_b.plan_id;
  select s.state, s.reason into v_state, v_reason
    from public.billing_state(v_enabled, coalesce(v_b.status, 'none'), v_b.trial_ends_at, v_b.paid_through,
                              v_b.comp_until, now()) s;
  v_details := v_role in ('owner', 'admin', 'manager');
  return jsonb_build_object(
    'billing_enabled', v_enabled,
    'state', v_state,
    'reason', v_reason,
    'plan_name', case when v_details then v_plan end,
    'trial_ends_at', case when v_details then v_b.trial_ends_at end,
    'current_period_end', case when not v_details then null
                               when v_b.status in ('canceled', 'unpaid', 'incomplete_expired', 'paused') then v_b.paid_through
                               else v_b.current_period_end end,
    'cancel_at_period_end', v_details and coalesce(v_b.cancel_at_period_end, false),
    'max_members', case when v_details then public.billing_max_members(p_shop_id) end,
    'members_used', case when v_details then public.billing_seats_used(p_shop_id) end,
    'can_write', v_state <> 'lapsed',
    'is_owner', v_role = 'owner');
end
$$;

-- ---------------------------------------------------------------------------
-- public_billing_plans() — anon + authenticated: [] while billing is off,
-- else the active plans ordered by sort, amount:
-- [{id, name, description, amount_cents, currency, interval, interval_count,
--   max_members, features}]. Never Stripe ids.
-- ---------------------------------------------------------------------------
create function public.public_billing_plans() returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select case when not public.billing_enabled() then '[]'::jsonb
              else coalesce((
                select jsonb_agg(jsonb_build_object(
                         'id', p.id,
                         'name', p.name,
                         'description', p.description,
                         'amount_cents', p.amount_cents,
                         'currency', p.currency,
                         'interval', p.interval,
                         'interval_count', p.interval_count,
                         'max_members', p.max_members,
                         'features', to_jsonb(p.features))
                       order by p.sort, p.amount_cents, p.name, p.id)
                  from public.platform_plans p
                 where p.active), '[]'::jsonb) end
$$;

-- ---------------------------------------------------------------------------
-- set_billing_config(enabled, trial days) — service_role (the deploy's
-- platform setup; docs/BILLING.md). Writes platform_config billing_enabled
-- ('true' | 'false') and billing_trial_days (0 .. 730; 22023 otherwise).
-- Turning billing ON (from off / unset) starts the in-app trial of every
-- shop that never subscribed and has none yet (status 'none', trial_ends_at
-- null): now + trial days (0 days: no trial, they stay lapsed until they
-- subscribe). Calling it again with the same values changes nothing.
-- ---------------------------------------------------------------------------
create function public.set_billing_config(p_enabled boolean, p_trial_days integer) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_was boolean := public.billing_enabled();
begin
  if p_enabled is null then
    raise exception 'billing must be turned on (true) or off (false)' using errcode = '22023';
  end if;
  if p_trial_days is null or p_trial_days < 0 or p_trial_days > 730 then
    raise exception 'trial days must be a whole number from 0 to 730' using errcode = '22023';
  end if;
  insert into public.platform_config (key, value)
  values ('billing_enabled', case when p_enabled then 'true' else 'false' end),
         ('billing_trial_days', p_trial_days::text)
  on conflict (key) do update set value = excluded.value
    where public.platform_config.value is distinct from excluded.value;
  if p_enabled and not v_was and p_trial_days > 0 then
    update public.shop_billing b
       set trial_ends_at = now() + make_interval(days => p_trial_days)
     where b.status = 'none' and b.trial_ends_at is null;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Plans (billing sync_plans / billing-webhook product.* and price.*)
-- ---------------------------------------------------------------------------
-- Upsert by stripe_price_id; returns the plan id. Name / description are
-- trimmed (and cut to 200 / 2000 characters); features must be lower-case
-- keys ([a-z0-9][a-z0-9_-]{0,63}, at most 50, duplicates dropped).
create function public.billing_upsert_plan(
  p_stripe_price_id    text,
  p_stripe_product_id  text,
  p_name               text,
  p_description        text,
  p_amount_cents       integer,
  p_currency           text,
  p_interval           text,
  p_interval_count     integer,
  p_max_members        integer,
  p_features           text[],
  p_sort               integer,
  p_active             boolean
) returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_name     text := left(btrim(coalesce(p_name, '')), 200);
  v_desc     text := left(nullif(btrim(coalesce(p_description, '')), ''), 2000);
  v_currency text := lower(btrim(coalesce(p_currency, '')));
  v_features text[];
  v_id       uuid;
begin
  if p_stripe_price_id is null or p_stripe_price_id !~ '^price_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe price id' using errcode = '22023';
  end if;
  if p_stripe_product_id is null or p_stripe_product_id !~ '^prod_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe product id' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'a plan needs a name' using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'amount must be zero or more cents' using errcode = '22023';
  end if;
  if v_currency !~ '^[a-z]{3}$' then
    raise exception 'currency must be a three-letter ISO code' using errcode = '22023';
  end if;
  if p_interval is null or p_interval not in ('month', 'year') then
    raise exception 'interval must be month or year' using errcode = '22023';
  end if;
  if p_interval_count is not null and p_interval_count < 1 then
    raise exception 'interval count must be at least 1' using errcode = '22023';
  end if;
  if p_max_members is not null and p_max_members < 1 then
    raise exception 'max members must be at least 1 (null = unlimited)' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_features, '{}')) f where f is null or f !~ '^[a-z0-9][a-z0-9_-]{0,63}$') then
    raise exception 'features must be lower-case keys' using errcode = '22023';
  end if;
  select coalesce(array_agg(f order by o), '{}') into v_features
    from (select f, min(o) as o from unnest(coalesce(p_features, '{}')) with ordinality as x(f, o) group by f) y;
  if cardinality(v_features) > 50 then
    raise exception 'at most 50 features' using errcode = '22023';
  end if;

  insert into public.platform_plans as p (stripe_price_id, stripe_product_id, name, description, amount_cents,
                                          currency, interval, interval_count, max_members, features, sort, active)
  values (p_stripe_price_id, p_stripe_product_id, v_name, v_desc, p_amount_cents, v_currency, p_interval,
          coalesce(p_interval_count, 1), p_max_members, v_features, coalesce(p_sort, 0), coalesce(p_active, true))
  on conflict (stripe_price_id) do update
    set stripe_product_id = excluded.stripe_product_id,
        name = excluded.name,
        description = excluded.description,
        amount_cents = excluded.amount_cents,
        currency = excluded.currency,
        interval = excluded.interval,
        interval_count = excluded.interval_count,
        max_members = excluded.max_members,
        features = excluded.features,
        sort = excluded.sort,
        active = excluded.active
  returning p.id into v_id;
  return v_id;
end
$$;

-- Retires every active plan whose price is not listed (null / empty list:
-- all of them). Returns how many were turned inactive. Retired plans stay
-- (shops subscribed to them keep their plan name); they are no longer
-- offered.
create function public.billing_deactivate_plans_except(p_active_price_ids text[]) returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.platform_plans p
     set active = false
   where p.active
     and not (p.stripe_price_id = any (coalesce(p_active_price_ids, '{}')));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------
-- billing_checkout_context(shop, user) — what `billing` checkout / portal
-- need: {is_owner, shop_name, owner_email, stripe_customer_id,
-- has_live_subscription, trial_end, billing_enabled}. Unknown shop: P0002.
--   is_owner               p_user_id is the shop's (active) owner
--   owner_email            the owner's account email
--   has_live_subscription  a subscription that still exists in Stripe:
--                          trialing, active, past_due, unpaid or paused
--                          (a new checkout would bill twice; the Customer
--                          Portal manages it)
--   trial_end              the shop's remaining in-app trial end while it is
--                          in the future and no subscription used a trial
-- ---------------------------------------------------------------------------
create function public.billing_checkout_context(p_shop_id uuid, p_user_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop  public.shops;
  v_b     public.shop_billing;
  v_owner uuid;
  v_email text;
begin
  select * into v_shop from public.shops s where s.id = p_shop_id;
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_b from public.shop_billing b where b.shop_id = p_shop_id;
  select m.user_id, u.email::text into v_owner, v_email
    from public.shop_members m
    join auth.users u on u.id = m.user_id
   where m.shop_id = p_shop_id and m.role = 'owner' and m.active;
  return jsonb_build_object(
    'is_owner', p_user_id is not null and p_user_id = v_owner,
    'shop_name', v_shop.name,
    'owner_email', v_email,
    'stripe_customer_id', v_b.stripe_customer_id,
    'has_live_subscription', v_b.stripe_subscription_id is not null
                             and coalesce(v_b.status, 'none') in ('trialing', 'active', 'past_due', 'unpaid', 'paused'),
    'trial_end', case when v_b.trial_ends_at > now() and not coalesce(v_b.trial_used, false) then v_b.trial_ends_at end,
    'billing_enabled', public.billing_enabled());
end
$$;

-- ---------------------------------------------------------------------------
-- billing_link_customer(shop, Stripe customer) — idempotent. 22023 for a
-- malformed id, P0002 for an unknown shop, 23505 when another shop already
-- owns the customer or this shop is linked to a different one (never
-- silently swapped).
-- ---------------------------------------------------------------------------
create function public.billing_link_customer(p_shop_id uuid, p_stripe_customer_id text) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_b public.shop_billing;
begin
  if p_stripe_customer_id is null or p_stripe_customer_id !~ '^cus_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe customer id' using errcode = '22023';
  end if;
  if not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  insert into public.shop_billing (shop_id) values (p_shop_id) on conflict (shop_id) do nothing;
  select * into v_b from public.shop_billing b where b.shop_id = p_shop_id for update;
  if v_b.stripe_customer_id = p_stripe_customer_id then
    return;
  end if;
  if v_b.stripe_customer_id is not null then
    raise exception 'this shop is already linked to another billing customer' using errcode = '23505';
  end if;
  if exists (select 1 from public.shop_billing b
              where b.stripe_customer_id = p_stripe_customer_id and b.shop_id <> p_shop_id) then
    raise exception 'this billing customer belongs to another shop' using errcode = '23505';
  end if;
  update public.shop_billing b set stripe_customer_id = p_stripe_customer_id where b.shop_id = p_shop_id;
end
$$;

-- ---------------------------------------------------------------------------
-- billing_apply_subscription — a subscription's CURRENT state (re-read from
-- Stripe by the webhook) as of p_event_created. Returns {shop_id, applied}:
--   * unknown customer: {shop_id: null, applied: false};
--   * an event older than the newest one applied (last_event_at): nothing
--     changes, {shop_id, applied: false} (out-of-order deliveries never roll
--     a shop back; equal times are applied — the state is re-read anyway);
--   * another subscription than the shop's current one is applied only when
--     it can be the shop's subscription now: one that has ended (canceled /
--     incomplete_expired) never replaces the current one, and a pending
--     (incomplete) one never replaces a live one — {shop_id, applied: false};
--   * plan: the plan with that price (active or retired); an unknown price
--     leaves plan_id null but the status is still applied;
--   * trial_used once a subscription had a trial (p_trial_end or trialing);
--     trial_ends_at follows the subscription's trial_end when it has one;
--   * canceled (subscription deleted): current_period_end is kept when the
--     event carries none, cancel_at_period_end becomes false;
--   * paid_through (what an ended subscription keeps access through, see
--     the header): active / trialing -> the period end; past_due / unpaid /
--     paused -> at most the event time (the period Stripe moved on to is
--     not paid); canceled / incomplete / incomplete_expired -> unchanged.
-- 22023: malformed ids, a status Stripe does not have, no event time.
-- ---------------------------------------------------------------------------
create function public.billing_apply_subscription(
  p_stripe_customer_id    text,
  p_subscription_id       text,
  p_price_id              text,
  p_status                text,
  p_trial_end             timestamptz,
  p_current_period_end    timestamptz,
  p_cancel_at_period_end  boolean,
  p_event_created         timestamptz
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_b     public.shop_billing;
  v_plan  uuid;
  v_live  constant text[] := array['trialing', 'active', 'past_due', 'unpaid', 'paused'];
  v_ended constant text[] := array['canceled', 'incomplete_expired'];
begin
  if p_stripe_customer_id is null or p_stripe_customer_id !~ '^cus_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe customer id' using errcode = '22023';
  end if;
  if p_subscription_id is null or p_subscription_id !~ '^sub_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe subscription id' using errcode = '22023';
  end if;
  if p_price_id is not null and p_price_id !~ '^price_[A-Za-z0-9]+$' then
    raise exception 'invalid Stripe price id' using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('trialing', 'active', 'past_due', 'canceled', 'unpaid', 'incomplete',
                                          'incomplete_expired', 'paused') then
    raise exception 'unknown subscription status "%"', p_status using errcode = '22023';
  end if;
  if p_event_created is null then
    raise exception 'the event time is required' using errcode = '22023';
  end if;

  select * into v_b from public.shop_billing b where b.stripe_customer_id = p_stripe_customer_id for update;
  if not found then
    return jsonb_build_object('shop_id', null, 'applied', false);
  end if;
  if v_b.last_event_at is not null and p_event_created < v_b.last_event_at then
    return jsonb_build_object('shop_id', v_b.shop_id, 'applied', false);
  end if;
  if v_b.stripe_subscription_id is not null and v_b.stripe_subscription_id <> p_subscription_id
     and (p_status = any (v_ended) or (p_status = 'incomplete' and v_b.status = any (v_live))) then
    return jsonb_build_object('shop_id', v_b.shop_id, 'applied', false);
  end if;
  if p_subscription_id <> coalesce(v_b.stripe_subscription_id, '')
     and exists (select 1 from public.shop_billing b
                  where b.stripe_subscription_id = p_subscription_id and b.shop_id <> v_b.shop_id) then
    raise exception 'this subscription belongs to another shop' using errcode = '23505';
  end if;

  select p.id into v_plan from public.platform_plans p where p.stripe_price_id = p_price_id;

  update public.shop_billing b
     set stripe_subscription_id = p_subscription_id,
         plan_id = v_plan,
         status = p_status,
         trial_ends_at = coalesce(p_trial_end, b.trial_ends_at),
         trial_used = b.trial_used or p_trial_end is not null or p_status = 'trialing',
         current_period_end = coalesce(p_current_period_end, b.current_period_end),
         paid_through = case when p_status in ('active', 'trialing')
                               then coalesce(p_current_period_end, b.current_period_end)
                             when p_status in ('past_due', 'unpaid', 'paused')
                               then least(b.paid_through, p_event_created)
                             else b.paid_through end,
         cancel_at_period_end = case when p_status = any (v_ended) then false
                                     else coalesce(p_cancel_at_period_end, false) end,
         last_event_at = greatest(coalesce(b.last_event_at, p_event_created), p_event_created)
   where b.shop_id = v_b.shop_id;
  return jsonb_build_object('shop_id', v_b.shop_id, 'applied', true);
end
$$;

-- ---------------------------------------------------------------------------
-- billing_payment_failed(Stripe customer, event time) — invoice.payment_failed
-- of a shop's subscription: the owner gets 'billing_payment_failed' (push +
-- in-app; the web deep-links the kind to /app/settings/billing). Neutral
-- wording only. Unknown customer: P0002. Nothing is sent when the owner
-- still has an unread one for this shop (retries do not pile up; a re-run
-- of the same event is harmless), nor for an event older than the newest
-- applied one once the subscription is active / trialing again.
-- ---------------------------------------------------------------------------
create function public.billing_payment_failed(p_stripe_customer_id text, p_event_created timestamptz) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_b public.shop_billing;
begin
  select * into v_b from public.shop_billing b where b.stripe_customer_id = p_stripe_customer_id for update;
  if not found then
    raise exception 'billing customer not found' using errcode = 'P0002';
  end if;
  if p_event_created is not null and v_b.last_event_at is not null and p_event_created < v_b.last_event_at
     and v_b.status in ('active', 'trialing') then
    return;
  end if;
  if exists (select 1 from public.notifications n
               join public.shop_members m on m.shop_id = n.shop_id and m.user_id = n.user_id
              where n.shop_id = v_b.shop_id and n.kind = 'billing_payment_failed' and n.read_at is null
                and m.role = 'owner' and m.active) then
    return;
  end if;
  perform public.notify_shop_staff(v_b.shop_id, array['owner']::public.shop_role[], 'billing_payment_failed',
                                   'Subscription payment problem',
                                   'There''s a problem with this shop''s subscription payment.');
end
$$;

-- ---------------------------------------------------------------------------
-- billing_set_comp(shop, until) — the operator's pilot-shop tool (service_role
-- / SQL editor): free until p_until ('infinity' = for good; null ends the
-- comp). Unknown shop: P0002.
--   select public.billing_set_comp('<shop id>', 'infinity');
-- ---------------------------------------------------------------------------
create function public.billing_set_comp(p_shop_id uuid, p_until timestamptz) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  insert into public.shop_billing (shop_id, comp_until) values (p_shop_id, p_until)
  on conflict (shop_id) do update set comp_until = excluded.comp_until;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.billing_state(boolean, text, timestamptz, timestamptz, timestamptz, timestamptz),
  public.shop_billing_standing(uuid),
  public.shop_can_write(uuid),
  public.billing_seats_used(uuid, uuid, text),
  public.billing_max_members(uuid),
  public.set_billing_config(boolean, integer),
  public.billing_upsert_plan(text, text, text, text, integer, text, text, integer, integer, text[], integer, boolean),
  public.billing_deactivate_plans_except(text[]),
  public.billing_checkout_context(uuid, uuid),
  public.billing_link_customer(uuid, text),
  public.billing_apply_subscription(text, text, text, text, timestamptz, timestamptz, boolean, timestamptz),
  public.billing_payment_failed(text, timestamptz),
  public.billing_set_comp(uuid, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.billing_state(boolean, text, timestamptz, timestamptz, timestamptz, timestamptz),
  public.shop_billing_standing(uuid),
  public.shop_can_write(uuid),
  public.billing_seats_used(uuid, uuid, text),
  public.billing_max_members(uuid),
  public.set_billing_config(boolean, integer),
  public.billing_upsert_plan(text, text, text, text, integer, text, text, integer, integer, text[], integer, boolean),
  public.billing_deactivate_plans_except(text[]),
  public.billing_checkout_context(uuid, uuid),
  public.billing_link_customer(uuid, text),
  public.billing_apply_subscription(text, text, text, text, timestamptz, timestamptz, boolean, timestamptz),
  public.billing_payment_failed(text, timestamptz),
  public.billing_set_comp(uuid, timestamptz)
to service_role;

revoke execute on function public.shop_entitlement(uuid) from public, anon;
grant execute on function public.shop_entitlement(uuid) to authenticated, service_role;

revoke execute on function public.public_billing_plans() from public;
grant execute on function public.public_billing_plans() to anon, authenticated, service_role;
