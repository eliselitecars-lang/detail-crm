-- ============================================================================
-- 0010 — Money (SPEC §4.5): money enums, quotes, quote_line_items, the quote
-- status machine, jobs.quote_id FK, and the staff/cron quote RPCs
-- (mark_quote_sent, convert_quote_to_job, expire_quotes).
--
-- Quote status machine (all contexts):
--   draft    -> sent                       (mark_quote_sent)
--   sent     -> viewed                     (public_get_quote, first open by a non-member)
--   sent|viewed -> approved | declined     (public_respond_quote, or staff recording it)
--   sent|viewed -> expired                 (expire_quotes cron, or lazily on public access)
--   approved -> converted                  (convert_quote_to_job)
--   sent|viewed|approved|declined|expired -> draft   (staff "revise"; clears stamps)
-- Direct staff updates may only move to draft / approved / declined; every
-- other transition belongs to an RPC. Stamps (sent_at … converted_at) are
-- server-set. Content (customer, vehicle, validity, notes, terms, pricing,
-- lines) is editable while draft / sent / viewed; otherwise revise to draft.
--
-- Changing the customer (all contexts) issues a new public_token, so the /q
-- link already delivered to the previous customer stops resolving, and a
-- sent / viewed quote returns to draft: it has not been sent to the new
-- customer yet (mark_quote_sent again).
--
-- A job's quote (jobs.quote_id) is always a quote of the job's customer
-- (jobs_quote_validate / quotes_validate): the job's messages link to it.
--
-- valid_until is a DATE: the quote is valid through the end of that day in
-- the shop's time zone (public.quote_validity_end).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Enums for the whole money range
-- ---------------------------------------------------------------------------
create type public.quote_status        as enum ('draft', 'sent', 'viewed', 'approved', 'declined', 'expired', 'converted');
create type public.invoice_status      as enum ('draft', 'open', 'partially_paid', 'paid', 'void');
create type public.payment_kind        as enum ('deposit', 'payment', 'membership');
create type public.payment_method      as enum ('card', 'card_present', 'cash', 'check', 'bank_transfer', 'other');
create type public.payment_status      as enum ('pending', 'succeeded', 'failed', 'cancelled', 'refunded', 'partially_refunded');
create type public.membership_status   as enum ('incomplete', 'active', 'past_due', 'cancelled');
create type public.membership_interval as enum ('month', 'year');

-- First instant after the validity date (start of the next local day).
create function public.quote_validity_end(p_valid_until date, p_timezone text) returns timestamptz
language sql stable
set search_path = ''
as $$ select ((p_valid_until + 1)::timestamp at time zone p_timezone) $$;

