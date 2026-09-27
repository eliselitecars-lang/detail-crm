-- ============================================================================
-- 0006 — Jobs (SPEC §4.4): job_status_transitions, jobs, job_line_items,
-- job_assignments, status machine, server-maintained totals, technician
-- restrictions and technician visibility of customers/vehicles.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Explicit status transition table (reference data, same for every shop).
--   forward  — any staff allowed to update the job (technicians only where
--              technician_allowed, and only on assigned jobs)
--   backward — owner/admin/manager only (corrections, reinstating)
-- ---------------------------------------------------------------------------
create table public.job_status_transitions (
  from_status         public.job_status not null,
  to_status           public.job_status not null,
  direction           text not null check (direction in ('forward', 'backward')),
  technician_allowed  boolean not null default false,
  primary key (from_status, to_status),
  constraint job_status_transitions_distinct check (from_status <> to_status),
  constraint job_status_transitions_tech_forward check (not technician_allowed or direction = 'forward')
);

insert into public.job_status_transitions (from_status, to_status, direction, technician_allowed) values
  -- forward
  ('requested',   'scheduled',   'forward',  false),
  ('requested',   'confirmed',   'forward',  false),
  ('requested',   'cancelled',   'forward',  false),
  ('scheduled',   'confirmed',   'forward',  false),
  ('scheduled',   'en_route',    'forward',  true),
  ('scheduled',   'in_progress', 'forward',  true),
  ('scheduled',   'completed',   'forward',  false),
  ('scheduled',   'cancelled',   'forward',  false),
  ('scheduled',   'no_show',     'forward',  false),
  ('confirmed',   'en_route',    'forward',  true),
  ('confirmed',   'in_progress', 'forward',  true),
  ('confirmed',   'completed',   'forward',  false),
  ('confirmed',   'cancelled',   'forward',  false),
  ('confirmed',   'no_show',     'forward',  false),
  ('en_route',    'in_progress', 'forward',  true),
  ('en_route',    'completed',   'forward',  false),
  ('en_route',    'cancelled',   'forward',  false),
  ('en_route',    'no_show',     'forward',  false),
  ('in_progress', 'completed',   'forward',  true),
  ('in_progress', 'cancelled',   'forward',  false),
  -- backward (manager+)
  ('scheduled',   'requested',   'backward', false),
  ('confirmed',   'requested',   'backward', false),
  ('confirmed',   'scheduled',   'backward', false),
  ('en_route',    'scheduled',   'backward', false),
  ('en_route',    'confirmed',   'backward', false),
  ('in_progress', 'scheduled',   'backward', false),
  ('in_progress', 'confirmed',   'backward', false),
  ('in_progress', 'en_route',    'backward', false),
  ('completed',   'in_progress', 'backward', false),
  ('cancelled',   'requested',   'backward', false),
  ('cancelled',   'scheduled',   'backward', false),
  ('cancelled',   'confirmed',   'backward', false),
  ('no_show',     'scheduled',   'backward', false),
  ('no_show',     'confirmed',   'backward', false);

-- Position on the main path (side exits have none).
create function public.job_status_rank(p_status public.job_status) returns integer
language sql immutable
set search_path = ''
as $$
  select case p_status
    when 'requested'   then 0
    when 'scheduled'   then 1
    when 'confirmed'   then 2
    when 'en_route'    then 3
    when 'in_progress' then 4
    when 'completed'   then 5
  end
$$;

