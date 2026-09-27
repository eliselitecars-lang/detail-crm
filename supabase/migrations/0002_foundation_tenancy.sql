-- ============================================================================
-- 0002 — Tenancy & identity (SPEC §3, §4.1): profiles, shops, shop_members,
-- role helpers, shop_invites, member_compensation, shop_stripe_accounts,
-- shop_counters + next_document_number, create_shop, invite RPCs,
-- leave_shop, transfer_ownership, shop_team.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- profiles — one per auth user, created by trigger.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  full_name    text check (full_name is null or char_length(full_name) between 1 and 200),
  phone        text check (phone is null or public.is_valid_e164(phone)),
  avatar_path  text check (avatar_path is null or char_length(avatar_path) <= 1024),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create function public.handle_new_auth_user() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id,
          left(nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name',
                                     new.raw_user_meta_data ->> 'name')), ''), 200))
  on conflict (id) do nothing;
  return new;
end
$$;

create trigger on_auth_user_created_profile after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- shops — the tenant.
-- ---------------------------------------------------------------------------
create table public.shops (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null check (char_length(btrim(name)) between 1 and 120),
  slug                        text not null unique
                                check (public.is_valid_slug(slug)),
  email                       extensions.citext check (email is null or public.is_valid_email(email::text)),
  phone                       text check (phone is null or public.is_valid_e164(phone)),
  website                     text check (website is null or char_length(website) <= 500),
  address_line1               text check (address_line1 is null or char_length(address_line1) <= 200),
  address_line2               text check (address_line2 is null or char_length(address_line2) <= 200),
  city                        text check (city is null or char_length(city) <= 100),
  region                      text check (region is null or char_length(region) <= 100),
  postal_code                 text check (postal_code is null or char_length(postal_code) <= 20),
  country                     text not null default 'US' check (country ~ '^[A-Z]{2}$'),
  lat                         double precision check (lat is null or lat between -90 and 90),
  lng                         double precision check (lng is null or lng between -180 and 180),
  timezone                    text not null,
  currency                    text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  logo_path                   text,
  brand_color                 text check (brand_color is null or public.is_valid_hex_color(brand_color)),
  business_type               public.business_type not null default 'fixed',
  tax_rate_bps                integer not null default 0 check (tax_rate_bps between 0 and 10000),
  techs_can_collect_payments  boolean not null default false,
  review_url                  text check (review_url is null or char_length(review_url) <= 1000),
  quote_terms                 text check (quote_terms is null or char_length(quote_terms) <= 20000),
  invoice_terms               text check (invoice_terms is null or char_length(invoice_terms) <= 20000),
  invoice_due_days            integer not null default 0 check (invoice_due_days between 0 and 365),
  sms_from_number             text check (sms_from_number is null or public.is_valid_e164(sms_from_number)),
  created_by                  uuid references auth.users (id) on delete set null,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint shops_lat_lng_pair check ((lat is null) = (lng is null)),
  -- the logo is an object of THIS shop's shop-assets folder (0001)
  constraint shops_logo_path_check check (logo_path is null or public.is_shop_asset_path(id, logo_path))
);
create index shops_created_by_idx on public.shops (created_by);

comment on table public.shops is 'Tenant. Created only via public.create_shop (or service_role).';

create function public.shops_before_write() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.timezone is distinct from old.timezone then
    if not public.is_valid_timezone(new.timezone) then
      raise exception 'invalid time zone "%"', new.timezone using errcode = '22023';
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.id <> old.id then
      raise exception 'shops.id cannot be changed' using errcode = '42501';
    end if;
    new.created_by := public.audit_user_ref(new.created_by, old.created_by);
  end if;
  new.name := btrim(new.name);
  return new;
end
$$;

create trigger shops_10_before_write before insert or update on public.shops
  for each row execute function public.shops_before_write();
create trigger shops_90_set_updated_at before update on public.shops
  for each row execute function public.set_updated_at();
-- upload the logo first, then save its path
create trigger shops_logo_object_exists after insert or update of logo_path on public.shops
  for each row execute function public.require_shop_asset_object('logo_path');