-- ---------------------------------------------------------------------------
-- quotes
-- ---------------------------------------------------------------------------
create table public.quotes (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  number            bigint not null,
  customer_id       uuid not null,
  vehicle_id        uuid,
  status            public.quote_status not null default 'draft',
  valid_until       date,
  notes             text check (notes is null or char_length(notes) <= 20000),
  terms             text check (terms is null or char_length(terms) <= 20000),
  internal_notes    text check (internal_notes is null or char_length(internal_notes) <= 20000),
  discount_kind     public.discount_kind not null default 'none',
  discount_value    bigint not null default 0,
  tax_rate_bps      integer not null check (tax_rate_bps between 0 and 10000),
  subtotal_cents    bigint not null default 0 check (subtotal_cents >= 0),
  discount_cents    bigint not null default 0 check (discount_cents >= 0),
  tax_cents         bigint not null default 0 check (tax_cents >= 0),
  total_cents       bigint not null default 0 check (total_cents >= 0),
  public_token      uuid not null default gen_random_uuid() unique,
  sent_at           timestamptz,
  viewed_at         timestamptz,
  approved_at       timestamptz,
  approved_by_name  text check (approved_by_name is null or char_length(btrim(approved_by_name)) between 1 and 200),
  declined_at       timestamptz,
  declined_reason   text check (declined_reason is null or char_length(declined_reason) <= 1000),
  expired_at        timestamptz,
  converted_at      timestamptz,
  converted_job_id  uuid,
  created_by        uuid references auth.users (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint quotes_shop_id_id_key unique (shop_id, id),
  constraint quotes_shop_number_key unique (shop_id, number),
  -- quotes are proposals, not money records: they go with their customer
  constraint quotes_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint quotes_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id),
  -- a deleted job leaves the quote "converted" (history) without a link
  constraint quotes_converted_job_fk foreign key (shop_id, converted_job_id)
    references public.jobs (shop_id, id) on delete set null (converted_job_id),
  constraint quotes_discount_value check (
    discount_value >= 0
    and (discount_kind <> 'none' or discount_value = 0)
    and (discount_kind <> 'percent' or discount_value <= 10000)),
  constraint quotes_totals_consistent check (total_cents = subtotal_cents - discount_cents + tax_cents),
  constraint quotes_converted_link check (converted_job_id is null or status = 'converted')
);
create index quotes_shop_customer_idx on public.quotes (shop_id, customer_id);
create index quotes_shop_vehicle_idx on public.quotes (shop_id, vehicle_id);
create index quotes_shop_converted_job_idx on public.quotes (shop_id, converted_job_id);
create index quotes_shop_status_idx on public.quotes (shop_id, status, created_at desc);
create index quotes_open_validity_idx on public.quotes (valid_until) where status in ('sent', 'viewed');
create index quotes_created_by_idx on public.quotes (created_by);

comment on column public.quotes.valid_until is
  'Valid through the end of this date in the shop time zone; null = no expiry.';
comment on column public.quotes.number is 'Human quote number per shop, assigned by quotes_integrity. @insert-optional';
comment on column public.quotes.tax_rate_bps is 'Defaults to the shop''s tax rate when omitted (quotes_integrity). @insert-optional';

-- jobs.quote_id (declared in 0006) now gets its composite FK.
alter table public.jobs
  add constraint jobs_quote_fk foreign key (shop_id, quote_id)
    references public.quotes (shop_id, id) on delete set null (quote_id);

-- ---------------------------------------------------------------------------
-- quote_line_items — optional lines are client-selectable upsells. Only
-- non-optional lines and selected optional lines count toward totals.
-- ---------------------------------------------------------------------------
create table public.quote_line_items (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  quote_id          uuid not null,
  service_id        uuid,
  vehicle_id        uuid,
  name              text not null check (char_length(btrim(name)) between 1 and 200),
  description       text check (description is null or char_length(description) <= 5000),
  quantity          numeric(10, 2) not null default 1 check (quantity > 0),
  unit_price_cents  bigint not null check (unit_price_cents >= 0),
  discount_cents    bigint not null default 0 check (discount_cents >= 0),
  taxable           boolean not null default true,
  duration_minutes  integer not null default 0 check (duration_minutes between 0 and 44640),
  optional          boolean not null default false,
  -- null on insert = "not optional ? true : false" (set by trigger)
  selected          boolean not null,
  sort              integer not null default 0,
  total_cents       bigint generated always as
                      (public.line_total_cents(quantity, unit_price_cents, discount_cents)) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint quote_line_items_shop_id_id_key unique (shop_id, id),
  constraint quote_line_items_quote_fk foreign key (shop_id, quote_id)
    references public.quotes (shop_id, id) on delete cascade,
  constraint quote_line_items_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete set null (service_id),
  constraint quote_line_items_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id),
  constraint quote_line_items_required_selected check (optional or selected)
);
create index quote_line_items_shop_quote_idx on public.quote_line_items (shop_id, quote_id, sort);
comment on column public.quote_line_items.selected is
  'Always true for required lines; an optional line defaults to not selected (quote_line_items_before_write). @insert-optional';