-- ---------------------------------------------------------------------------
-- jobs
-- ---------------------------------------------------------------------------
create table public.jobs (
  id                      uuid primary key default gen_random_uuid(),
  shop_id                 uuid not null references public.shops (id) on delete cascade,
  number                  bigint not null,
  customer_id             uuid not null,
  vehicle_id              uuid,
  status                  public.job_status not null default 'scheduled',
  scheduled_start         timestamptz,
  scheduled_end           timestamptz,
  location_type           public.location_type not null default 'shop',
  service_address_line1   text check (service_address_line1 is null or char_length(service_address_line1) <= 200),
  service_address_line2   text check (service_address_line2 is null or char_length(service_address_line2) <= 200),
  service_city            text check (service_city is null or char_length(service_city) <= 100),
  service_region          text check (service_region is null or char_length(service_region) <= 100),
  service_postal_code     text check (service_postal_code is null or char_length(service_postal_code) <= 20),
  service_lat             double precision check (service_lat is null or service_lat between -90 and 90),
  service_lng             double precision check (service_lng is null or service_lng between -180 and 180),
  resource_id             uuid,
  notes                   text check (notes is null or char_length(notes) <= 20000),
  internal_notes          text check (internal_notes is null or char_length(internal_notes) <= 20000),
  source                  public.job_source not null default 'staff',
  quote_id                uuid,
  coupon_id               uuid,
  discount_kind           public.discount_kind not null default 'none',
  discount_value          bigint not null default 0,
  subtotal_cents          bigint not null default 0 check (subtotal_cents >= 0),
  discount_cents          bigint not null default 0 check (discount_cents >= 0),
  tax_rate_bps            integer not null check (tax_rate_bps between 0 and 10000),
  tax_cents               bigint not null default 0 check (tax_cents >= 0),
  total_cents             bigint not null default 0 check (total_cents >= 0),
  deposit_required_cents  bigint not null default 0 check (deposit_required_cents >= 0),
  public_token            uuid not null default gen_random_uuid() unique,
  created_by              uuid references auth.users (id) on delete set null,
  confirmed_at            timestamptz,
  en_route_at             timestamptz,
  started_at              timestamptz,
  completed_at            timestamptz,
  cancelled_at            timestamptz,
  cancel_reason           text check (cancel_reason is null or char_length(cancel_reason) <= 1000),
  reminder_sent_at        timestamptz,
  review_requested_at     timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint jobs_shop_id_id_key unique (shop_id, id),
  constraint jobs_shop_number_key unique (shop_id, number),
  constraint jobs_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete restrict,
  constraint jobs_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id),
  constraint jobs_resource_fk foreign key (shop_id, resource_id)
    references public.resources (shop_id, id) on delete set null (resource_id),
  constraint jobs_coupon_fk foreign key (shop_id, coupon_id)
    references public.coupons (shop_id, id) on delete set null (coupon_id),
  constraint jobs_schedule_pair check ((scheduled_start is null) = (scheduled_end is null)),
  constraint jobs_schedule_order check (scheduled_end > scheduled_start),
  constraint jobs_schedule_length check (scheduled_end - scheduled_start <= interval '31 days'),
  constraint jobs_schedule_required check (scheduled_start is not null or status in ('requested', 'cancelled')),
  constraint jobs_service_lat_lng_pair check ((service_lat is null) = (service_lng is null)),
  constraint jobs_discount_value check (
    discount_value >= 0
    and (discount_kind <> 'none' or discount_value = 0)
    and (discount_kind <> 'percent' or discount_value <= 10000)),
  constraint jobs_totals_consistent check (total_cents = subtotal_cents - discount_cents + tax_cents)
);
create index jobs_shop_start_idx on public.jobs (shop_id, scheduled_start);
create index jobs_shop_status_idx on public.jobs (shop_id, status);
create index jobs_shop_customer_idx on public.jobs (shop_id, customer_id);
create index jobs_shop_vehicle_idx on public.jobs (shop_id, vehicle_id);
create index jobs_shop_resource_idx on public.jobs (shop_id, resource_id);
create index jobs_shop_coupon_idx on public.jobs (shop_id, coupon_id);
create index jobs_shop_quote_idx on public.jobs (shop_id, quote_id);
create index jobs_created_by_idx on public.jobs (created_by);
create index jobs_shop_range_idx on public.jobs using gist (shop_id, tstzrange(scheduled_start, scheduled_end))
  where scheduled_start is not null;