-- ---------------------------------------------------------------------------
-- shop_members — staff membership. Exactly one owner per shop.
-- ---------------------------------------------------------------------------
create table public.shop_members (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops (id) on delete cascade,
  user_id         uuid not null references auth.users (id) on delete cascade,
  role            public.shop_role not null,
  display_name    text not null check (char_length(btrim(display_name)) between 1 and 100),
  phone           text check (phone is null or public.is_valid_e164(phone)),
  calendar_color  text check (calendar_color is null or public.is_valid_hex_color(calendar_color)),
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint shop_members_shop_user_key unique (shop_id, user_id),
  constraint shop_members_shop_id_id_key unique (shop_id, id),
  constraint shop_members_owner_active check (role <> 'owner' or active),
  -- at most one owner; checked at end of statement so transfer_ownership can
  -- swap roles in a single UPDATE.
  constraint shop_members_one_owner exclude using btree (shop_id with =) where (role = 'owner')
    deferrable initially immediate
);
create index shop_members_user_idx on public.shop_members (user_id);

-- ---------------------------------------------------------------------------
-- Role helpers (SECURITY DEFINER so RLS policies can call them without
-- recursing into shop_members' own policies). Inactive members have no role.
-- ---------------------------------------------------------------------------
create function public.shop_role_of(p_shop_id uuid) returns public.shop_role
language sql stable security definer
set search_path = ''
as $$
  select m.role
  from public.shop_members m
  where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active
$$;

create function public.is_shop_member(p_shop_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active)
$$;

create function public.has_shop_role(p_shop_id uuid, variadic p_roles public.shop_role[]) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(public.shop_role_of(p_shop_id) = any (p_roles), false)
$$;

-- owner/admin
create function public.is_shop_admin(p_shop_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$ select public.has_shop_role(p_shop_id, 'owner', 'admin') $$;

-- owner/admin/manager
create function public.is_shop_manager(p_shop_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$ select public.has_shop_role(p_shop_id, 'owner', 'admin', 'manager') $$;

-- The caller's own active membership row?
create function public.is_own_member(p_member_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shop_members m
    where m.id = p_member_id and m.user_id = auth.uid() and m.active)
$$;

-- Is the caller a manager+ in some shop where p_user_id is a member?
create function public.manages_user(p_user_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.shop_members me
    join public.shop_members them on them.shop_id = me.shop_id
    where me.user_id = auth.uid() and me.active
      and me.role in ('owner', 'admin', 'manager')
      and them.user_id = p_user_id)
$$;

-- ---------------------------------------------------------------------------
-- shop_members guards
-- ---------------------------------------------------------------------------

-- Direct (PostgREST) updates/deletes. RPCs (create_shop, accept_invite,
-- leave_shop, transfer_ownership) run as the definer and bypass this.
create function public.shop_members_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_caller_role public.shop_role;
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;
  v_caller_role := public.shop_role_of(old.shop_id);

  if tg_op = 'DELETE' then
    if old.role = 'owner' then
      raise exception 'the owner membership cannot be removed; transfer ownership first'
        using errcode = '42501';
    end if;
    if old.user_id = auth.uid() then
      raise exception 'use leave_shop to leave a shop' using errcode = '42501';
    end if;
    return old;
  end if;

  if new.id <> old.id or new.shop_id <> old.shop_id or new.user_id <> old.user_id then
    raise exception 'membership identity columns cannot be changed' using errcode = '42501';
  end if;

  if old.user_id = auth.uid() then
    if new.role <> old.role then
      raise exception 'you cannot change your own role' using errcode = '42501';
    end if;
    if new.active <> old.active then
      raise exception 'you cannot change your own active status' using errcode = '42501';
    end if;
    return new;
  end if;

  if v_caller_role is null or v_caller_role not in ('owner', 'admin') then
    raise exception 'only owners and admins can modify team members' using errcode = '42501';
  end if;
  if old.role = 'owner' then
    raise exception 'only the owner can modify the owner membership' using errcode = '42501';
  end if;
  if new.role = 'owner' then
    raise exception 'use transfer_ownership to make someone the owner' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger shop_members_10_client_guard before update or delete on public.shop_members
  for each row execute function public.shop_members_client_guard();

-- In every context: the owner row can only disappear with its shop.
create function public.shop_members_protect_owner() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.role = 'owner' and exists (select 1 from public.shops s where s.id = old.shop_id) then
    raise exception 'the owner membership cannot be removed; transfer ownership or delete the shop first'
      using errcode = '23514';
  end if;
  return old;
end
$$;

create trigger shop_members_20_protect_owner before delete on public.shop_members
  for each row execute function public.shop_members_protect_owner();

create trigger shop_members_30_prevent_shop_change before update on public.shop_members
  for each row execute function public.prevent_shop_change();
create trigger shop_members_90_set_updated_at before update on public.shop_members
  for each row execute function public.set_updated_at();

-- End of statement: a surviving shop must have exactly one owner.
create function public.shop_members_owner_invariant() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop uuid := old.shop_id;
begin
  if exists (select 1 from public.shops s where s.id = v_shop)
     and (select count(*) from public.shop_members m where m.shop_id = v_shop and m.role = 'owner') <> 1 then
    raise exception 'a shop must have exactly one owner' using errcode = '23514';
  end if;
  return null;
end
$$;

create constraint trigger shop_members_owner_invariant
  after update or delete on public.shop_members
  deferrable initially immediate
  for each row execute function public.shop_members_owner_invariant();

-- At commit: every new shop has its owner membership (create_shop inserts
-- the shop, then the owner, in one transaction).
create function public.shops_require_owner() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = new.id)
     and not exists (select 1 from public.shop_members m where m.shop_id = new.id and m.role = 'owner') then
    raise exception 'shop % was created without an owner', new.id using errcode = '23514';
  end if;
  return null;
end
$$;

create constraint trigger shops_require_owner
  after insert on public.shops
  deferrable initially deferred
  for each row execute function public.shops_require_owner();

-- ---------------------------------------------------------------------------
-- shop_invites
-- ---------------------------------------------------------------------------
create table public.shop_invites (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  email        extensions.citext not null check (public.is_valid_email(email::text)),
  role         public.shop_role not null check (role <> 'owner'),
  token        uuid not null default gen_random_uuid() unique,
  invited_by   uuid references auth.users (id) on delete set null,
  expires_at   timestamptz not null default (now() + interval '7 days'),
  accepted_at  timestamptz,
  accepted_by  uuid references auth.users (id) on delete set null,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now(),
  constraint shop_invites_shop_id_id_key unique (shop_id, id),
  constraint shop_invites_not_both check (accepted_at is null or revoked_at is null)
);
-- one pending invite per email per shop
create unique index shop_invites_pending_email_key on public.shop_invites (shop_id, lower(email::text))
  where accepted_at is null and revoked_at is null;
create index shop_invites_invited_by_idx on public.shop_invites (invited_by);
create index shop_invites_accepted_by_idx on public.shop_invites (accepted_by);

-- An invite carries its inviter's authority: once the inviter stops being an
-- active owner/admin of the shop (deactivated, removed, demoted, or their
-- account deleted) their pending invites are revoked, so a departing admin
-- cannot leave themselves a way back in (accept_invite re-checks the inviter
-- too, which also covers invites whose inviter account no longer exists).
create function public.shop_members_revoke_inviter_invites() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not (old.active and old.role in ('owner', 'admin')) then
    return null;
  end if;
  if tg_op = 'UPDATE' and new.active and new.role in ('owner', 'admin') then
    return null;
  end if;
  -- the whole shop is being deleted: its invites go with it
  if not exists (select 1 from public.shops s where s.id = old.shop_id) then
    return null;
  end if;
  update public.shop_invites i
     set revoked_at = now()
   where i.shop_id = old.shop_id and i.invited_by = old.user_id
     and i.accepted_at is null and i.revoked_at is null;
  return null;
end
$$;

create trigger shop_members_40_revoke_inviter_invites
  after update of role, active or delete on public.shop_members
  for each row execute function public.shop_members_revoke_inviter_invites();

-- ---------------------------------------------------------------------------
-- member_compensation
-- ---------------------------------------------------------------------------
create table public.member_compensation (
  shop_id            uuid not null references public.shops (id) on delete cascade,
  member_id          uuid primary key,
  hourly_rate_cents  bigint not null default 0 check (hourly_rate_cents >= 0),
  commission_bps     integer not null default 0 check (commission_bps between 0 and 10000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint member_compensation_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id) on delete cascade
);
create index member_compensation_shop_member_idx on public.member_compensation (shop_id, member_id);

create trigger member_compensation_10_prevent_shop_change before update on public.member_compensation
  for each row execute function public.prevent_shop_change();
create trigger member_compensation_90_set_updated_at before update on public.member_compensation
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- shop_stripe_accounts — written only by service_role (stripe-connect fn).
-- ---------------------------------------------------------------------------
create table public.shop_stripe_accounts (
  shop_id            uuid primary key references public.shops (id) on delete cascade,
  stripe_account_id  text not null unique check (stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  charges_enabled    boolean not null default false,
  payouts_enabled    boolean not null default false,
  details_submitted  boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create trigger shop_stripe_accounts_90_set_updated_at before update on public.shop_stripe_accounts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- shop_counters + next_document_number
-- ---------------------------------------------------------------------------
create table public.shop_counters (
  shop_id     uuid not null references public.shops (id) on delete cascade,
  kind        public.document_kind not null,
  next_value  bigint not null default 1001 check (next_value >= 1),
  primary key (shop_id, kind)
);

-- Concurrency safe: the upsert takes the row lock, so concurrent callers
-- serialize and never receive the same number. First number is 1001.
create function public.next_document_number(p_shop_id uuid, p_kind public.document_kind) returns bigint
language sql volatile security definer
set search_path = ''
as $$
  insert into public.shop_counters as c (shop_id, kind, next_value)
  values (p_shop_id, p_kind, 1002)
  on conflict (shop_id, kind) do update set next_value = c.next_value + 1
  returning c.next_value - 1
$$;

-- Seed this range's per-shop defaults.
create function public.shops_seed_tenancy() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.shop_counters (shop_id, kind)
  select new.id, k from unnest(enum_range(null::public.document_kind)) as k
  on conflict do nothing;
  return null;
end
$$;

create trigger shops_seed_tenancy after insert on public.shops
  for each row execute function public.shops_seed_tenancy();

-- ---------------------------------------------------------------------------
-- RPC: create_shop
-- ---------------------------------------------------------------------------
create function public.create_shop(
  p_name           text,
  p_slug           text,
  p_timezone       text,
  p_business_type  public.business_type default 'fixed',
  p_email          text default null,
  p_phone          text default null,
  p_currency       text default 'usd',
  p_country        text default 'US'
) returns public.shops
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_user  auth.users;
  v_shop  public.shops;
  v_name  text := btrim(p_name);
  v_slug  text := lower(btrim(p_slug));
  v_display text;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select * into v_user from auth.users u where u.id = v_uid and u.deleted_at is null;
  if not found or v_user.is_anonymous then
    raise exception 'a registered account is required to create a shop' using errcode = '42501';
  end if;
  if v_name is null or v_name = '' or char_length(v_name) > 120 then
    raise exception 'shop name is required (max 120 characters)' using errcode = '22023';
  end if;
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' then
    raise exception 'slug must be 3-50 lowercase letters, digits or hyphens and cannot start or end with a hyphen'
      using errcode = '22023';
  end if;
  if public.is_reserved_slug(v_slug) then
    raise exception 'slug "%" is reserved', v_slug using errcode = '22023';
  end if;
  if not public.is_valid_timezone(p_timezone) then
    raise exception 'invalid time zone "%"', p_timezone using errcode = '22023';
  end if;
  if p_email is not null and not public.is_valid_email(btrim(p_email)) then
    raise exception 'invalid email' using errcode = '22023';
  end if;
  if p_phone is not null and not public.is_valid_e164(btrim(p_phone)) then
    raise exception 'phone must be in E.164 format, e.g. +12055550100' using errcode = '22023';
  end if;
  if exists (select 1 from public.shops s where s.slug = v_slug) then
    raise exception 'slug "%" is already taken', v_slug using errcode = '23505';
  end if;

  insert into public.shops (name, slug, timezone, business_type, email, phone, currency, country, created_by)
  values (v_name, v_slug, p_timezone, coalesce(p_business_type, 'fixed'),
          nullif(btrim(p_email), '')::extensions.citext, nullif(btrim(p_phone), ''),
          lower(coalesce(p_currency, 'usd')), upper(coalesce(p_country, 'US')), v_uid)
  returning * into v_shop;

  select coalesce(p.full_name, split_part(v_user.email, '@', 1), 'Owner')
    into v_display
    from public.profiles p where p.id = v_uid;

  insert into public.shop_members (shop_id, user_id, role, display_name)
  values (v_shop.id, v_uid, 'owner',
          left(coalesce(nullif(btrim(v_display), ''), split_part(v_user.email, '@', 1), 'Owner'), 100));

  return v_shop;
end
$$;

comment on function public.create_shop(text, text, text, public.business_type, text, text, text, text) is
  'Any registered user creates a shop and becomes its owner. Domain defaults are seeded by AFTER INSERT triggers on shops.';

-- ---------------------------------------------------------------------------
-- RPCs: invites
-- ---------------------------------------------------------------------------
create function public.invite_member(p_shop_id uuid, p_email text, p_role public.shop_role)
returns public.shop_invites
language plpgsql security definer
set search_path = ''
as $$
declare
  v_email  text := lower(btrim(p_email));
  v_invite public.shop_invites;
begin
  if not public.is_shop_admin(p_shop_id) then
    raise exception 'only owners and admins can invite team members' using errcode = '42501';
  end if;
  if p_role is null or p_role = 'owner' then
    raise exception 'invites cannot grant the owner role; use transfer_ownership' using errcode = '22023';
  end if;
  if v_email is null or not public.is_valid_email(v_email) then
    raise exception 'invalid email' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.shop_members m
    join auth.users u on u.id = m.user_id
    where m.shop_id = p_shop_id and m.active and lower(u.email) = v_email) then
    raise exception '% is already a member of this shop', v_email using errcode = '23505';
  end if;

  update public.shop_invites i
     set revoked_at = now()
   where i.shop_id = p_shop_id and lower(i.email::text) = v_email
     and i.accepted_at is null and i.revoked_at is null;

  insert into public.shop_invites (shop_id, email, role, invited_by)
  values (p_shop_id, v_email::extensions.citext, p_role, auth.uid())
  returning * into v_invite;
  return v_invite;
end
$$;

create function public.revoke_invite(p_invite_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_invite public.shop_invites;
begin
  select * into v_invite from public.shop_invites i where i.id = p_invite_id for update;
  if not found or not public.is_shop_admin(v_invite.shop_id) then
    raise exception 'invite not found' using errcode = 'P0002';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'invite was already accepted' using errcode = '22023';
  end if;
  if v_invite.revoked_at is null then
    update public.shop_invites set revoked_at = now() where id = p_invite_id;
  end if;
end
$$;

-- Invite landing page data (token holders only; anon or authenticated).
create function public.public_get_invite(p_token uuid)
returns table (shop_name text, shop_slug text, role public.shop_role, email text,
               expires_at timestamptz, status text)
language sql stable security definer
set search_path = ''
as $$
  select s.name, s.slug, i.role, i.email::text, i.expires_at,
         case
           when i.accepted_at is not null then 'accepted'
           when i.revoked_at is not null then 'revoked'
           -- accept_invite refuses invites whose inviter lost owner/admin rights
           when not exists (
             select 1 from public.shop_members m
             where m.shop_id = i.shop_id and m.user_id = i.invited_by
               and m.active and m.role in ('owner', 'admin')) then 'revoked'
           when i.expires_at <= now() then 'expired'
           else 'pending'
         end
  from public.shop_invites i
  join public.shops s on s.id = i.shop_id
  where i.token = p_token
$$;

create function public.accept_invite(p_token uuid) returns public.shop_members
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_user    auth.users;
  v_invite  public.shop_invites;
  v_member  public.shop_members;
  v_existing boolean;
  v_display text;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select * into v_user from auth.users u where u.id = v_uid and u.deleted_at is null;
  if not found or v_user.is_anonymous then
    raise exception 'a registered account is required' using errcode = '42501';
  end if;
  if v_user.email is null or v_user.email_confirmed_at is null then
    raise exception 'confirm your email address before accepting an invite' using errcode = '42501';
  end if;

  select * into v_invite from public.shop_invites i where i.token = p_token for update;
  if not found then
    raise exception 'invite not found' using errcode = 'P0002';
  end if;
  if v_invite.revoked_at is not null then
    raise exception 'this invite was revoked' using errcode = '22023';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'this invite was already used' using errcode = '22023';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'this invite has expired' using errcode = '22023';
  end if;
  if lower(v_invite.email::text) <> lower(v_user.email) then
    raise exception 'this invite was sent to a different email address' using errcode = '42501';
  end if;
  -- The inviter must still be an active owner/admin of the shop (SPEC §3:
  -- team membership is owner/admin-controlled; removing or demoting an admin
  -- ends the authority behind the invites they sent). FOR SHARE: a
  -- concurrent deactivation/demotion either commits first (the row no longer
  -- qualifies) or waits until this acceptance is done.
  perform 1 from public.shop_members m
   where m.shop_id = v_invite.shop_id and m.user_id = v_invite.invited_by
     and m.active and m.role in ('owner', 'admin')
   for share;
  if not found then
    raise exception 'this invite was revoked: the person who sent it can no longer invite team members'
      using errcode = '22023';
  end if;

  select * into v_member from public.shop_members m
   where m.shop_id = v_invite.shop_id and m.user_id = v_uid for update;
  v_existing := found;
  if v_existing and v_member.active then
    raise exception 'you are already a member of this shop' using errcode = '23505';
  end if;

  select coalesce(nullif(btrim(p.full_name), ''), split_part(v_user.email, '@', 1))
    into v_display from public.profiles p where p.id = v_uid;
  v_display := left(coalesce(v_display, split_part(v_user.email, '@', 1)), 100);

  if v_existing then
    update public.shop_members m
       set role = v_invite.role, active = true
     where m.id = v_member.id
    returning * into v_member;
  else
    insert into public.shop_members (shop_id, user_id, role, display_name)
    values (v_invite.shop_id, v_uid, v_invite.role, v_display)
    returning * into v_member;
  end if;

  update public.shop_invites
     set accepted_at = now(), accepted_by = v_uid
   where id = v_invite.id;
  return v_member;
end
$$;

-- Leaving deactivates the membership (history such as time entries and
-- assignments keeps pointing at it). The owner must transfer first.
create function public.leave_shop(p_shop_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member public.shop_members;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active for update;
  if not found then
    raise exception 'you are not a member of this shop' using errcode = 'P0002';
  end if;
  if v_member.role = 'owner' then
    raise exception 'the owner cannot leave; transfer ownership first' using errcode = '23514';
  end if;
  update public.shop_members set active = false where id = v_member.id;
end
$$;

-- Owner only. Target becomes owner, caller becomes admin — one statement so
-- the one-owner constraints are checked on the final state.
create function public.transfer_ownership(p_shop_id uuid, p_member_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_me     public.shop_members;
  v_target public.shop_members;
begin
  select * into v_me from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active and m.role = 'owner' for update;
  if not found then
    raise exception 'only the owner can transfer ownership' using errcode = '42501';
  end if;
  select * into v_target from public.shop_members m
   where m.id = p_member_id and m.shop_id = p_shop_id for update;
  if not found then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_target.id = v_me.id then
    raise exception 'you already own this shop' using errcode = '22023';
  end if;
  if not v_target.active then
    raise exception 'ownership can only be transferred to an active member' using errcode = '22023';
  end if;
  update public.shop_members m
     set role = case when m.id = v_target.id then 'owner'::public.shop_role else 'admin'::public.shop_role end
   where m.id in (v_me.id, v_target.id);
end
$$;

-- Team directory for any active member. Technicians get names/colors only
-- (SPEC §3); contact details are returned to managers and above.
create function public.shop_team(p_shop_id uuid)
returns table (member_id uuid, user_id uuid, role public.shop_role, display_name text,
               calendar_color text, active boolean, phone text, email text)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.shop_role := public.shop_role_of(p_shop_id);
begin
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  return query
    select m.id, m.user_id, m.role, m.display_name, m.calendar_color, m.active,
           case when v_role <> 'technician' then m.phone end,
           case when v_role <> 'technician' then u.email::text end
    from public.shop_members m
    join auth.users u on u.id = m.user_id
    where m.shop_id = p_shop_id
      and (m.active or v_role <> 'technician')
    order by m.active desc, m.display_name;
end
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.shops                enable row level security;
alter table public.shop_members         enable row level security;
alter table public.shop_invites         enable row level security;
alter table public.member_compensation  enable row level security;
alter table public.shop_stripe_accounts enable row level security;
alter table public.shop_counters        enable row level security;

-- profiles: own row; managers+ read co-members' profiles.
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.manages_user(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- shops: members read; owner/admin update; owner deletes. Inserts via create_shop.
create policy shops_select on public.shops for select to authenticated
  using (public.is_shop_member(id));
create policy shops_update on public.shops for update to authenticated
  using (public.is_shop_admin(id)) with check (public.is_shop_admin(id));
create policy shops_delete on public.shops for delete to authenticated
  using (public.has_shop_role(id, 'owner'));

-- shop_members: managers+ read the roster, everyone reads their own row
-- (technicians use shop_team() for names/colors). Inserts only via RPCs.
create policy shop_members_select on public.shop_members for select to authenticated
  using (user_id = auth.uid() or public.is_shop_manager(shop_id));
create policy shop_members_update_admin on public.shop_members for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy shop_members_update_self on public.shop_members for update to authenticated
  using (user_id = auth.uid() and active) with check (user_id = auth.uid());
create policy shop_members_delete on public.shop_members for delete to authenticated
  using (public.is_shop_admin(shop_id));

-- shop_invites: owner/admin read; writes only via RPCs.
create policy shop_invites_select on public.shop_invites for select to authenticated
  using (public.is_shop_admin(shop_id));

-- member_compensation: owner/admin manage; members read their own row.
create policy member_compensation_select on public.member_compensation for select to authenticated
  using (public.is_shop_admin(shop_id) or public.is_own_member(member_id));
create policy member_compensation_insert on public.member_compensation for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy member_compensation_update on public.member_compensation for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy member_compensation_delete on public.member_compensation for delete to authenticated
  using (public.is_shop_admin(shop_id));

-- shop_stripe_accounts: owner/admin read; service_role writes.
create policy shop_stripe_accounts_select on public.shop_stripe_accounts for select to authenticated
  using (public.is_shop_admin(shop_id));

-- shop_counters: no client access at all (numbers come from triggers/RPCs).

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.profiles, public.shops, public.shop_members, public.shop_invites,
              public.member_compensation, public.shop_stripe_accounts, public.shop_counters
  from anon;
revoke insert, update, delete, truncate on public.shop_stripe_accounts from authenticated;
revoke all on public.shop_counters from authenticated;
revoke insert, delete, truncate on public.profiles from authenticated;
revoke insert, truncate on public.shops, public.shop_members, public.shop_invites from authenticated;
revoke update, delete on public.shop_invites from authenticated;

revoke execute on function
  public.handle_new_auth_user(),
  public.shops_before_write(),
  public.shop_members_client_guard(),
  public.shop_members_protect_owner(),
  public.shop_members_owner_invariant(),
  public.shop_members_revoke_inviter_invites(),
  public.shops_require_owner(),
  public.shops_seed_tenancy(),
  public.next_document_number(uuid, public.document_kind)
from public, anon, authenticated;
grant execute on function public.next_document_number(uuid, public.document_kind) to service_role;

-- helpers used by RLS policies / staff UI
revoke execute on function
  public.shop_role_of(uuid),
  public.is_shop_member(uuid),
  public.has_shop_role(uuid, public.shop_role[]),
  public.is_shop_admin(uuid),
  public.is_shop_manager(uuid),
  public.is_own_member(uuid),
  public.manages_user(uuid),
  public.create_shop(text, text, text, public.business_type, text, text, text, text),
  public.invite_member(uuid, text, public.shop_role),
  public.revoke_invite(uuid),
  public.accept_invite(uuid),
  public.leave_shop(uuid),
  public.transfer_ownership(uuid, uuid),
  public.shop_team(uuid)
from public, anon;
grant execute on function
  public.shop_role_of(uuid),
  public.is_shop_member(uuid),
  public.has_shop_role(uuid, public.shop_role[]),
  public.is_shop_admin(uuid),
  public.is_shop_manager(uuid),
  public.is_own_member(uuid),
  public.manages_user(uuid),
  public.create_shop(text, text, text, public.business_type, text, text, text, text),
  public.invite_member(uuid, text, public.shop_role),
  public.revoke_invite(uuid),
  public.accept_invite(uuid),
  public.leave_shop(uuid),
  public.transfer_ownership(uuid, uuid),
  public.shop_team(uuid)
to authenticated, service_role;

revoke execute on function public.public_get_invite(uuid) from public;
grant execute on function public.public_get_invite(uuid) to anon, authenticated, service_role;