create index quote_line_items_shop_service_idx on public.quote_line_items (shop_id, service_id);
create index quote_line_items_shop_vehicle_idx on public.quote_line_items (shop_id, vehicle_id);

-- ---------------------------------------------------------------------------
-- quotes triggers
-- ---------------------------------------------------------------------------

-- 10: direct-write guard (staff via PostgREST).
create function public.quotes_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'new quotes start as drafts' using errcode = '23514';
    end if;
    new.public_token := gen_random_uuid();
    new.converted_job_id := null;
    return new;
  end if;

  if new.number <> old.number then
    raise exception 'quote numbers cannot be changed' using errcode = '42501';
  end if;
  if new.public_token <> old.public_token then
    raise exception 'quote public_token cannot be changed' using errcode = '42501';
  end if;
  new.converted_job_id := old.converted_job_id;

  if old.status not in ('draft', 'sent', 'viewed')
     and new.status is not distinct from old.status
     and (new.customer_id, new.vehicle_id, new.valid_until, new.notes, new.terms,
          new.discount_kind, new.discount_value, new.tax_rate_bps)
         is distinct from
         (old.customer_id, old.vehicle_id, old.valid_until, old.notes, old.terms,
          old.discount_kind, old.discount_value, old.tax_rate_bps) then
    raise exception 'a % quote cannot be edited; revise it back to draft first', old.status
      using errcode = '23514';
  end if;
  return new;
end
$$;

-- 20: numbering and server defaults.
create function public.quotes_integrity() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.number := public.next_document_number(new.shop_id, 'quote');
    if new.tax_rate_bps is null then
      select s.tax_rate_bps into new.tax_rate_bps from public.shops s where s.id = new.shop_id;
    end if;
    if new.terms is null then
      select s.quote_terms into new.terms from public.shops s where s.id = new.shop_id;
    end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    new.number := old.number;
    new.created_by := public.audit_user_ref(new.created_by, old.created_by);
    -- a different customer never inherits the previous customer's link
    if new.customer_id is distinct from old.customer_id then
      new.public_token := gen_random_uuid();
      if old.status in ('sent', 'viewed') then
        if new.status = old.status then
          new.status := 'draft';
        elsif new.status <> 'draft' then
          raise exception 'change the quote''s customer on its own; it returns to draft to be sent to the new customer'
            using errcode = '23514';
        end if;
      end if;
    end if;
  end if;
  return new;
end
$$;