comment on column public.jobs.quote_id is 'FK to quotes(shop_id, id) is added by the money migrations.';
comment on column public.jobs.subtotal_cents is 'Server-maintained from job_line_items (SPEC §4.5); client writes are ignored.';

-- ---------------------------------------------------------------------------
-- job_line_items
-- ---------------------------------------------------------------------------
create table public.job_line_items (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  job_id            uuid not null,
  service_id        uuid,
  vehicle_id        uuid,
  name              text not null check (char_length(btrim(name)) between 1 and 200),
  description       text check (description is null or char_length(description) <= 5000),
  quantity          numeric(10, 2) not null default 1 check (quantity > 0),
  unit_price_cents  bigint not null check (unit_price_cents >= 0),
  discount_cents    bigint not null default 0 check (discount_cents >= 0),
  taxable           boolean not null default true,
  duration_minutes  integer not null default 0 check (duration_minutes between 0 and 44640),
  sort              integer not null default 0,
  total_cents       bigint generated always as
                      (public.line_total_cents(quantity, unit_price_cents, discount_cents)) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint job_line_items_shop_id_id_key unique (shop_id, id),
  constraint job_line_items_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint job_line_items_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete set null (service_id),
  constraint job_line_items_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id)
);
create index job_line_items_shop_job_idx on public.job_line_items (shop_id, job_id, sort);
create index job_line_items_shop_service_idx on public.job_line_items (shop_id, service_id);
create index job_line_items_shop_vehicle_idx on public.job_line_items (shop_id, vehicle_id);

-- ---------------------------------------------------------------------------
-- job_assignments
-- ---------------------------------------------------------------------------
create table public.job_assignments (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  job_id      uuid not null,
  member_id   uuid not null,
  created_at  timestamptz not null default now(),
  constraint job_assignments_shop_id_id_key unique (shop_id, id),
  constraint job_assignments_job_member_key unique (shop_id, job_id, member_id),
  constraint job_assignments_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  -- NO ACTION (not cascade): assignments are the historical attribution of
  -- work, revenue and commission (report_team). Members with assignments are
  -- deactivated, not deleted; deleting the whole shop still works.
  constraint job_assignments_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id)
);
create index job_assignments_shop_member_idx on public.job_assignments (shop_id, member_id);

-- ---------------------------------------------------------------------------
-- Assignment / visibility helpers
-- ---------------------------------------------------------------------------
create function public.is_assigned_to_job(p_job_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.job_assignments ja
    join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
    where ja.job_id = p_job_id and m.user_id = auth.uid() and m.active)
$$;

create function public.is_customer_on_assigned_job(p_customer_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.jobs j
    join public.job_assignments ja on ja.job_id = j.id and ja.shop_id = j.shop_id
    join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
    where j.customer_id = p_customer_id and m.user_id = auth.uid() and m.active)
$$;

create function public.is_vehicle_on_assigned_job(p_vehicle_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.jobs j
    join public.job_assignments ja on ja.job_id = j.id and ja.shop_id = j.shop_id
    join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
    where m.user_id = auth.uid() and m.active
      and (j.vehicle_id = p_vehicle_id
           or exists (select 1 from public.job_line_items li
                      where li.job_id = j.id and li.vehicle_id = p_vehicle_id)))
$$;

-- ---------------------------------------------------------------------------
-- jobs triggers (fire in name order)
-- ---------------------------------------------------------------------------

