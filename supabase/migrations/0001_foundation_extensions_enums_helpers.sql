-- ============================================================================
-- 0001 — Foundation: extensions, foundation enums, pure helper functions and
-- the canonical document-totals calculation (SPEC §4.5).
--
-- Conventions used by every foundation migration:
--   * Tenant tables carry shop_id, UNIQUE (shop_id, id) and composite FKs
--     (shop_id, parent_id) -> parent (shop_id, id) so rows can never point
--     at another shop's data.
--   * SECURITY DEFINER functions: set search_path = '' and schema-qualify.
--   * "Client context" = current_user is anon/authenticated, i.e. a direct
--     PostgREST write. SECURITY DEFINER RPCs run as the function owner, so
--     guard triggers (SECURITY INVOKER) let validated RPC writes through.
-- ============================================================================

create schema if not exists extensions;
create extension if not exists citext     with schema extensions;
create extension if not exists pg_trgm    with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto   with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums (foundation range only; money/ops/comms enums live in their ranges)
-- ---------------------------------------------------------------------------
create type public.shop_role          as enum ('owner', 'admin', 'manager', 'technician');
create type public.business_type      as enum ('fixed', 'mobile', 'both');
create type public.resource_kind      as enum ('bay', 'van', 'other');
create type public.deposit_type       as enum ('percent', 'fixed');
create type public.customer_lifecycle as enum ('lead', 'customer');
create type public.customer_source    as enum ('staff', 'online_booking', 'referral', 'google',
                                               'facebook', 'instagram', 'walk_in', 'other');
create type public.service_kind       as enum ('service', 'package', 'addon', 'product');
create type public.coupon_kind        as enum ('percent', 'fixed');
create type public.job_status         as enum ('requested', 'scheduled', 'confirmed', 'en_route',
                                               'in_progress', 'completed', 'cancelled', 'no_show');
create type public.location_type      as enum ('shop', 'mobile');
create type public.job_source         as enum ('staff', 'online_booking', 'quote', 'membership');
create type public.discount_kind      as enum ('none', 'percent', 'fixed');
create type public.document_kind      as enum ('job', 'quote', 'invoice');

-- Result of public.compute_document_totals (shared by jobs, quotes, invoices).
create type public.document_totals as (
  subtotal_cents          bigint,
  discount_cents          bigint,
  taxable_subtotal_cents  bigint,
  taxable_discount_cents  bigint,
  tax_cents               bigint,
  total_cents             bigint
);