-- 30: status machine + stamps. In client context stamps are never taken from
-- the client; in trusted context an explicitly supplied stamp is kept (e.g.
-- expire_quotes passes p_now), otherwise now() is used.
create function public.quotes_status_machine() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_client boolean := public.is_client_context();
begin
  if tg_op = 'INSERT' then
    if v_client then
      new.sent_at := null; new.viewed_at := null; new.approved_at := null; new.approved_by_name := null;
      new.declined_at := null; new.declined_reason := null; new.expired_at := null; new.converted_at := null;
    end if;
    return new;
  end if;

  if v_client then
    new.sent_at := old.sent_at;
    new.viewed_at := old.viewed_at;
    new.approved_at := old.approved_at;
    new.declined_at := old.declined_at;
    new.expired_at := old.expired_at;
    new.converted_at := old.converted_at;
    if new.status is distinct from 'approved' or old.status = 'approved' then
      new.approved_by_name := old.approved_by_name;
    end if;
    if new.status is distinct from 'declined' or old.status = 'declined' then
      new.declined_reason := old.declined_reason;
    end if;
  end if;

  if new.status = old.status then
    return new;
  end if;

  if not ((old.status = 'draft' and new.status = 'sent')
       or (old.status = 'sent' and new.status = 'viewed')
       or (old.status in ('sent', 'viewed') and new.status in ('approved', 'declined', 'expired'))
       or (old.status = 'approved' and new.status = 'converted')
       or (old.status in ('sent', 'viewed', 'approved', 'declined', 'expired') and new.status = 'draft')) then
    raise exception 'invalid quote status transition: % -> %', old.status, new.status using errcode = '23514';
  end if;

  if v_client and new.status not in ('draft', 'approved', 'declined') then
    raise exception 'quotes move to % only through the %', new.status,
      case new.status
        when 'sent' then 'mark_quote_sent RPC'
        when 'converted' then 'convert_quote_to_job RPC'
        else 'client quote page / expiry job'
      end
      using errcode = '42501';
  end if;

  case new.status
    when 'draft' then
      new.sent_at := null; new.viewed_at := null; new.approved_at := null; new.approved_by_name := null;
      new.declined_at := null; new.declined_reason := null; new.expired_at := null; new.converted_at := null;
    when 'sent' then
      if new.sent_at is not distinct from old.sent_at then new.sent_at := now(); end if;
    when 'viewed' then
      if new.viewed_at is not distinct from old.viewed_at then new.viewed_at := now(); end if;
    when 'approved' then
      if new.approved_at is not distinct from old.approved_at then new.approved_at := now(); end if;
      new.approved_by_name := nullif(btrim(new.approved_by_name), '');
    when 'declined' then
      if new.declined_at is not distinct from old.declined_at then new.declined_at := now(); end if;
      new.declined_reason := nullif(btrim(new.declined_reason), '');
    when 'expired' then
      if new.expired_at is not distinct from old.expired_at then new.expired_at := now(); end if;
    when 'converted' then
      if new.converted_at is not distinct from old.converted_at then new.converted_at := now(); end if;
  end case;
  return new;
end
$$;

-- 40: canonical totals over non-optional + selected optional lines.
create function public.quotes_compute_totals() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t public.document_totals;
begin
  v_t := public.compute_document_totals(
           (select coalesce(jsonb_agg(jsonb_build_object(
                             'quantity', li.quantity,
                             'unit_price_cents', li.unit_price_cents,
                             'discount_cents', li.discount_cents,
                             'taxable', li.taxable)), '[]'::jsonb)
              from public.quote_line_items li
             where li.quote_id = new.id and li.shop_id = new.shop_id
               and (not li.optional or li.selected)),
           new.discount_kind, new.discount_value, new.tax_rate_bps);
  new.subtotal_cents := v_t.subtotal_cents;
  new.discount_cents := v_t.discount_cents;
  new.tax_cents := v_t.tax_cents;
  new.total_cents := v_t.total_cents;
  return new;
end
$$;

-- AFTER: vehicle belongs to the quote's customer (and so do line vehicles).
create function public.quotes_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id
          or new.customer_id is distinct from old.customer_id)
     and not exists (select 1 from public.vehicles v
                     where v.id = new.vehicle_id and v.shop_id = new.shop_id
                       and v.customer_id = new.customer_id) then
    raise exception 'the vehicle does not belong to this quote''s customer' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id
     and exists (select 1 from public.quote_line_items li
                 join public.vehicles v on v.id = li.vehicle_id and v.shop_id = li.shop_id
                 where li.quote_id = new.id and li.shop_id = new.shop_id and v.customer_id <> new.customer_id) then
    raise exception 'line items reference vehicles of the previous customer; update them first'
      using errcode = '23514';
  end if;
  -- a job's quote stays a quote of the job's customer (see jobs_quote_validate)
  if tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id
     and exists (select 1 from public.jobs j
                 where j.quote_id = new.id and j.shop_id = new.shop_id and j.customer_id <> new.customer_id) then
    raise exception 'quote #% is linked to job #% of its current customer; unlink it from the job first', new.number,
      (select min(j.number) from public.jobs j
        where j.quote_id = new.id and j.shop_id = new.shop_id and j.customer_id <> new.customer_id)
      using errcode = '23514';
  end if;
  return null;