-- 10: direct-write guard. Tokens/numbers are server-issued; automation
-- markers (reminder_sent_at, review_requested_at) are server-maintained;
-- technicians may change only status and internal_notes.
create function public.jobs_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed constant text[] := array['status', 'internal_notes', 'updated_at'];
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.public_token := gen_random_uuid();
    new.reminder_sent_at := null;
    new.review_requested_at := null;
    return new;
  end if;
  new.reminder_sent_at := old.reminder_sent_at;
  new.review_requested_at := old.review_requested_at;
  if new.number <> old.number then
    raise exception 'job numbers cannot be changed' using errcode = '42501';
  end if;
  if new.public_token <> old.public_token then
    raise exception 'job public_token cannot be changed' using errcode = '42501';
  end if;
  if public.shop_role_of(old.shop_id) = 'technician'
     and (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'technicians can only update the status and internal notes of assigned jobs'
      using errcode = '42501';
  end if;
  return new;
end
$$;

-- 20: numbering and server defaults.
create function public.jobs_integrity() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.number := public.next_document_number(new.shop_id, 'job');
    if new.tax_rate_bps is null then
      select s.tax_rate_bps into new.tax_rate_bps from public.shops s where s.id = new.shop_id;
    end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    new.number := old.number;
    new.created_by := public.audit_user_ref(new.created_by, old.created_by);
  end if;
  return new;
end
$$;

-- AFTER (runs once RLS, constraints and composite FKs have passed): the job's
-- vehicle belongs to the job's customer, and so do line-item vehicles.
create function public.jobs_validate() returns trigger
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
    raise exception 'the vehicle does not belong to this job''s customer' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id
     and exists (select 1 from public.job_line_items li
                 join public.vehicles v on v.id = li.vehicle_id and v.shop_id = li.shop_id
                 where li.job_id = new.id and li.shop_id = new.shop_id and v.customer_id <> new.customer_id) then
    raise exception 'line items reference vehicles of the previous customer; update them first'
      using errcode = '23514';
  end if;
  return null;
end
$$;

-- 30: status machine + timestamps.
create function public.jobs_status_machine() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_client  boolean := public.is_client_context();
  v_edge    public.job_status_transitions;
  v_role    public.shop_role;
  v_rank    integer;
begin
  if tg_op = 'INSERT' then
    if v_client then
      new.confirmed_at := null;
      new.en_route_at := null;
      new.started_at := null;
      new.completed_at := null;
      new.cancelled_at := null;
    end if;
    case new.status
      when 'confirmed'   then new.confirmed_at := coalesce(new.confirmed_at, now());
      when 'en_route'    then new.en_route_at  := coalesce(new.en_route_at, now());
      when 'in_progress' then new.started_at   := coalesce(new.started_at, now());
      when 'completed'   then new.completed_at := coalesce(new.completed_at, now());
      when 'cancelled'   then new.cancelled_at := coalesce(new.cancelled_at, now());
      else null;
    end case;
    if new.status = 'cancelled' then
      new.cancel_reason := nullif(btrim(new.cancel_reason), '');
    else
      new.cancel_reason := null;
    end if;
    return new;
  end if;

  if new.status = old.status then
    if v_client then
      new.confirmed_at := old.confirmed_at;
      new.en_route_at := old.en_route_at;
      new.started_at := old.started_at;
      new.completed_at := old.completed_at;
      new.cancelled_at := old.cancelled_at;
      if new.status = 'cancelled' then
        new.cancel_reason := nullif(btrim(new.cancel_reason), '');
      else
        new.cancel_reason := old.cancel_reason;
      end if;
    end if;
    return new;
  end if;

  select * into v_edge from public.job_status_transitions t
   where t.from_status = old.status and t.to_status = new.status;
  if not found then
    raise exception 'invalid job status transition: % -> %', old.status, new.status using errcode = '23514';
  end if;

  if v_client then
    v_role := public.shop_role_of(new.shop_id);
    if v_role is null then
      raise exception 'not a member of this shop' using errcode = '42501';
    elsif v_role = 'technician' and not v_edge.technician_allowed then
      raise exception 'technicians cannot move a job from % to %', old.status, new.status using errcode = '42501';
    end if;
    -- timestamps are never client-supplied
    new.confirmed_at := old.confirmed_at;
    new.en_route_at := old.en_route_at;
    new.started_at := old.started_at;
    new.completed_at := old.completed_at;
  end if;

  if v_edge.direction = 'backward' then
    v_rank := public.job_status_rank(new.status);
    if v_rank < 2 then new.confirmed_at := null; end if;
    if v_rank < 3 then new.en_route_at := null; end if;
    if v_rank < 4 then new.started_at := null; end if;
    if v_rank < 5 then new.completed_at := null; end if;
  end if;

  case new.status
    when 'confirmed' then
      new.confirmed_at := case when v_edge.direction = 'forward' then now() else coalesce(new.confirmed_at, now()) end;
    when 'en_route' then
      new.en_route_at := case when v_edge.direction = 'forward' then now() else coalesce(new.en_route_at, now()) end;
    when 'in_progress' then
      new.started_at := case when v_edge.direction = 'forward' then now() else coalesce(new.started_at, now()) end;
    when 'completed' then
      new.completed_at := now();
    else null;
  end case;

  if new.status = 'cancelled' then
    new.cancelled_at := now();
    new.cancel_reason := nullif(btrim(new.cancel_reason), '');
  else
    new.cancelled_at := null;
    new.cancel_reason := null;
  end if;
  return new;
end
$$;

-- 40: canonical totals from the job's line items (client values ignored).
create function public.jobs_compute_totals() returns trigger
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
              from public.job_line_items li
             where li.job_id = new.id and li.shop_id = new.shop_id),
           new.discount_kind, new.discount_value, new.tax_rate_bps);

  new.subtotal_cents := v_t.subtotal_cents;
  new.discount_cents := v_t.discount_cents;
  new.tax_cents := v_t.tax_cents;
  new.total_cents := v_t.total_cents;
  return new;