-- ---------------------------------------------------------------------------
-- Generic trigger functions
-- ---------------------------------------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- Audit references to auth.users (created_by, recorded_by, uploaded_by, ...)
-- are write-once: BEFORE UPDATE triggers pin them with
--   new.col := public.audit_user_ref(new.col, old.col);
-- The one legitimate change is the column's own ON DELETE SET NULL when the
-- account is deleted (Supabase auth.admin.deleteUser, an erasure request):
-- the referential action runs an UPDATE through those same triggers, and
-- pinning the old id there made the re-checked FK fail (23503) and rolled
-- the whole account deletion back. So the value may become NULL, and only
-- once the referenced account no longer exists; any other change keeps the
-- old value. SECURITY DEFINER to read auth.users; it answers only inside a
-- trigger (pg_trigger_depth() > 0), where its arguments are a row's own
-- values, so calling it directly reveals nothing about which accounts exist.
create function public.audit_user_ref(p_new uuid, p_old uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
  select case
           when p_new is null and p_old is not null
                and pg_catalog.pg_trigger_depth() > 0
                and not exists (select 1 from auth.users u where u.id = p_old)
             then null
           else p_old
         end
$$;

comment on function public.audit_user_ref(uuid, uuid) is
  'Pinned value of a write-once auth.users audit column on UPDATE: the old value, or NULL when the change is the ON DELETE SET NULL of a deleted account.';

-- created_by is always the acting user when there is one; never editable
-- (except the ON DELETE SET NULL of a deleted account: audit_user_ref).
create function public.set_created_by() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    new.created_by := public.audit_user_ref(new.created_by, old.created_by);
  end if;
  return new;
end
$$;

-- Rows never move between shops.
create function public.prevent_shop_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.shop_id is distinct from old.shop_id then
    raise exception '%.shop_id cannot be changed', tg_table_name using errcode = '42501';
  end if;
  return new;
end
$$;

-- True for direct PostgREST writes (anon/authenticated). Must stay SECURITY
-- INVOKER: inside SECURITY DEFINER code current_user is the function owner.
create function public.is_client_context() returns boolean
language sql stable
set search_path = ''
as $$ select current_user in ('anon', 'authenticated') $$;

-- The request clock. Time-dependent RPCs take an optional p_now so tests and
-- trusted callers (service_role: edge functions, cron; direct database
-- sessions) can run them at a fixed instant. Requests made as
-- anon/authenticated (PostgREST) ALWAYS use the server clock: a
-- caller-supplied time could otherwise list past availability (and so map a
-- shop's schedule), book in the past, redeem an expired coupon or cancel
-- after the cancellation deadline. The PostgREST role is read from the
-- `role` setting (SET ROLE, unchanged inside SECURITY DEFINER functions) and,
-- as a second signal, the JWT role claim. Used from 0007 (slots) onward.
create function public.is_api_request() returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(current_setting('role', true), 'none') in ('anon', 'authenticated')
      or coalesce(auth.role(), '') in ('anon', 'authenticated')
$$;

comment on function public.is_api_request() is
  'True when the current request runs as the PostgREST anon/authenticated role (even inside SECURITY DEFINER code).';

create function public.effective_now(p_now timestamptz) returns timestamptz
language sql stable
set search_path = ''
as $$
  select case when public.is_api_request() or p_now is null then now() else p_now end
$$;

comment on function public.effective_now(timestamptz) is
  'p_now for trusted callers (service_role / direct sessions); the server clock for API (anon/authenticated) requests.';

-- ---------------------------------------------------------------------------
-- Pure validators (IMMUTABLE so they can back CHECK constraints)
-- ---------------------------------------------------------------------------
create function public.is_valid_e164(p text) returns boolean
language sql immutable
set search_path = ''
as $$ select p ~ '^\+[1-9][0-9]{6,14}$' $$;

create function public.is_valid_email(p text) returns boolean
language sql immutable
set search_path = ''
as $$ select char_length(p) <= 254 and p ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' $$;

create function public.is_valid_hex_color(p text) returns boolean
language sql immutable
set search_path = ''
as $$ select p ~ '^#[0-9A-Fa-f]{6}$' $$;

create function public.is_reserved_slug(p text) returns boolean
language sql immutable
set search_path = ''
as $$
  select lower(p) = any (array['app', 'api', 'admin', 'book', 'booking', 'login', 'signup', 'portal',
                               'invite', 'www', 'support', 'help', 'static', 'assets', 'q', 'i', 'f'])
$$;

-- 3-50 chars of lowercase letters, digits and hyphens; no leading/trailing
-- hyphen; not reserved.
create function public.is_valid_slug(p text) returns boolean
language sql immutable
set search_path = ''
as $$ select p ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' and not public.is_reserved_slug(p) $$;

create function public.is_valid_timezone(p text) returns boolean
language sql stable
set search_path = ''
as $$ select p is not null and exists (select 1 from pg_catalog.pg_timezone_names where name = p) $$;

-- ---------------------------------------------------------------------------
-- Shop assets (SPEC §4.6): shops.logo_path and services.image_path name an
-- object in the public `shop-assets` bucket, stored WITHOUT the bucket. The
-- first folder of every object name is the owning shop's id, so a row may
-- only name an object under its OWN shop's folder — the storage version of
-- the composite-FK rule (a shop must never display another tenant's file,
-- nor keep it "in use" for the purge queue, 0025).
-- ---------------------------------------------------------------------------

-- "<shop_id>/<file...>" for exactly this shop: the folder is the canonical
-- (lower-case uuid::text) form the storage policies and the purge queue
-- match (0020, 0025), followed by a file name; and the name obeys the same
-- rules as public.is_safe_storage_path (0020): 1-1024 chars, no leading or
-- trailing slash, no empty, "." or ".." segments, no backslashes or control
-- characters. Pure, so it backs CHECK constraints.
create function public.is_shop_asset_path(p_shop_id uuid, p_path text) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_shop_id is not null
     and p_path is not null
     and char_length(p_path) between 1 and 1024
     and p_path !~ '^/'
     and p_path !~ '/$'
     and p_path !~ '//'
     and p_path !~ '(^|/)\.{1,2}(/|$)'
     and p_path !~ '[\\[:cntrl:]]'
     and pg_catalog.starts_with(p_path, p_shop_id::text || '/')
$$;

-- AFTER INSERT OR UPDATE trigger: the object named by column TG_ARGV[0] must
-- already exist in the shop-assets bucket when the path is set or changed
-- (upload first, then save the path — like job photos, 0022). The table's
-- CHECK (is_shop_asset_path) has already pinned the path to the row's own
-- shop, so this reveals nothing about other shops' files. SECURITY DEFINER:
-- storage.objects sits behind storage RLS.
create function public.require_shop_asset_object() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_path text := pg_catalog.to_jsonb(new) ->> tg_argv[0];
begin
  if v_path is not null
     and (tg_op = 'INSERT' or v_path is distinct from (pg_catalog.to_jsonb(old) ->> tg_argv[0]))
     and not exists (select 1 from storage.objects o where o.bucket_id = 'shop-assets' and o.name = v_path) then
    raise exception 'upload the image to shop-assets before saving its path' using errcode = '23514';
  end if;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- Canonical totals (SPEC §4.5) — the ONLY implementation of document math.
-- ---------------------------------------------------------------------------

-- line_total = greatest(0, round(quantity * unit_price) - line discount).
-- numeric round() is half away from zero.
create function public.line_total_cents(p_quantity numeric, p_unit_price_cents bigint, p_discount_cents bigint)
returns bigint
language sql immutable
set search_path = ''
as $$
  select greatest(0::bigint,
                  round(p_quantity * p_unit_price_cents)::bigint - coalesce(p_discount_cents, 0))
$$;

-- p_lines: jsonb array of {quantity, unit_price_cents, discount_cents?, taxable?}.
-- Callers pass exactly the lines that count (e.g. quotes pass only
-- non-optional or selected-optional lines).
--   subtotal         = Σ line_total
--   discount         = least(percent: round(subtotal × bps / 10000) | fixed: value, subtotal)
--   taxable_subtotal = Σ taxable line_total
--   taxable_discount = subtotal > 0 ? round(discount × taxable_subtotal / subtotal) : 0
--   tax              = round((taxable_subtotal − taxable_discount) × tax_rate_bps / 10000)
--   total            = subtotal − discount + tax
create function public.compute_document_totals(
  p_lines          jsonb,
  p_discount_kind  public.discount_kind default 'none',
  p_discount_value bigint default 0,
  p_tax_rate_bps   integer default 0
) returns public.document_totals
language plpgsql immutable
set search_path = ''
as $$
declare
  v_line        jsonb;
  v_qty         numeric;
  v_price       bigint;
  v_line_disc   bigint;
  v_taxable     boolean;
  v_line_total  bigint;
  r             public.document_totals;
begin
  if p_lines is null then
    p_lines := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;
  if p_tax_rate_bps is null or p_tax_rate_bps < 0 or p_tax_rate_bps > 10000 then
    raise exception 'tax_rate_bps must be between 0 and 10000' using errcode = '22023';
  end if;
  p_discount_kind := coalesce(p_discount_kind, 'none');
  p_discount_value := coalesce(p_discount_value, 0);
  if p_discount_value < 0 then
    raise exception 'discount value cannot be negative' using errcode = '22023';
  end if;
  if p_discount_kind = 'percent' and p_discount_value > 10000 then
    raise exception 'percent discount cannot exceed 10000 bps' using errcode = '22023';
  end if;

  r.subtotal_cents := 0;
  r.taxable_subtotal_cents := 0;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'each line must be a JSON object' using errcode = '22023';
    end if;
    v_qty       := coalesce((v_line ->> 'quantity')::numeric, 1);
    v_price     := (v_line ->> 'unit_price_cents')::bigint;
    v_line_disc := coalesce((v_line ->> 'discount_cents')::bigint, 0);
    v_taxable   := coalesce((v_line ->> 'taxable')::boolean, true);
    if v_price is null or v_price < 0 then
      raise exception 'unit_price_cents must be a non-negative integer' using errcode = '22023';
    end if;
    if v_qty <= 0 then
      raise exception 'quantity must be positive' using errcode = '22023';
    end if;
    if v_line_disc < 0 then
      raise exception 'line discount cannot be negative' using errcode = '22023';
    end if;
    v_line_total := public.line_total_cents(v_qty, v_price, v_line_disc);
    r.subtotal_cents := r.subtotal_cents + v_line_total;
    if v_taxable then
      r.taxable_subtotal_cents := r.taxable_subtotal_cents + v_line_total;
    end if;
  end loop;

  r.discount_cents := case p_discount_kind
    when 'percent' then round(r.subtotal_cents::numeric * p_discount_value / 10000)::bigint
    when 'fixed'   then p_discount_value
    else 0
  end;
  r.discount_cents := least(r.discount_cents, r.subtotal_cents);

  r.taxable_discount_cents := case
    when r.subtotal_cents > 0
      then round(r.discount_cents::numeric * r.taxable_subtotal_cents / r.subtotal_cents)::bigint
    else 0
  end;

  r.tax_cents := round((r.taxable_subtotal_cents - r.taxable_discount_cents)::numeric
                       * p_tax_rate_bps / 10000)::bigint;
  r.total_cents := r.subtotal_cents - r.discount_cents + r.tax_cents;
  return r;
end
$$;

comment on function public.compute_document_totals(jsonb, public.discount_kind, bigint, integer) is
  'Canonical SPEC §4.5 totals. Pure; reused by jobs, quotes and invoices.';

-- Trigger functions are never called directly.
revoke execute on function public.set_updated_at(), public.set_created_by(), public.prevent_shop_change(),
                            public.require_shop_asset_object()
  from public, anon, authenticated;

-- Called from invoker triggers during direct (authenticated / service_role)
-- writes; anon never writes tables directly.
revoke execute on function public.audit_user_ref(uuid, uuid) from public, anon;
grant execute on function public.audit_user_ref(uuid, uuid) to authenticated, service_role;

-- The request clock is internal: called only from SECURITY DEFINER RPCs.
revoke execute on function public.is_api_request(), public.effective_now(timestamptz)
  from public, anon, authenticated;
grant execute on function public.is_api_request(), public.effective_now(timestamptz) to service_role;