end
$$;

-- AFTER on jobs (all contexts; composite FKs have passed): a job's quote is a
-- quote of the job's customer. The job's messages render {{quote_link}} from
-- it, so a job linked to another customer's quote would send that customer's
-- /q page (name, vehicle, prices, approval) to this one. A job cannot be
-- linked to another customer's quote, and a job created from a quote cannot
-- move to another customer while it stays linked (unlink it — quote_id =
-- null — in the same write). The quote side is checked in quotes_validate.
create function public.jobs_quote_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_number    bigint;
  v_customer  uuid;
begin
  if new.quote_id is null
     or (tg_op = 'UPDATE' and new.quote_id is not distinct from old.quote_id
         and new.customer_id is not distinct from old.customer_id) then
    return null;
  end if;
  select q.number, q.customer_id into v_number, v_customer
    from public.quotes q where q.id = new.quote_id and q.shop_id = new.shop_id;
  if found and v_customer <> new.customer_id then
    if tg_op = 'UPDATE' and new.quote_id is not distinct from old.quote_id then
      raise exception 'this job is linked to quote #% of its previous customer; unlink the quote to move the job to another customer',
        v_number using errcode = '23514';
    end if;
    raise exception 'quote #% belongs to another customer', v_number using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger jobs_quote_validate after insert or update of quote_id, customer_id on public.jobs
  for each row execute function public.jobs_quote_validate();

create trigger quotes_05_prevent_shop_change before update on public.quotes
  for each row execute function public.prevent_shop_change();
create trigger quotes_10_client_guard before insert or update on public.quotes
  for each row execute function public.quotes_client_guard();
create trigger quotes_20_integrity before insert or update on public.quotes
  for each row execute function public.quotes_integrity();
create trigger quotes_30_status_machine before insert or update on public.quotes
  for each row execute function public.quotes_status_machine();
create trigger quotes_40_compute_totals before insert or update on public.quotes
  for each row execute function public.quotes_compute_totals();
create trigger quotes_90_set_updated_at before update on public.quotes
  for each row execute function public.set_updated_at();
create trigger quotes_validate after insert or update on public.quotes
  for each row execute function public.quotes_validate();

-- ---------------------------------------------------------------------------
-- quote_line_items triggers
-- ---------------------------------------------------------------------------

-- Staff may edit lines only while the quote is draft/sent/viewed; lines never
-- move between quotes. (Trusted code — public_respond_quote — is exempt.)
-- The quote row is locked before its status is read, so a line edit cannot
-- slip past a concurrent approval (public_respond_quote locks the quote too):
-- it waits and then sees the committed status.
create function public.quote_line_items_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.quote_status;
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and new.quote_id is distinct from old.quote_id then
    raise exception 'line items cannot move between quotes' using errcode = '42501';
  end if;
  select q.status into v_status
    from public.quotes q
   where q.id = case when tg_op = 'DELETE' then old.quote_id else new.quote_id end
     and q.shop_id = case when tg_op = 'DELETE' then old.shop_id else new.shop_id end
     for no key update;
  if found and v_status not in ('draft', 'sent', 'viewed') then
    raise exception 'line items of a % quote cannot be changed; revise it back to draft first', v_status
      using errcode = '23514';
  end if;
  return coalesce(new, old);
end
$$;

create function public.quote_line_items_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.name is null and new.service_id is not null then
    select s.name into new.name from public.services s where s.id = new.service_id and s.shop_id = new.shop_id;
  end if;
  if not new.optional then
    new.selected := true;
  elsif new.selected is null then
    new.selected := false;
  end if;
  return new;
end
$$;

create function public.quote_line_items_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id or new.quote_id is distinct from old.quote_id)
     and not exists (select 1
                     from public.quotes q
                     join public.vehicles v on v.customer_id = q.customer_id and v.shop_id = q.shop_id
                     where q.id = new.quote_id and q.shop_id = new.shop_id and v.id = new.vehicle_id) then
    raise exception 'the vehicle does not belong to this quote''s customer' using errcode = '23514';
  end if;
  return null;