end
$$;

create trigger jobs_05_prevent_shop_change before update on public.jobs
  for each row execute function public.prevent_shop_change();
create trigger jobs_10_client_guard before insert or update on public.jobs
  for each row execute function public.jobs_client_guard();
create trigger jobs_20_integrity before insert or update on public.jobs
  for each row execute function public.jobs_integrity();
create trigger jobs_30_status_machine before insert or update on public.jobs
  for each row execute function public.jobs_status_machine();
create trigger jobs_40_compute_totals before insert or update on public.jobs
  for each row execute function public.jobs_compute_totals();
create trigger jobs_90_set_updated_at before update on public.jobs
  for each row execute function public.set_updated_at();
create trigger jobs_validate after insert or update on public.jobs
  for each row execute function public.jobs_validate();

-- ---------------------------------------------------------------------------
-- job_line_items triggers
-- ---------------------------------------------------------------------------
-- Line name defaults to the service name (same shop only).
create function public.job_line_items_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.name is null and new.service_id is not null then
    select s.name into new.name from public.services s where s.id = new.service_id and s.shop_id = new.shop_id;
  end if;
  return new;
end
$$;

-- AFTER: a line's vehicle belongs to the job's customer.
create function public.job_line_items_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id or new.job_id is distinct from old.job_id)
     and not exists (select 1
                     from public.jobs j
                     join public.vehicles v on v.customer_id = j.customer_id and v.shop_id = j.shop_id
                     where j.id = new.job_id and j.shop_id = new.shop_id and v.id = new.vehicle_id) then
    raise exception 'the vehicle does not belong to this job''s customer' using errcode = '23514';
  end if;
  return null;
end
$$;

-- Recompute the parent job(s) by touching them; jobs_compute_totals does
-- the math so it lives in exactly one place.
create function public.job_line_items_touch_job() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.jobs set updated_at = now() where id = old.job_id and shop_id = old.shop_id;
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.job_id is distinct from old.job_id) then
    update public.jobs set updated_at = now() where id = new.job_id and shop_id = new.shop_id;
  end if;
  return null;
