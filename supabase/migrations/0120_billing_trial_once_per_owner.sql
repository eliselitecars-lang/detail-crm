-- ============================================================================
-- 0120 — The in-app free trial is given once per owner, not once per shop.
--
-- shops_zz_billing_seed (0100) gave every new shop a fresh trial
-- (trial_ends_at = now() + billing_trial_days) while billing is on, and
-- create_shop lets any registered user create any number of shops. Nothing
-- tied a trial to the person: trial_used is per shop (and only about Stripe
-- trials). An owner whose trial ended (lapsed: no new work, BILLING.md §8)
-- could create another shop — or delete the lapsed one and re-create it
-- under the freed slug — re-import the customer and service CSV export
-- (0087 / 0114) and get another full trial, indefinitely: a shop never had
-- to pay.
--
-- Now a trial is recorded against the person it was given to:
--   * billing_trial_grants (new, internal: no client access; the operator
--     reads / deletes rows as service_role): one row per in-app trial given
--     — the owner's user id (null once the account is deleted), a hash of
--     their normalized email (kept when the account or the shop is
--     deleted, so a re-registered address is recognised), the shop (no
--     foreign key: the row outlives the shop) and the trial's end.
--   * billing_trial_email_key(email) (internal, immutable): sha256 hex of
--     the email lower-cased and trimmed, with a "+tag" dropped from the
--     local part (name+2@x.com is name@x.com); null for no email.
--   * billing_trial_already_given(user) (internal): true when a grant
--     exists for the user id or for the user's email key.
--   * shops_seed_billing (0100 body): while billing is on with a trial
--     length > 0, a shop created by a user (shops.created_by, set by
--     create_shop) gets the trial only when that user was never given
--     one; otherwise it starts without a trial (trial_ends_at null:
--     lapsed / no_subscription — Settings → Billing offers the plans, and
--     checkout carries no trial). The grant is recorded in the same
--     transaction, under an advisory lock per user and per email key, so
--     two shops created at once cannot both take the trial. A shop with no
--     creator (service role / operator SQL) is seeded as before.
--   * set_billing_config (0101 body): turning billing on still starts the
--     trial of every existing shop that never subscribed (unchanged, the
--     operator's go-live), and now records a grant for each such shop's
--     owner, so those owners' later shops start without one.
-- Deleting a shop or an account never gives a trial back. The operator can
-- (service role): `delete from public.billing_trial_grants where ...`.
-- Not covered (documented in BILLING.md §5): a person who signs up again
-- under a different email address.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- billing_trial_grants
-- ---------------------------------------------------------------------------
create table public.billing_trial_grants (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references auth.users (id) on delete set null,
  email_key      text check (email_key is null or email_key ~ '^[0-9a-f]{64}$'),
  trial_shop_id  uuid,
  trial_ends_at  timestamptz not null,
  created_at     timestamptz not null default now()
);
create index billing_trial_grants_user_idx on public.billing_trial_grants (user_id) where user_id is not null;
create index billing_trial_grants_email_idx on public.billing_trial_grants (email_key) where email_key is not null;

comment on table public.billing_trial_grants is
  'Internal (0120): one row per in-app free trial given (new shop while billing is on, or billing switched on) — the owner''s user id (null after the account is deleted), billing_trial_email_key of their email, the shop (no FK: kept after the shop is deleted) and the trial end. A user (or email) with a row gets no trial on another shop. No client access; the operator may delete rows (service role) to allow another trial.';
comment on column public.billing_trial_grants.email_key is
  'sha256 hex of the owner''s normalized email (billing_trial_email_key): recognises the address after the account is deleted and registered again, without keeping the address itself.';
comment on column public.billing_trial_grants.trial_shop_id is
  'The shop the trial was given to (no foreign key: the row outlives the shop).';

alter table public.billing_trial_grants enable row level security;
revoke all on table public.billing_trial_grants from public, anon, authenticated;
grant select, delete on table public.billing_trial_grants to service_role;

-- ---------------------------------------------------------------------------
-- billing_trial_email_key / billing_trial_already_given — internal
-- ---------------------------------------------------------------------------
create function public.billing_trial_email_key(p_email text) returns text
language sql immutable
set search_path = ''
as $$
  select case when v is null or v = '' then null
              else encode(sha256(convert_to(regexp_replace(v, '^([^@+]*)\+[^@]*@', '\1@'), 'UTF8')), 'hex') end
    from (select lower(btrim(p_email)) as v) x
$$;

comment on function public.billing_trial_email_key(text) is
  'Internal (0120): sha256 hex of an email lower-cased and trimmed, "+tag" removed from the local part; null for no email.';

create function public.billing_trial_already_given(p_user_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_user_id is not null
     and exists (select 1 from public.billing_trial_grants g
                  where g.user_id = p_user_id
                     or g.email_key = (select public.billing_trial_email_key(u.email::text)
                                         from auth.users u where u.id = p_user_id))
$$;

comment on function public.billing_trial_already_given(uuid) is
  'Internal (0120): true when an in-app trial was already given to this user (by user id or by their email key).';

-- Records a grant for a user (no-op for a null user).
create function public.billing_record_trial_grant(p_user_id uuid, p_shop_id uuid, p_trial_ends_at timestamptz)
returns void
language sql volatile security definer
set search_path = ''
as $$
  insert into public.billing_trial_grants (user_id, email_key, trial_shop_id, trial_ends_at)
  select u.id, public.billing_trial_email_key(u.email::text), p_shop_id, p_trial_ends_at
    from auth.users u
   where u.id = p_user_id and p_trial_ends_at is not null
$$;

comment on function public.billing_record_trial_grant(uuid, uuid, timestamptz) is
  'Internal (0120): records that p_user_id was given the in-app trial of p_shop_id (billing_trial_grants).';

-- ---------------------------------------------------------------------------
-- shops_seed_billing (0100 body) — the trial once per creator
-- ---------------------------------------------------------------------------
create or replace function public.shops_seed_billing() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_days   integer := public.billing_trial_days();
  v_trial  timestamptz;
  v_key    text;
begin
  if public.billing_enabled() and v_days > 0 then
    if new.created_by is not null then
      -- 0120: one trial per person; serialise this person's shop creations
      select public.billing_trial_email_key(u.email::text) into v_key from auth.users u where u.id = new.created_by;
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('public.billing_trial_grants:user:' || new.created_by::text, 0));
      if v_key is not null then
        perform pg_catalog.pg_advisory_xact_lock(
          pg_catalog.hashtextextended('public.billing_trial_grants:email:' || v_key, 0));
      end if;
      if not public.billing_trial_already_given(new.created_by) then
        v_trial := now() + make_interval(days => v_days);
      end if;
    else
      v_trial := now() + make_interval(days => v_days);
    end if;
  end if;
  insert into public.shop_billing (shop_id, trial_ends_at)
  values (new.id, v_trial)
  on conflict (shop_id) do nothing;
  if found and v_trial is not null and new.created_by is not null then
    perform public.billing_record_trial_grant(new.created_by, new.id, v_trial);
  end if;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- set_billing_config (0101 body) — turning billing on records the grants
-- ---------------------------------------------------------------------------
create or replace function public.set_billing_config(p_enabled boolean, p_trial_days integer) returns void
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
    with started as (
      update public.shop_billing b
         set trial_ends_at = now() + make_interval(days => p_trial_days)
       where b.status = 'none' and b.trial_ends_at is null
      returning b.shop_id, b.trial_ends_at
    )
    -- 0120: each such shop's owner (else its creator) has now had a trial
    insert into public.billing_trial_grants (user_id, email_key, trial_shop_id, trial_ends_at)
    select u.id, public.billing_trial_email_key(u.email::text), st.shop_id, st.trial_ends_at
      from started st
      join public.shops s on s.id = st.shop_id
      join auth.users u
        on u.id = coalesce((select m.user_id from public.shop_members m
                             where m.shop_id = s.id and m.role = 'owner' and m.active
                             order by m.created_at limit 1),
                           s.created_by);
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants (functions)
-- ---------------------------------------------------------------------------
revoke execute on function
  public.billing_trial_email_key(text),
  public.billing_trial_already_given(uuid),
  public.billing_record_trial_grant(uuid, uuid, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.billing_trial_email_key(text),
  public.billing_trial_already_given(uuid)
to service_role;