end
$$;

create function public.quote_line_items_touch_quote() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.quotes set updated_at = now() where id = old.quote_id and shop_id = old.shop_id;
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.quote_id is distinct from old.quote_id) then
    update public.quotes set updated_at = now() where id = new.quote_id and shop_id = new.shop_id;
  end if;
  return null;
end
$$;

create trigger quote_line_items_05_prevent_shop_change before update on public.quote_line_items
  for each row execute function public.prevent_shop_change();
create trigger quote_line_items_10_client_guard before insert or update or delete on public.quote_line_items
  for each row execute function public.quote_line_items_client_guard();
create trigger quote_line_items_20_before_write before insert or update on public.quote_line_items
  for each row execute function public.quote_line_items_before_write();
create trigger quote_line_items_90_set_updated_at before update on public.quote_line_items
  for each row execute function public.set_updated_at();
create trigger quote_line_items_touch_quote after insert or update or delete on public.quote_line_items
  for each row execute function public.quote_line_items_touch_quote();
create trigger quote_line_items_validate after insert or update on public.quote_line_items
  for each row execute function public.quote_line_items_validate();

-- ---------------------------------------------------------------------------
-- RLS — quotes are owner/admin/manager only (SPEC §3: technicians have no
-- quote access). Converted quotes cannot be deleted (they document a job).
-- ---------------------------------------------------------------------------
alter table public.quotes           enable row level security;
alter table public.quote_line_items enable row level security;

create policy quotes_select on public.quotes for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy quotes_insert on public.quotes for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy quotes_update on public.quotes for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy quotes_delete on public.quotes for delete to authenticated
  using (public.is_shop_manager(shop_id) and status <> 'converted');

create policy quote_line_items_select on public.quote_line_items for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy quote_line_items_insert on public.quote_line_items for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy quote_line_items_update on public.quote_line_items for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy quote_line_items_delete on public.quote_line_items for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- ---------------------------------------------------------------------------
-- RPC: mark_quote_sent — draft -> sent (stamps sent_at); on an already
-- sent/viewed quote it re-stamps sent_at (re-send) without changing status.
-- ---------------------------------------------------------------------------
create function public.mark_quote_sent(p_quote_id uuid) returns public.quotes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_q   public.quotes;
  v_tz  text;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found or not public.is_shop_member(v_q.shop_id) then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_q.shop_id) then
    raise exception 'only owners, admins and managers can send quotes' using errcode = '42501';
  end if;
  if v_q.status not in ('draft', 'sent', 'viewed') then
    raise exception 'a % quote cannot be sent; revise it back to draft first', v_q.status using errcode = '22023';
  end if;
  if not exists (select 1 from public.quote_line_items li where li.quote_id = v_q.id and li.shop_id = v_q.shop_id) then
    raise exception 'add at least one line item before sending the quote' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.valid_until is not null and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    raise exception 'the quote''s valid-until date has passed; choose a later date' using errcode = '22023';
  end if;

  if v_q.status = 'draft' then
    update public.quotes set status = 'sent' where id = v_q.id returning * into v_q;
  else
    update public.quotes set sent_at = now() where id = v_q.id returning * into v_q;
  end if;
  return v_q;
end
$$;