end
$$;

create trigger job_line_items_05_prevent_shop_change before update on public.job_line_items
  for each row execute function public.prevent_shop_change();
create trigger job_line_items_20_before_write before insert or update on public.job_line_items
  for each row execute function public.job_line_items_before_write();
create trigger job_line_items_90_set_updated_at before update on public.job_line_items
  for each row execute function public.set_updated_at();
create trigger job_line_items_touch_job after insert or update or delete on public.job_line_items
  for each row execute function public.job_line_items_touch_job();
create trigger job_line_items_validate after insert or update on public.job_line_items
  for each row execute function public.job_line_items_validate();

-- ---------------------------------------------------------------------------
-- job_assignments triggers
-- ---------------------------------------------------------------------------
create function public.job_assignments_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members m
                 where m.id = new.member_id and m.shop_id = new.shop_id and m.active) then
    raise exception 'only active team members can be assigned to jobs' using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger job_assignments_05_prevent_shop_change before update on public.job_assignments
  for each row execute function public.prevent_shop_change();
create trigger job_assignments_validate after insert or update on public.job_assignments
  for each row execute function public.job_assignments_validate();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.job_status_transitions enable row level security;
alter table public.jobs                   enable row level security;
alter table public.job_line_items         enable row level security;
alter table public.job_assignments        enable row level security;

create policy job_status_transitions_select on public.job_status_transitions for select to authenticated
  using (true);

-- jobs: managers+ everything; technicians read/update assigned jobs (the
-- guard trigger limits which columns and transitions).
create policy jobs_select on public.jobs for select to authenticated
  using (public.is_shop_manager(shop_id) or public.is_assigned_to_job(id));
create policy jobs_insert on public.jobs for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy jobs_update_staff on public.jobs for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy jobs_update_assigned on public.jobs for update to authenticated
  using (public.is_assigned_to_job(id)) with check (public.is_assigned_to_job(id));
create policy jobs_delete on public.jobs for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy job_line_items_select on public.job_line_items for select to authenticated
  using (public.is_shop_manager(shop_id) or public.is_assigned_to_job(job_id));
create policy job_line_items_insert on public.job_line_items for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy job_line_items_update on public.job_line_items for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy job_line_items_delete on public.job_line_items for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy job_assignments_select on public.job_assignments for select to authenticated
  using (public.is_shop_manager(shop_id) or public.is_assigned_to_job(job_id));
create policy job_assignments_insert on public.job_assignments for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy job_assignments_update on public.job_assignments for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy job_assignments_delete on public.job_assignments for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- Technicians: read-only access to customers/vehicles on their assigned jobs.
create policy customers_select_assigned on public.customers for select to authenticated
  using (public.is_shop_member(shop_id) and public.is_customer_on_assigned_job(id));
create policy vehicles_select_assigned on public.vehicles for select to authenticated
  using (public.is_shop_member(shop_id) and public.is_vehicle_on_assigned_job(id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.job_status_transitions, public.jobs, public.job_line_items, public.job_assignments
  from anon;
revoke insert, update, delete, truncate on public.job_status_transitions from authenticated;

revoke execute on function
  public.jobs_client_guard(),
  public.jobs_integrity(),
  public.jobs_status_machine(),
  public.jobs_compute_totals(),
  public.jobs_validate(),
  public.job_line_items_before_write(),
  public.job_line_items_validate(),
  public.job_line_items_touch_job(),
  public.job_assignments_validate()
from public, anon, authenticated;

revoke execute on function
  public.is_assigned_to_job(uuid),
  public.is_customer_on_assigned_job(uuid),
  public.is_vehicle_on_assigned_job(uuid)
from public, anon;
grant execute on function
  public.is_assigned_to_job(uuid),
  public.is_customer_on_assigned_job(uuid),
  public.is_vehicle_on_assigned_job(uuid)
to authenticated, service_role;