-- ---------------------------------------------------------------------------
-- RPC: convert_quote_to_job — approved quote -> new job (source 'quote').
-- Copies the counted lines (non-optional + selected optional), discount,
-- tax rate, notes; links job.quote_id and quote.converted_job_id. With no
-- times the job is 'requested' (unscheduled), otherwise 'scheduled'.
-- ---------------------------------------------------------------------------
create function public.convert_quote_to_job(
  p_quote_id  uuid,
  p_start     timestamptz default null,
  p_end       timestamptz default null
) returns public.jobs
language plpgsql security definer
set search_path = ''
as $$
declare
  v_q    public.quotes;
  v_job  public.jobs;
  v_num  bigint;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found or not public.is_shop_member(v_q.shop_id) then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_q.shop_id) then
    raise exception 'only owners, admins and managers can convert quotes' using errcode = '42501';
  end if;
  if v_q.status = 'converted' then
    select j.number into v_num from public.jobs j where j.id = v_q.converted_job_id and j.shop_id = v_q.shop_id;
    raise exception 'this quote was already converted%', coalesce(' to job #' || v_num, '') using errcode = '22023';
  end if;
  if v_q.status <> 'approved' then
    raise exception 'only approved quotes can be converted (this one is %)', v_q.status using errcode = '22023';
  end if;
  if (p_start is null) <> (p_end is null) then
    raise exception 'provide both a start and an end time, or neither' using errcode = '22023';
  end if;
  if p_start is not null and p_end <= p_start then
    raise exception 'the end time must be after the start time' using errcode = '22023';
  end if;

  insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end,
                           notes, internal_notes, source, quote_id, discount_kind, discount_value, tax_rate_bps)
  values (v_q.shop_id, v_q.customer_id, v_q.vehicle_id,
          case when p_start is null then 'requested' else 'scheduled' end::public.job_status,
          p_start, p_end, v_q.notes, v_q.internal_notes, 'quote', v_q.id,
          v_q.discount_kind, v_q.discount_value, v_q.tax_rate_bps)
  returning * into v_job;

  insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, description, quantity,
                                     unit_price_cents, discount_cents, taxable, duration_minutes, sort)
  select v_q.shop_id, v_job.id, li.service_id, li.vehicle_id, li.name, li.description, li.quantity,
         li.unit_price_cents, li.discount_cents, li.taxable, li.duration_minutes,
         row_number() over (order by li.sort, li.created_at, li.id)::integer
  from public.quote_line_items li
  where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and (not li.optional or li.selected);

  update public.quotes set status = 'converted', converted_job_id = v_job.id where id = v_q.id;

  select * into v_job from public.jobs j where j.id = v_job.id;
  return v_job;
end
$$;

-- ---------------------------------------------------------------------------
-- expire_quotes (service_role / pg_cron): sent/viewed quotes whose validity
-- ended at or before p_now become expired (expired_at = p_now). Returns the
-- number of quotes expired. Idempotent.
-- ---------------------------------------------------------------------------
create function public.expire_quotes(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  with due as (
    select q.id
    from public.quotes q
    join public.shops s on s.id = q.shop_id
    where q.status in ('sent', 'viewed')
      and q.valid_until is not null
      and public.quote_validity_end(q.valid_until, s.timezone) <= p_now
    for update of q skip locked
  )
  update public.quotes q
     set status = 'expired', expired_at = p_now
    from due
   where q.id = due.id;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.quotes, public.quote_line_items from anon;

revoke execute on function
  public.quotes_client_guard(),
  public.quotes_integrity(),
  public.quotes_status_machine(),
  public.quotes_compute_totals(),
  public.quotes_validate(),
  public.jobs_quote_validate(),
  public.quote_line_items_client_guard(),
  public.quote_line_items_before_write(),
  public.quote_line_items_validate(),
  public.quote_line_items_touch_quote()
from public, anon, authenticated;

revoke execute on function
  public.mark_quote_sent(uuid),
  public.convert_quote_to_job(uuid, timestamptz, timestamptz)
from public, anon;
grant execute on function
  public.mark_quote_sent(uuid),
  public.convert_quote_to_job(uuid, timestamptz, timestamptz)
to authenticated, service_role;

revoke execute on function public.expire_quotes(timestamptz) from public, anon, authenticated;
grant execute on function public.expire_quotes(timestamptz) to service_role;
